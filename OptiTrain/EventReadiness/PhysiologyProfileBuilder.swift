import Foundation

/// Builds a PhysiologyProfile from raw HealthKit-derived inputs. Each component
/// is scored 0-100 with an explicit formula. The whole thing is deterministic
/// and unit-testable. Where a real model isn't possible yet (heat adaptation,
/// fueling without nutrition data) we surface the placeholder transparently
/// and set the component to a conservative midpoint.
struct PhysiologyProfileBuilder: Sendable {

    struct Inputs {
        let history: [DailyMetrics]
        let workouts: [WorkoutSummary]       // 90 days
        let load: TrainingLoadEngine.Snapshot?
        let recoveryDebt: RecoveryDebtModel.Snapshot?
        let autonomic: AutonomicStability.Snapshot?
        let vo2max: VO2maxTrajectory.Snapshot?
        let aerobicEfficiency: AerobicEfficiency.Snapshot?
        let bestRunReference: RaceTimePrediction.Reference?
        let restingHR: Double
        let maxHR: Double
    }

    init() {}

    func build(_ i: Inputs) -> PhysiologyProfile {
        let perfVO2 = performanceVO2(i.bestRunReference)
        let vo2 = vo2Score(i.vo2max, performanceVO2: perfVO2, restingHR: i.restingHR, maxHR: i.maxHR)
        let threshold = thresholdScore(i.aerobicEfficiency, vo2Part: vo2)
        let anaerobic = anaerobicScore(workouts: i.workouts, vo2Score: vo2)
        let durability = durabilityScore(workouts: i.workouts, vo2max: i.vo2max)
        let fueling = fuelingScore(workouts: i.workouts)
        let heat = heatScore()  // placeholder — see notes
        let recoveryResilience = recoveryScore(i.recoveryDebt)
        let sleepConsistency = sleepConsistencyScore(history: i.history)
        let sleepQuality = sleepQualityScore(history: i.history)
        // Autonomic backbone for daily readiness: current 7-day HRV mean vs the
        // athlete's personal baseline, as a z-derived 0–100. This is exactly the
        // signal WHOOP Recovery / Oura HRV Balance / Garmin HRV Status anchor
        // their daily recovery on — distinct from `stabilityScore` (CV-based
        // consistency, Plews et al.), which is a different question (how steady
        // your autonomic state has been), not what the commercial recovery
        // scores read off. Falls back to the stability score if no baseline yet.
        let autonomic = i.autonomic?.hrvBaselineScore
            ?? i.autonomic?.stabilityScore
            ?? 60
        let volumeTolerance = volumeScore(workouts: i.workouts)
        let fatigueResistance = fatigueResistanceScore(workouts: i.workouts, restingHR: latestRHR(i.history))
        let specificity = specificityScore(workouts: i.workouts)
        let freshness = freshnessScore(i.load)

        return PhysiologyProfile(
            vo2maxScore: vo2,
            thresholdScore: threshold,
            anaerobicCapacityScore: anaerobic,
            durabilityScore: durability,
            fuelingScore: fueling,
            heatScore: heat,
            recoveryResilienceScore: recoveryResilience,
            sleepConsistencyScore: sleepConsistency,
            volumeToleranceScore: volumeTolerance,
            fatigueResistanceScore: fatigueResistance,
            specificityScore: specificity,
            freshnessScore: freshness,
            autonomicScore: autonomic,
            sleepQualityScore: sleepQuality
        )
    }

    // MARK: - Components

    /// Performance-grounded VO₂max from the athlete's best recent race-equivalent
    /// effort (Jack Daniels' VDOT). nil when we have no usable run reference.
    private func performanceVO2(_ ref: RaceTimePrediction.Reference?) -> Double? {
        guard let ref, ref.distanceMeters > 0, ref.durationSeconds > 0 else { return nil }
        let v = RaceTimePrediction.vdot(distanceMeters: ref.distanceMeters, durationSeconds: ref.durationSeconds)
        return v > 0 ? v : nil
    }

