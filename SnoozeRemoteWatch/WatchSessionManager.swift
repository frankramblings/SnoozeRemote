import Foundation
import WatchConnectivity
import WatchKit

/// Watch-side session manager.
/// The Watch is the remote control; the iPhone is the source of truth for the timer.
/// If the Watch loses connectivity, the iPhone continues independently.
final class WatchSessionManager: NSObject, ObservableObject {
    static let shared = WatchSessionManager()

    // MARK: - Published State

    @Published var isTimerActive = false
    @Published var remainingSeconds: TimeInterval = 0
    @Published var totalDuration: TimeInterval = 0
    @Published var showCompletion = false
    @Published var isPhoneReachable = false
    @Published var fadeOutEnabled = true

    /// Used for Digital Crown scrubbing on the active timer view.
    @Published var crownValue: Double = 0

    private var session: WCSession?

    // MARK: - Local fallback timer (runs if phone disconnects)

    private var fallbackTimer: Timer?
    private var fallbackEndDate: Date?

    private override init() {
        super.init()
        setupSession()
    }

    // MARK: - Session Setup

    private func setupSession() {
        guard WCSession.isSupported() else { return }
        session = WCSession.default
        session?.delegate = self
        session?.activate()
    }

    // MARK: - Timer Commands

    func startTimer(minutes: Int) {
        let duration = TimeInterval(minutes * 60)
        totalDuration = duration
        remainingSeconds = duration
        crownValue = duration
        isTimerActive = true
        showCompletion = false

        sendMessage([
            MessageKey.command: TimerCommand.start.rawValue,
            MessageKey.duration: minutes,
            MessageKey.fadeOutEnabled: fadeOutEnabled
        ])

        // Start a local fallback timer in case the phone becomes unreachable
        startFallbackTimer(duration: duration)
    }

    func cancelTimer() {
        isTimerActive = false
        remainingSeconds = 0
        totalDuration = 0
        stopFallbackTimer()

        sendMessage([
            MessageKey.command: TimerCommand.cancel.rawValue
        ])
    }

    func addTime(minutes: Int) {
        let additionalSeconds = TimeInterval(minutes * 60)
        totalDuration += additionalSeconds
        remainingSeconds += additionalSeconds

        // Update fallback timer
        if let end = fallbackEndDate {
            fallbackEndDate = end.addingTimeInterval(additionalSeconds)
        }

        sendMessage([
            MessageKey.command: TimerCommand.addTime.rawValue,
            MessageKey.duration: minutes
        ])
    }

    func dismissCompletion() {
        showCompletion = false
    }

    // MARK: - Fallback Timer

    /// A local timer on the Watch as a fallback display when the phone
    /// can't send updates. The phone remains the actual source of truth
    /// for pausing media.
    private func startFallbackTimer(duration: TimeInterval) {
        stopFallbackTimer()
        fallbackEndDate = Date().addingTimeInterval(duration)

        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let end = self.fallbackEndDate else { return }
            DispatchQueue.main.async {
                let remaining = end.timeIntervalSinceNow
                if remaining <= 0 {
                    self.timerDidFire()
                } else {
                    // Only use fallback value if the phone isn't sending updates
                    if self.session?.isReachable != true {
                        self.remainingSeconds = remaining
                    }
                }
            }
        }
    }

    private func stopFallbackTimer() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        fallbackEndDate = nil
    }

    private func timerDidFire() {
        stopFallbackTimer()
        DispatchQueue.main.async {
            self.isTimerActive = false
            self.remainingSeconds = 0
            self.showCompletion = true
        }
    }

    // MARK: - Send Message

    private func sendMessage(_ message: [String: Any]) {
        guard let session = session, session.isReachable else {
            isPhoneReachable = false
            return
        }
        isPhoneReachable = true
        session.sendMessage(message, replyHandler: nil) { error in
            print("SnoozeRemote Watch: Send failed - \(error.localizedDescription)")
        }
    }

    // MARK: - Handle Incoming Messages

    private func handleMessage(_ message: [String: Any]) {
        guard let rawCommand = message[MessageKey.command] as? String,
              let command = TimerCommand(rawValue: rawCommand) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            switch command {
            case .timerUpdate:
                if let remaining = message[MessageKey.remainingTime] as? TimeInterval {
                    self.remainingSeconds = remaining
                }

            case .timerFired:
                self.timerDidFire()

            case .statusResponse:
                if let remaining = message[MessageKey.remainingTime] as? TimeInterval, remaining > 0 {
                    self.remainingSeconds = remaining
                    self.isTimerActive = true
                }
                if let playing = message[MessageKey.isPlaying] as? Bool {
                    // Could be used for UI indication
                    _ = playing
                }

            default:
                break
            }
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isPhoneReachable = session.isReachable
        }
        if activationState == .activated {
            // Query iPhone for current timer status on launch
            sendMessage([MessageKey.command: TimerCommand.queryStatus.rawValue])
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isPhoneReachable = session.isReachable
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleMessage(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handleMessage(message)
        replyHandler(["status": "received"])
    }
}
