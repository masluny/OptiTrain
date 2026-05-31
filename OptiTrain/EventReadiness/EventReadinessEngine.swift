import Foundation

/// Computes per-event readiness as a weighted blend of physiology components.
/// Provides limiting-factor analysis (the smallest weighted contribution) and
/// "race-collapse risk" — the probability that the athlete underperforms by
/// >10% due to a specific weakness exceeding a tolerance.
struct EventReadinessEngine: Sendable {

    struct Readiness: Equatable, Identifiable, Sendable {
        let id: String
        let event: RaceTimePrediction.RaceDistance
        let score: Int                           // 0...100
        // The three pillars behind the score, the way Garmin/WHOOP/Oura split
        // capability from form from acute recovery. All 0...100.
        let fitnessScore: Double                 // built capability (VO₂max/VDOT + coverage)
        let formScore: Double                    // TSB taper state (Coggan/TrainingPeaks)
        let recoveryScore: Double                // HRV-baseline + recovery debt + sleep
        let limitingFactor: Factor?
        let strongestFactor: Factor?
        let collapseRiskPercent: Double          // 0-100, qualitative
        let completionProbability: Double        // 0-1
        let trainingCoveragePercent: Double      // 0...100 of event distance covered by longest run
        let longestRunMeters: Double
        let referenceDate: Date?
        let referenceDistanceMeters: Double?
        let referenceAgeDays: Int?
        let assumptions: [String]
        let explanation: Explanation
        let confidence: Confidence
    }

    /// Demonstrated-performance context: the athlete's best recent run effort and
    /// how far they've actually gone. This is what grounds readiness in *what you
    /// did*, not just a HealthKit VO₂max estimate.
    struct PerformanceContext: Sendable {
        let reference: RaceTimePrediction.Reference?
        let longestRunMeters: Double
        let longestRunWindowDays: Int
        let fitnessTrend: Double            // 0...1, 0.5 = flat, >0.5 = VO₂max/efficiency improving
        let observedDayCoverage: Double     // 0...1 in recent loaded history
        let historyWindowDays: Int
    }

    init() {}

