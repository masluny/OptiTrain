import Foundation

/// Biological sex, used only to pick the correct Banister TRIMP weighting.
/// Unknown/unspecified falls back to the male curve (the historical default,
/// so existing scores are unchanged when sex isn't shared).
enum AthleteSex: Sendable { case male, female }

/// Banister TRIMP — Training Impulse. Distills a workout's cardiovascular
/// cost into a single load number using duration and heart-rate intensity.
///
/// TRIMP = D · r · k · e^(b·r), where r = (HR_avg − HR_rest)/(HR_max − HR_rest).
/// Banister gave sex-specific weightings: men k=0.64, b=1.92; women k=0.86,
/// b=1.67 (the female curve weights moderate intensities more heavily).
///
/// When HR isn't available (strength training without HR strap), we fall
/// back to a kcal-based estimate scaled to a 130 bpm equivalent.
enum TrainingImpulse {

    struct Inputs {
        let durationSeconds: Double
        let averageHR: Double?
        let kcal: Double?
        let kind: WorkoutSummary.Kind
        let restingHR: Double      // user RHR
        let maxHR: Double          // estimated from age (Tanaka) or observed peak
        let sex: AthleteSex        // selects the Banister weighting curve

        init(durationSeconds: Double, averageHR: Double?, kcal: Double?, kind: WorkoutSummary.Kind, restingHR: Double, maxHR: Double, sex: AthleteSex = .male) {
            self.durationSeconds = durationSeconds
            self.averageHR = averageHR
            self.kcal = kcal
            self.kind = kind
            self.restingHR = restingHR
            self.maxHR = maxHR
            self.sex = sex
        }
    }

    /// Returns Banister TRIMP. Always non-negative.
    static func banister(_ i: Inputs) -> Double {
        let durMin = i.durationSeconds / 60.0
        guard durMin > 0 else { return 0 }

        if let hr = i.averageHR, i.maxHR > i.restingHR + 10 {
            let r = max(0, min(1, (hr - i.restingHR) / (i.maxHR - i.restingHR)))
            let (k, b): (Double, Double) = i.sex == .female ? (0.86, 1.67) : (0.64, 1.92)
            return durMin * r * k * exp(b * r)
        }
        // No HR: lift / yoga / etc. Use a discipline-weighted kcal proxy.
        let kcal = i.kcal ?? 0
        let modifier: Double = {
            switch i.kind {
            case .lift: 0.10     // strength has high mechanical load not captured by kcal
            case .walk: 0.04
            case .run, .ride: 0.07
            case .other: 0.05
            }
        }()
        return kcal * modifier + durMin * 0.5  // floor: time-on-feet matters even unmonitored
    }

    /// Convenience: per-day TRIMP from an array of workouts.
    static func daily(_ workouts: [WorkoutSummary], restingHR: Double, maxHR: Double, sex: AthleteSex = .male) -> Double {
        workouts.reduce(0) { sum, w in
            sum + banister(.init(
                durationSeconds: w.duration,
                averageHR: w.averageHeartRate,
                kcal: w.activeEnergyKcal,
                kind: w.kind,
                restingHR: restingHR,
                maxHR: maxHR,
                sex: sex
            ))
        }
    }
}

/// Estimating an athlete's maximum heart rate — the denominator in every
/// heart-rate-reserve (Karvonen) intensity and Banister TRIMP calculation, so
/// getting it right ripples through fitness, fatigue, readiness and load risk.
///
/// Priority order:
///   1. **Observed peak** — the highest HR actually reached in a recorded
///      workout. A directly measured maximum beats any age formula.
///   2. **Tanaka** (208 − 0.7·age) — the 351-study meta-analysis replacement for
///      the textbook 220−age, which over-predicts for the young and
///      under-predicts for older adults (Tanaka, Monahan & Seals, JACC 2001).
///   3. A neutral 190 bpm fallback when neither age nor data is known.
enum MaxHeartRate {
    /// Tanaka et al. (2001): HRmax = 208 − 0.7 × age.
    static func tanaka(age: Int) -> Double { 208.0 - 0.7 * Double(age) }

    /// Fox et al. (1971): HRmax = 220 − age. Kept for reference.
    static func fox(age: Int) -> Double { 220.0 - Double(age) }

    /// Best estimate from what we know. `observedPeak` is the maximum HR seen
    /// across recent workouts; `age` is the athlete's age in years if shared.
    static func estimate(observedPeak: Double?, age: Int?) -> Double {
        let formula = age.map(tanaka) ?? 190.0
        // A demonstrated peak above the formula is real and authoritative. A peak
        // *below* it just means the athlete hasn't gone max-effort lately, so we
        // keep the formula as the floor rather than under-reading their max.
        guard let peak = observedPeak, peak.isFinite, peak > 100 else { return formula }
        return max(peak, formula)
    }
}
