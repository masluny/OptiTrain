import Foundation

/// Orchestrator that runs every engine in the right order and assembles a
/// single immutable snapshot. Pure — takes data in, returns a snapshot. The
/// only async work is upstream (HealthKit). Composition order matters: load
/// must run before recovery debt (which uses TRIMP), and the physiology
/// profile depends on all the upstream engines.
struct AdaptiveIntelligencePipeline {

    struct Inputs {
        let today: DailyMetrics
        let history: [DailyMetrics]                     // 30+ days, includes today
        let workouts: [WorkoutSummary]                  // 90+ days
        let vo2Samples: [VO2maxTrajectory.Sample]
        let bmi: Double?
        let age: Int?
        let sex: AthleteSex?
        let scoreDate: Date
        let usingPreviousDay: Bool
        let useWristTemperature: Bool
        /// Fraction (0...1) of recent days with any observed signal.
        let observedDayCoverage: Double
        /// Number of days loaded into `history`.
        let historyWindowDays: Int
    }

    // Engines are tiny structs — instantiating per-run is essentially free.
    private let loadEngine = TrainingLoadEngine()
    private let recoveryDebtEngine = RecoveryDebtModel()
    private let stabilityEngine = AutonomicStability()
    private let vo2Engine = VO2maxTrajectory()
    private let efficiencyEngine = AerobicEfficiency()
    private let racePrediction = RaceTimePrediction()
    private let physiologyBuilder = PhysiologyProfileBuilder()
    private let eventEngine = EventReadinessEngine()
    private let bodyEfficiencyEngine = BodyEfficiency()
    private let plateau = PlateauDetector()
    private let injury = InjuryAndBurnoutRisk()
    private let sleep = SleepIntelligence()
    private let response = ResponseProfile()
    private let extractor = FeatureExtractor()

    init() {}

