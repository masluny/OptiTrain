import SwiftUI
import UIKit

// MARK: - Color palette

/// Shared green→red ramp used everywhere Athlete Level is drawn, keyed to the
/// 0–10 score so the home card, the full view, and the share image always agree.
enum EfficiencyPalette {
    static func colors(forScore10 s: Double) -> [Color] {
        switch s {
        case 8...:        [.green, .mint]
        case 6.5..<8:     [.mint, .teal]
        case 5..<6.5:     [.yellow, .green]
        case 3.5..<5:     [.orange, .yellow]
        default:          [.red, .orange]
        }
    }
    static func color(forScore10 s: Double) -> Color { colors(forScore10: s).first ?? .gray }
    static func color(forScore100 s: Double) -> Color { color(forScore10: s / 10.0) }
}

// MARK: - Human body figure

/// A clean, recognizable human body filled with a single smooth gradient keyed
/// to the overall Athlete Level — one cohesive head-to-toe wash, not divided into
/// per-system regions. A soft glow keyed to the same score sits behind it. The
/// four systems are read in the breakdown below, not painted onto the body.
/// Built on the `figure.stand` system symbol so it reads as a real body at any
/// size.
struct BodyEfficiencyFigure: View {
    let systems: [BodyEfficiency.System]
    let overallScore: Double          // 0–10
    var glow: Bool = true
    var glowRadius: CGFloat = 18

    private var gradient: LinearGradient {
        LinearGradient(colors: EfficiencyPalette.colors(forScore10: overallScore),
                       startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        Image(systemName: "figure.stand")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(gradient)
            .shadow(color: glow ? EfficiencyPalette.color(forScore10: overallScore).opacity(0.5) : .clear,
                    radius: glowRadius)
    }
}

// MARK: - Tier pill

private struct TierPill: View {
    let tier: BodyEfficiency.Tier
    let score: Double
    var body: some View {
        Text(tier.rawValue.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(0.6)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(EfficiencyPalette.color(forScore10: score).opacity(0.22), in: Capsule())
            .foregroundStyle(EfficiencyPalette.color(forScore10: score))
    }
}

// MARK: - Home-screen card

/// Compact Athlete Level summary for the Today tab. Tapping it pushes the full
/// `BodyEfficiencyView`. This is the feature's primary entry point. Designed to
/// sit as a square next to ReadinessHeroCard in a row.
struct BodyEfficiencyCard: View {
    let snapshot: BodyEfficiency.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // `.headline` to match the Breakdown card's header weight, with
                // lineLimit + scale floor as defensive insurance on tight rows.
                Text("Athlete Level")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .top, spacing: 10) {
                BodyEfficiencyFigure(systems: snapshot.systems, overallScore: snapshot.score, glow: false)
                    .frame(width: 44, height: 104)
                // Score stacked vertically — big number on top, tiny "/ 10"
                // below — so an inline HStack can never wrap a side-by-side
                // "6.5/10" on a narrow column. Tier pill anchors the bottom.
                VStack(alignment: .leading, spacing: 0) {
                    Text(snapshot.formattedScore)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(EfficiencyPalette.color(forScore10: snapshot.score))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("/ 10")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    TierPill(tier: snapshot.tier, score: snapshot.score)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .aspectRatio(1, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Full feature view

struct BodyEfficiencyView: View {
    let snapshot: BodyEfficiency.Snapshot
    let date: Date

    @State private var shareURL: URL?
    @State private var sharePreview: Image?
    @State private var showingSystemsInfo = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                hero
                systemsBreakdown
                insights
                Text("Confidence \(snapshot.confidence.description) · derived from your last weeks of training. The more you log, the sharper this gets.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Athlete Level")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { shareButton }
        }
        .task(id: snapshot.score) { await prepareShareImage() }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 20) {
            BodyEfficiencyFigure(systems: snapshot.systems, overallScore: snapshot.score)
                .frame(width: 110, height: 220)

            VStack(alignment: .leading, spacing: 10) {
                Text("YOUR ATHLETE LEVEL")
                    .font(.caption2.weight(.semibold)).tracking(0.8)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(snapshot.formattedScore)
                        .font(.system(size: 68, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(EfficiencyPalette.color(forScore10: snapshot.score))
                        .contentTransition(.numericText())
                    Text("/ 10")
                        .font(.title.weight(.semibold)).foregroundStyle(.secondary)
                }
                TierPill(tier: snapshot.tier, score: snapshot.score)
                Text(snapshot.headline)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    // MARK: Systems

    private var systemsBreakdown: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                showingSystemsInfo = true
            } label: {
                HStack {
                    Text("The four systems")
                        .font(.headline)
                    Image(systemName: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("What they mean & how to train them")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            ForEach(snapshot.systems) { system in
                SystemRow(system: system)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .sheet(isPresented: $showingSystemsInfo) {
            MetricGlossarySheet(glossary: .systems(snapshot))
        }
    }

    private var insights: some View {
        VStack(spacing: 10) {
            if let weak = snapshot.weakestSystem {
                InsightRow(symbol: "arrow.up.forward.circle.fill", tint: .orange,
                           title: "Biggest opportunity — \(weak.kind.rawValue)",
                           detail: "At \(Int(weak.score.rounded()))/100, this system is holding your number back most. Train it to move the needle fastest.")
            }
            if let strong = snapshot.strongestSystem {
                InsightRow(symbol: "checkmark.seal.fill", tint: .green,
                           title: "Strongest — \(strong.kind.rawValue)",
                           detail: "Leading at \(Int(strong.score.rounded()))/100. Keep it ticking with regular maintenance work.")
            }
        }
    }

    // MARK: Share

    private var shareButton: some View {
        Group {
            if let shareURL {
                ShareLink(item: shareURL,
                          preview: SharePreview("My Athlete Level: \(snapshot.formattedScore)/10",
                                                image: sharePreview ?? Image(systemName: "figure.stand"))) {
                    Image(systemName: "square.and.arrow.up")
                }
            } else {
                ProgressView()
            }
        }
    }

    @MainActor private func prepareShareImage() async {
        let card = BodyEfficiencyShareCard(snapshot: snapshot, date: date)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        guard let ui = renderer.uiImage, let data = ui.pngData() else { return }
        sharePreview = Image(uiImage: ui)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OptiTrain-BodyEfficiency.png")
        if (try? data.write(to: url, options: .atomic)) != nil {
            shareURL = url
        }
    }
}

private struct SystemRow: View {
    let system: BodyEfficiency.System
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: system.kind.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(EfficiencyPalette.color(forScore100: system.score))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(system.kind.rawValue).font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(Int(system.score.rounded()))")
                        .font(.subheadline.monospacedDigit().bold())
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 7)
                        Capsule()
                            .fill(EfficiencyPalette.color(forScore100: system.score))
                            .frame(width: geo.size.width * system.score / 100.0, height: 7)
                    }
                }
                .frame(height: 7)
            }
        }
    }
}

private struct InsightRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Shareable PNG card

/// Minimalist, story-friendly card rendered to a PNG via `ImageRenderer`.
/// Self-contained (no environment) so it renders identically off-screen.
/// Designed at 360×640 pt → 1080×1920 px at 3× (9:16 — Instagram / Snap story).
struct BodyEfficiencyShareCard: View {
    let snapshot: BodyEfficiency.Snapshot
    let date: Date

