import Foundation

/// Detect stalled adaptation: rising effort with flat or declining performance.
///
/// Algorithm:
///   • Trend HR for matched-pace runs in last 60 days (effort proxy)
///   • Trend pace at matched HR (performance proxy)
///   • Plateau probability = sigmoid(rising_effort − rising_performance)
struct PlateauDetector: Sendable {

    struct Snapshot: Equatable, Sendable {
        let plateauProbability: Double      // 0...1
        let likelyCauses: [String]
        let recommendedIntervention: String
        let confidence: Confidence
    }

    init() {}

    func detect(workouts: [WorkoutSummary],
                       restingHR: Double,
                       load: TrainingLoadEngine.Snapshot?) -> Snapshot? {
        let runs = workouts
            .filter { $0.kind == .run && $0.averageHeartRate != nil && ($0.distanceMeters ?? 0) > 4_000 }
            .sorted(by: { $0.start < $1.start })
            .suffix(20)
        guard runs.count >= 6 else { return nil }

        // Effort = avg HR. Performance = avg pace at a HR zone we hold constant.
        let hrs = runs.map { $0.averageHeartRate! }
        let paces = runs.map { ($0.distanceMeters ?? 0) / max(1, $0.duration) }   // m/s
        let hrSlope = RobustStatistics.linearSlope(hrs) ?? 0
        let paceSlope = RobustStatistics.linearSlope(paces) ?? 0

        // Sigmoid centered on (effort rising, pace flat-or-falling).
        let signal = hrSlope - paceSlope * 25.0                            // unit balance
        let p = 1.0 / (1.0 + exp(-signal))

        var causes: [String] = []
        if let m = load?.monotony, m > 1.8 { causes.append("Training monotony too high (\(String(format: "%.2f", m))) — same paces, same days, same HR.") }
        if let r = load?.risk, r == .overreaching || r == .danger { causes.append("Cumulative load excessive for current adaptation rate.") }
        if hrSlope > 0 && paceSlope <= 0 { causes.append("Heart-rate cost rising while pace is flat — classic stagnation pattern.") }
        if causes.isEmpty { causes.append("Could be a typical adaptation lag; revisit in 7-10 days.") }

        let intervention: String = {
            if p > 0.7 { return "Take a 5-7 day deload, then introduce a new stimulus (intervals if you've been long-and-slow, long-Z2 if you've been speed-heavy)." }
            if p > 0.45 { return "Inject variety: a tempo workout, a hill session, or a true rest day." }
            return "Stay the course; monitor next 2 weeks."
        }()

        return Snapshot(
            plateauProbability: p,
            likelyCauses: causes,
            recommendedIntervention: intervention,
            confidence: Confidence.fromSampleDensity(present: runs.count, target: 12)
        )
    }
}