    func snapshot(_ i: Inputs) -> AdaptiveIntelligenceSnapshot {
        let sortedHistory = i.history.sorted { $0.date < $1.date }
        let restingHR = sortedHistory.compactMap(\.restingHeartRate).last ?? 60
        // Max HR: prefer the highest HR actually observed across recorded
        // workouts; otherwise Tanaka (208 − 0.7·age) from DOB, with a neutral
        // 190 bpm fallback when neither is known. Feeds every HR-reserve
        // (Karvonen) intensity, Banister TRIMP and the Uth VO₂max fallback.
        let observedPeakHR = i.workouts.compactMap(\.maxHeartRate).max()
        let maxHR = MaxHeartRate.estimate(observedPeak: observedPeakHR, age: i.age)
        let sex = i.sex ?? .male    // TRIMP defaults to the male curve when sex is unknown

        // Daily TRIMP for the last 60 days.
        let calendar = Calendar.current
        let workoutsByDay = Dictionary(grouping: i.workouts) { calendar.startOfDay(for: $0.start) }
        // Avoid treating fully missing watch days as confirmed zero-load days.
        let observedHistory = sortedHistory.filter { d in
            let dayKey = calendar.startOfDay(for: d.date)
            let hasWorkout = !(workoutsByDay[dayKey] ?? []).isEmpty
            return d.hasAnySignal || hasWorkout
        }
        let daily: [TrainingLoadEngine.DailyLoad] = observedHistory.map { d in
            let dayKey = calendar.startOfDay(for: d.date)
            let dayWs = workoutsByDay[dayKey] ?? []
            let trimp = TrainingImpulse.daily(dayWs, restingHR: restingHR, maxHR: maxHR, sex: sex)
            return .init(date: d.date, trimp: trimp)
        }
        let loadSnap = loadEngine.snapshot(from: daily)

        // Recovery + autonomic.
        let debt = recoveryDebtEngine.snapshot(history: sortedHistory, loads: daily)
        let stability = stabilityEngine.snapshot(history: sortedHistory)

        // Performance.
        let vo2 = vo2Engine.snapshot(from: i.vo2Samples)
        let efficiency = efficiencyEngine.snapshot(from: i.workouts, restingHR: restingHR)

        // Race predictions for every supported distance.
        let bestRef = racePrediction.bestReference(from: i.workouts)
        let longestRunWindowDays = 120
        let longestRunCutoff = calendar.date(byAdding: .day, value: -longestRunWindowDays, to: i.scoreDate) ?? i.scoreDate
        let longestRun = i.workouts
            .filter { $0.kind == .run && $0.start >= longestRunCutoff }
            .compactMap(\.distanceMeters)
            .max() ?? 0
        let predictions: [RaceTimePrediction.Prediction] = {
            guard let ref = bestRef else { return [] }
            return RaceTimePrediction.RaceDistance.allCases
                .filter(\.supportsTimePrediction)
                .map {
                racePrediction.predict($0, from: ref, longestRecentRunMeters: longestRun)
            }
        }()

        // Physiology profile drives the event readiness engine.
        let profile = physiologyBuilder.build(.init(
            history: sortedHistory,
            workouts: i.workouts,
            load: loadSnap,
            recoveryDebt: debt,
            autonomic: stability,
            vo2max: vo2,
            aerobicEfficiency: efficiency,
            bestRunReference: bestRef,
            restingHR: restingHR,
            maxHR: maxHR
        ))
        let baseConfidence = Confidence.combine([
            Confidence.fromSampleDensity(present: observedHistory.count, target: 28),
            Confidence.fromSampleDensity(present: i.workouts.count, target: 12),
            loadSnap?.confidence ?? Confidence(0.5),
            debt?.confidence ?? Confidence(0.5),
            Confidence(i.observedDayCoverage)
        ])
        // Are VO₂max and aerobic efficiency trending up? Folded into one 0–1
        // signal (0.5 = flat) that lets demonstrated *progress* lift race
        // readiness on top of raw training coverage.
        let fitnessTrend: Double = {
            var signals: [Double] = []
            if let v = vo2 { signals.append(min(1, max(0, 0.5 + (v.trendSlopePerWeek / 0.3) * 0.5))) }
            if let e = efficiency { signals.append(min(1, max(0, 0.5 + (e.trendSlopePerWeek / 0.1) * 0.5))) }
            guard !signals.isEmpty else { return 0.5 }
            return signals.reduce(0, +) / Double(signals.count)
        }()
        let events = eventEngine.allReadiness(
            profile: profile,
            performance: .init(reference: bestRef,
                               longestRunMeters: longestRun,
                               longestRunWindowDays: longestRunWindowDays,
                               fitnessTrend: fitnessTrend,
                               observedDayCoverage: i.observedDayCoverage,
                               historyWindowDays: i.historyWindowDays),
            baseConfidence: baseConfidence
        )
        let bodyEfficiency = bodyEfficiencyEngine.snapshot(profile: profile, bmi: i.bmi, confidence: baseConfidence)

        // Risk + behavior layers.
        let plateauSnap = plateau.detect(workouts: i.workouts, restingHR: restingHR, load: loadSnap)
        let injurySnap = injury.snapshot(load: loadSnap, debt: debt, stability: stability, recentWorkouts: i.workouts)
        let sleepSnap = sleep.snapshot(history: sortedHistory, workouts: i.workouts)
        let responseSnap = response.classify(workouts: i.workouts, vo2Trajectory: vo2, debt: debt)

        // Backward-compatible legacy ReadinessScore (TodayView still uses this).
        let legacyCalc = ReadinessCalculator(useWristTemperature: i.useWristTemperature)
        let legacy = legacyCalc.score(today: i.today, history: sortedHistory.filter { $0.date < i.today.date })

        // ML feature vector.
        let features = extractor.extract(.init(
            today: i.today, history: sortedHistory,
            load: loadSnap, debt: debt, stability: stability,
            vo2: vo2, eff: efficiency
        ))

        return AdaptiveIntelligenceSnapshot(
            computedAt: Date(),
            scoreDate: i.scoreDate,
            usingPreviousDay: i.usingPreviousDay,
            readiness: legacy,
            load: loadSnap,
            recoveryDebt: debt,
            autonomicStability: stability,
            vo2maxTrajectory: vo2,
            aerobicEfficiency: efficiency,
            racePredictions: predictions,
            eventReadiness: events,
            physiologyProfile: profile,
            bodyEfficiency: bodyEfficiency,
            plateau: plateauSnap,
            injuryRisk: injurySnap,
            sleepIntelligence: sleepSnap,
            responseProfile: responseSnap,
            features: features
        )
    }
}
