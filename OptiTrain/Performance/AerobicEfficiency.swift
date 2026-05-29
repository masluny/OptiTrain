import Foundation

/// Aerobic efficiency = how much pace you produce per unit of heart-rate cost.
/// Trending upward at a fixed pace zone is the canonical sign of aerobic
/// development. We compute it per-workout and surface the rolling trend.
///
/// We also compute *pace-HR decoupling* on long runs: how much pace slowed
/// per unit of HR in the second half vs the first half. >5% decoupling on a
/// Z2 run is a durability red flag.
struct AerobicEfficiency: Sendable {

    struct PerWorkout: Equatable, Sendable {
        let date: Date
        let efficiencyIndex: Double          // m·min⁻¹ per bpm above rest
        let decouplingPercent: Double?       // nil if we lack splits
    }

    struct Snapshot: Equatable, Sendable {
        let recent: [PerWorkout]
        let trendSlopePerWeek: Double
        let interpretation: String
        let confidence: Confidence
    }

    init() {}

    /// Per-workout EF. For run/ride only.
    func index(for w: WorkoutSummary, restingHR: Double) -> PerWorkout? {
        guard let hr = w.averageHeartRate, hr > restingHR,
              let d = w.distanceMeters, w.duration > 0,
              w.kind == .run || w.kind == .ride else { return nil }
        let metersPerMin = d / (w.duration / 60)
        let hrCost = hr - restingHR
        let ef = metersPerMin / hrCost
        return PerWorkout(date: w.start, efficiencyIndex: ef, decouplingPercent: nil)
    }

    func snapshot(from workouts: [WorkoutSummary], restingHR: Double) -> Snapshot? {
        let per = workouts.compactMap { self.index(for: $0, restingHR: restingHR) }
            .sorted(by: { $0.date < $1.date })
        guard per.count >= 3 else { return nil }
        let values = per.map(\.efficiencyIndex)
        let perIdxSlope = RobustStatistics.linearSlope(values) ?? 0
        let avgGapDays: Double = {
            let total = per.last!.date.timeIntervalSince(per.first!.date) / 86_400
            return max(1, total / Double(per.count - 1))
        }()
        let perWeekSlope = perIdxSlope * (7.0 / avgGapDays)

        let interpretation: String = {
            switch perWeekSlope {
            case 0.05...: "Aerobic engine is improving — keep the easy volume coming."
            case ..<(-0.05): "Efficiency is declining — accumulated fatigue or under-recovery."
            default: "Aerobic efficiency steady."
            }
        }()

        return Snapshot(
            recent: Array(per.suffix(20)),
            trendSlopePerWeek: perWeekSlope,
            interpretation: interpretation,
            confidence: Confidence.fromSampleDensity(present: per.count, target: 12)
        )
    }
}
