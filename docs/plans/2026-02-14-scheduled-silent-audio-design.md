# Scheduled Silent Audio Player Design

## Problem

The current architecture fights iOS's background execution model. It relies on keeping a timer alive in the phone app's background, which fails when the app is suspended, woken, or restarted. The audio pause mechanism (MPMusicPlayerController + audio session interruption) is fragile and races with session deactivation.

## Desired Outcome

User wakes up at 2am, hits play on any audio app, starts a sleep timer from their Apple Watch, and falls back asleep with confidence the music will stop. Works every night without manually launching the phone app.

## Constraints

- Must work with any audio app (Spotify, Podcasts, Apple Music, etc.)
- Phone app must stay in app switcher (not force-quit) -- accepted tradeoff
- No alarm/notification fallback -- silent failure preferred
- WCSession from foreground watch app can wake a backgrounded (not force-quit) iOS app

## Design: Two-Phase Audio Lifecycle

### Phase 1 -- Coexist (start to 30 seconds before end)

- Audio session: `.playback` + `.mixWithOthers`
- Play a looping silent track at volume 0
- User's music plays normally alongside our silent audio
- iOS keeps our app alive because we're "playing audio"

### Phase 2 -- Interrupt (final 30 seconds to end)

- If fade enabled: gradually lower system volume to 0 over 30 seconds using MPVolumeView slider
- Stop the Phase 1 (mixing) player
- Switch audio session to `.playback` WITHOUT `.mixWithOthers`
- Play a new silent track of exactly the remaining duration
- This exclusive session interrupts the other app's audio session
- When the track finishes, `audioPlayerDidFinishPlaying` delegate fires
- Deactivate audio session WITHOUT `notifyOthersOnDeactivation` -- other app stays paused
- Restore system volume to original level

If fade disabled: Phase 2 is instant -- stop mixing player, start 1-second exclusive player, it finishes, other app is interrupted and stays paused.

## Phone App Architecture

### MediaController (rewritten)

Three responsibilities:
1. Start timer -- receive duration, begin Phase 1
2. Transition to Phase 2 -- switch from mixing to exclusive
3. Clean up -- handle `audioPlayerDidFinishPlaying` callback

Components:
- AVAudioPlayer (silent, looping) -- Phase 1: keeps app alive
- AVAudioPlayer (silent, fixed-length) -- Phase 2: interrupts other audio
- AVAudioSession management
- MPVolumeView slider -- for volume fade-out
- Single DispatchSourceTimer -- fires once to trigger Phase 1 to Phase 2 transition
- Method to generate silent WAV of arbitrary duration

### PhoneSessionManager (simplified)

Receives WCSession commands, passes to MediaController:
- "start sleep timer for N minutes with fade on/off"
- "cancel"
- "add N minutes"

### TimerManager -- DELETED

No more tick-every-second timer, DispatchSourceTimer, beginBackgroundTask, or background/foreground observers. The audio players ARE the timer.

### ContentView (simplified)

Uses SwiftUI `Text(timerInterval:)` for countdown display. No timer-driven updates needed.

## WCSession Reliability

Every command sent via all three mechanisms:
1. `sendMessage` -- real-time, wakes the phone app (primary)
2. `updateApplicationContext` -- queued, delivered on activation (backup)
3. `transferUserInfo` -- queued, guaranteed delivery (second backup)

Phone deduplicates by timestamp.

## Watch App

Mostly unchanged:
- Local fallback countdown for display (already built)
- Sends commands via all three WCSession methods
- Shows completion screen based on local timer (can't know for certain if pause succeeded)

## What Gets Deleted

- `TimerManager.swift` -- entire file
- `generateSilentWAV()` 1-second fixed version -- replaced with arbitrary-duration generator
- `pauseMedia()` as standalone -- Phase 2 ending IS the pause
- `MPMusicPlayerController.systemMusicPlayer` usage -- audio session interruption is universal
- All `beginBackgroundTask` / `endBackgroundTask` plumbing
- Background/foreground notification observers
