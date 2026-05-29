import Foundation

struct ReadinessCalculator {
    struct Weights: Equatable {
        // HRV-dominant, autonomic-led — matching the published priority order of
        // WHOOP Recovery, Fitbit Daily Readiness and Oura Readiness, where HRV is
        // the single largest contributor and resting HR is second. Together the
        // two autonomic markers carry half the score; sleep is third; training
        // load is intentionally light because ACWR is a contested predictor.
        var sleep: Double = 0.25
        var hrv: Double = 0.30
        var rhr: Double = 0.20
        var load: Double = 0.15
        var temp: Double = 0.10

        static let `default` = Weights()
    }

    var weights: Weights
    var idealSleepHours: Double = 7.5

    init(useWristTemperature: Bool = true, idealSleepHours: Double = 7.5) {
        self.idealSleepHours = idealSleepHours
        if useWristTemperature {
            self.weights = .default
        } else {
            // Redistribute the temp weight proportionally to the other four signals.
            let drop = Weights.default.temp
            let scale = 1.0 / (1.0 - drop)
            self.weights = Weights(
                sleep: Weights.default.sleep * scale,
                hrv: Weights.default.hrv * scale,
                rhr: Weights.default.rhr * scale,
                load: Weights.default.load * scale,
                temp: 0
            )
        }
    }

    /// `today` is the day being scored. `history` should include the prior ~28 days (excluding today)
    /// used to build personal baselines for HRV / RHR / load / temperature.
    func score(today: DailyMetrics, history: [DailyMetrics]) -> ReadinessScore {
        let sleep = sleepSub(today.sleep)
        let hrv = hrvSub(value: today.overnightHRV, history: history.compactMap(\.overnightHRV))
        let rhr = rhrSub(value: today.restingHeartRate, history: history.compactMap(\.restingHeartRate))
        let load = loadSub(history: history + [today])

        var subs: [SubScore] = [sleep, hrv, rhr, load]
        if weights.temp > 0 {
            subs.append(tempSub(today.wristTemperatureDelta, history: history.compactMap(\.wristTemperatureDelta)))
        }
        let weighted = subs.reduce(0.0) { $0 + $1.weighted }
        let value = Int(weighted.rounded())

        let acwr = computeACWR(history: history + [today])
        let headline = makeHeadline(value: value, subs: subs, acwr: acwr)

        return ReadinessScore(date: today.date, value: value, subScores: subs, acwr: acwr, headline: headline)
    }

    // MARK: - Sub-scores

    private func sleepSub(_ sleep: SleepMetrics?) -> SubScore {
        guard let sleep, sleep.asleepDuration > 0 else {
            return SubScore(kind: .sleep, value: 40, weight: weights.sleep, detail: "No sleep data — neutral score")
        }
        let hours = sleep.asleepDuration / 3600
        // Duration vs ideal (penalize over-sleep too, gently)
        let durationScore: Double = {
            let ratio = hours / idealSleepHours
            if ratio >= 1.0 { return min(100, 95 + (1 - min(ratio, 1.3) - 1) * 30) }
            return max(0, ratio * 95)
        }()
        // Architecture bonus: deep + rem proportion
        let restorative = (sleep.deepDuration + sleep.remDuration) / max(sleep.asleepDuration, 1)
        let archBonus = min(10, max(-10, (restorative - 0.35) * 50))
        let efficiencyBonus = min(5, max(-10, (sleep.efficiency - 0.85) * 40))
        let value = max(0, min(100, durationScore + archBonus + efficiencyBonus))
        let detail = String(format: "%.1fh asleep · %.0f%% restorative · %.0f%% efficient",
                            hours, restorative * 100, sleep.efficiency * 100)
        return SubScore(kind: .sleep, value: value, weight: weights.sleep, detail: detail)
    }

    private func hrvSub(value: Double?, history: [Double]) -> SubScore {
        guard let value, let baseline = baseline(from: history) else {
            return SubScore(kind: .hrv, value: 50, weight: weights.hrv, detail: "Not enough HRV history yet")
        }
        // Higher HRV = better. +1 SD ≈ 80, mean ≈ 60, -1 SD ≈ 40.
        let z = baseline.zScore(for: value)
        let score = max(0, min(100, 60 + z * 20))
        let detail = String(format: "%.0f ms vs %.0f ms baseline (%.1fσ)", value, baseline.mean, z)
        return SubScore(kind: .hrv, value: score, weight: weights.hrv, detail: detail)
    }

