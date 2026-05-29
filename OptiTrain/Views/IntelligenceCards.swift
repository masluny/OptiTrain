import SwiftUI

/// Shared header for the tappable intelligence cards: the title label plus a
/// trailing info glyph that hints "tap me to learn what these numbers mean".
private struct CardHeader: View {
    let title: String
    let systemImage: String
    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Spacer()
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

struct LoadCard: View {
    let snapshot: TrainingLoadEngine.Snapshot
    @State private var showingInfo = false
    var body: some View {
        Button { showingInfo = true } label: {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "Training load", systemImage: "chart.line.uptrend.xyaxis.circle.fill")
                HStack(spacing: 12) {
                    Stat(label: "Fitness", value: String(format: "%.0f", snapshot.ctl), tone: .blue)
                    Stat(label: "Fatigue", value: String(format: "%.0f", snapshot.atl), tone: .orange)
                    Stat(label: "Form", value: String(format: "%+.0f", snapshot.tsb), tone: snapshot.tsb >= 0 ? .green : .red)
                }
                // The verdict line ("Building — load is climbing safely")
                // used to sit here; it now leads the info sheet so the card
                // itself reads at a glance.
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingInfo) { MetricGlossarySheet(glossary: .trainingLoad(snapshot)) }
    }

    private struct Stat: View {
        let label: String; let value: String; let tone: Color
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(tone)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct RecoveryDebtCard: View {
    let snapshot: RecoveryDebtModel.Snapshot
    @State private var showingInfo = false
    var body: some View {
        Button { showingInfo = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Recovery debt", systemImage: "battery.50percent")
                HStack(spacing: 12) {
                    DebtPill(label: "7d", percent: snapshot.sevenDay.debtPercent)
                    DebtPill(label: "14d", percent: snapshot.fourteenDay.debtPercent)
                    DebtPill(label: "30d", percent: snapshot.thirtyDay.debtPercent)
                }
                // The "Estimated time to clear …" line lived here; it's now
                // exposed as the "Time to clear" entry inside the info sheet.
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingInfo) { MetricGlossarySheet(glossary: .recoveryDebt(snapshot)) }
    }
    private struct DebtPill: View {
        let label: String; let percent: Double
        var body: some View {
            VStack(spacing: 4) {
                Text("\(Int(percent))%").font(.title3.bold().monospacedDigit()).foregroundStyle(color)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        private var color: Color {
            switch percent { case ..<20: .green; case 20..<45: .yellow; case 45..<65: .orange; default: .red }
        }
    }
}

struct AutonomicCard: View {
    let snapshot: AutonomicStability.Snapshot
    @State private var showingInfo = false
    var body: some View {
        Button { showingInfo = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Autonomic stability", systemImage: "waveform.path.ecg")
                HStack {
                    Text("\(Int(snapshot.stabilityScore))").font(.system(size: 38, weight: .bold, design: .rounded))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        SignalBadge(label: "Illness", signal: snapshot.illnessRiskSignal)
                        SignalBadge(label: "Overreach", signal: snapshot.overtrainingSignal)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingInfo) { MetricGlossarySheet(glossary: .autonomic(snapshot)) }
    }

    private struct SignalBadge: View {
        let label: String; let signal: AutonomicStability.Signal
        var body: some View {
            HStack(spacing: 6) {
                Text(label).font(.caption2)
                Text(signal.label).font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color.opacity(0.20), in: Capsule())
                    .foregroundStyle(color)
            }
        }
        private var color: Color {
            switch signal { case .quiet: .green; case .watch: .yellow; case .elevated: .orange; case .alarming: .red }
        }
    }
}

struct InjuryRiskCard: View {
    let snapshot: InjuryAndBurnoutRisk.Snapshot
    @State private var showingInfo = false
    var body: some View {
        Button { showingInfo = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Risk panel", systemImage: "shield.lefthalf.filled.badge.checkmark")
                HStack(spacing: 12) {
                    RiskRow(label: "Soft tissue", value: snapshot.softTissueRisk)
                    RiskRow(label: "Overreaching", value: snapshot.overreachingRisk)
                    RiskRow(label: "Burnout", value: snapshot.burnoutRisk)
                }
                // The recommendation sentence used to live here; it now leads
                // the info sheet so the card itself reads at a glance.
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingInfo) { MetricGlossarySheet(glossary: .injuryRisk(snapshot)) }
    }

    private struct RiskRow: View {
        let label: String; let value: Double
        var body: some View {
            VStack(spacing: 2) {
                Text("\(Int(value * 100))%").font(.title3.bold().monospacedDigit()).foregroundStyle(color)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        private var color: Color {
            switch value { case ..<0.3: .green; case ..<0.5: .yellow; case ..<0.75: .orange; default: .red }
        }
    }
}