    private var accent: Color { EfficiencyPalette.color(forScore10: snapshot.score) }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black, accent.opacity(0.28), .black],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            // subtle radial halo behind the figure
            RadialGradient(colors: [accent.opacity(0.30), .clear],
                           center: .init(x: 0.5, y: 0.42), startRadius: 4, endRadius: 320)

            VStack(spacing: 0) {
                // The real logo glyphs in the top-left, with the dark plate
                // chroma-keyed out at build time (see Logo.imageset) so only the
                // green/cyan "OT" letters remain — no clipShape, no rounded
                // background. Sized large enough to carry the brand on its own.
                HStack {
                    Image("Logo")
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 110, height: 110)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 20)
                .padding(.top, 24)

                Spacer(minLength: 0)

                BodyEfficiencyFigure(systems: snapshot.systems, overallScore: snapshot.score, glowRadius: 30)
                    .frame(width: 150, height: 270)

                Spacer(minLength: 0)

                // Score
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(snapshot.formattedScore)
                        .font(.system(size: 92, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                    Text("/ 10")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Text(snapshot.tier.rawValue.uppercased())
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(accent.opacity(0.25), in: Capsule())
                    .padding(.top, 6)

                // Systems mini-row
                HStack(spacing: 10) {
                    ForEach(snapshot.systems) { s in
                        VStack(spacing: 4) {
                            Circle()
                                .fill(EfficiencyPalette.color(forScore100: s.score))
                                .frame(width: 8, height: 8)
                            Text(s.kind.shortLabel.uppercased())
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                                .tracking(0.5)
                                .foregroundStyle(.white.opacity(0.55))
                            Text("\(Int(s.score.rounded()))")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 22)

                // Trailing breathing room. The dated footer that used to sit
                // here was removed — a share card is a moment, not a log entry.
                Spacer(minLength: 44)
            }
        }
        .frame(width: 360, height: 640)
    }
}

#Preview("Card") {
    let systems: [BodyEfficiency.System] = [
        .init(kind: .recovery, score: 72, weight: 0.15),
        .init(kind: .aerobic, score: 81, weight: 0.35),
        .init(kind: .endurance, score: 64, weight: 0.30),
        .init(kind: .locomotion, score: 58, weight: 0.20)
    ]
    let snap = BodyEfficiency.Snapshot(score: 7.1, score100: 71, tier: .strong,
                                       systems: systems, confidence: Confidence(0.7))
    return NavigationStack {
        ScrollView { BodyEfficiencyCard(snapshot: snap).padding() }
    }
}

#Preview("Full") {
    let systems: [BodyEfficiency.System] = [
        .init(kind: .recovery, score: 72, weight: 0.15),
        .init(kind: .aerobic, score: 81, weight: 0.35),
        .init(kind: .endurance, score: 64, weight: 0.30),
        .init(kind: .locomotion, score: 58, weight: 0.20)
    ]
    let snap = BodyEfficiency.Snapshot(score: 7.1, score100: 71, tier: .strong,
                                       systems: systems, confidence: Confidence(0.7))
    return NavigationStack { BodyEfficiencyView(snapshot: snap, date: Date()) }
}
