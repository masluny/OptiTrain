import SwiftUI

struct EventReadinessView: View {
    @Environment(AppSession.self) private var session
    @State private var filter: RaceTimePrediction.RaceDistance.Category?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Look at session.state, not just intelligence — the old version
                // showed a forever-spinner whenever the snapshot was nil for any
                // reason (including `.failed`), which is what made the Races tab
                // feel "stuck" for new users with no HealthKit data.
                switch session.state {
                case .idle, .requestingAuth:
                    LoadingProgressView(progress: 0,
                                        label: session.loadingStatus)
                case .loading:
                    LoadingProgressView(progress: session.progress,
                                        label: session.loadingStatus)
                case .failed(let message):
                    ErrorBanner(message: message) {
                        Task { await session.bootstrap() }
                    }
                case .ready:
                    if let snap = session.intelligence {
                        PhysiologyDisclosure(profile: snap.physiologyProfile)
                        CategoryFilterBar(selected: $filter)
                        ForEach(filtered(snap.eventReadiness)) { r in
                            let prediction = snap.racePredictions.first(where: { $0.distance == r.event })
                            EventCard(readiness: r, prediction: prediction)
                        }
                    } else {
                        LoadingProgressView(progress: session.progress,
                                            label: session.loadingStatus)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
            .animation(.snappy(duration: 0.25), value: filter)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Race Readiness")
    }

    private func filtered(_ events: [EventReadinessEngine.Readiness]) -> [EventReadinessEngine.Readiness] {
        guard let filter else { return events }
        return events.filter { $0.event.category == filter }
    }
}

private struct CategoryFilterBar: View {
    private enum FilterOption: Hashable {
        case all
        case category(RaceTimePrediction.RaceDistance.Category)
    }

    @Binding var selected: RaceTimePrediction.RaceDistance.Category?

    private var binding: Binding<FilterOption> {
        Binding(
            get: { selected.map(FilterOption.category) ?? .all },
            set: { newValue in
                switch newValue {
                case .all: selected = nil
                case .category(let category): selected = category
                }
            }
        )
    }

    var body: some View {
        HStack {
            Label("Event type", systemImage: "line.3.horizontal.decrease.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("Event type", selection: binding) {
                Text("All").tag(FilterOption.all)
                ForEach(RaceTimePrediction.RaceDistance.Category.allCases, id: \.self) { category in
                    Text(category.rawValue).tag(FilterOption.category(category))
                }
            }
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 2)
        .accessibilityHint("Filters race readiness cards by event type")
    }
}

/// Collapses the physiology breakdown behind a compact profile icon. Tap to
/// reveal the six component bars; collapsed by default so the screen leads with
/// the races, not a wall of stats.
private struct PhysiologyDisclosure: View {
    let profile: PhysiologyProfile
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "figure.run.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    Text("Your physiology")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Each race weighs these differently. A 90 for 5K isn't a 90 for Ironman.")
                        .font(.caption).foregroundStyle(.secondary)
                    ComponentBarRow(label: "VO₂max",      value: profile.vo2maxScore)
                    ComponentBarRow(label: "Threshold",   value: profile.thresholdScore)
                    ComponentBarRow(label: "Durability",  value: profile.durabilityScore)
                    ComponentBarRow(label: "Fueling",     value: profile.fuelingScore)
                    ComponentBarRow(label: "Volume",      value: profile.volumeToleranceScore)
                    ComponentBarRow(label: "Freshness",   value: profile.freshnessScore)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct ComponentBarRow: View {
    let label: String
    let value: Double
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.caption).frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 6)
                    Capsule().fill(color).frame(width: geo.size.width * value / 100.0, height: 6)
                }
            }
            .frame(height: 6)
            Text("\(Int(value))").font(.caption.monospacedDigit()).frame(width: 28, alignment: .trailing)
        }
    }
    private var color: Color {
        switch value {
        case 80...: .green
        case 60..<80: .mint
        case 40..<60: .yellow
        default: .orange
        }
    }
}

