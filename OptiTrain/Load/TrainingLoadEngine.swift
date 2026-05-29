import Foundation

/// Banister fitness-fatigue model:
///   • Chronic Training Load (CTL) — EWMA of daily TRIMP with τ=42 days → "fitness"
///   • Acute Training Load  (ATL) — EWMA with τ=7 days                  → "fatigue"
///   • Training Stress Balance    = CTL − ATL                           → "form"
///
/// Plus rolling and EWMA-based ACWR, Foster monotony and strain, and a
/// load-risk classification used by the recommender.
struct TrainingLoadEngine: Sendable {

    struct DailyLoad: Equatable, Sendable {
        let date: Date
        let trimp: Double
    }

    struct Snapshot: Equatable, Sendable {
        let date: Date
        let ctl: Double          // fitness
        let atl: Double          // fatigue
        let tsb: Double          // form (CTL − ATL)
        let acwrRolling: Double? // 7d avg / 28d avg
        let acwrEWMA: Double?    // EWMA(7) / EWMA(28)
        let monotony: Double?    // Foster
        let strain: Double?      // Foster
        let weeklyLoad: Double   // sum of last 7 days
        let risk: LoadRisk
        let trajectory: Trajectory
        let confidence: Confidence
    }

    enum LoadRisk: String, Sendable {
        case undertrained, productive, optimal, overreaching, danger
        var headline: String {
            switch self {
            case .undertrained: "Detrained — fitness drifting down"
            case .productive: "Building — load is climbing safely"
            case .optimal: "Optimal — fitness rising, fatigue managed"
            case .overreaching: "Overreaching — load spike, watch recovery"
            case .danger: "High injury risk — pull back this week"
            }
        }
    }

    enum Trajectory: String, Sendable {
        case rising, steady, falling
    }

    init() {}

    /// Build a full snapshot from at least ~28 days of daily loads (oldest first).
    func snapshot(from daily: [DailyLoad]) -> Snapshot? {
        guard let last = daily.last else { return nil }
        let loads = daily.map(\.trimp)

        // CTL / ATL series → take the trailing values.
        let ctlSeries = EWMA.series(of: loads, tau: 42)
        let atlSeries = EWMA.series(of: loads, tau: 7)
        let ctl = ctlSeries.last ?? 0
        let atl = atlSeries.last ?? 0
        let tsb = ctl - atl

        // ACWR — rolling and EWMA flavor (Williams et al. 2017 recommended both).
        let acwrRolling: Double? = {
            guard loads.count >= 28 else { return nil }
            let acute = loads.suffix(7).reduce(0, +) / 7
            let chronic = loads.suffix(28).reduce(0, +) / 28
            return chronic > 0 ? acute / chronic : nil
        }()
        let acwrEWMA: Double? = {
            guard atl > 0, ctl > 0 else { return nil }
            return atl / ctl
        }()

        // Foster monotony + strain — last 7 days.
        let last7 = Array(loads.suffix(7))
        let monotony: Double? = {
            guard last7.count == 7 else { return nil }
            let mean = last7.reduce(0, +) / 7
            let variance = last7.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / 7
            let sd = sqrt(variance)
            return sd > 0 ? mean / sd : nil
        }()
        let weeklyLoad = last7.reduce(0, +)
        let strain = monotony.map { weeklyLoad * $0 }

        // Trajectory of CTL itself: rising / steady / falling.
        let slope = RobustStatistics.linearSlope(Array(ctlSeries.suffix(14))) ?? 0
        let trajectory: Trajectory = {
            switch slope {
            case 0.5...: .rising
            case ..<(-0.5): .falling
            default: .steady
            }
        }()

        let risk = classify(tsb: tsb, acwr: acwrRolling ?? acwrEWMA, monotony: monotony, ctlTrajectory: trajectory)
        let confidence = Confidence.combine([
            Confidence.fromSampleDensity(present: loads.count, target: 42),
            Confidence.fromRecency(daysOld: 0)
        ])

        return Snapshot(
            date: last.date,
            ctl: ctl, atl: atl, tsb: tsb,
            acwrRolling: acwrRolling, acwrEWMA: acwrEWMA,
            monotony: monotony, strain: strain,
            weeklyLoad: weeklyLoad, risk: risk, trajectory: trajectory,
            confidence: confidence
        )
    }

    /// Banister classification, layered with ACWR and monotony alarms.
    private func classify(tsb: Double, acwr: Double?, monotony: Double?, ctlTrajectory: Trajectory) -> LoadRisk {
        if let m = monotony, m > 2.0 { return .danger }                       // Foster red line
        if let a = acwr, a > 1.5 { return .danger }
        if let a = acwr, a > 1.3 { return .overreaching }
        if tsb < -25 { return .overreaching }
        if ctlTrajectory == .rising && tsb < 10 { return .optimal }
        if ctlTrajectory == .rising { return .productive }
        if ctlTrajectory == .falling { return .undertrained }
        return .productive
    }

    func explanation(_ s: Snapshot) -> Explanation {
        var f: [Factor] = []
        f.append(Factor(
            label: "Fitness (CTL)",
            direction: s.trajectory == .rising ? .positive : (s.trajectory == .falling ? .negative : .neutral),
            magnitude: min(1, abs(s.ctl) / 100),
            detail: String(format: "CTL %.0f, %@", s.ctl, s.trajectory.rawValue)
        ))
        f.append(Factor(
            label: "Form (TSB)",
            direction: s.tsb > 5 ? .positive : (s.tsb < -15 ? .negative : .neutral),
            magnitude: min(1, abs(s.tsb) / 30),
            detail: String(format: "TSB %+.0f — %@", s.tsb, s.tsb > 5 ? "fresh" : (s.tsb < -15 ? "fatigued" : "neutral"))
        ))
        if let a = s.acwrRolling ?? s.acwrEWMA {
            f.append(Factor(
                label: "Acute:Chronic ratio",
                direction: (0.8...1.3).contains(a) ? .positive : .negative,
                magnitude: min(1, abs(a - 1.0)),
                detail: String(format: "ACWR %.2f", a)
            ))
        }
        if let m = s.monotony {
            f.append(Factor(
                label: "Monotony",
                direction: m > 2.0 ? .negative : .positive,
                magnitude: min(1, m / 3.0),
                detail: String(format: "Foster monotony %.2f", m)
            ))
        }
        return Explanation(headline: s.risk.headline, factors: f)
    }
}
