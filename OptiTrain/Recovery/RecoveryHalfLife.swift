import Foundation

/// Estimate the recovery half-life of a workout — i.e. how long until the
/// fatigue it caused has decayed by 50%. Used to forecast the next-optimal
/// training window. Modulated by prior fatigue (TSB), sleep quality, and the
/// athlete's CTL (fitness buffers recovery).
struct RecoveryHalfLife: Sendable {

    struct Inputs {
        let workout: WorkoutSummary
        let trimp: Double
        let priorTSB: Double          // form going in
        let lastNightSleepHours: Double?
        let ctl: Double               // fitness
        let restingHR: Double
        let maxHR: Double
    }

    struct Estimate: Equatable, Sendable {
        let halfLifeHours: Double
        let fullRecoveryHours: Double      // ~3 half-lives (87%)
        let nextOptimalWindow: DateInterval
        let intensityClass: IntensityClass
    }

    enum IntensityClass: String, Sendable {
        case light, moderate, hard, veryHard, brutal
    }

    init() {}

    func estimate(_ i: Inputs, from start: Date = Date()) -> Estimate {
        // Base half-life: ~8h per 50 TRIMP (linearised; the real curve is
        // closer to sqrt but this is good enough at the resolution we have).
        var hours = max(2.0, i.trimp * 8.0 / 50.0)

        // Prior fatigue lengthens recovery (negative TSB → multiply up).
        if i.priorTSB < 0 { hours *= 1.0 + min(1.0, -i.priorTSB / 30.0) }

        // Fitness shortens recovery — high CTL athletes clear fatigue faster.
        let ctlFactor = max(0.7, 1.0 - i.ctl / 200.0)
        hours *= ctlFactor

        // Sleep last night: 8h → 1.0, 5h → 1.4, 6h → 1.2.
        let sleepFactor: Double = {
            guard let s = i.lastNightSleepHours else { return 1.0 }
            if s >= 8 { return 1.0 }
            return 1.0 + max(0, (8 - s) * 0.10)
        }()
        hours *= sleepFactor

        let full = hours * 3.0
        let next = start.addingTimeInterval(full * 3600)
        let nextEnd = next.addingTimeInterval(24 * 3600)

        let intensity: IntensityClass = {
            switch i.trimp {
            case ..<30:   .light
            case 30..<70: .moderate
            case 70..<120: .hard
            case 120..<200: .veryHard
            default: .brutal
            }
        }()

        return Estimate(
            halfLifeHours: hours,
            fullRecoveryHours: full,
            nextOptimalWindow: DateInterval(start: next, end: nextEnd),
            intensityClass: intensity
        )
    }
}
