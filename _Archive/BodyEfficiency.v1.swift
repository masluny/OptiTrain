import Foundation

/// "Athlete Level" (the type keeps its original `BodyEfficiency` name) — a
/// single 0–10 headline metric for how capable the athlete's body is. It's a
/// deliberate simplification of the twelve-component `PhysiologyProfile`: we
/// fold those components into four physiological systems that map cleanly onto
/// regions of the body, then blend the systems into one number an athlete can
/// read at a glance (and share). A body-composition (BMI) modifier then nudges
/// the headline number — see `bmiFactor`.
///
/// The four systems and their body regions:
///   • Aerobic engine  → chest / heart   (VO₂max, threshold)
///   • Endurance core  → torso / core    (durability, volume tolerance, fueling)
///   • Locomotion      → legs            (fatigue resistance, anaerobic, specificity)
///   • Recovery        → head            (recovery resilience, sleep, freshness)
///
/// Heat adaptation is intentionally excluded — it's a placeholder midpoint in
/// the profile and would only drag every score toward 5.0.
struct BodyEfficiency: Sendable {

    /// A physiological system: a named bundle of profile components, scored
    /// 0–100, that lights up one region of the body silhouette.
    struct System: Equatable, Sendable, Identifiable {
        enum Kind: String, CaseIterable, Sendable {
            case aerobic   = "Aerobic engine"
            case endurance = "Endurance core"
            case locomotion = "Locomotion"
            case recovery  = "Recovery"

            /// Compact label for tight share-card chips.
            var shortLabel: String {
                switch self {
                case .aerobic:    "Engine"
                case .endurance:  "Core"
                case .locomotion: "Legs"
                case .recovery:   "Recovery"
                }
            }

            var symbol: String {
                switch self {
                case .aerobic:    "heart.fill"
                case .endurance:  "figure.core.training"
                case .locomotion: "figure.run"
                case .recovery:   "moon.zzz.fill"
                }
            }

            /// Vertical position of this system's body region, 0 = head, 1 = feet.
            /// Used to build the silhouette's top-to-bottom color gradient.
            var bodyRegionCenter: Double {
                switch self {
                case .recovery:   0.10   // head
                case .aerobic:    0.36   // chest
                case .endurance:  0.60   // core
                case .locomotion: 0.86   // legs
                }
            }
        }

        var id: String { kind.rawValue }
        let kind: Kind
        let score: Double     // 0–100
        let weight: Double    // contribution to the overall blend
    }

    enum Tier: String, Sendable {
        case peak       = "Peak"
        case elite      = "Elite"
        case strong     = "Strong"
        case building   = "Building"
        case developing = "Developing"
        case base       = "Base"

        init(score: Double) {           // score is 0–10
            switch score {
            case 9.0...:  self = .peak
            case 7.5...:  self = .elite
            case 6.0...:  self = .strong
            case 4.5...:  self = .building
            case 3.0...:  self = .developing
            default:      self = .base
            }
        }

        var headline: String {
            switch self {
            case .peak:       "Firing on all cylinders — race-ready machine."
            case .elite:      "Elite engine. Built to perform under load."
            case .strong:     "Strong and capable across every system."
            case .building:   "Solid foundation with clear room to climb."
            case .developing: "Foundations forming — keep stacking the weeks."
            case .base:       "Early days. Your engine is just waking up."
            }
        }
    }

    struct Snapshot: Equatable, Sendable {
        let score: Double          // 0–10, one decimal
        let score100: Double       // underlying 0–100
        let tier: Tier
        let systems: [System]      // always 4, in head→legs order
        let confidence: Confidence

        var formattedScore: String { String(format: "%.1f", score) }
        var headline: String { tier.headline }

        /// The single weakest system — the one most worth training next.
        var weakestSystem: System? { systems.min(by: { $0.score < $1.score }) }
        /// The single strongest system.
        var strongestSystem: System? { systems.max(by: { $0.score < $1.score }) }
    }

    init() {}

