import SwiftUI

@main
struct SnoozeRemoteApp: App {
    @StateObject private var sessionManager = PhoneSessionManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionManager)
        }
    }
}
