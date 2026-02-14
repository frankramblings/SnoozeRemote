import SwiftUI

struct HomeView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager

    @State private var showCustomPicker = false

    var body: some View {
        NavigationStack {
            if sessionManager.isTimerActive {
                ActiveTimerView()
            } else if sessionManager.showCompletion {
                CompletionView()
            } else {
                timerSetupView
            }
        }
    }

    private var timerSetupView: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.indigo)
                    .padding(.top, 4)

                Text("SnoozeRemote")
                    .font(.headline)

                // Preset buttons
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 10) {
                    ForEach(AppConstants.presetMinutes, id: \.self) { minutes in
                        PresetButton(minutes: minutes) {
                            sessionManager.startTimer(minutes: minutes)
                        }
                    }
                }

                // Custom timer button
                Button {
                    showCustomPicker = true
                } label: {
                    Label("Custom", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.gray)

                // Fade-out toggle
                Toggle(isOn: $sessionManager.fadeOutEnabled) {
                    Label("Fade Out", systemImage: "speaker.wave.2.fill")
                        .font(.caption)
                }
                .padding(.top, 4)

                if !sessionManager.isPhoneReachable {
                    Label("iPhone not connected", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal)
        }
        .sheet(isPresented: $showCustomPicker) {
            CustomPickerView()
        }
    }
}

// MARK: - Preset Button

struct PresetButton: View {
    let minutes: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text("\(minutes)")
                    .font(.system(.title2, design: .rounded).bold())
                Text("min")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(.indigo)
    }
}

#Preview {
    HomeView()
        .environmentObject(WatchSessionManager.shared)
}
