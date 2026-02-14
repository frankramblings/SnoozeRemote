# Scheduled Silent Audio Player Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the fragile timer+background-task architecture with a two-phase silent audio player that uses iOS's audio background mode as the timer mechanism itself.

**Architecture:** Phase 1 plays looping silent audio with `.mixWithOthers` to keep the app alive while the user's music plays. A single one-shot DispatchSourceTimer fires to trigger Phase 2, which switches to an exclusive (non-mixing) fixed-length silent track that interrupts other audio. When the track ends, the delegate callback deactivates the session — other apps stay paused.

**Tech Stack:** AVAudioPlayer, AVAudioSession, WatchConnectivity, SwiftUI

---

### Task 1: Rewrite MediaController with two-phase audio

**Files:**
- Rewrite: `SnoozeRemote/MediaController.swift`

**Step 1: Write the new MediaController**

Replace the entire file with the two-phase implementation. MediaController becomes an `NSObject` subclass to conform to `AVAudioPlayerDelegate`. It is also `ObservableObject` so ContentView can observe `isTimerActive` and `endDate`.

```swift
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

        // Fade volume if enabled
        if fadeOutEnabled, let slider = volumeSlider {
            DispatchQueue.main.async {
                self.originalVolume = slider.value
            }
            let steps = 30
            let stepDuration = min(remaining, AppConstants.fadeOutDurationSeconds) / Double(steps)
            var currentStep = 0
            fadeTimer = Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { [weak self] timer in
                guard let self = self else { timer.invalidate(); return }
                currentStep += 1
                let newVolume = max(0, self.originalVolume - (self.originalVolume / Float(steps)) * Float(currentStep))
                DispatchQueue.main.async {
                    self.volumeSlider?.value = newVolume
                }
                if currentStep >= steps {
                    timer.invalidate()
                    self.fadeTimer = nil
                }
            }
        } else {
            // Capture volume for restore later even without fade
            if let slider = volumeSlider {
                originalVolume = slider.value
            }
        }

        // Stop Phase 1 mixing player
        mixingPlayer?.stop()
        mixingPlayer = nil

        // Switch to exclusive session (this interrupts other audio)
        try? audioSession.setCategory(.playback, mode: .default)
        try? audioSession.setActive(true)

        // Play a fixed-length silent track for the remaining duration.
        // When it finishes, audioPlayerDidFinishPlaying fires.
        let exclusiveDuration = max(1, Int(ceil(remaining)))
        guard let data = generateSilentWAV(durationSeconds: exclusiveDuration) else { return }
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
```

**Step 2: Build to verify**

Run: `xcodebuild -scheme SnoozeRemote -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | grep -E "(error:|BUILD)" | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add SnoozeRemote/MediaController.swift
git commit -m "refactor: rewrite MediaController with two-phase silent audio player"
```

---

### Task 2: Delete TimerManager and update PhoneSessionManager

**Files:**
- Delete: `SnoozeRemote/TimerManager.swift`
- Rewrite: `SnoozeRemote/PhoneSessionManager.swift`
- Modify: `SnoozeRemote.xcodeproj/project.pbxproj` (remove TimerManager references)

**Step 1: Rewrite PhoneSessionManager**

PhoneSessionManager now talks directly to MediaController instead of TimerManager. It also adds `transferUserInfo` handling for the third WCSession delivery method.

```swift
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
```

**Step 2: Delete TimerManager.swift**

Run: `rm SnoozeRemote/TimerManager.swift`

**Step 3: Remove TimerManager from Xcode project**

Remove these four lines from `project.pbxproj`:
- Line containing `A10006 /* TimerManager.swift in Sources */` (PBXBuildFile)
- Line containing `A20006 /* TimerManager.swift */` (PBXFileReference)
- Line containing `A20006 /* TimerManager.swift */` (PBXGroup children)
- Line containing `A10006 /* TimerManager.swift in Sources */` (PBXSourcesBuildPhase)

**Step 4: Build to verify**

Run: `xcodebuild -scheme SnoozeRemote -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | grep -E "(error:|BUILD)" | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: delete TimerManager, wire PhoneSessionManager to MediaController directly"
```

---

### Task 3: Update ContentView to use MediaController

**Files:**
- Rewrite: `SnoozeRemote/ContentView.swift`

**Step 1: Rewrite ContentView**

Replace TimerManager references with MediaController. Use `Text(timerInterval:)` for the countdown display so no timer-driven updates are needed.

```swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sessionManager: PhoneSessionManager

    private var mediaController: MediaController {
        sessionManager.mediaController
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.indigo)

                Text("SnoozeRemote")
                    .font(.largeTitle.bold())

                Text("This app works as a companion to the Apple Watch app. Open SnoozeRemote on your Watch to set a sleep timer that will stop audio playback on this iPhone.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if mediaController.isTimerActive, let end = mediaController.endDate {
                    timerStatusView(endDate: end)
                } else {
                    idleStatusView
                }

                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func timerStatusView(endDate: Date) -> some View {
        VStack(spacing: 12) {
            Label("Timer Active", systemImage: "timer")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(timerInterval: Date.now...endDate, countsDown: true)
                .font(.system(.title, design: .monospaced))
                .foregroundStyle(.primary)

            Text("Audio will stop when the timer ends.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    private var idleStatusView: some View {
        VStack(spacing: 8) {
            Label("Waiting for Watch", systemImage: "applewatch")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("No timer is currently running.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
        .environmentObject(PhoneSessionManager.shared)
}
```

**Step 2: Build to verify**

Run: `xcodebuild -scheme SnoozeRemote -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | grep -E "(error:|BUILD)" | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add SnoozeRemote/ContentView.swift
git commit -m "refactor: update ContentView to use MediaController with Text(timerInterval:)"
```

---

### Task 4: Add transferUserInfo to WatchSessionManager

**Files:**
- Modify: `SnoozeRemoteWatch/WatchSessionManager.swift`

**Step 1: Add transferUserInfo as third delivery method**

In `WatchSessionManager`, add a `sendUserInfo` method and call it alongside `sendMessage` and `sendApplicationContext` for start, cancel, and addTime commands.

Add this method after `sendApplicationContext`:

```swift
private func sendUserInfo(_ message: [String: Any]) {
    guard let session = session else { return }
    var info = message
    info["timestamp"] = Date().timeIntervalSince1970
    session.transferUserInfo(info)
}
```

Then in `startTimer`, `cancelTimer`, and `addTime`, add a `sendUserInfo(message)` call alongside the existing `sendMessage` and `sendApplicationContext` calls.

**Step 2: Build to verify**

Run: `xcodebuild -scheme SnoozeRemoteWatch -destination 'generic/platform=watchOS' -configuration Debug build 2>&1 | grep -E "(error:|BUILD)" | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add SnoozeRemoteWatch/WatchSessionManager.swift
git commit -m "feat: add transferUserInfo as third WCSession delivery method"
```

---

### Task 5: Build both targets and verify

**Step 1: Build iPhone target**

Run: `xcodebuild -scheme SnoozeRemote -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | grep -E "(error:|BUILD)" | tail -5`
Expected: BUILD SUCCEEDED

**Step 2: Build watch target**

Run: `xcodebuild -scheme SnoozeRemoteWatch -destination 'generic/platform=watchOS' -configuration Debug build 2>&1 | grep -E "(error:|BUILD)" | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Final commit**

```bash
git add -A
git commit -m "chore: verify both targets build clean after scheduled-silent-audio refactor"
```