private struct EventCard: View {
    let readiness: EventReadinessEngine.Readiness
    let prediction: RaceTimePrediction.Prediction?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Minimal, always-visible summary row — tap to expand.
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) { expanded.toggle() }
            } label: {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(readiness.event.rawValue).font(.headline)
                        HStack(spacing: 6) {
                            ForEach(readiness.event.disciplines, id: \.self) { discipline in
                                DisciplineTag(discipline: discipline)
                            }
                        }
                        if let prediction {
                            Text(formatTime(prediction.predictedSeconds))
                                .font(.subheadline.monospacedDigit().weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    ReadinessRing(value: readiness.score, size: 48, lineWidth: 5)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    Text(readiness.explanation.headline)
                        .font(.subheadline).foregroundStyle(.secondary)
                    eventContext

                    // The three pillars behind the score — capability, taper,
                    // acute recovery — the way Garmin/WHOOP/Oura present it.
                    HStack(spacing: 10) {
                        PillarPill(label: "Fitness", value: readiness.fitnessScore, symbol: "bolt.fill")
                        PillarPill(label: "Form", value: readiness.formScore, symbol: "wind")
                        PillarPill(label: "Recovery", value: readiness.recoveryScore, symbol: "heart.fill")
                    }
                    Text("Readiness = fitness you've built, sharpened by taper, gated by recovery.")
                        .font(.caption2).foregroundStyle(.tertiary)

                    if let prediction {
                        // Predicted time already shows on the collapsed card row,
                        // so the expanded view splits the range into Best- and
                        // Worst-case pills (one line each, no awkward dash-wrap
                        // on long races) tinted to mirror the readiness ramp.
                        HStack(spacing: 14) {
                            StatPill(label: "Best case",
                                     value: formatTime(prediction.lowerBoundSeconds),
                                     valueTint: .green)
                            StatPill(label: "Worst case",
                                     value: formatTime(prediction.upperBoundSeconds),
                                     valueTint: .orange)
                            StatPill(label: "Finish",
                                     value: "\(Int(readiness.completionProbability * 100))%")
                        }
                    }

                    if let lim = readiness.limitingFactor {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Limiting factor — \(lim.label)").font(.caption).bold()
                                Text(lim.detail).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if readiness.collapseRiskPercent > 20 {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.heart.fill").foregroundStyle(.red)
                            Text(String(format: "Collapse risk %.0f%% — a weakness could blow this race up.", readiness.collapseRiskPercent))
                                .font(.caption2)
                        }
                    }

                    Text("Confidence \(readiness.confidence.description)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var eventContext: some View {
        VStack(alignment: .leading, spacing: 6) {
            let longestKm = readiness.longestRunMeters / 1000.0
            Text(String(format: "Longest recorded run: %.1f km · Coverage: %.0f%% of this event",
                        longestKm, readiness.trainingCoveragePercent))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let refDate = readiness.referenceDate {
                let refKm = (readiness.referenceDistanceMeters ?? 0) / 1000.0
                let ageText = readiness.referenceAgeDays.map { "\($0)d ago" } ?? "recent"
                Text(String(format: "Best reference: %.1f km on %@ (%@)",
                            refKm,
                            refDate.formatted(.dateTime.year().month().day()),
                            ageText))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            } else {
                Text("No qualifying run reference found in recorded data.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !readiness.assumptions.isEmpty {
                ForEach(Array(readiness.assumptions.enumerated()), id: \.offset) { _, note in
                    Text("• \(note)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Small colored tag for one of an event's sports (Swim / Bike / Run).
private struct DisciplineTag: View {
    let discipline: RaceTimePrediction.RaceDistance.Discipline

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: discipline.symbol).font(.system(size: 10, weight: .semibold))
            Text(discipline.label).font(.caption2.weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.15), in: Capsule())
    }

    private var tint: Color {
        switch discipline {
        case .swim: .cyan
        case .bike: .green
        case .run: .orange
        }
    }
}

/// One of the three readiness pillars (Fitness / Form / Recovery), shown as a
/// labeled chip with a color keyed to its 0–100 value.
private struct PillarPill: View {
    let label: String
    let value: Double
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                Text(label).font(.caption2.weight(.medium))
            }
            .foregroundStyle(.secondary)
            Text("\(Int(value.rounded()))")
                .font(.subheadline.monospacedDigit().bold())
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var tint: Color {
        switch value {
        case 80...: .green
        case 60..<80: .mint
        case 40..<60: .yellow
        default: .orange
        }
    }
}

private struct StatPill: View {
    let label: String
    let value: String
    /// Optional tint applied to the value text (defaults to primary). Used to
    /// hint Best/Worst pills green/orange in line with the readiness ramp.
    var valueTint: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.monospacedDigit().bold())
                .foregroundStyle(valueTint)
        }
        // `maxHeight: .infinity` keeps every pill the same height in its HStack
        // even if any sibling ever wraps — defensive against future longer
        // labels or values.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Circular readiness gauge: the arc fills proportionally to the score and
/// shifts green→red as readiness drops. A full green ring = race-ready; a short
/// red arc = a long way off. The number sits in the middle.
struct ReadinessRing: View {
    let value: Int            // 0...100
    var size: CGFloat = 66
    var lineWidth: CGFloat = 7

    private var clamped: Int { min(100, max(0, value)) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(clamped) / 100.0)
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: clamped)
            Text("\(clamped)")
                .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
    }

    private var ringColor: Color {
        switch clamped {
        case 85...: .green
        case 70..<85: .mint
        case 55..<70: .yellow
        case 40..<55: .orange
        default: .red
        }
    }
}
