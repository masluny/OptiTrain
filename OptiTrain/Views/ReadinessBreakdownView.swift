import SwiftUI

struct ReadinessBreakdownView: View {
    let score: ReadinessScore
    @State private var focus: SubScore.Kind?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Breakdown").font(.headline)
            ForEach(score.subScores) { sub in
                Button { focus = sub.kind } label: {
                    SubScoreRow(sub: sub)
                }
                .buttonStyle(.plain)
            }
            // The ACWR chip and tap-hint that used to live here are now
            // surfaced inside the glossary sheet (ACWR appears as its own
            // entry; the info.circle on each row signals tappability).
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .sheet(item: $focus) { kind in
            MetricGlossarySheet(glossary: .readiness(score, focus: kind))
        }
    }
}

extension SubScore.Kind: Identifiable {
    var id: String { rawValue }
}

private struct SubScoreRow: View {
    let sub: SubScore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(sub.kind.label).font(.subheadline).bold()
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Label(sub.kind.directionHint, systemImage: sub.kind.directionSymbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(sub.value))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 8)
                    Capsule().fill(color)
                        .frame(width: geo.size.width * (sub.value / 100.0), height: 8)
                }
            }
            .frame(height: 8)
            // The per-metric detail (e.g. "7h 40m, solid") used to live here.
            // It now appears in the glossary sheet that opens on tap so the
            // breakdown reads at-a-glance.
        }
    }

    private var color: Color {
        switch sub.value {
        case 80...: .green
        case 65..<80: .mint
        case 50..<65: .yellow
        case 35..<50: .orange
        default: .red
        }
    }
}
