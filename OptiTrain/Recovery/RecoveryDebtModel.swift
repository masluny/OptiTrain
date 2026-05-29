import Foundation

/// Accumulated incomplete recovery. Each component measures how far a daily
/// signal has drifted *adversely* from the user's personal baseline, summed
/// over a window. The result is normalized to a 0-100% "debt" along with an
/// estimate of days needed to clear it.
struct RecoveryDebtModel: Sendable {

    struct WindowDebt: Equatable, Sendable {
        let windowDays: Int
        let debtPercent: Double          // 0...100
        let estimatedRecoveryDays: Double
        let stressClass: StressClass
        let factors: [Factor]
    }

    enum StressClass: String, Sendable {
        case adapted, balanced, accumulating, overreached, deeplyDepleted
    }

    struct Snapshot: Equatable, Sendable {
        let sevenDay: WindowDebt
        let fourteenDay: WindowDebt
        let thirtyDay: WindowDebt
        let confidence: Confidence
    }

    /// Targets — these are the "ideal" against which we measure deficit.
    struct Targets {
        var sleepHours: Double = 7.5
        /// Sleeping within this many hours of the target still counts as fully
        /// rested — most adults are fine on 7–7.5h, so we don't punish normal nights.
        var sleepGraceHours: Double = 0.5
        /// Only autonomic deviations *beyond* this many σ from the personal
        /// baseline accrue debt. Normal night-to-night fluctuation around one's
        /// own median (which is ~half of all nights, by definition) must not.
        var autonomicDeadbandSigma: Double = 1.0
        var maxDailyTRIMP: Double = 140        // beyond this, the day adds load-debt
    }

    let targets: Targets

    init(targets: Targets = Targets()) {
        self.targets = targets
    }

    func snapshot(history: [DailyMetrics],
                         loads: [TrainingLoadEngine.DailyLoad]) -> Snapshot? {
        guard !history.isEmpty else { return nil }
        let sorted = history.sorted { $0.date < $1.date }
        let loadsByDate = Dictionary(uniqueKeysWithValues: loads.map { ($0.date.startOfDayUTC, $0.trimp) })

        let hrvBaseline = AdaptiveBaseline.build(from: sorted.compactMap(\.overnightHRV))
        let rhrBaseline = AdaptiveBaseline.build(from: sorted.compactMap(\.restingHeartRate))

        let seven = windowDebt(days: 7, history: sorted, hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline, loads: loadsByDate)
        let fourteen = windowDebt(days: 14, history: sorted, hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline, loads: loadsByDate)
        let thirty = windowDebt(days: 30, history: sorted, hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline, loads: loadsByDate)

        let confidence = Confidence.combine([
            Confidence.fromSampleDensity(present: sorted.count, target: 30),
            Confidence(hrvBaseline == nil ? 0.3 : 0.9),
            Confidence(rhrBaseline == nil ? 0.4 : 0.9)
        ])

        return Snapshot(sevenDay: seven, fourteenDay: fourteen, thirtyDay: thirty, confidence: confidence)
    }

    /// Per-window calculation. Weights are intentionally explicit — adjust here.
    private func windowDebt(days: Int,
                            history: [DailyMetrics],
                            hrvBaseline: AdaptiveBaseline?,
                            rhrBaseline: AdaptiveBaseline?,
                            loads: [Date: Double]) -> WindowDebt {
        let window = Array(history.suffix(days))

        // Sleep deficit: only nights with actual sleep data count (a missing
        // night is unknown, not an 8h shortfall), and only time below the
        // grace-adjusted floor is debt.
        let sleepFloor = targets.sleepHours - targets.sleepGraceHours          // e.g. 7.0h
        let sleepNights = window.compactMap { $0.sleep?.asleepDuration }
            .filter { $0 > 0 }
            .map { $0 / 3600 }
        let sleepDeficitHours = sleepNights.reduce(0.0) { $0 + max(0, sleepFloor - $1) }

        // Autonomic debt: only suppression/elevation *beyond* the deadband
        // counts, so being a little below your own median on a normal night is
        // free — only a sustained, meaningful drift accrues debt.
        let deadband = targets.autonomicDeadbandSigma
        let hrvSuppression = hrvBaseline.map { base in
            window.reduce(0.0) { sum, d in
                guard let v = d.overnightHRV else { return sum }
                let z = base.z(of: v)
                return sum + max(0, -z - deadband)   // suppression beyond the deadband
            }
        } ?? 0
        let rhrElevation = rhrBaseline.map { base in
            window.reduce(0.0) { sum, d in
                guard let v = d.restingHeartRate else { return sum }
                let z = base.z(of: v)
                return sum + max(0, z - deadband)    // elevation beyond the deadband
            }
        } ?? 0
        let loadExcess = window.reduce(0.0) { sum, d in
            let trimp = loads[d.date.startOfDayUTC] ?? 0
            return sum + max(0, trimp - targets.maxDailyTRIMP)
        }

        // Normalize each to ~0...1 over the window length.
        let sleepNorm = sleepNights.isEmpty
            ? 0
            : min(1, sleepDeficitHours / (Double(sleepNights.count) * 1.5))    // 1.5h below floor every recorded night = 100%
        let hrvNorm   = min(1, hrvSuppression / (Double(days) * 1.0))          // sustained ≥2σ below baseline = 100%
        let rhrNorm   = min(1, rhrElevation   / (Double(days) * 1.0))
        let loadNorm  = min(1, loadExcess     / (Double(days) * 60.0))         // 60 TRIMP over cap × all days

        // Weighted blend → 0...100%.
        let debt01 = 0.30 * sleepNorm + 0.30 * hrvNorm + 0.20 * rhrNorm + 0.20 * loadNorm
        let debtPct = debt01 * 100

        let stress: StressClass = {
            switch debtPct {
            case ..<10:  .adapted
            case 10..<30: .balanced
            case 30..<55: .accumulating
            case 55..<75: .overreached
            default:      .deeplyDepleted
            }
        }()

        // Empirical: every 10% of debt ≈ 0.7 days of true recovery.
        let estDays = debtPct / 100.0 * 7.0

        let factors: [Factor] = [
            .init(label: "Sleep deficit",
                  direction: sleepNorm > 0.15 ? .negative : .neutral,
                  magnitude: sleepNorm,
                  detail: String(format: "%.1f h below %.1f h over %d nights", sleepDeficitHours, sleepFloor, sleepNights.count)),
            .init(label: "HRV suppression",
                  direction: hrvNorm > 0.10 ? .negative : .neutral,
                  magnitude: hrvNorm,
                  detail: String(format: "%.1fσ beyond normal range (cumulative)", hrvSuppression)),
            .init(label: "Elevated resting HR",
                  direction: rhrNorm > 0.10 ? .negative : .neutral,
                  magnitude: rhrNorm,
                  detail: String(format: "%.1fσ beyond normal range (cumulative)", rhrElevation)),
            .init(label: "Load excess",
                  direction: loadNorm > 0.10 ? .negative : .neutral,
                  magnitude: loadNorm,
                  detail: String(format: "%.0f TRIMP above %.0f cap (cumulative)", loadExcess, targets.maxDailyTRIMP))
        ]

        return WindowDebt(windowDays: days, debtPercent: debtPct, estimatedRecoveryDays: estDays, stressClass: stress, factors: factors)
    }
}

extension Date {
    /// Normalize a Date to its UTC start-of-day for keying.
    var startOfDayUTC: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.startOfDay(for: self)
    }
}
