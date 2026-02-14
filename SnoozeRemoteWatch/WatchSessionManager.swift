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

    /// Tracks whether the phone is actively sending timer updates.
    /// When true, we let the phone drive `remainingSeconds` instead of the fallback.
    private var receivingPhoneUpdates = false
    private var lastPhoneUpdateDate: Date?

    // MARK: - Local fallback timer (always runs for display)

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
        receivingPhoneUpdates = false

        let message: [String: Any] = [
            MessageKey.command: TimerCommand.start.rawValue,
            MessageKey.duration: minutes,
            MessageKey.fadeOutEnabled: fadeOutEnabled
        ]
        sendMessage(message)

        // Also send via applicationContext so the phone gets it even if not currently reachable
        sendApplicationContext(message)

        // Guaranteed delivery via transferUserInfo
        sendUserInfo(message)

        // Always start the local countdown for display
        startFallbackTimer(duration: duration)
    }

    func cancelTimer() {
        isTimerActive = false
        remainingSeconds = 0
        totalDuration = 0
        receivingPhoneUpdates = false
        stopFallbackTimer()

        let message: [String: Any] = [
            MessageKey.command: TimerCommand.cancel.rawValue
        ]
        sendMessage(message)
        sendApplicationContext(message)
        sendUserInfo(message)
    }

    func addTime(minutes: Int) {
        let additionalSeconds = TimeInterval(minutes * 60)
        totalDuration += additionalSeconds
        remainingSeconds += additionalSeconds

        // Update fallback timer
        if let end = fallbackEndDate {
            fallbackEndDate = end.addingTimeInterval(additionalSeconds)
        }

        let message: [String: Any] = [
            MessageKey.command: TimerCommand.addTime.rawValue,
            MessageKey.duration: minutes
        ]
        sendMessage(message)
        sendApplicationContext(message)
        sendUserInfo(message)
    }

    func dismissCompletion() {
        showCompletion = false
    }

    // MARK: - Fallback Timer

    /// A local timer on the Watch that always counts down for display purposes.
    /// If the phone is actively sending updates, those override the local value.
    private func startFallbackTimer(duration: TimeInterval) {
        stopFallbackTimer()
        fallbackEndDate = Date().addingTimeInterval(duration)

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let end = self.fallbackEndDate else { return }
            let remaining = end.timeIntervalSinceNow
            if remaining <= 0 {
                self.timerDidFire()
            } else {
                // If the phone sent an update within the last 3 seconds,
                // let it drive the display. Otherwise use local countdown.
                let phoneIsActive: Bool
                if let lastUpdate = self.lastPhoneUpdateDate {
                    phoneIsActive = Date().timeIntervalSince(lastUpdate) < 3
                } else {
                    phoneIsActive = false
                }

                if !phoneIsActive {
                    self.remainingSeconds = remaining
                }
            }
        }
        // Add to .common mode so it fires during Digital Crown interaction
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    private func stopFallbackTimer() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        fallbackEndDate = nil
    }

    private func timerDidFire() {
        stopFallbackTimer()
        isTimerActive = false
        remainingSeconds = 0
        showCompletion = true
    }

    // MARK: - Send Message

    private func sendMessage(_ message: [String: Any]) {
        guard let session = session, session.isReachable else {
            DispatchQueue.main.async { [weak self] in
                self?.isPhoneReachable = false
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.isPhoneReachable = true
        }
        session.sendMessage(message, replyHandler: nil) { error in
            print("SnoozeRemote Watch: Send failed - \(error.localizedDescription)")
        }
    }

    /// Sends command via applicationContext as a backup delivery mechanism.
    /// Unlike sendMessage, this is queued and delivered when the counterpart app launches.
    private func sendApplicationContext(_ message: [String: Any]) {
        guard let session = session else { return }
        // Add a timestamp so the phone can tell if the context is stale
        var context = message
        context["timestamp"] = Date().timeIntervalSince1970
        try? session.updateApplicationContext(context)
    }

    /// Sends command via transferUserInfo as a guaranteed delivery mechanism.
    /// Queued and delivered even if the counterpart app is not currently reachable.
    private func sendUserInfo(_ message: [String: Any]) {
        guard let session = session else { return }
        var info = message
        info["timestamp"] = Date().timeIntervalSince1970
        session.transferUserInfo(info)
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
                    self.receivingPhoneUpdates = true
                    self.lastPhoneUpdateDate = Date()
                    // Sync fallback timer to phone's value
                    self.fallbackEndDate = Date().addingTimeInterval(remaining)
                }

            case .timerFired:
                self.timerDidFire()

            case .statusResponse:
                if let remaining = message[MessageKey.remainingTime] as? TimeInterval, remaining > 0 {
                    self.remainingSeconds = remaining
                    self.isTimerActive = true
                    // Sync fallback
                    self.fallbackEndDate = Date().addingTimeInterval(remaining)
                }
                if let playing = message[MessageKey.isPlaying] as? Bool {
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
