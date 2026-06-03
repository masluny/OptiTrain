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
    /// Human-readable phase text shown next to the progress ring. Per-stage
    /// granularity ("Loading daily metrics (12/35)…") so cold-start never
    /// looks frozen — driven from the per-day callback on the HealthKit fetch.
    var loadingStatus: String = "Connecting to Apple Health…"
    /// Per-input notes about missing data ("HRV is unavailable, so …").
    /// Surfaces *which* inputs are missing and what the app did instead so
    /// users with sparse signals don't blame the app for nothing.
    var dataQualityNotes: [String] = []
    /// Count of unique days in the trailing 90-day window that had any
    /// observed signal (daily metrics or a workout). 90 is the long-term
    /// window the Athlete Level engine reads — drives the data-coverage
    /// bar in the expanded view so users can see how much training history
    /// the score is built from.
    var trainingDaysObserved: Int = 0
    /// The denominator the trainingDaysObserved is compared against — 90.
    let trainingDaysTarget: Int = 90
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
    /// Monotonic counter so a refresh kicked off while a previous one is still
    /// in flight (rapid pull-to-refresh, tab switch, etc.) can drop the older
    /// run's stale state updates on the floor instead of stomping the newer one.
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
            // Daily-metrics is the dominant cost (now ~3× faster thanks to the
            // bounded-parallelism loop in HealthKitManager) so it still owns
            // most of the progress bar. The other fetches use `try?` so a
            // single failure (e.g. a denied auth type) doesn't kill the run.
            async let allDaysTask = health.recentDailyMetrics(days: 35) { [weak self] completed in
                Task { @MainActor [weak self] in
                    guard let self, self.refreshGeneration == generation else { return }
                    self.progress = min(0.72, Double(completed) / 35.0 * 0.72)
                    self.loadingStatus = "Loading daily metrics (\(completed)/35)…"
                }
            }
            // A year of workouts lets the racePrediction engine see PRs that
            // happened more than 90 days ago — biggest qualitative upgrade for
            // event readiness on athletes who train consistently year-round.
            async let workoutsTask: [WorkoutSummary] = (try? await health.workouts(in: .init(
                start: Calendar.current.date(byAdding: .day, value: -365, to: Date())!,
                end: Date()))) ?? []
            async let vo2Task: [VO2maxTrajectory.Sample] = (try? await health.vo2maxSamples(days: 180)) ?? []
            async let bodyCompTask = health.bodyComposition()

            // Each fetch returns `[]` / `nil` on failure rather than throwing,
            // so a missing permission for one type doesn't break all of them.
            let all = (try? await allDaysTask) ?? []
            guard refreshGeneration == generation else { return }
            loadingStatus = "Loading workouts…"
            progress = max(progress, 0.78)

            let workouts365 = await workoutsTask
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
            let observedCoverage = observedDayCoverage(in: sorted, workouts: workouts365)
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
            let weekWorkouts = workouts365.filter { weekInterval.contains($0.start) }
            // Read the chosen goal at refresh time so the advisor's picks
            // align with it. nil → general advice path.
            let goal = UserDefaults.standard.string(forKey: UserSettingsKey.selectedGoal)
                .flatMap { Goal(rawValue: $0) }
            let plan = advisor.plan(for: .init(readiness: score,
                                               recentWorkouts: weekWorkouts,
                                               consecutiveLowReadinessDays: lowStreak,
                                               goal: goal))

            // Run the Adaptive Intelligence pipeline.
            loadingStatus = "Running intelligence pipeline…"
            let snapshot = pipeline.snapshot(.init(
                today: scoreDay,
                history: sorted,
                workouts: workouts365,
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
            self.trainingDaysObserved = countTrainingDays(in: 90,
                                                          history: sorted,
                                                          workouts: workouts365,
                                                          relativeTo: Date())
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

    /// Resolve the day to score and, when sleep had to be borrowed, the night
    /// it came from. We always score the most recent day so readiness is for
    /// *today*. Even when no sleep exists anywhere in the window we still
    /// return a (neutral-sleep) row instead of nil — that's the difference
    /// between "app shows you what it can" and "app gives up". The
    /// `hasAnySleepData` flag tells the caller whether sleep is real data or
    /// a placeholder, so the data-quality notes can warn the user.
    private func resolveScoreDay(in sorted: [DailyMetrics]) -> (day: DailyMetrics, sleepFrom: Date?, hasAnySleepData: Bool)? {
        guard let latest = sorted.last else { return nil }
        if (latest.sleep?.asleepDuration ?? 0) > 0 {
            return (latest, nil, true)
        }
        guard let lastSlept = sorted.reversed().first(where: { ($0.sleep?.asleepDuration ?? 0) > 0 }) else {
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

    /// Per-input notes about what data is missing and how the app adapted.
    /// Tells the user "we noticed and worked around it" instead of letting
    /// them wonder why every score is neutral.
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
        // Only flag wrist temperature when the user *wants* it. If they've
        // turned the toggle off in Settings, missing data is the expected
        // state — no need to nag.
        if UserSettings.current.useWristTemperature,
           scoreDay.wristTemperatureDelta == nil,
           history.allSatisfy({ $0.wristTemperatureDelta == nil }) {
            notes.append("Wrist temperature is unavailable (unsupported watch or no data), so temperature weighting is neutralized.")
        }
        return notes
    }

    /// Unique calendar days in the trailing `window` with either a daily
    /// signal or a recorded workout. Drives the Athlete Level data-coverage
    /// bar — concrete "27 of 90 days" framing the user can act on.
    private func countTrainingDays(in window: Int,
                                   history: [DailyMetrics],
                                   workouts: [WorkoutSummary],
                                   relativeTo reference: Date) -> Int {
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -window, to: reference) else {
            return 0
        }
        var observedDays: Set<Date> = []
        for d in history where d.date >= cutoff && d.hasAnySignal {
            observedDays.insert(calendar.startOfDay(for: d.date))
        }
        for w in workouts where w.start >= cutoff {
            observedDays.insert(calendar.startOfDay(for: w.start))
        }
        return min(window, observedDays.count)
    }

    /// What fraction of the loaded history has *any* observed signal vs. being
    /// a missing-watch day. Feeds the pipeline's confidence calculation and the
    /// observedHistory filter so missing days don't get counted as confirmed
    /// zeros in CTL/ATL averages.
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
