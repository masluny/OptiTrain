import Foundation

/// Autonomic stability — how *consistent* the nervous system has been over a
/// rolling 7-day window. High volatility in HRV/RHR/RR/wrist temperature is a
/// classic precursor to illness or non-functional overreaching, often visible
/// 24-72h before subjective symptoms.
///
/// We don't try to predict illness — we surface the *signal*, with explicit
/// thresholds derived from sports-science literature on autonomic balance.
struct AutonomicStability: Sendable {

    struct Snapshot: Equatable, Sendable {
        let stabilityScore: Double           // 0-100, higher = more stable (CV-based, Plews et al.)
        /// Current HRV vs personal baseline → 0–100, the way WHOOP Recovery,
        /// Oura HRV Balance and Garmin HRV Status frame *daily* readiness.
        /// Distinct from stabilityScore: stability is consistency-over-time,
        /// baseline-score is "where are you right now vs your normal."
        let hrvBaselineScore: Double
        let hrvCV: Double?
        let rhrCV: Double?
        let respiratoryCV: Double?
        let tempVariance: Double?
        let illnessRiskSignal: Signal
        let overtrainingSignal: Signal
        let factors: [Factor]
        let confidence: Confidence
    }

    enum Signal: String, Sendable {
        case quiet, watch, elevated, alarming
        var label: String {
            switch self {
            case .quiet: "Quiet"; case .watch: "Watch"
            case .elevated: "Elevated"; case .alarming: "Alarming"
            }
        }
    }

    init() {}

