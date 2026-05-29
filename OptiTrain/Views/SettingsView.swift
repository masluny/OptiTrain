import SwiftUI

struct SettingsView: View {
    @Environment(AppSession.self) private var session
    @AppStorage(UserSettingsKey.useWristTemperature) private var useWristTemperature: Bool = true
    @AppStorage(UserSettingsKey.aiFeaturesEnabled) private var aiFeaturesEnabled: Bool = true

    var body: some View {
        Form {
            Section {
                Toggle("Use wrist temperature", isOn: $useWristTemperature)
                Text("Apple Watch Series 8 and later measure overnight wrist temperature. Turn this off if your watch doesn't support it (Series 7 and earlier, or SE) — the readiness score will be recomputed from sleep, HRV, RHR, and training load only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Signals")
            }
            .onChange(of: useWristTemperature) { _, _ in
                Task { await session.refresh() }
            }

            Section {
                Toggle("AI features", isOn: $aiFeaturesEnabled)
                Text("Uses Apple Intelligence on-device to write your daily briefing and goal plan. Apple Intelligence isn't available in every region (including the EU). Turn this off to use OptiTrain's built-in, rule-based guidance instead — no AI required.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Intelligence")
            }

            Section("Activity") {
                NavigationLink {
                    WorkoutsView()
                } label: {
                    Label("Workouts", systemImage: "figure.run")
                }
            }

            Section("Data") {
                Button("Refresh from Apple Health") {
                    Task { await session.refresh() }
                }
                NavigationLink("Diagnostics") {
                    DiagnosticsView()
                }
                if case .ready = session.state {
                    LabeledContent("Days of history", value: "\(session.history.count)")
                }
            }

            Section("About") {
                LabeledContent("App", value: "OptiTrain")
                LabeledContent("Version", value: "0.3.0")
                Text("OptiTrain is a personal training-readiness tool. It is not a medical device. All processing happens on your phone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Settings")
    }
}
