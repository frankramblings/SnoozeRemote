import Foundation
import MediaPlayer
import AVFoundation
import UIKit

final class MediaController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = MediaController()

    private let audioSession = AVAudioSession.sharedInstance()
    private var volumeSlider: UISlider?

    // Phase 1: looping silent player (mixWithOthers, keeps app alive)
    private var mixingPlayer: AVAudioPlayer?
    // Phase 2: fixed-length exclusive player (interrupts other audio)
    private var exclusivePlayer: AVAudioPlayer?
    // One-shot timer to trigger Phase 1 → Phase 2 transition
    private var transitionTimer: DispatchSourceTimer?
    // Fade timer for volume reduction
    private var fadeTimer: Timer?
    private var originalVolume: Float = 1.0

    // Observable state
    @Published var isTimerActive = false
    @Published var fadeOutEnabled = true
    var endDate: Date?

    /// Called when the timer completes (audio interrupted). PhoneSessionManager uses this.
    var onTimerCompleted: (() -> Void)?

    private override init() {
        super.init()
        setupVolumeSlider()
    }

    private func setupVolumeSlider() {
        DispatchQueue.main.async { [weak self] in
            let volumeView = MPVolumeView(frame: .zero)
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first {
                volumeView.alpha = 0.01
                window.addSubview(volumeView)
            }
            self?.volumeSlider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider
        }
    }

    // MARK: - Public API

    func startSleepTimer(durationMinutes: Int, fadeOut: Bool) {
        cancel()

        let duration = TimeInterval(durationMinutes * 60)
        endDate = Date().addingTimeInterval(duration)
        fadeOutEnabled = fadeOut

        DispatchQueue.main.async {
            self.isTimerActive = true
        }

        // Phase 1: start mixing silent audio to keep app alive
        startPhase1()

        // Schedule the Phase 2 transition
        let fadeSeconds = fadeOut ? AppConstants.fadeOutDurationSeconds : 1.0
        let transitionDelay = max(1, duration - fadeSeconds)
        scheduleTransition(after: transitionDelay)
    }

    func addTime(minutes: Int) {
        guard isTimerActive, let end = endDate else { return }
        let additional = TimeInterval(minutes * 60)
        let newEnd = end.addingTimeInterval(additional)
        endDate = newEnd

        // Reschedule the transition timer
        transitionTimer?.cancel()
        transitionTimer = nil
        let remaining = newEnd.timeIntervalSinceNow
        let fadeSeconds = fadeOutEnabled ? AppConstants.fadeOutDurationSeconds : 1.0
        let transitionDelay = max(1, remaining - fadeSeconds)
        scheduleTransition(after: transitionDelay)
    }

    func cancel() {
        transitionTimer?.cancel()
        transitionTimer = nil
        fadeTimer?.invalidate()
        fadeTimer = nil

        mixingPlayer?.stop()
        mixingPlayer = nil
        exclusivePlayer?.stop()
        exclusivePlayer = nil

        endDate = nil

        // Restore volume if we were mid-fade
        if let slider = volumeSlider, originalVolume > 0 {
            DispatchQueue.main.async {
                slider.value = self.originalVolume
            }
        }

        // notifyOthersOnDeactivation so the user's music can resume after cancel
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)

        DispatchQueue.main.async {
            self.isTimerActive = false
        }
    }

    var isMediaPlaying: Bool {
        audioSession.isOtherAudioPlaying
    }

    // MARK: - Phase 1: Coexist

    private func startPhase1() {
        try? audioSession.setCategory(.playback, mode: .default, options: .mixWithOthers)
        try? audioSession.setActive(true)

        // 1-second looping silent track
        guard let data = generateSilentWAV(durationSeconds: 1) else { return }
        do {
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = -1
            player.volume = 0
            player.play()
            mixingPlayer = player
        } catch {
            print("SnoozeRemote: Phase 1 audio failed - \(error)")
        }
    }

    // MARK: - Transition to Phase 2

    private func scheduleTransition(after delay: TimeInterval) {
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        source.schedule(deadline: .now() + delay)
        source.setEventHandler { [weak self] in
            self?.beginPhase2()
        }
        source.resume()
        transitionTimer = source
    }

    private func beginPhase2() {
        guard let end = endDate else { return }
        let remaining = max(1, end.timeIntervalSinceNow)

        // Capture volume for restore later
        if let slider = volumeSlider {
            DispatchQueue.main.async {
                self.originalVolume = slider.value
            }
        }

        if fadeOutEnabled, let slider = volumeSlider {
            // Fade volume while STAYING in Phase 1 (mixing mode).
            // The mixing player keeps running so the user's audio is uninterrupted.
            // Only after the fade completes do we switch to exclusive mode.
            let steps = 30
            let stepDuration = min(remaining, AppConstants.fadeOutDurationSeconds) / Double(steps)
            var currentStep = 0
            DispatchQueue.main.async {
                self.fadeTimer = Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { [weak self] timer in
                    guard let self = self else { timer.invalidate(); return }
                    currentStep += 1
                    let newVolume = max(0, self.originalVolume - (self.originalVolume / Float(steps)) * Float(currentStep))
                    slider.value = newVolume
                    if currentStep >= steps {
                        timer.invalidate()
                        self.fadeTimer = nil
                        // Fade done — now interrupt
                        self.interruptOtherAudio()
                    }
                }
            }
        } else {
            // No fade — interrupt immediately
            interruptOtherAudio()
        }
    }

    /// Stops the mixing player, switches to exclusive audio session, and plays
    /// a short silent track whose completion triggers the delegate callback.
    private func interruptOtherAudio() {
        // Stop Phase 1 mixing player
        mixingPlayer?.stop()
        mixingPlayer = nil

        // Switch to exclusive session (this interrupts other audio)
        try? audioSession.setCategory(.playback, mode: .default)
        try? audioSession.setActive(true)

        // Play a 1-second exclusive silent track.
        // When it finishes, audioPlayerDidFinishPlaying fires.
        guard let data = generateSilentWAV(durationSeconds: 1) else { return }
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.volume = 0
            player.play()
            exclusivePlayer = player
        } catch {
            print("SnoozeRemote: Phase 2 audio failed - \(error)")
        }
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === exclusivePlayer else { return }
        exclusivePlayer = nil

        // Deactivate WITHOUT notifyOthersOnDeactivation — other apps stay paused
        try? audioSession.setActive(false)

        // Restore volume
        if let slider = volumeSlider {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                slider.value = self?.originalVolume ?? 0.5
            }
        }

        DispatchQueue.main.async {
            self.isTimerActive = false
            self.endDate = nil
        }

        onTimerCompleted?()
    }

    // MARK: - Silent WAV Generator

    private func generateSilentWAV(durationSeconds: Int) -> Data? {
        let sampleRate: UInt32 = 8000
        let bitsPerSample: UInt16 = 16
        let numChannels: UInt16 = 1
        let bytesPerSample = UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let dataSize = sampleRate * bytesPerSample * UInt32(durationSeconds)
        let fileSize: UInt32 = 36 + dataSize

        var d = Data()
        d.reserveCapacity(Int(44 + dataSize))
        d.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        d.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        d.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        d.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        d.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        d.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        d.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        d.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        let byteRate = sampleRate * bytesPerSample
        d.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        let blockAlign = UInt16(bytesPerSample)
        d.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        d.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        d.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        d.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        d.append(Data(count: Int(dataSize)))
        return d
    }
}
