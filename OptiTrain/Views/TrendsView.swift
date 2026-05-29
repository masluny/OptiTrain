import SwiftUI
import Charts

struct TrendsView: View {
    @Environment(AppSession.self) private var session
    @State private var category: TrendCategory = .all

    /// The lens applied to the trend list. `all` shows everything; the others
    /// narrow to one family of signals so the screen isn't a wall of charts.
    enum TrendCategory: String, CaseIterable, Identifiable {
        case all = "All"
        case recovery = "Recovery"
        case sleep = "Sleep"
        case training = "Training"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .all: "square.grid.2x2"
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

                if session.history.isEmpty {
                    ContentUnavailableView("No history yet",
                                           systemImage: "chart.line.uptrend.xyaxis",
                                           description: Text("Charts appear once Apple Health has a few days of data."))
                        .padding(.top, 60)
                } else {
                    Text("Last \(session.history.count) days")
                        .font(.caption).foregroundStyle(.secondary)

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
