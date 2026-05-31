import SwiftUI
import Charts

struct TrendsView: View {
    @Environment(AppSession.self) private var session
    @State private var category: TrendCategory = .all

    /// The lens applied to the trend list. `all` shows everything; the others
    /// narrow to one family of signals so the screen isn't a wall of charts.
    enum TrendCategory: String, CaseIterable, Identifiable {
        case all = "All"
        case performance = "Performance"
        case recovery = "Recovery"
        case sleep = "Sleep"
        case training = "Training"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .all: "square.grid.2x2"
            case .performance: "bolt.fill"
            case .recovery: "heart.text.square.fill"
            case .sleep: "bed.double.fill"
            case .training: "figure.run"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                filterBar

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
                    if session.history.isEmpty {
                        ContentUnavailableView("No history yet",
                                               systemImage: "chart.line.uptrend.xyaxis",
                                               description: Text("Charts appear once Apple Health has a few days of data."))
                            .padding(.top, 60)
                    } else {
                    Text("Last \(session.history.count) days")
                        .font(.caption).foregroundStyle(.secondary)

                    if shows(.performance) {
                        sectionHeader("Performance", systemImage: "bolt.fill", tint: .green)
                        athleteLevelChart
                        vo2maxChart
                        fitnessChart
                        formChart
                    }
                    if shows(.recovery) {
                        sectionHeader("Recovery", systemImage: "heart.text.square.fill", tint: .pink)
                        hrvChart
                        rhrChart
                        respiratoryChart
                        if hasTemp { temperatureChart }
                    }
                    if shows(.sleep) {
                        sectionHeader("Sleep", systemImage: "bed.double.fill", tint: .indigo)
                        sleepDurationChart
                        sleepStagesChart
                        sleepEfficiencyChart
                    }
                    if shows(.training) {
                        sectionHeader("Training", systemImage: "figure.run", tint: .orange)
                        loadChart
                        activeEnergyChart
                        stepsChart
                    }
                }
                }   // close the `switch session.state`
            }
            .padding()
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Trends")
    }

    private func shows(_ c: TrendCategory) -> Bool { category == .all || category == c }

    // MARK: - Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TrendCategory.allCases) { c in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { category = c }
                    } label: {
                        Label(c.rawValue, systemImage: c.symbol)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 13).padding(.vertical, 7)
                            .background(
                                category == c ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.12)),
                                in: Capsule()
                            )
                            .foregroundStyle(category == c ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func sectionHeader(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(tint)
            .padding(.top, 4)
    }

    // MARK: - Recovery charts

    private var hrvChart: some View {
        let points = series { $0.overnightHRV }
        return chartCard(title: "Overnight HRV", unit: "ms", points: points) {
            Chart(points, id: \.date) { p in
                LineMark(x: .value("Day", p.date, unit: .day), y: .value("HRV", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.mint)
                PointMark(x: .value("Day", p.date, unit: .day), y: .value("HRV", p.value))
                    .foregroundStyle(.mint)
                    .symbolSize(18)
            }
        }
    }

    private var rhrChart: some View {
        let points = series { $0.restingHeartRate }
        return chartCard(title: "Resting heart rate", unit: "bpm", points: points) {
            Chart(points, id: \.date) { p in
                LineMark(x: .value("Day", p.date, unit: .day), y: .value("RHR", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.pink)
            }
        }
    }

    private var respiratoryChart: some View {
        let points = series { $0.respiratoryRate }
        return chartCard(title: "Respiratory rate", unit: "br/min", points: points) {
            Chart(points, id: \.date) { p in
                LineMark(x: .value("Day", p.date, unit: .day), y: .value("RR", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.teal)
            }
        }
    }

    private var hasTemp: Bool { session.history.contains { $0.wristTemperatureDelta != nil } }

    private var temperatureChart: some View {
        let points = series { $0.wristTemperatureDelta }
        return chartCard(title: "Wrist temperature", unit: "°C from baseline", points: points) {
            Chart(points, id: \.date) { p in
                AreaMark(x: .value("Day", p.date, unit: .day), y: .value("Δ°C", p.value))
                    .foregroundStyle(.orange.opacity(0.25))
                LineMark(x: .value("Day", p.date, unit: .day), y: .value("Δ°C", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.orange)
                RuleMark(y: .value("Baseline", 0))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sleep charts

    private var sleepDurationChart: some View {
        let points = series { day in day.sleep.map { $0.asleepDuration / 3600 } }
        return chartCard(title: "Sleep duration", unit: "hours asleep", points: points) {
            Chart(points, id: \.date) { p in
                BarMark(x: .value("Day", p.date, unit: .day), y: .value("Hours", p.value))
                    .foregroundStyle(.indigo)
                RuleMark(y: .value("Target", 7.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sleepStagesChart: some View {
        let stagePoints: [StagePoint] = session.history.flatMap { day -> [StagePoint] in
            guard let s = day.sleep, s.asleepDuration > 0 else { return [] }
            return [
                StagePoint(date: day.date, stage: "Deep", hours: s.deepDuration / 3600),
                StagePoint(date: day.date, stage: "REM", hours: s.remDuration / 3600),
                StagePoint(date: day.date, stage: "Core", hours: s.coreDuration / 3600)
            ]
        }
        return chartCard(title: "Sleep stages", unit: "hours", points: stagePoints.map { TrendPoint(date: $0.date, value: $0.hours) }) {
            Chart(stagePoints) { p in
                BarMark(x: .value("Day", p.date, unit: .day), y: .value("Hours", p.hours))
                    .foregroundStyle(by: .value("Stage", p.stage))
            }
            .chartForegroundStyleScale([
                "Deep": Color.indigo, "REM": Color.purple, "Core": Color.blue.opacity(0.6)
            ])
            .chartLegend(position: .bottom, spacing: 6)
        }
    }

    private var sleepEfficiencyChart: some View {
        let points = series { day in day.sleep.map { $0.efficiency * 100 } }
        return chartCard(title: "Sleep efficiency", unit: "% of time in bed asleep", points: points) {
            Chart(points, id: \.date) { p in
                LineMark(x: .value("Day", p.date, unit: .day), y: .value("Efficiency", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.indigo)
            }
            .chartYScale(domain: 60...100)
        }
    }

    // MARK: - Training charts

    private var loadChart: some View {
        let points = series { $0.workoutLoad ?? 0 }
        return chartCard(title: "Daily training load", unit: "TRIMP", points: points) {
            Chart(points, id: \.date) { p in
                BarMark(x: .value("Day", p.date, unit: .day), y: .value("Load", p.value))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var activeEnergyChart: some View {
        let points = series { $0.activeEnergyKcal }
        return chartCard(title: "Active energy", unit: "kcal", points: points) {
            Chart(points, id: \.date) { p in
                BarMark(x: .value("Day", p.date, unit: .day), y: .value("kcal", p.value))
                    .foregroundStyle(.red)
            }
        }
    }

    private var stepsChart: some View {
        let points = series { day in day.steps.map(Double.init) }
        return chartCard(title: "Steps", unit: "per day", points: points) {
            Chart(points, id: \.date) { p in
                BarMark(x: .value("Day", p.date, unit: .day), y: .value("Steps", p.value))
                    .foregroundStyle(.teal)
            }
        }
    }

    // MARK: - Performance charts (the headlines for runners)

    /// Horizontal bar chart of the four Athlete-Level systems — a *snapshot*
    /// rather than a trend, because Athlete Level isn't stored historically.
    /// Shows where the body is strongest vs. weakest at a glance.
    private var athleteLevelChart: some View {
        let systems = session.intelligence?.bodyEfficiency.systems ?? []
        let placeholder = systems.map { TrendPoint(date: Date(), value: $0.score) }
        return chartCard(title: "Athlete Level systems", unit: "score 0–100", points: placeholder) {
            Chart(systems) { s in
                BarMark(
                    x: .value("Score", s.score),
                    y: .value("System", s.kind.shortLabel)
                )
                .foregroundStyle(EfficiencyPalette.color(forScore100: s.score))
                .annotation(position: .trailing) {
                    Text("\(Int(s.score))")
                        .font(.caption2.monospacedDigit().bold())
                        .foregroundStyle(.secondary)
                }
            }
            .chartXScale(domain: 0...100)
        }
    }

    private var vo2maxChart: some View {
        let points = session.vo2Samples.map { TrendPoint(date: $0.date, value: $0.value) }
        let band = vo2GoodBand
        let yDomain = vo2YDomain(points: points, band: band)
        return chartCard(title: "VO₂max", unit: "ml/kg/min · green band = good (\(bandSubtitle))", points: points) {
            Chart {
                // Age/sex-adjusted "Good" band — solid translucent fill framed
                // by two thin rules so the target reads at a glance even when
                // the line passes through it.
                RectangleMark(yStart: .value("Good low", band.low),
                              yEnd:   .value("Good high", band.high))
                    .foregroundStyle(.green.opacity(0.20))
                RuleMark(y: .value("Good low", band.low))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(.green.opacity(0.55))
                RuleMark(y: .value("Good high", band.high))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(.green.opacity(0.55))

                ForEach(points, id: \.date) { p in
                    LineMark(x: .value("Day", p.date, unit: .day), y: .value("VO₂max", p.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.green)
                    PointMark(x: .value("Day", p.date, unit: .day), y: .value("VO₂max", p.value))
                        .foregroundStyle(.green)
                        .symbolSize(18)
                }
            }
            .chartYScale(domain: yDomain)
        }
    }

    /// A tight Y-axis domain for the VO₂max chart — the union of the data
    /// points and the reference band, plus a small margin so the line never
    /// runs flush with the chart edges. Swift Charts would otherwise pick a
    /// fairly wide auto-domain that pushes the data flat against one edge;
    /// this gives the line vertical breathing room without zooming so far in
    /// that day-to-day noise looks like a trend.
    private func vo2YDomain(points: [TrendPoint], band: VO2GoodBand) -> ClosedRange<Double> {
        var values = [band.low, band.high]
        values.append(contentsOf: points.map(\.value))
        guard let lo = values.min(), let hi = values.max() else { return 20...50 }
        let padding = max(2.0, (hi - lo) * 0.10)
        return (lo - padding)...(hi + padding)
    }

    /// ACSM "Good" VO₂max range, picked for the athlete's age + biological sex.
    /// Brackets the user supplied verbatim (20-29, 40-49, 60+) plus midpoint
    /// interpolations for the gaps (30-39, 50-59). Falls back to the male
    /// 30-39 range if Apple Health hasn't shared age/sex.
    private struct VO2GoodBand { let low: Double; let high: Double }

    private var vo2GoodBand: VO2GoodBand {
        let age = session.age ?? 35
        if session.sex == .female {
            switch age {
            case ..<30:  return .init(low: 32.0, high: 36.0)
            case 30..<40: return .init(low: 31.0, high: 34.5)  // interpolated
            case 40..<50: return .init(low: 30.0, high: 33.0)
            case 50..<60: return .init(low: 25.5, high: 29.0)  // interpolated
            default:     return .init(low: 21.0, high: 25.0)
            }
        } else {
            switch age {
            case ..<30:  return .init(low: 42.5, high: 46.4)
            case 30..<40: return .init(low: 40.75, high: 45.05) // interpolated
            case 40..<50: return .init(low: 39.0, high: 43.7)
            case 50..<60: return .init(low: 32.5, high: 36.85) // interpolated
            default:     return .init(low: 26.0, high: 30.0)
            }
        }
    }

    /// Short descriptor of which ACSM bracket the band came from — shown next
    /// to the unit so the reader knows the band is *theirs*, not generic.
    private var bandSubtitle: String {
        let sexLabel = session.sex == .female ? "♀" : "♂"
        if let age = session.age { return "\(sexLabel) \(age)" }
        return sexLabel
    }

    /// Fitness = CTL, the 42-day EWMA of daily training load — the slow-moving
    /// curve that captures how much chronic work the body has absorbed.
    private var fitnessChart: some View {
        let points = ctlTsbSeries.ctl
        return chartCard(title: "Fitness (CTL)", unit: "42-day EWMA of daily load", points: points) {
            Chart(points, id: \.date) { p in
                AreaMark(x: .value("Day", p.date, unit: .day), y: .value("CTL", p.value))
                    .foregroundStyle(.blue.opacity(0.18))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", p.date, unit: .day), y: .value("CTL", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.blue)
            }
        }
    }

    /// Form = CTL − ATL: positive = tapered and fresh, negative = fatigued.
    /// The same TSB curve TrainingPeaks/Coggan use for race-readiness.
    private var formChart: some View {
        let points = ctlTsbSeries.tsb
        return chartCard(title: "Form (TSB)", unit: "+ fresh · − fatigued", points: points) {
            Chart(points, id: \.date) { p in
                LineMark(x: .value("Day", p.date, unit: .day), y: .value("TSB", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.purple)
                RuleMark(y: .value("Zero", 0))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Computes the CTL and TSB series once per render, sharing work between
    /// the Fitness and Form charts. Empty when there isn't enough history.
    private var ctlTsbSeries: (ctl: [TrendPoint], tsb: [TrendPoint]) {
        let history = session.history
        guard history.count >= 2 else { return ([], []) }
        let loads = history.map { $0.workoutLoad ?? 0 }
        let ctl = EWMA.series(of: loads, tau: 42)
        let atl = EWMA.series(of: loads, tau: 7)
        let ctlPts = zip(history, ctl).map { TrendPoint(date: $0.0.date, value: $0.1) }
        let tsbPts = zip(history, zip(ctl, atl).map { $0 - $1 })
            .map { TrendPoint(date: $0.0.date, value: $0.1) }
        return (ctlPts, tsbPts)
    }

    // MARK: - Helpers

    private struct TrendPoint { let date: Date; let value: Double }
    private struct StagePoint: Identifiable {
        let id = UUID(); let date: Date; let stage: String; let hours: Double
    }

    /// Build a clean (date, value) series from the history, dropping missing days.
    private func series(_ pick: (DailyMetrics) -> Double?) -> [TrendPoint] {
        session.history.compactMap { day in
            guard let v = pick(day), v.isFinite else { return nil }
            return TrendPoint(date: day.date, value: v)
        }
    }

    @ViewBuilder
    private func chartCard<Content: View>(title: String, unit: String, points: [TrendPoint],
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline).bold()
                Spacer()
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
            if points.isEmpty {
                Text("No data in range")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                content().frame(height: 150)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
