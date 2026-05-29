import Foundation

/// Smooths the noisy VO₂max signal Apple writes from outdoor runs and projects
/// a 30/60-day forward trajectory using a linear extrapolation of the last
/// 90-day EWMA slope. Honest about uncertainty: a single-point spike is
/// flagged low-confidence, and we never extrapolate further than the data
/// supports.
struct VO2maxTrajectory: Sendable {

    struct Sample: Equatable, Sendable {
        let date: Date
        let value: Double
    }

    struct Snapshot: Equatable, Sendable {
        let current: Double
        let smoothed: Double
        let trendSlopePerWeek: Double          // mL/kg/min per week
        let forecast30Day: Double?
        let forecast60Day: Double?
        let band: Band
        let confidence: Confidence
    }

    enum Band: String, Sendable {
        case below_average, average, above_average, excellent, elite
    }

    init() {}

    /// Uth–Sørensen–Overgaard–Pedersen (2004) heart-rate-ratio estimate:
    /// VO₂max ≈ 15.3 × (HRmax / HRrest). A validated fallback for athletes who
    /// never record an outdoor run (so Apple writes no VO₂max sample) but whose
    /// max and resting HR we know. Guarded against degenerate HR inputs.
    static func uthEstimate(maxHR: Double, restingHR: Double) -> Double {
        guard restingHR > 30, maxHR > restingHR else { return 35 }
        return 15.3 * (maxHR / restingHR)
    }

    /// Build a snapshot from raw samples (oldest first).
    func snapshot(from samples: [Sample]) -> Snapshot? {
        guard let latest = samples.last else { return nil }

        let values = samples.map(\.value)
        let smoothed = EWMA.series(of: values, tau: 14).last ?? latest.value

        // Convert per-index slope to per-week if we know the sampling cadence.
        let last90 = Array(samples.suffix(while: { $0.date >= Date().addingTimeInterval(-90 * 86_400) }))
        let last90Values = last90.map(\.value)
        let perIndexSlope = RobustStatistics.linearSlope(last90Values) ?? 0
        let avgGap: Double = {
            guard last90.count >= 2 else { return 7 }
            let totalDays = last90.last!.date.timeIntervalSince(last90.first!.date) / 86_400
            return max(1, totalDays / Double(last90.count - 1))
        }()
        let perWeekSlope = perIndexSlope * (7.0 / avgGap)

        let f30 = last90.count >= 3 ? smoothed + perWeekSlope * (30.0 / 7.0) : nil
        let f60 = last90.count >= 6 ? smoothed + perWeekSlope * (60.0 / 7.0) : nil

        let confidence = Confidence.combine([
            Confidence.fromSampleDensity(present: last90.count, target: 12),
            Confidence.fromRecency(daysOld: Int(max(0, Date().timeIntervalSince(latest.date) / 86_400)), halfLifeDays: 14)
        ])

        return Snapshot(
            current: latest.value,
            smoothed: smoothed,
            trendSlopePerWeek: perWeekSlope,
            forecast30Day: f30,
            forecast60Day: f60,
            band: classify(smoothed),
            confidence: confidence
        )
    }

    /// ACSM-aligned bands for adult males 30-39. We use a single neutral
    /// table here; the right move long-term is to pull age/sex from HealthKit.
    private func classify(_ v: Double) -> Band {
        switch v {
        case ..<35: .below_average
        case 35..<43: .average
        case 43..<50: .above_average
        case 50..<58: .excellent
        default: .elite
        }
    }
}

private extension Array {
    /// Suffix while predicate holds, scanning from the end.
    func suffix(while pred: (Element) -> Bool) -> [Element] {
        var i = endIndex
        while i > startIndex, pred(self[i - 1]) { i -= 1 }
        return Array(self[i..<endIndex])
    }
}
