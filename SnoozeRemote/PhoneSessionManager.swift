import Foundation
import WatchConnectivity
import Combine

final class PhoneSessionManager: NSObject, ObservableObject {
    static let shared = PhoneSessionManager()

    let mediaController = MediaController.shared
    private var session: WCSession?
    /// Tracks the last command timestamp to deduplicate across delivery methods.
    private var lastProcessedTimestamp: TimeInterval = 0

    private override init() {
        super.init()
        setupSession()
        setupCallbacks()
    }

    private func setupSession() {
        guard WCSession.isSupported() else { return }
        session = WCSession.default
        session?.delegate = self
        session?.activate()
    }

    private func setupCallbacks() {
        mediaController.onTimerCompleted = { [weak self] in
            self?.sendMessage([
                MessageKey.command: TimerCommand.timerFired.rawValue
            ])
        }
    }

    // MARK: - Send Messages

    private func sendMessage(_ message: [String: Any]) {
        guard let session = session, session.isReachable else { return }
        session.sendMessage(message, replyHandler: nil) { error in
            print("SnoozeRemote: Failed to send message - \(error.localizedDescription)")
        }
    }

    // MARK: - Handle Incoming Commands

    private func handleCommand(_ message: [String: Any]) {
        guard let rawCommand = message[MessageKey.command] as? String,
              let command = TimerCommand(rawValue: rawCommand) else { return }

        // Deduplicate: skip if we already processed this exact timestamp
        if let ts = message["timestamp"] as? TimeInterval, ts <= lastProcessedTimestamp {
            return
        }
        if let ts = message["timestamp"] as? TimeInterval {
            lastProcessedTimestamp = ts
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            switch command {
            case .start:
                let minutes = message[MessageKey.duration] as? Int ?? 30
                let fadeOut = message[MessageKey.fadeOutEnabled] as? Bool ?? true
                self.mediaController.startSleepTimer(durationMinutes: minutes, fadeOut: fadeOut)

            case .cancel:
                self.mediaController.cancel()

            case .addTime:
                let minutes = message[MessageKey.duration] as? Int ?? AppConstants.addTimeMinutes
                self.mediaController.addTime(minutes: minutes)

            case .queryStatus:
                let remaining = self.mediaController.endDate?.timeIntervalSinceNow ?? 0
                self.sendMessage([
                    MessageKey.command: TimerCommand.statusResponse.rawValue,
                    MessageKey.isPlaying: self.mediaController.isMediaPlaying,
                    MessageKey.remainingTime: max(0, remaining)
                ])

            default:
                break
            }
        }
    }
}

// MARK: - WCSessionDelegate

extension PhoneSessionManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("SnoozeRemote: WCSession activation failed - \(error.localizedDescription)")
        }
        if activationState == .activated {
            let context = session.receivedApplicationContext
            if !context.isEmpty {
                handleCommand(context)
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleCommand(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handleCommand(message)
        replyHandler(["status": "received"])
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleCommand(applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleCommand(userInfo)
    }
}
