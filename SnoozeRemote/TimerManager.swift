import Foundation
import Combine

/// iPhone-side timer that serves as the source of truth.
/// Even if the Watch disconnects, this timer continues running and will
/// pause media when it expires.
final class TimerManager: ObservableObject {
    static let shared = TimerManager()

    @Published var isTimerActive = false
    @Published var remainingSeconds: TimeInterval = 0
    @Published var fadeOutEnabled = true

    private var timer: Timer?
    private var endDate: Date?
    private let mediaController = MediaController.shared

    /// Called when the Watch sends a start command.
    var onTimerUpdate: ((TimeInterval) -> Void)?
    /// Called when the timer fires and media is stopped.
    var onTimerCompleted: (() -> Void)?

    private init() {}

    // MARK: - Timer Control

    func startTimer(durationMinutes: Int, fadeOut: Bool = true) {
        stopTimer(notify: false)

        fadeOutEnabled = fadeOut
        let duration = TimeInterval(durationMinutes * 60)
        endDate = Date().addingTimeInterval(duration)
        remainingSeconds = duration
        isTimerActive = true

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    func addTime(minutes: Int) {
        guard isTimerActive, let end = endDate else { return }
        let newEnd = end.addingTimeInterval(TimeInterval(minutes * 60))
        endDate = newEnd
        remainingSeconds = newEnd.timeIntervalSinceNow
    }

    func stopTimer(notify: Bool = true) {
        timer?.invalidate()
        timer = nil
        endDate = nil
        isTimerActive = false
        remainingSeconds = 0
        mediaController.cancelFadeOut()

        if notify {
            onTimerCompleted?()
        }
    }

    // MARK: - Tick

    private func tick() {
        guard let end = endDate else {
            stopTimer()
            return
        }

        remainingSeconds = max(0, end.timeIntervalSinceNow)
        onTimerUpdate?(remainingSeconds)

        // Begin fade-out during the final 30 seconds
        if fadeOutEnabled && remainingSeconds <= AppConstants.fadeOutDurationSeconds && remainingSeconds > 0 {
            if mediaController.isMediaPlaying {
                mediaController.fadeOutAndPause(duration: remainingSeconds) { [weak self] in
                    self?.stopTimer()
                }
                // Cancel the repeating timer since fade handles completion
                timer?.invalidate()
                timer = nil
                return
            }
        }

        if remainingSeconds <= 0 {
            // Timer expired without fade — pause immediately
            mediaController.pauseMedia()
            stopTimer()
        }
    }
}