    private func rhrSub(value: Double?, history: [Double]) -> SubScore {
        guard let value, let baseline = baseline(from: history) else {
            return SubScore(kind: .restingHeartRate, value: 50, weight: weights.rhr, detail: "Not enough RHR history yet")
        }
        // Lower RHR = better. Invert sign of z.
        let z = baseline.zScore(for: value)
        let score = max(0, min(100, 60 - z * 20))
        let detail = String(format: "%.0f bpm vs %.0f bpm baseline (%+.1fσ)", value, baseline.mean, z)
        return SubScore(kind: .restingHeartRate, value: score, weight: weights.rhr, detail: detail)
    }

    private func loadSub(history: [DailyMetrics]) -> SubScore {
        let acwr = computeACWR(history: history) ?? 1.0
        // ACWR is a soft, contested signal (mathematical coupling; the 0.8–1.3
        // "sweet spot" lacks causal evidence — Impellizzeri 2020), so we treat
        // departures as a gentle nudge, never a cliff.
        let score: Double
        switch acwr {
        case ..<0.5: score = 65
        case 0.5..<0.8: score = 82
        case 0.8...1.3: score = 100
        case 1.3...1.5: score = 85
        case 1.5...1.8: score = 65
        default: score = 45
        }
        let detail = String(format: "ACWR %.2f (acute 7d ÷ chronic 28d)", acwr)
        return SubScore(kind: .load, value: score, weight: weights.load, detail: detail)
    }

    private func tempSub(_ delta: Double?, history: [Double]) -> SubScore {
        guard let delta else {
            return SubScore(kind: .wristTemperature, value: 70, weight: weights.temp, detail: "No wrist temp reading")
        }
        // Apple already reports a deviation in °C from personal baseline.
        // |Δ| ≤ 0.2 → great. ≥ 0.6 → bad (possible illness / poor sleep).
        let absDelta = abs(delta)
        let score: Double
        switch absDelta {
        case ..<0.2: score = 100
        case 0.2..<0.4: score = 80
        case 0.4..<0.6: score = 60
        case 0.6..<0.9: score = 40
        default: score = 25
        }
        let detail = String(format: "%+.2f °C from baseline", delta)
        return SubScore(kind: .wristTemperature, value: score, weight: weights.temp, detail: detail)
    }

    // MARK: - Helpers

    private func baseline(from values: [Double], minSamples: Int = 7) -> Baseline? {
        let filtered = values.filter { $0.isFinite }
        guard filtered.count >= minSamples else { return nil }
        let mean = filtered.reduce(0, +) / Double(filtered.count)
        let variance = filtered.reduce(0) { $0 + pow($1 - mean, 2) } / Double(filtered.count)
        return Baseline(mean: mean, stdDev: sqrt(variance), sampleCount: filtered.count)
    }

    func computeACWR(history: [DailyMetrics]) -> Double? {
        let loads = history.map { $0.workoutLoad ?? 0 }
        guard loads.count >= 14 else { return nil }
        let acuteWindow = Array(loads.suffix(7))
        let chronicWindow = Array(loads.suffix(28))
        let acute = acuteWindow.reduce(0, +) / Double(acuteWindow.count)
        let chronic = chronicWindow.reduce(0, +) / Double(chronicWindow.count)
        guard chronic > 0 else { return nil }
        return acute / chronic
    }

    private func makeHeadline(value: Int, subs: [SubScore], acwr: Double?) -> String {
        let limiter = subs.min(by: { $0.value < $1.value })
        let band = ReadinessScore(date: Date(), value: value, subScores: subs, acwr: acwr, headline: "").band
        switch band {
        case .prime: return "Prime. Go take a swing at something hard."
        case .ready: return "Ready. Plan the session you actually want."
        case .moderate: return limiter.map { "Held back by \($0.kind.label.lowercased()). Train, but moderate." } ?? "Moderate. Train, but moderate."
        case .low: return "Low. Prioritize recovery, keep work easy."
        case .depleted: return "Depleted. Walk, mobilize, sleep — no hard training."
        }
    }
}
