import Foundation

struct SleepMetrics: Equatable {
    let inBedDuration: TimeInterval
    let asleepDuration: TimeInterval
    let deepDuration: TimeInterval
    let remDuration: TimeInterval
    let coreDuration: TimeInterval
    let awakeDuration: TimeInterval
    let sleepMidpoint: Date?

    var efficiency: Double {
        guard inBedDuration > 0 else { return 0 }
        return asleepDuration / inBedDuration
    }
}

struct DailyMetrics: Equatable {
    let date: Date
    let sleep: SleepMetrics?
    let overnightHRV: Double?
    let restingHeartRate: Double?
    let wristTemperatureDelta: Double?
    let respiratoryRate: Double?
    let steps: Int?
    let activeEnergyKcal: Double?
    let workoutLoad: Double?

    /// True when at least one health/workout signal exists for this day.
    /// Used to avoid treating fully missing watch days as confirmed "zero".
    var hasAnySignal: Bool {
        let hasSleep = (sleep?.asleepDuration ?? 0) > 0
        let hasWorkout = (workoutLoad ?? 0) > 0
        return hasSleep
            || overnightHRV != nil
            || restingHeartRate != nil
            || wristTemperatureDelta != nil
            || respiratoryRate != nil
            || steps != nil
            || activeEnergyKcal != nil
            || hasWorkout
    }

    /// Returns a copy with the sleep block swapped out. Used to carry the most
    /// recent recorded night forward into today when the watch wasn't worn to bed.
    func replacingSleep(_ newSleep: SleepMetrics?) -> DailyMetrics {
        DailyMetrics(
            date: date,
            sleep: newSleep,
            overnightHRV: overnightHRV,
            restingHeartRate: restingHeartRate,
            wristTemperatureDelta: wristTemperatureDelta,
            respiratoryRate: respiratoryRate,
            steps: steps,
            activeEnergyKcal: activeEnergyKcal,
            workoutLoad: workoutLoad
        )
    }
}

struct WorkoutSummary: Identifiable, Equatable, Hashable {
    enum Kind: String { case run, walk, lift, ride, other }
    let id: UUID
    let kind: Kind
    let start: Date
    let end: Date
    let activeEnergyKcal: Double
    let averageHeartRate: Double?
    let maxHeartRate: Double?
    let distanceMeters: Double?
    let elevationAscendedMeters: Double?

    var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Pace in seconds per kilometer for distance-based workouts.
    var paceSecondsPerKm: Double? {
        guard let d = distanceMeters, d > 100 else { return nil }
        return duration / (d / 1000.0)
    }
}

struct Baseline: Equatable {
    let mean: Double
    let stdDev: Double
    let sampleCount: Int

    func zScore(for value: Double) -> Double {
        guard stdDev > 0 else { return 0 }
        return (value - mean) / stdDev
    }
}