    func snapshot(history: [DailyMetrics]) -> Snapshot? {
        guard history.count >= 5 else { return nil }
        let sortedHistory = history.sorted(by: { $0.date < $1.date })
        let window = Array(sortedHistory.suffix(7))

        // Long-term personal baseline (median + MAD over all available history),
        // used to judge whether the recent week sits inside the athlete's normal
        // HRV range — the same "7-day average vs personal baseline" comparison
        // Garmin's HRV Status and Oura's HRV Balance are built on.
        let hrvBaseline = AdaptiveBaseline.build(from: sortedHistory.compactMap(\.overnightHRV))

        let hrv = window.compactMap(\.overnightHRV)
        let rhr = window.compactMap(\.restingHeartRate)
        let rr  = window.compactMap(\.respiratoryRate)
        let temps = window.compactMap(\.wristTemperatureDelta)

        let hrvCV = RobustStatistics.coefficientOfVariation(hrv)
        let rhrCV = RobustStatistics.coefficientOfVariation(rhr)
        let rrCV  = RobustStatistics.coefficientOfVariation(rr)
        let tempVar: Double? = {
            guard temps.count >= 3 else { return nil }
            let mean = temps.reduce(0, +) / Double(temps.count)
            return temps.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(temps.count)
        }()

        // Score each component: lower CV → higher stability.
        // Thresholds chosen against published values for trained athletes.
        let hrvScore = hrvCV.map { score(cv: $0, idealCV: 0.08, redlineCV: 0.25) } ?? 50
        let rhrScore = rhrCV.map { score(cv: $0, idealCV: 0.03, redlineCV: 0.12) } ?? 50
        let rrScore  = rrCV.map  { score(cv: $0, idealCV: 0.04, redlineCV: 0.18) } ?? 50
        let tempScore = tempVar.map { v in
            // Apple's "deviation from baseline" is already centered. Variance > 0.15 is alarming.
            min(100, max(0, 100 - v * 400))
        } ?? 50

        let stability = 0.40 * hrvScore + 0.30 * rhrScore + 0.15 * rrScore + 0.15 * tempScore

        // Current 7-day HRV mean's z-score vs personal baseline — the WHOOP /
        // Oura / Garmin HRV-vs-baseline signal. Used both for the overtraining
        // call below and the new hrvBaselineScore exposed for daily-readiness
        // consumers (Athlete Level Recovery + race readiness Recovery pillar).
        let hrvBaselineZ: Double? = {
            guard let base = hrvBaseline, !hrv.isEmpty else { return nil }
            return base.z(of: hrv.reduce(0, +) / Double(hrv.count))
        }()
        let hrvBaselineScore = hrvBaselineZ.map(Self.scoreFromBaselineZ) ?? 60

        let illness: Signal = {
            // Suppressed HRV + elevated RR + warm temp is the classic pre-illness triad.
            var hits = 0
            if (hrvCV ?? 0) > 0.20 { hits += 1 }
            if let lastRR = rr.last, let baseline = RobustStatistics.median(rr), lastRR > baseline * 1.10 { hits += 1 }
            if let temp = temps.last, temp > 0.5 { hits += 1 }
            switch hits {
            case 3: return .alarming
            case 2: return .elevated
            case 1: return .watch
            default: return .quiet
            }
        }()

        let overtraining: Signal = {
            // Garmin HRV Status / Oura HRV Balance: 7-day HRV mean vs personal
            // baseline. We already have the z above — just classify it.
            guard let z = hrvBaselineZ else { return .quiet }
            switch z {
            case ..<(-1.5): return .alarming    // 7-day avg well below personal range
            case ..<(-1.0): return .elevated
            case ..<(-0.5): return .watch
            default:        return .quiet       // inside the normal band, or above
            }
        }()

        let factors: [Factor] = [
            .init(label: "HRV variability", direction: (hrvCV ?? 0) > 0.15 ? .negative : .positive,
                  magnitude: min(1, (hrvCV ?? 0) / 0.30),
                  detail: String(format: "CV %.1f%% over 7d", (hrvCV ?? 0) * 100)),
            .init(label: "RHR variability", direction: (rhrCV ?? 0) > 0.08 ? .negative : .positive,
                  magnitude: min(1, (rhrCV ?? 0) / 0.15),
                  detail: String(format: "CV %.1f%% over 7d", (rhrCV ?? 0) * 100)),
            .init(label: "Respiratory rate", direction: (rrCV ?? 0) > 0.10 ? .negative : .positive,
                  magnitude: min(1, (rrCV ?? 0) / 0.20),
                  detail: String(format: "CV %.1f%% over 7d", (rrCV ?? 0) * 100))
        ]

        let confidence = Confidence.combine([
            Confidence.fromSampleDensity(present: hrv.count, target: 7),
            Confidence.fromSampleDensity(present: rhr.count, target: 7)
        ])

        return Snapshot(
            stabilityScore: stability,
            hrvBaselineScore: hrvBaselineScore,
            hrvCV: hrvCV, rhrCV: rhrCV, respiratoryCV: rrCV, tempVariance: tempVar,
            illnessRiskSignal: illness, overtrainingSignal: overtraining,
            factors: factors, confidence: confidence
        )
    }

    private func score(cv: Double, idealCV: Double, redlineCV: Double) -> Double {
        if cv <= idealCV { return 100 }
        if cv >= redlineCV { return 0 }
        return 100 * (1 - (cv - idealCV) / (redlineCV - idealCV))
    }

    /// Map a z-score (current 7-day HRV mean vs personal baseline) → 0–100,
    /// the way WHOOP Recovery, Oura HRV Balance and Garmin HRV Status frame
    /// daily recovery. In-range (z≈0) is solidly recovered (~75); suppression
    /// below baseline linearly degrades, well above scores high. Piecewise
    /// linear between published-style anchors.
    static func scoreFromBaselineZ(_ z: Double) -> Double {
        let anchors: [(z: Double, s: Double)] = [
            (-2.0, 10), (-1.5, 25), (-1.0, 45), (-0.5, 62),
            ( 0.0, 75), ( 0.5, 85), ( 1.0, 95), ( 2.0, 100)
        ]
        if z <= anchors.first!.z { return anchors.first!.s }
        if z >= anchors.last!.z  { return anchors.last!.s }
        for i in 1..<anchors.count {
            let lo = anchors[i - 1], hi = anchors[i]
            if z <= hi.z {
                let t = (z - lo.z) / (hi.z - lo.z)
                return lo.s + t * (hi.s - lo.s)
            }
        }
        return 75
    }
}
