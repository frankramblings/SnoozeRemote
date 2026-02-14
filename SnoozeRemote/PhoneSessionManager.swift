import Foundation
import WatchConnectivity
import Combine

/// iPhone-side WatchConnectivity manager.
/// Receives commands from the Watch and manages the timer as the source of truth.
final class PhoneSessionManager: NSObject, ObservableObject {
    static let shared = PhoneSessionManager()

    let timerManager = TimerManager.shared
    private var session: WCSession?

    private override init() {
        super.init()
        setupSession()
        setupTimerCallbacks()
    }

    // MARK: - Session Setup

    private func setupSession() {
        guard WCSession.isSupported() else { return }
        session = WCSession.default
        session?.delegate = self
        session?.activate()
    }

    private func setupTimerCallbacks() {
        timerManager.onTimerUpdate = { [weak self] remaining in
            self?.sendTimerUpdate(remaining: remaining)
        }
        timerManager.onTimerCompleted = { [weak self] in
            self?.sendMessage([
                MessageKey.command: TimerCommand.timerFired.rawValue
            ])
        }
    }

    // MARK: - Send Messages

    private func sendTimerUpdate(remaining: TimeInterval) {
        sendMessage([
            MessageKey.command: TimerCommand.timerUpdate.rawValue,
            MessageKey.remainingTime: remaining
        ])
    }

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

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            switch command {
            case .start:
                let minutes = message[MessageKey.duration] as? Int ?? 30
                let fadeOut = message[MessageKey.fadeOutEnabled] as? Bool ?? true
                self.timerManager.startTimer(durationMinutes: minutes, fadeOut: fadeOut)

            case .cancel:
                self.timerManager.stopTimer()

            case .addTime:
                let minutes = message[MessageKey.duration] as? Int ?? AppConstants.addTimeMinutes
                self.timerManager.addTime(minutes: minutes)

            case .queryStatus:
                let isPlaying = MediaController.shared.isMediaPlaying
                self.sendMessage([
                    MessageKey.command: TimerCommand.statusResponse.rawValue,
                    MessageKey.isPlaying: isPlaying,
                    MessageKey.remainingTime: self.timerManager.remainingSeconds
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
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for subsequent connections
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleCommand(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handleCommand(message)
        replyHandler(["status": "received"])
    }
}
