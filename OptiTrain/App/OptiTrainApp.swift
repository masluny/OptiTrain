import SwiftUI

@main
struct OptiTrainApp: App {
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .task { await session.bootstrap() }
        }
    }
}

@Observable
final class AppSession {
    enum LoadState: Equatable {
        case idle
        case requestingAuth
        case loading
        case ready
        case failed(String)
    }

    var state: LoadState = .idle
    /// 0.0 → 1.0 fill for the loading ring. Climbs in real time as HealthKit
    /// queries complete so the user can tell the app is actually working and
    /// not stuck. Reset to 0 at the start of every refresh.
    var progress: Double = 0
    /// Human-readable phase text shown next to the progress ring.
    var loadingStatus: String = "Connecting to Apple Health…"
    /// Data coverage notes shown in UI so users know exactly which inputs are
    /// missing and why some scores/charts may be neutral.
    var dataQualityNotes: [String] = []
    var todayReadiness: ReadinessScore?
    var plan: AdvisorPlan?
    var history: [DailyMetrics] = []
    var recentWorkouts: [WorkoutSummary] = []
    /// Raw VO₂max samples from HealthKit (date + value), exposed so the Trends
    /// view's Performance section can plot the trajectory directly without
    /// re-fetching from the engine.
    var vo2Samples: [VO2maxTrajectory.Sample] = []
    /// HealthKit demographics — drive the age/sex-adjusted reference band on
    /// the VO₂max chart in Trends. nil when not shared with Apple Health.
    var age: Int?
    var sex: AthleteSex?
    /// When true, today's own sleep was missing so the score reuses the most
    /// recent recorded night (still awake past midnight, or watch not worn to bed).
    var showingPreviousDay: Bool = false
    var scoreDate: Date?
    /// The night the sleep block was borrowed from, set when `showingPreviousDay`.
    var sleepCarriedFrom: Date?

    /// Full Adaptive Intelligence Engine snapshot — populated by the pipeline.
    /// Nil while loading or after a hard failure.
    var intelligence: AdaptiveIntelligenceSnapshot?

    private let health = HealthKitManager.shared
    private let advisor = ActivityAdvisor()
    private let pipeline = AdaptiveIntelligencePipeline()
    private var refreshGeneration: UInt64 = 0
    private var calculator: ReadinessCalculator {
        ReadinessCalculator(useWristTemperature: UserSettings.current.useWristTemperature)
    }