    /// VO₂max → 0–100, calibrated so 28 → 25, 40 → 50, 64 → 100. Grounded in the
    /// *highest* of: the measured (HealthKit) VO₂max, the performance VDOT, and —
    /// when neither exists — the Uth heart-rate-ratio estimate (15.3·HRmax/HRrest),
    /// so a real race result can't be dragged down by a stale or walk-derived
    /// estimate, and an athlete who never records an outdoor run still gets a
    /// physiologically grounded value rather than a flat 50.
    private func vo2Score(_ snap: VO2maxTrajectory.Snapshot?, performanceVO2: Double?, restingHR: Double, maxHR: Double) -> Double {
        let uth = VO2maxTrajectory.uthEstimate(maxHR: maxHR, restingHR: restingHR)
        let measured = [snap?.smoothed, performanceVO2].compactMap { $0 }.max()
        // Prefer measured/VDOT; fall back to the HR-ratio estimate only when we
        // have no direct signal at all.
        let v = measured ?? uth
        return max(0, min(100, (v - 28.0) / 36.0 * 75.0 + 25.0))
    }

    /// Threshold proxy: aerobic efficiency trend + the (already computed) VO₂max
    /// component, so both share one grounded VO₂max value.
    private func thresholdScore(_ ef: AerobicEfficiency.Snapshot?, vo2Part: Double) -> Double {
        let efPart: Double = {
            guard let s = ef else { return 50 }
            // Slope > +0.1/wk → great; < -0.1 → bad.
            return max(0, min(100, 60 + s.trendSlopePerWeek * 200))
        }()
        return 0.6 * vo2Part + 0.4 * efPart
    }

    /// Recent high-intensity exposure as a proxy for anaerobic capacity.
    private func anaerobicScore(workouts: [WorkoutSummary], vo2Score: Double) -> Double {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let highIntensityMinutes = workouts
            .filter { $0.start >= cutoff && ($0.averageHeartRate ?? 0) >= 165 }
            .map { $0.duration / 60 }
            .reduce(0, +)
        // 60 min of HIIT/threshold work in 30 days = strong.
        let measured = max(0, min(100, highIntensityMinutes / 60.0 * 100))
        // Absent HR-zone data, anaerobic capacity broadly tracks the aerobic
        // engine, so floor it there rather than reading a hard 0 for athletes
        // who simply don't record HIIT heart-rate.
        return max(measured, 0.55 * vo2Score)
    }

    /// Longest sustained effort × cumulative long-run volume in 90 days.
    private func durabilityScore(workouts: [WorkoutSummary], vo2max: VO2maxTrajectory.Snapshot?) -> Double {
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        let recent = workouts.filter { $0.start >= cutoff && $0.kind == .run }
        let longest = recent.map { $0.distanceMeters ?? 0 }.max() ?? 0
        let longRunCount = recent.filter { ($0.distanceMeters ?? 0) > 16_000 }.count
        // 25 km longest + 6 long runs ≈ 100.
        let longestScore = min(100, longest / 25_000 * 100)
        let countScore = min(100, Double(longRunCount) / 6.0 * 100)
        return 0.6 * longestScore + 0.4 * countScore
    }

    /// Time-on-feet history (>90 min runs in last 60 days). Proxy for fueling
    /// tolerance — real version would integrate logged nutrition.
    private func fuelingScore(workouts: [WorkoutSummary]) -> Double {
        let cutoff = Date().addingTimeInterval(-60 * 86_400)
        let longHours = workouts
            .filter { $0.start >= cutoff && $0.duration >= 90 * 60 }
            .map { $0.duration / 3600 }
            .reduce(0, +)
        return max(0, min(100, longHours / 20 * 100))   // 20h of long sessions = 100
    }

    /// Placeholder until we have ambient-temp data from a third source.
    private func heatScore() -> Double { 50 }

    private func recoveryScore(_ debt: RecoveryDebtModel.Snapshot?) -> Double {
        guard let d = debt else { return 60 }
        // 14-day window is the right horizon for race readiness.
        return max(0, 100 - d.fourteenDay.debtPercent)
    }

    /// Average nightly sleep *quality* over the last ~14 nights — duration vs
    /// need, restorative (deep + REM) proportion, and efficiency. This is the
    /// signal a good sleeper expects rewarded, and the one WHOOP/Oura fold into
    /// recovery; distinct from `sleepConsistencyScore`, which only judges timing.
    private func sleepQualityScore(history: [DailyMetrics]) -> Double {
        let nights = history.suffix(14).compactMap(\.sleep).filter { $0.asleepDuration > 0 }
        guard nights.count >= 3 else { return 55 }
        let scores = nights.map(nightlySleepQuality)
        return scores.reduce(0, +) / Double(scores.count)
    }