    func snapshot(profile p: PhysiologyProfile, bmi: Double? = nil, confidence: Confidence) -> Snapshot {
        let aerobic   = 0.55 * p.vo2maxScore + 0.45 * p.thresholdScore
        let endurance = 0.45 * p.durabilityScore + 0.30 * p.volumeToleranceScore + 0.25 * p.fuelingScore
        let locomotion = 0.45 * p.fatigueResistanceScore + 0.30 * p.anaerobicCapacityScore + 0.25 * p.specificityScore
        // Recovery here means *durable* recovery capacity — built the way the
        // commercial recovery scores (WHOOP, Oura, Garmin) are. The autonomic
        // backbone (steadiness of overnight HRV + resting HR) carries the most;
        // habitual sleep *quality* is a strong second; load-absorption (recovery
        // debt) and sleep-timing regularity round it out. Acute freshness is
        // deliberately excluded — that's a "today" signal, not a durable trait —
        // so a single rough night can't tank the figure.
        let recovery  = 0.40 * p.autonomicScore
                      + 0.30 * p.sleepQualityScore
                      + 0.15 * p.recoveryResilienceScore
                      + 0.15 * p.sleepConsistencyScore

        // System weights toward the overall score. Athlete Level is a measure
        // of *durable* fitness, so the aerobic engine, endurance core and
        // locomotion — slow-moving, training-built systems — carry almost all of
        // it. Recovery is a near-token weight: it still colors the figure's head,
        // but is deliberately kept from swinging the headline number on one bad
        // night's sleep or a heavy training day.
        let systems: [System] = [
            System(kind: .recovery,   score: clamp(recovery),   weight: 0.08),
            System(kind: .aerobic,    score: clamp(aerobic),    weight: 0.38),
            System(kind: .endurance,  score: clamp(endurance),  weight: 0.32),
            System(kind: .locomotion, score: clamp(locomotion), weight: 0.22)
        ]

        let weightSum = systems.reduce(0) { $0 + $1.weight }
        let blended100 = systems.reduce(0) { $0 + $1.score * $1.weight } / max(weightSum, 0.0001)
        // Body composition nudges the headline: a healthy/athletic BMI leaves it
        // untouched, while a markedly high or low BMI trims it modestly (capped),
        // since BMI is a crude proxy that can't be allowed to dominate the
        // training-built systems above.
        let adjusted100 = clamp(blended100 * bmiFactor(bmi))
        let score10 = (displayScore(fromCapability: adjusted100) * 10).rounded() / 10.0  // 0–10, one decimal

        return Snapshot(
            score: score10,
            score100: adjusted100,
            tier: Tier(score: score10),
            systems: systems,
            confidence: confidence
        )
    }

    private func clamp(_ v: Double) -> Double { min(100, max(0, v)) }

    /// Multiplier in [0.80, 1.0] applied to the capability blend from BMI. Inside
    /// the healthy/athletic band (18.5–25) it's a no-op (1.0); outside, every BMI
    /// point of deviation trims 2.5%, floored at 0.80 so a crude number can never
    /// halve someone's level. Returns 1.0 when we have no height/weight data.
    private func bmiFactor(_ bmi: Double?) -> Double {
        guard let bmi, bmi > 0 else { return 1.0 }
        let lower = 18.5, upper = 25.0
        let deviation = bmi < lower ? lower - bmi : (bmi > upper ? bmi - upper : 0)
        return max(0.80, 1.0 - deviation * 0.025)
    }

    /// Maps the raw 0–100 capability blend onto the displayed 0–10 score with a
    /// deliberately non-linear, motivating curve (vs. a straight line):
    ///   • 1–3 are rare — reserved for genuinely low-fitness bodies, so a sub-4
    ///     number actually means something. A 1 stays reachable, just uncommon.
    ///   • 4 is the "hardly trains" level; 5 is the average, untrained-but-healthy
    ///     middle — reaching it takes a real aerobic base.
    ///   • 5 → 9 is the easy, rewarding stretch: steady training moves the number
    ///     fast, so progress feels earned and visible.
    ///   • 10 is the wall — a genuinely elite ceiling that takes far more than 9.
    ///
    /// Anchors are (capability 0–100, displayed 0–10), interpolated linearly
    /// between. Slopes in "capability points needed per displayed point":
    /// 0→3 = 4 (a 1 lands at capability ~4; below 3 needs capability < 12),
    /// 3→4 = 12, 4→5 = 14 (you must build a base to be "average"),
    /// 5→9 = 6 (the easy climb), 9→10 = 38 (the elite wall).
    func displayScore(fromCapability x: Double) -> Double {
        let anchors: [(x: Double, y: Double)] = [
            (0, 0), (12, 3), (24, 4), (38, 5), (62, 9), (100, 10)
        ]
        let cx = min(100, max(0, x))
        for i in 1..<anchors.count {
            let lo = anchors[i - 1], hi = anchors[i]
            if cx <= hi.x {
                let t = (cx - lo.x) / (hi.x - lo.x)
                return lo.y + t * (hi.y - lo.y)
            }
        }
        return 10
    }
}
