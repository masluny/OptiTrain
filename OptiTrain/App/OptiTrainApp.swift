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
    private var calculator: ReadinessCalculator {
        ReadinessCalculator(useWristTemperature: UserSettings.current.useWristTemperature)
    }

    func bootstrap() async {
        state = .requestingAuth
        do {
            try await health.requestAuthorization()
            await refresh()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        state = .loading
        progress = 0
        do {
            // Pull a wider history for the v1 engines. The 35-day daily-metrics
            // loop is the dominant cost (it's sequential per day) so it owns
            // the lion's share of the progress bar — 0 → 70%. The other three
            // fetches run in parallel and are usually done by the time the
            // daily loop finishes.
            async let allDaysTask = health.recentDailyMetrics(days: 35) { [weak self] completed in
                Task { @MainActor [weak self] in
                    self?.progress = min(0.70, Double(completed) / 35.0 * 0.70)
                }
            }
            async let workoutsTask = health.workouts(in: .init(start: Calendar.current.date(byAdding: .day, value: -90, to: Date())!, end: Date()))
            async let vo2Task = health.vo2maxSamples(days: 180)
            async let bodyCompTask = health.bodyComposition()

            let all = try await allDaysTask
            let workouts90 = try await workoutsTask
            let vo2Samples = try await vo2Task
            let bodyComp = await bodyCompTask
            let age = health.ageInYears()
            let sex = health.biologicalSex()
            progress = 0.85    // all HealthKit fetches done; pipeline next

            let sorted = all.sorted { $0.date < $1.date }
            guard let resolved = resolveScoreDay(in: sorted) else {
                state = .failed("No sleep data in the last 30 days. Check Apple Health permissions in Settings → Diagnostics.")
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
                useWristTemperature: UserSettings.current.useWristTemperature
            ))

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
            self.progress = 1.0
            self.state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Resolve the day to score and, when sleep had to be borrowed, the night it
    /// came from. We always score the most recent day so the readiness is for
    /// *today*. If today has no sleep — you're up past midnight, or you didn't
    /// wear the watch to bed — carry the most recent recorded night forward into
    /// today's metrics so you still get a score. Returns nil only when there is
    /// no sleep anywhere in the window.
    private func resolveScoreDay(in sorted: [DailyMetrics]) -> (day: DailyMetrics, sleepFrom: Date?)? {
        guard let latest = sorted.last else { return nil }
        if (latest.sleep?.asleepDuration ?? 0) > 0 {
            return (latest, nil)
        }
        guard let lastSlept = sorted.reversed().first(where: { ($0.sleep?.asleepDuration ?? 0) > 0 }) else {
            return nil
        }
        return (latest.replacingSleep(lastSlept.sleep), lastSlept.date)
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
}
