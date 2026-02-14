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
