import SwiftUI

@main
struct SnoozeRemoteWatchApp: App {
    @StateObject private var sessionManager = WatchSessionManager.shared

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(sessionManager)
        }
    }
}
