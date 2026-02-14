import SwiftUI

struct CustomPickerView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMinutes: Double = 30

    var body: some View {
        VStack(spacing: 12) {
            Text("Set Timer")
                .font(.headline)

            // Minutes display — updates with Digital Crown
            Text("\(Int(selectedMinutes))")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundStyle(.indigo)
                .focusable()
                .digitalCrownRotation(
                    $selectedMinutes,
                    from: Double(AppConstants.minimumMinutes),
                    through: Double(AppConstants.maximumMinutes),
                    by: 1,
                    sensitivity: .medium,
                    isContinuous: false,
                    isHapticFeedbackEnabled: true
                )

            Text("minutes")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                sessionManager.startTimer(minutes: Int(selectedMinutes))
                dismiss()
            } label: {
                Label("Start", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
        .padding()
    }
}

#Preview {
    CustomPickerView()
        .environmentObject(WatchSessionManager.shared)
}
