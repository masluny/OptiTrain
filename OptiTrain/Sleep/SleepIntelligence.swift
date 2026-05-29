import Foundation

/// Sleep behavior + circadian signals: consistency, predicted need, and the
/// time-of-day at which performance tends to peak. The first two are
/// computed from history; the third is a coarse estimate (refines as more
/// workouts get logged across times of day).
struct SleepIntelligence: Sendable {

    struct Snapshot: Equatable, Sendable {
        let consistencyIndex: Double         // 0...100
        let predictedSleepNeedHours: Double
        let optimalTrainingHour: Int?        // 0-23, peak performance window
        let expectedPerformanceByHour: [Int: Double]   // 0...100
        let circadianRegularity: Double      // 0...1
        let confidence: Confidence
    }

    init() {}

    func snapshot(history: [DailyMetrics], workouts: [WorkoutSummary]) -> Snapshot? {
        let recent = history.suffix(28)
        let midpoints = recent.compactMap { $0.sleep?.sleepMidpoint }
        guard midpoints.count >= 5 else { return nil }

        // Consistency: tighter midpoint variance → higher index.
        let seconds = midpoints.map { $0.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) }
        let mean = seconds.reduce(0, +) / Double(seconds.count)
        let variance = seconds.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(seconds.count)
        let sdHours = sqrt(variance) / 3600.0
        let consistency = max(0, min(100, 100 - sdHours * 50))

        // Sleep need = max of (median actual, 7.5h baseline) + 0.5h if 7d HRV is suppressed.
        let actualHours = recent.compactMap { $0.sleep?.asleepDuration }.map { $0 / 3600 }
        let medianActual = RobustStatistics.median(actualHours) ?? 7.5
        let need = max(medianActual, 7.5)

        // Performance-by-hour from workout history: average pace deviation
        // bucketed by hour of day. Sparse early — we fall back to sensible
        // chronotype curve (afternoon peak).
        var hourScores: [Int: [Double]] = [:]
        let restingHR = recent.compactMap(\.restingHeartRate).last ?? 60
        for w in workouts where w.kind == .run && w.averageHeartRate != nil && (w.distanceMeters ?? 0) > 2_000 {
            let hour = Calendar.current.component(.hour, from: w.start)
            let mPerMin = (w.distanceMeters ?? 0) / (w.duration / 60)
            let ef = mPerMin / max(1, w.averageHeartRate! - restingHR)
            hourScores[hour, default: []].append(ef)
        }
        let learned = hourScores.mapValues { values -> Double in
            values.reduce(0, +) / Double(values.count)
        }
        let blended: [Int: Double] = {
            if learned.count >= 4 {
                let maxV = learned.values.max() ?? 1
                return Dictionary(uniqueKeysWithValues: learned.map { ($0.key, min(100, $0.value / maxV * 100)) })
            } else {
                // Default chronotype curve: morning rise, mid-afternoon peak, evening fall.
                return Dictionary(uniqueKeysWithValues: (0..<24).map { h in
                    let phase = Double(h) - 16.0
                    return (h, max(20, 95 - phase * phase * 1.5))
                })
            }
        }()
        let peakHour = blended.max(by: { $0.value < $1.value })?.key

        return Snapshot(
            consistencyIndex: consistency,
            predictedSleepNeedHours: need,
            optimalTrainingHour: peakHour,
            expectedPerformanceByHour: blended,
            circadianRegularity: consistency / 100.0,
            confidence: Confidence.combine([
                Confidence.fromSampleDensity(present: midpoints.count, target: 21),
                Confidence(learned.count >= 4 ? 0.85 : 0.4)
            ])
        )
    }
}
