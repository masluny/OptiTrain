import SwiftUI

/// Training Readiness, styled after the Garmin watch gauge: a circular dial with a
/// bottom gap, a red→cyan color ramp, thin ticks at the band boundaries, and a
/// white marker riding the current value. The number is tinted to its band, with
/// the band word set in italics underneath. Sits on the same translucent material
/// as the rest of the cards so the app's ambient shine reads through it.
struct ReadinessHeroCard: View {
    let score: ReadinessScore
    @State private var showingInfo = false

    private let gaugeSize: CGFloat = 168
    private let lineWidth: CGFloat = 12
    private let gap = 0.16                       // fraction of the circle left open at the bottom

    private var sweep: Double { (1 - gap) * 360 }
    private var pathRadius: CGFloat { (gaugeSize - lineWidth) / 2 }

    /// Angle (degrees, clockwise from straight up) for a 0–100 value along the arc.
    /// Value 0 sits just left of the bottom gap; value 100 just right of it.
    private func angle(for value: Double) -> Double {
        180 + gap * 180 + (value / 100) * sweep
    }

    var body: some View {
        Button { showingInfo = true } label: {
        VStack(spacing: 14) {
            // Header sits in the top-left corner; the verdict text used to live
            // below the gauge but moved into the info sheet so the card itself
            // reads at a glance.
            HStack {
                Text("Training Readiness")
                    .font(.headline)
                Spacer()
                Image(systemName: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ZStack {
                // Empty track behind the colored ring.
                Circle()
                    .trim(from: 0, to: 1 - gap)
                    .stroke(Color.secondary.opacity(0.15),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(90 + gap * 180))

                // The readiness ramp: low = red, high = cyan. Angles are set in the
                // un-rotated frame so the gradient stays glued to the trim after we
                // rotate the whole stroke into place.
                Circle()
                    .trim(from: 0, to: 1 - gap)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [.red, .orange, .yellow, .green, .mint, .cyan]),
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(sweep)
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(90 + gap * 180))

                // Band-boundary notches (depleted|low|moderate|ready|prime).
                ForEach([40, 55, 70, 85], id: \.self) { boundary in
                    Capsule()
                        .fill(Color.black)
                        .frame(width: 2.5, height: lineWidth)
                        .offset(y: -pathRadius)
                        .rotationEffect(.degrees(angle(for: Double(boundary))))
                }

                // White marker riding the current value.
                Circle()
                    .fill(.white)
                    .frame(width: lineWidth - 3, height: lineWidth - 3)
                    .overlay(Circle().stroke(.black, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .offset(y: -pathRadius)
                    .rotationEffect(.degrees(angle(for: Double(score.value))))
                    .animation(.easeOut(duration: 0.6), value: score.value)

                // Center readout — just the number and the band, since the
                // "Training Readiness" label now lives in the top-left header.
                VStack(spacing: 2) {
                    Text("\(score.value)")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(bandColor)
                        .contentTransition(.numericText())
                    Text(score.band.label)
                        .font(.title3.weight(.semibold).italic())
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: gaugeSize, height: gaugeSize)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .contentShape(RoundedRectangle(cornerRadius: 24))
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