    @MainActor
    func bootstrap() async {
        state = .requestingAuth
        loadingStatus = "Requesting Apple Health access…"
        do {
            try await health.requestAuthorization()
            await refresh()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    @MainActor
    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration

        state = .loading
        progress = 0
        loadingStatus = "Preparing refresh…"
        dataQualityNotes = []
        do {
            // Pull a wider history for the v1 engines. This is still the
            // dominant cost, so we map most of the progress bar to this loop.
            async let allDaysTask = health.recentDailyMetrics(days: 35) { [weak self] completed in
                Task { @MainActor [weak self] in
                    guard let self, self.refreshGeneration == generation else { return }
                    self.progress = min(0.72, Double(completed) / 35.0 * 0.72)
                    self.loadingStatus = "Loading daily metrics (\(completed)/35)…"
                }
            }
            async let workoutsTask: [WorkoutSummary] = (try? await health.workouts(in: .init(start: Calendar.current.date(byAdding: .day, value: -365, to: Date())!, end: Date()))) ?? []
            async let vo2Task: [VO2maxTrajectory.Sample] = (try? await health.vo2maxSamples(days: 180)) ?? []
            async let bodyCompTask = health.bodyComposition()

            let all = (try? await allDaysTask) ?? []
            guard refreshGeneration == generation else { return }
            loadingStatus = "Loading workouts…"
            progress = max(progress, 0.78)

            let workouts90 = await workoutsTask
            guard refreshGeneration == generation else { return }
            loadingStatus = "Loading VO₂max…"
            progress = max(progress, 0.84)

            let vo2Samples = await vo2Task
            guard refreshGeneration == generation else { return }
            loadingStatus = "Loading body composition…"
            progress = max(progress, 0.88)

            let bodyComp = await bodyCompTask
            guard refreshGeneration == generation else { return }
            loadingStatus = "Loading demographics…"
            progress = max(progress, 0.92)

            let age = health.ageInYears()
            let sex = health.biologicalSex()
            guard refreshGeneration == generation else { return }
            loadingStatus = "Computing readiness…"
            progress = max(progress, 0.95)

            let sorted = all.sorted { $0.date < $1.date }
            let observedCoverage = observedDayCoverage(in: sorted, workouts: workouts90)
            guard let resolved = resolveScoreDay(in: sorted) else {
                state = .failed("No daily health data is available yet. Open Apple Health, allow permissions, then pull to refresh.")
                return
            }
            let scoreDay = resolved.day
            let carriedSleepFrom = resolved.sleepFrom
            let usingFallback = carriedSleepFrom != nil
            let historyForScore = sorted.filter { $0.date < scoreDay.date }
            let score = calculator.score(today: scoreDay, history: historyForScore)
            let lowStreak = consecutiveLowDays(in: historyForScore + [scoreDay])
            let weekInterval = DateInterval(start: Calendar.current.date(byAdding: .day, value: -7, to: Date())!, end: Date())
            let weekWorkouts = workouts90.filter { weekInterval.contains($0.start) }
            let plan = advisor.plan(for: .init(readiness: score, recentWorkouts: weekWorkouts, consecutiveLowReadinessDays: lowStreak))

            // Run the Adaptive Intelligence pipeline.
            loadingStatus = "Running intelligence pipeline…"
            let snapshot = pipeline.snapshot(.init(
                today: scoreDay,
                history: sorted,
                workouts: workouts90,
                vo2Samples: vo2Samples,
                bmi: bodyComp.bmi,
                age: age,
                sex: sex,
                scoreDate: scoreDay.date,
                usingPreviousDay: usingFallback,
                useWristTemperature: UserSettings.current.useWristTemperature,
                observedDayCoverage: observedCoverage,
                historyWindowDays: sorted.count
            ))
            guard refreshGeneration == generation else { return }

            self.history = sorted
            self.todayReadiness = score
            self.plan = plan
            self.recentWorkouts = weekWorkouts
            self.vo2Samples = vo2Samples
            self.age = age
            self.sex = sex
            self.showingPreviousDay = usingFallback
            self.scoreDate = scoreDay.date
            self.sleepCarriedFrom = carriedSleepFrom
            self.intelligence = snapshot
            self.dataQualityNotes = buildDataQualityNotes(scoreDay: scoreDay,
                                                          history: sorted,
                                                          hasAnySleepData: resolved.hasAnySleepData,
                                                          observedCoverage: observedCoverage)
            self.loadingStatus = "Up to date"
            self.progress = 1.0
            self.state = .ready
        } catch {
            guard refreshGeneration == generation else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Resolve the day to score and, when sleep had to be borrowed, the night it
    /// came from. We always score the most recent day so the readiness is for
    /// *today*. If today has no sleep — you're up past midnight, or you didn't
    /// wear the watch to bed — carry the most recent recorded night forward into
    /// today's metrics so you still get a score. Returns nil only when there are
    /// no daily rows at all.
    private func resolveScoreDay(in sorted: [DailyMetrics]) -> (day: DailyMetrics, sleepFrom: Date?, hasAnySleepData: Bool)? {
        guard let latest = sorted.last else { return nil }
        if (latest.sleep?.asleepDuration ?? 0) > 0 {
            return (latest, nil, true)
        }
        guard let lastSlept = sorted.reversed().first(where: { ($0.sleep?.asleepDuration ?? 0) > 0 }) else {
            // Still score "today" with neutral sleep so the app remains usable.
            return (latest, nil, false)
        }
        return (latest.replacingSleep(lastSlept.sleep), lastSlept.date, true)
    }

    private func consecutiveLowDays(in days: [DailyMetrics]) -> Int {
        // Score each of the trailing 7 days using only the days that came before it.
        let sorted = days.sorted { $0.date < $1.date }
        let window = sorted.suffix(7)
        var count = 0
        for day in window.reversed() {
            let prior = sorted.filter { $0.date < day.date }
            let s = calculator.score(today: day, history: prior)
            if s.value < 55 { count += 1 } else { break }
        }
        return count
    }

    private func buildDataQualityNotes(scoreDay: DailyMetrics,
                                       history: [DailyMetrics],
                                       hasAnySleepData: Bool,
                                       observedCoverage: Double) -> [String] {
        var notes: [String] = []
        if observedCoverage < 0.70 {
            notes.append("Only \(Int((observedCoverage * 100).rounded()))% of recent days had recorded signals. Missing-watch days are excluded where possible, and confidence is reduced.")
        }
        if !hasAnySleepData {
            notes.append("No sleep data found in the loaded window, so sleep uses a neutral placeholder score. Check Apple Health sleep permissions and wear your watch overnight.")
        }
        if scoreDay.overnightHRV == nil && history.allSatisfy({ $0.overnightHRV == nil }) {
            notes.append("HRV is unavailable, so readiness is computed without HRV trend context.")
        }
        if scoreDay.restingHeartRate == nil && history.allSatisfy({ $0.restingHeartRate == nil }) {
            notes.append("Resting heart rate is unavailable, so autonomic baseline confidence is reduced.")
        }
        if scoreDay.respiratoryRate == nil && history.allSatisfy({ $0.respiratoryRate == nil }) {
            notes.append("Respiratory rate is unavailable on this device/account, so respiratory trends are omitted.")
        }
        if scoreDay.wristTemperatureDelta == nil && history.allSatisfy({ $0.wristTemperatureDelta == nil }) {
            notes.append("Wrist temperature is unavailable (unsupported watch or no data), so temperature weighting is neutralized.")
        }
        return notes
    }

    private func observedDayCoverage(in history: [DailyMetrics], workouts: [WorkoutSummary]) -> Double {
        guard !history.isEmpty else { return 0 }
        let calendar = Calendar.current
        let workoutDays = Set(workouts.map { calendar.startOfDay(for: $0.start) })
        let observed = history.filter { day in
            day.hasAnySignal || workoutDays.contains(calendar.startOfDay(for: day.date))
        }.count
        return Double(observed) / Double(history.count)
    }
}