    func readiness(for event: RaceTimePrediction.RaceDistance,
                          profile: PhysiologyProfile,
                          performance: PerformanceContext,
                          baseConfidence: Confidence) -> Readiness {
        let w = EventWeightingMatrix.weights(for: event)

        // ── Pillar 1 · FITNESS (what you've built) ───────────────────────────
        // The capability you'd bring to the start line, independent of taper or
        // today's recovery. Garmin frames this as VO₂max + race-predictor +
        // chronic load. We anchor it in demonstrated *training*: covering the
        // distance is dominant, then VDOT speed and an upward trend lift it.
        // Speed is gated by coverage so a fast 5K can't inflate a marathon you've
        // never trained for (the classic VO₂max over-prediction).
        let capabilityBlend = Self.capabilityScore(profile: profile, weights: w)
        let coverage = Self.coverage(longestRunMeters: performance.longestRunMeters, eventMeters: event.equivalentRunMeters)
        let trainingFitness: Double
        if let ref = performance.reference {
            let vdot = RaceTimePrediction.vdot(distanceMeters: ref.distanceMeters, durationSeconds: ref.durationSeconds)
            let speed = Self.vdotReadiness(vdot) / 100.0
            let trend = max(0, min(1, performance.fitnessTrend))
            let base = 40 + 50 * coverage                               // 40 (untrained) → 90 (covered)
            let lift = (100 - base) * (0.6 * speed + 0.4 * trend) * coverage
            trainingFitness = base + lift
        } else {
            trainingFitness = capabilityBlend
        }
        // How much a running result describes this event. Pure running → trust
        // the demonstrated effort; the more a race leans on other disciplines,
        // the more we lean on the physiology capability blend instead.
        let applicability = Self.performanceApplicability(for: event, hasReference: performance.reference != nil)
        let fitness = max(0, min(100, applicability * trainingFitness + (1 - applicability) * capabilityBlend))

        // ── Pillar 2 · FORM (taper / freshness) ──────────────────────────────
        // Coggan's TSB "form" model, as Garmin Training Status and TrainingPeaks
        // use it for race day: peaked (TSB +5…+25) sharpens performance, deep
        // fatigue blunts it. freshnessScore already encodes the TSB window; we
        // turn it into a *gentle* modifier (≈ +5% peaked … −8% buried). It's kept
        // deliberately mild because this is forward-looking race readiness — you
        // taper before the race, so today's fatigue shouldn't dominate the score.
        let formScore = profile.freshnessScore
        let formModifier = min(1.05, max(0.92, 0.92 + formScore / 100.0 * 0.14))

        // ── Pillar 3 · RECOVERY (acute readiness) ────────────────────────────
        // The WHOOP Recovery / Oura Readiness / Garmin Training-Readiness
        // backbone: HRV vs personal baseline carries the most (autonomic), with
        // recovery debt and habitual sleep quality behind it. It's a one-sided
        // *gate* (≤1.0) — being well-recovered can't make you fitter than you
        // are, but being under-recovered blunts how much you can express it.
        // Capped at a mild −10% (vs WHOOP/Oura's harsher daily gate): race
        // readiness assumes you'll be recovered by race day, not gated on today.
        let recoveryScore = min(100, max(0,
            0.55 * profile.autonomicScore
          + 0.25 * profile.recoveryResilienceScore
          + 0.20 * profile.sleepQualityScore))
        let recoveryModifier = min(1.0, max(0.90, 0.90 + recoveryScore / 100.0 * 0.10))

        // Capability, shaped by form, gated by recovery.
        let raw = max(0, min(100, fitness * formModifier * recoveryModifier))
        let score = Int(raw.rounded())

        // Per-component weighted contribution — the ones that move the score most.
        let contributions: [(label: String, weight: Double, value: Double)] = [
            ("VO₂max",                 w.vo2max,             profile.vo2maxScore),
            ("Threshold",              w.threshold,          profile.thresholdScore),
            ("Anaerobic capacity",     w.anaerobic,          profile.anaerobicCapacityScore),
            ("Durability",             w.durability,         profile.durabilityScore),
            ("Fueling",                w.fueling,            profile.fuelingScore),
            ("Heat adaptation",        w.heat,               profile.heatScore),
            ("Recovery resilience",    w.recoveryResilience, profile.recoveryResilienceScore),
            ("Sleep consistency",      w.sleepConsistency,   profile.sleepConsistencyScore),
            ("Volume tolerance",       w.volumeTolerance,    profile.volumeToleranceScore),
            ("Fatigue resistance",     w.fatigueResistance,  profile.fatigueResistanceScore),
            ("Specificity",            w.specificity,        profile.specificityScore),
            ("Freshness",              w.freshness,          profile.freshnessScore)
        ].filter { $0.weight > 0.001 }

        // Sort contributions by *missed potential* (weight × (100 − value)) — that's
        // the component that, if improved, would lift the score most.
        let missed = contributions
            .map { ($0.label, $0.weight, $0.value, $0.weight * (100 - $0.value)) }
            .sorted { $0.3 > $1.3 }
        let strongest = contributions
            .map { ($0.label, $0.weight * $0.value) }
            .max(by: { $0.1 < $1.1 })

        // Headline breakdown is the three pillars — capability, form, recovery —
        // mirroring how Garmin/WHOOP/Oura present readiness.
        let factors: [Factor] = [
            Factor(
                label: "Fitness",
                direction: fitness > 70 ? .positive : (fitness < 45 ? .negative : .neutral),
                magnitude: min(1, fitness / 100),
                detail: String(format: "%.0f/100 — built capability", fitness)
            ),
            Factor(
                label: "Form (taper)",
                direction: formModifier > 1.0 ? .positive : (formModifier < 0.95 ? .negative : .neutral),
                magnitude: min(1, abs(formModifier - 1.0) / 0.15),
                detail: String(format: "TSB freshness %.0f/100 · %+.0f%%", formScore, (formModifier - 1) * 100)
            ),
            Factor(
                label: "Recovery",
                direction: recoveryScore > 66 ? .positive : (recoveryScore < 40 ? .negative : .neutral),
                magnitude: min(1, recoveryScore / 100),
                detail: String(format: "%.0f/100 — HRV/sleep state · %+.0f%%", recoveryScore, (recoveryModifier - 1) * 100)
            )
        ]

        let limiting = missed.first.map { m in
            Factor(label: m.0, direction: .negative, magnitude: min(1, m.3 / 30.0),
                   detail: String(format: "Lifting this from %.0f → 75 would add ~%.0f points", m.2, max(0, (75 - m.2)) * m.1))
        }

        // Collapse risk: a single component below a tolerance threshold
        // tailored to its event-importance. A 25/100 durability with weight 0.28
        // (Ironman) is a near-certain bonk; a 25/100 anaerobic for a marathon
        // is irrelevant.
        let collapseRisk: Double = contributions.reduce(0) { risk, c in
            let tolerance: Double = c.weight > 0.15 ? 40 : 25
            guard c.value < tolerance else { return risk }
            return risk + (tolerance - c.value) * c.weight
        }.bounded(in: 0...60)
        let collapsePct = (collapseRisk / 60.0) * 100

        // Completion probability — a soft inverse of collapse + base.
        let completion = max(0.05, min(0.99, 0.50 + (raw - 50) / 80.0 - collapsePct / 200.0))
        let referenceAgeDays = performance.reference.map {
            max(0, Int(Date().timeIntervalSince($0.date) / 86_400.0))
        }
        var assumptions: [String] = [
            "Calculated from recorded Apple Health workouts and physiology signals."
        ]
        if let age = referenceAgeDays, age > 180 {
            assumptions.append("Best reference workout is \(age) days old, so confidence is reduced.")
        }
        if performance.observedDayCoverage < 0.70 {
            let pct = Int((performance.observedDayCoverage * 100).rounded())
            assumptions.append("Only \(pct)% of recent days had recorded signals in the \(performance.historyWindowDays)-day window.")
        }
        if coverage < 0.60 {
            assumptions.append("Longest recorded run in the last \(performance.longestRunWindowDays) days is well below this event distance, which caps readiness.")
        }
        if performance.reference == nil {
            assumptions.append("No qualifying run reference was found, so readiness leans more on physiology proxies.")
        }

        let headline: String = {
            let noun: String = {
                switch event {
                case .tennisMatch, .boulderingSession: return "session"
                default: return "race"
                }
            }()
            return switch score {
            case 85...: "\(event.rawValue) — A-\(noun) ready."
            case 70...: "\(event.rawValue) — \(noun)-fit, fine-tune."
            case 55...: "\(event.rawValue) — capable, with caveats."
            case 40...: "\(event.rawValue) — manageable, far from optimal."
            default:    "\(event.rawValue) — keep this \(noun) easy today."
            }
        }()

        let expl = Explanation(headline: headline, factors: factors, limitingFactor: limiting)

        return Readiness(
            id: event.rawValue,
            event: event,
            score: score,
            fitnessScore: fitness,
            formScore: formScore,
            recoveryScore: recoveryScore,
            limitingFactor: limiting,
            strongestFactor: strongest.map { Factor(label: $0.0, direction: .positive, magnitude: 1, detail: "Top contributor") },
            collapseRiskPercent: collapsePct,
            completionProbability: completion,
            trainingCoveragePercent: coverage * 100,
            longestRunMeters: performance.longestRunMeters,
            referenceDate: performance.reference?.date,
            referenceDistanceMeters: performance.reference?.distanceMeters,
            referenceAgeDays: referenceAgeDays,
            assumptions: assumptions,
            explanation: expl,
            confidence: baseConfidence
        )
    }

