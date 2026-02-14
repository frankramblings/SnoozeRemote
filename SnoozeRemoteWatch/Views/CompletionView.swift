import SwiftUI
import WatchKit

struct CompletionView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Audio Stopped")
                .font(.headline)

            Text("Sweet dreams.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Done") {
                sessionManager.dismissCompletion()
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
        .onAppear {
            // Play success haptic — a gentle "crown tap" feel
            WKInterfaceDevice.current().play(.success)
        }
    }
}

#Preview {
    CompletionView()
        .environmentObject(WatchSessionManager.shared)
}
