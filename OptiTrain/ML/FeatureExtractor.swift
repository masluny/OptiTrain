import Foundation

/// CoreML-ready feature extractor. Turns the orchestrator's full snapshot
/// into a flat `[String: Double]` vector that can be:
///   • Fed to a future CoreML model (response profiling, personalized weight learning)
///   • Logged to a local CSV for offline analysis
///   • Used by the reinforcement-learning hook when we add one
///
/// All features are physiologically meaningful and z-score normalized where
/// reasonable so a downstream model doesn't need feature engineering.
struct FeatureExtractor: Sendable {

    struct Inputs {
        let today: DailyMetrics
        let history: [DailyMetrics]
        let load: TrainingLoadEngine.Snapshot?
        let debt: RecoveryDebtModel.Snapshot?
        let stability: AutonomicStability.Snapshot?
        let vo2: VO2maxTrajectory.Snapshot?
        let eff: AerobicEfficiency.Snapshot?
    }

    init() {}

    func extract(_ i: Inputs) -> [String: Double] {
        var f: [String: Double] = [:]

        // Sleep
        if let s = i.today.sleep {
            f["sleep_hours"] = s.asleepDuration / 3600
            f["sleep_efficiency"] = s.efficiency
            f["sleep_deep_fraction"] = s.deepDuration / max(1, s.asleepDuration)
            f["sleep_rem_fraction"] = s.remDuration / max(1, s.asleepDuration)
        }

        // Autonomic
        if let hrv = i.today.overnightHRV,
           let base = AdaptiveBaseline.build(from: i.history.compactMap(\.overnightHRV)) {
            f["hrv_z"] = base.z(of: hrv)
            f["hrv_value"] = hrv
        }
        if let rhr = i.today.restingHeartRate,
           let base = AdaptiveBaseline.build(from: i.history.compactMap(\.restingHeartRate)) {
            f["rhr_z"] = base.z(of: rhr)
            f["rhr_value"] = rhr
        }
        if let t = i.today.wristTemperatureDelta { f["wrist_temp_delta_c"] = t }
        if let r = i.today.respiratoryRate { f["respiratory_rate"] = r }

        // Load
        if let l = i.load {
            f["ctl"] = l.ctl
            f["atl"] = l.atl
            f["tsb"] = l.tsb
            if let a = l.acwrRolling { f["acwr_rolling"] = a }
            if let m = l.monotony { f["monotony"] = m }
            f["weekly_load"] = l.weeklyLoad
        }

        // Recovery / stability
        if let d = i.debt {
            f["recovery_debt_7d"]  = d.sevenDay.debtPercent
            f["recovery_debt_14d"] = d.fourteenDay.debtPercent
            f["recovery_debt_30d"] = d.thirtyDay.debtPercent
        }
        if let s = i.stability {
            f["autonomic_stability"] = s.stabilityScore
            if let cv = s.hrvCV { f["hrv_cv_7d"] = cv }
        }

        // Performance
        if let v = i.vo2 {
            f["vo2max_smoothed"] = v.smoothed
            f["vo2max_slope_per_week"] = v.trendSlopePerWeek
        }
        if let e = i.eff {
            f["aerobic_efficiency_slope"] = e.trendSlopePerWeek
        }

        return f
    }
}
