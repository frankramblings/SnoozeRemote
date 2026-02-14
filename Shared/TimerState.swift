import Foundation

/// Shared message keys and state used by both Watch and iPhone targets.
enum MessageKey {
    static let command = "command"
    static let duration = "duration"
    static let remainingTime = "remainingTime"
    static let isPlaying = "isPlaying"
    static let fadeOutEnabled = "fadeOutEnabled"
}

enum TimerCommand: String {
    case start
    case cancel
    case addTime
    case queryStatus
    case timerFired
    case timerUpdate
    case statusResponse
}

enum AppConstants {
    static let presetMinutes: [Int] = [15, 30, 45, 60]
    static let addTimeMinutes: Int = 5
    static let minimumMinutes: Int = 1
    static let maximumMinutes: Int = 120
    static let fadeOutDurationSeconds: TimeInterval = 30
}
