# SnoozeRemote

A watchOS + iOS app that lets you set a sleep timer from your Apple Watch to stop audio playback on your iPhone.

## Overview

SnoozeRemote provides a remote "Stop Playing" timer on your wrist. No matter what app is playing audio (Spotify, Audible, Podcasts, etc.), SnoozeRemote will fade out and pause playback when the timer expires.

## Features

- **Quick Presets** - 15, 30, 45, and 60-minute one-tap timers
- **Custom Timer** - Digital Crown-controlled picker for 1-120 minutes
- **Fade Out** - Gradually reduces volume over the final 30 seconds
- **Resilient** - iPhone is the source of truth; timer runs even if the Watch disconnects
- **Haptic Feedback** - Gentle confirmation when audio stops

## Architecture

| Component | Role |
|---|---|
| `SnoozeRemoteWatch` | watchOS UI - timer presets, active countdown, custom picker |
| `SnoozeRemote` | iOS companion - receives commands, manages timer, controls media |
| `Shared/` | Common message keys and constants |

Communication uses `WatchConnectivity` (`WCSession`). Media control uses `MPRemoteCommandCenter` and `MPVolumeView`.

## Requirements

- iOS 17.0+
- watchOS 10.0+
- Xcode 15.0+
- Swift 5.0+