    /// All events at once — that's the punchline of the spec: high 5K, low Ironman simultaneously.
    func allReadiness(profile: PhysiologyProfile, performance: PerformanceContext, baseConfidence: Confidence) -> [Readiness] {
        RaceTimePrediction.RaceDistance.allCases.map {
            readiness(for: $0, profile: profile, performance: performance, baseConfidence: baseConfidence)
        }
    }

    // MARK: - Performance anchoring

    /// Capability-only physiology blend: the *training-built* components, with
    /// recovery resilience, sleep and freshness deliberately excluded — those are
    /// scored separately as the Recovery and Form pillars, so folding them in here
    /// too would double-count them. Re-normalizes over the remaining weights.
    private static func capabilityScore(profile p: PhysiologyProfile, weights w: EventWeightingMatrix.Weights) -> Double {
        let pairs: [(weight: Double, value: Double)] = [
            (w.vo2max,            p.vo2maxScore),
            (w.threshold,         p.thresholdScore),
            (w.anaerobic,         p.anaerobicCapacityScore),
            (w.durability,        p.durabilityScore),
            (w.fueling,           p.fuelingScore),
            (w.heat,              p.heatScore),
            (w.volumeTolerance,   p.volumeToleranceScore),
            (w.fatigueResistance, p.fatigueResistanceScore),
            (w.specificity,       p.specificityScore)
        ]
        let wsum = pairs.reduce(0) { $0 + $1.weight }
        guard wsum > 0.0001 else { return 50 }
        return pairs.reduce(0) { $0 + $1.weight * $1.value } / wsum
    }