    /// One night's sleep-quality score, 0–100.
    private func nightlySleepQuality(_ s: SleepMetrics) -> Double {
        let hours = s.asleepDuration / 3600
        let ideal = 7.5
        // Duration: linear up to ideal, full marks 7.5–9h, gentle taper past 9h.
        let durationScore = hours >= ideal
            ? max(70, 100 - max(0, hours - 9.0) * 12)
            : max(0, hours / ideal * 100)
        // Architecture: deep + REM share, ideal ≈ 0.45; efficiency vs 85%.
        let restorative = (s.deepDuration + s.remDuration) / max(s.asleepDuration, 1)
        let archBonus = min(10, max(-12, (restorative - 0.35) * 55))
        let efficiencyBonus = min(5, max(-12, (s.efficiency - 0.85) * 45))
        return max(0, min(100, durationScore + archBonus + efficiencyBonus))
    }

    /// Variance of sleep midpoint in the last 21 days.
    private func sleepConsistencyScore(history: [DailyMetrics]) -> Double {
        let midpoints = history.suffix(21).compactMap { $0.sleep?.sleepMidpoint }
            .map { $0.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) }
        guard midpoints.count >= 5 else { return 50 }
        let mean = midpoints.reduce(0, +) / Double(midpoints.count)
        let variance = midpoints.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(midpoints.count)
        let sdHours = sqrt(variance) / 3600.0
        // 0h variance → 100. 2h variance → 0.
        return max(0, min(100, 100 - sdHours * 50))
    }

    /// Weekly running distance vs an event-agnostic "healthy weekly volume" of 40km.
    private func volumeScore(workouts: [WorkoutSummary]) -> Double {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let km = workouts.filter { $0.start >= cutoff && $0.kind == .run }
            .reduce(0.0) { $0 + ($1.distanceMeters ?? 0) / 1000 }
        return max(0, min(100, km / 40 * 100))
    }

    /// 1 − pace-HR decoupling proxy. We approximate by comparing avg-HR rise
    /// across recent long runs of similar pace; lower rise = better.
    private func fatigueResistanceScore(workouts: [WorkoutSummary], restingHR: Double) -> Double {
        let runs = workouts
            .filter { $0.kind == .run && ($0.distanceMeters ?? 0) >= 12_000 && $0.averageHeartRate != nil }
            .sorted(by: { $0.start > $1.start })
            .prefix(5)
        guard runs.count >= 3 else { return 55 }
        let avgHRs = runs.compactMap(\.averageHeartRate)
        let efficiencies = zip(runs, avgHRs).map { (w, hr) -> Double in
            let mPerMin = (w.distanceMeters ?? 0) / (w.duration / 60)
            return mPerMin / max(1, hr - restingHR)
        }
        // Higher mean efficiency = better fatigue resistance.
        let mean = efficiencies.reduce(0, +) / Double(efficiencies.count)
        return max(0, min(100, mean * 25))      // ~4 m/min/bpm = 100
    }

    /// What fraction of last 28d work matches running modality (for a runner).
    /// Adaptive: would weight differently for tri athletes.
    private func specificityScore(workouts: [WorkoutSummary]) -> Double {
        let cutoff = Date().addingTimeInterval(-28 * 86_400)
        let recent = workouts.filter { $0.start >= cutoff }
        guard !recent.isEmpty else { return 40 }
        let runningDuration = recent.filter { $0.kind == .run }.map { $0.duration }.reduce(0, +)
        let totalDuration = recent.map { $0.duration }.reduce(0, +)
        guard totalDuration > 0 else { return 40 }
        return min(100, runningDuration / totalDuration * 130)
    }

    private func freshnessScore(_ load: TrainingLoadEngine.Snapshot?) -> Double {
        guard let l = load else { return 60 }
        // Coggan's TSB taper window is +5 to +25 → 100.
        let tsb = l.tsb
        switch tsb {
        case 25...:   return 90
        case 5..<25:  return 100
        case -5..<5:  return 80
        case -15..<(-5): return 60
        case -30..<(-15): return 35
        default:      return 15
        }
    }

    private func latestRHR(_ history: [DailyMetrics]) -> Double {
        history.reversed().compactMap(\.restingHeartRate).first ?? 60
    }
}
