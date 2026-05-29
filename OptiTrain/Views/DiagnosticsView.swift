import SwiftUI

struct DiagnosticsView: View {
    @State private var report: HealthKitManager.DiagnosticReport?
    @State private var loading = false
    @State private var windowDays = 7

    var body: some View {
        List {
            Section {
                Stepper("Window: \(windowDays) days", value: $windowDays, in: 1...30)
                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        Text(loading ? "Querying HealthKit…" : "Run diagnostics")
                        if loading { Spacer(); ProgressView() }
                    }
                }
                .disabled(loading)
            } footer: {
                Text("Runs a raw HealthKit query for every metric the app tries to use. Use this to figure out which signals are missing and why.")
            }

            if let report {
                Section("Results · \(report.generatedAt.formatted(date: .omitted, time: .standard))") {
                    ForEach(report.types) { row in
                        TypeStatusRow(status: row)
                    }
                }
                Section {
                    Link("Open iOS Settings → Health → Data Access", destination: URL(string: UIApplication.openSettingsURLString)!)
                } footer: {
                    Text("HealthKit doesn't let an app re-prompt for read permission. To grant a previously denied signal: iOS Settings → Health → Data Access & Devices → OptiTrain.")
                }
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Diagnostics")
    }

    private func run() async {
        loading = true
        defer { loading = false }
        report = await HealthKitManager.shared.diagnostics(days: windowDays)
    }
}

private struct TypeStatusRow: View {
    let status: HealthKitManager.DiagnosticReport.TypeStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(status.label).font(.subheadline).bold()
                Spacer()
                Text("\(status.sampleCount)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(status.sampleCount == 0 ? .red : .green)
            }
            if let last = status.lastSampleAt {
                Text("Last: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let v = status.lastValue {
                Text("Most recent: \(v)").font(.caption).foregroundStyle(.secondary)
            }
            if let notes = status.notes {
                Text(notes).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
