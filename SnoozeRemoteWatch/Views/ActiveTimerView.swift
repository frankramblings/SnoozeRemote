import SwiftUI

struct ActiveTimerView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager

    var body: some View {
        VStack(spacing: 8) {
            // Circular progress
            ZStack {
                // Background ring
                Circle()
                    .stroke(lineWidth: 8)
                    .foregroundStyle(.gray.opacity(0.2))

                // Progress ring
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(
                            colors: [.indigo, .purple, .indigo],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)

                // Time display
                VStack(spacing: 2) {
                    Text(timeString)
                        .font(.system(.title2, design: .monospaced).bold())
                        .foregroundStyle(.primary)

                    Text("remaining")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, height: 120)
            .focusable()
            .digitalCrownRotation(
                $sessionManager.crownValue,
                from: 0,
                through: sessionManager.totalDuration,
                sensitivity: .low,
                isContinuous: false
            )

            // Controls
            HStack(spacing: 16) {
                // Cancel
                Button {
                    sessionManager.cancelTimer()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.red.opacity(0.8))

                // +5 minutes
                Button {
                    sessionManager.addTime(minutes: AppConstants.addTimeMinutes)
                } label: {
                    Text("+5")
                        .font(.body.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }
        }
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Computed Properties

    private var progress: CGFloat {
        guard sessionManager.totalDuration > 0 else { return 0 }
        return CGFloat(sessionManager.remainingSeconds / sessionManager.totalDuration)
    }

    private var timeString: String {
        let total = Int(sessionManager.remainingSeconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#Preview {
    ActiveTimerView()
        .environmentObject(WatchSessionManager.shared)
}
