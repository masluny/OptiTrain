import SwiftUI

/// Training Readiness card with a clean, native-feeling ring and center readout.
/// The visual is intentionally minimal so it reads quickly and stays consistent
/// with Apple's system card language.
struct ReadinessHeroCard: View {
    let score: ReadinessScore
    @State private var showingInfo = false

    // Compact size — this card now lives side-by-side with the Athlete Level
    // card on the Today page, so the gauge is roughly 65% of its old size.
    private let gaugeSize: CGFloat = 108
    private let lineWidth: CGFloat = 9

    var body: some View {
        Button { showingInfo = true } label: {
        VStack(spacing: 0) {
            // Header sits in the top-left corner; the verdict text used to live
            // below the gauge but moved into the info sheet so the card itself
            // reads at a glance.
            HStack(spacing: 6) {
                // `.headline` matches the Breakdown card's header so the three
                // titles on the Today page agree. lineLimit + scale floor are
                // defensive against Dynamic Type re-introducing a wrap on the
                // narrow ~146pt content width.
                Text("Training ready")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Image(systemName: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            ZStack {
                // Track
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)

                // Value ring
                Circle()
                    .trim(from: 0, to: max(0.02, CGFloat(score.value) / 100.0))
                    .stroke(
                        bandColor,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: score.value)

                // Center readout — just the number and the band, since the
                // "Training Readiness" label now lives in the top-left header.
                VStack(spacing: 1) {
                    Text("\(score.value)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(bandColor)
                        .contentTransition(.numericText())
                    Text(score.band.label)
                        .font(.callout.weight(.semibold).italic())
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: gaugeSize, height: gaugeSize)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .aspectRatio(1, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingInfo) {
            MetricGlossarySheet(glossary: .readiness(score))
        }
    }

    /// Number tint, matched to the ring's ramp so the digits agree with the marker.
    private var bandColor: Color {
        switch score.band {
        case .prime: .cyan
        case .ready: .green
        case .moderate: .yellow
        case .low: .orange
        case .depleted: .red
        }
    }
}

#Preview {
    let subs: [SubScore] = [
        .init(kind: .sleep, value: 82, weight: 0.3, detail: "7h 40m, solid"),
        .init(kind: .hrv, value: 74, weight: 0.3, detail: "Above baseline"),
        .init(kind: .restingHeartRate, value: 68, weight: 0.2, detail: "48 bpm"),
        .init(kind: .load, value: 60, weight: 0.2, detail: "Balanced")
    ]
    return ScrollView {
        VStack(spacing: 16) {
            ReadinessHeroCard(score: .init(date: Date(), value: 82, subScores: subs,
                                           acwr: 1.1, headline: "Well recovered and ready to train hard."))
            ReadinessHeroCard(score: .init(date: Date(), value: 47, subScores: subs,
                                           acwr: 1.4, headline: "Carrying fatigue — keep it easy today."))
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}
