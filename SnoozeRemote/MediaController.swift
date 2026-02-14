import Foundation
import MediaPlayer
import AVFoundation

/// Controls the iPhone's global media session and system volume.
final class MediaController {
    static let shared = MediaController()

    private let audioSession = AVAudioSession.sharedInstance()
    private var fadeTimer: Timer?
    private var originalVolume: Float = 1.0

    private init() {
        try? audioSession.setCategory(.playback, mode: .default)
        try? audioSession.setActive(true)
    }

    // MARK: - Now Playing Detection

    /// Returns true if any app is currently playing audio.
    var isMediaPlaying: Bool {
        audioSession.isOtherAudioPlaying
    }

    // MARK: - Pause Command

    /// Sends a system-level pause command via MPRemoteCommandCenter.
    func pauseMedia() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.pauseCommand.isEnabled = true
        // Trigger the system Now Playing pause
        MPNowPlayingInfoCenter.default().playbackState = .paused
    }

    // MARK: - Fade Out

    /// Gradually reduces the system volume over the given duration, then pauses.
    func fadeOutAndPause(duration: TimeInterval = AppConstants.fadeOutDurationSeconds, completion: (() -> Void)? = nil) {
        fadeTimer?.invalidate()

        let volumeView = MPVolumeView()
        guard let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider else {
            // Fallback: just pause immediately
            pauseMedia()
            completion?()
            return
        }

        originalVolume = slider.value
        let steps = 30
        let stepDuration = duration / Double(steps)
        let volumeDecrement = originalVolume / Float(steps)
        var currentStep = 0

        fadeTimer = Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { [weak self] timer in
            currentStep += 1
            let newVolume = max(0, self?.originalVolume ?? 1.0 - volumeDecrement * Float(currentStep))
            slider.value = newVolume

            if currentStep >= steps {
                timer.invalidate()
                self?.fadeTimer = nil
                self?.pauseMedia()
                // Restore volume after a brief delay so next playback isn't silent
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    slider.value = self?.originalVolume ?? 0.5
                }
                completion?()
            }
        }
    }

    /// Cancels any in-progress fade-out.
    func cancelFadeOut() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }
}