    /// How much a running VDOT should drive this event's readiness, vs the
    /// physiology blend. Pure running events are performance-dominated; the more a
    /// race leans on other disciplines, the less a run result tells us about it.
    private static func performanceApplicability(for event: RaceTimePrediction.RaceDistance, hasReference: Bool) -> Double {
        guard hasReference else { return 0 }
        switch event.category {
        case .running:             return 0.90
        case .duathlon, .biathlon: return 0.45
        case .triathlon:           return 0.35
        case .cycling:             return 0.20
        case .racket, .climbing:   return 0.15
        }
    }

    /// Demonstrated aerobic engine → 0–100 readiness. Deliberately generous about
    /// *being able to race at all*: simply running an event-equivalent effort earns
    /// a solidly "capable" number, with the top of the scale reserved for genuine
    /// speed. (VDOT ≈ 30, a ~31-min 5K, lands around 72.)
    private static func vdotReadiness(_ vdot: Double) -> Double {
        let anchors: [(x: Double, y: Double)] = [
            (0, 0), (20, 50), (30, 72), (40, 83), (50, 91), (60, 96), (75, 100)
        ]
        let v = max(0, min(75, vdot))
        for i in 1..<anchors.count {
            let lo = anchors[i - 1], hi = anchors[i]
            if v <= hi.x {
                let t = (v - lo.x) / (hi.x - lo.x)
                return lo.y + t * (hi.y - lo.y)
            }
        }
        return 100
    }

    /// How much of this distance you've actually trained for — the dominant
    /// input to readiness. Full marks (1.0) once your longest recent run reaches
    /// the event distance; below that a pow-shaped ramp so a near-miss barely
    /// dents readiness while a big gap (a marathon off a 10 km long run) clearly
    /// caps it. This both sets the base *and* gates how much raw speed can lift it.
    private static func coverage(longestRunMeters longest: Double, eventMeters: Double) -> Double {
        guard eventMeters > 0 else { return 1 }
        let ratio = max(0, min(1, longest / eventMeters))
        return pow(ratio, 0.85)
    }
}

private extension Double {
    func bounded(in r: ClosedRange<Double>) -> Double { min(r.upperBound, max(r.lowerBound, self)) }
}
