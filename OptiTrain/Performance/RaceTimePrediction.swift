import Foundation

/// Race-time prediction using Pete Riegel's endurance equation:
///   T₂ = T₁ · (D₂ / D₁)^1.06
///
/// Riegel's exponent 1.06 is well-validated for distances within ~5×–10× of
/// the reference, less reliable extrapolating from a 5K to a marathon, and
/// poor for sub-5K (anaerobic dominated). We use the user's most recent
/// distance-matched effort as the reference, with a durability adjustment
/// that penalizes extrapolations the athlete hasn't earned.
struct RaceTimePrediction: Sendable {

    enum RaceDistance: String, CaseIterable, Sendable {
        // Running
        case mile = "Mile"
        case fiveK = "5K"
        case tenK = "10K"
        case halfMarathon = "Half"
        case marathon = "Marathon"
        case fiftyKUltra = "50K Ultra"
        // Cycling
        case fortyKTT = "40K TT"
        case granFondo = "Gran Fondo"
        case century = "Century"
        // Triathlon
        case sprintTri = "Sprint Tri"
        case olympicTri = "Olympic / 5150"
        case seventyThree = "70.3"
        case ironman = "Ironman"
        // Duathlon (run → bike → run)
        case sprintDuathlon = "Sprint Duathlon"
        case standardDuathlon = "Standard Duathlon"
        // Biathlon (swim → run)
        case sprintBiathlon = "Sprint Biathlon"
        case standardBiathlon = "Standard Biathlon"

        /// Sport family used to group and filter events in the UI.
        enum Category: String, CaseIterable, Sendable {
            case running = "Running"
            case cycling = "Cycling"
            case triathlon = "Triathlon"
            case duathlon = "Duathlon"
            case biathlon = "Biathlon"

            var symbol: String {
                switch self {
                case .running: "figure.run"
                case .cycling: "figure.outdoor.cycle"
                case .triathlon: "figure.pool.swim"
                case .duathlon: "bicycle"
                case .biathlon: "drop.fill"
                }
            }
        }

        var category: Category {
            switch self {
            case .mile, .fiveK, .tenK, .halfMarathon, .marathon, .fiftyKUltra: .running
            case .fortyKTT, .granFondo, .century: .cycling
            case .sprintTri, .olympicTri, .seventyThree, .ironman: .triathlon
            case .sprintDuathlon, .standardDuathlon: .duathlon
            case .sprintBiathlon, .standardBiathlon: .biathlon
            }
        }

        /// Running-equivalent distance in meters. For multisport events we use
        /// the total moving distance — not physiologically perfect, but a
        /// consistent basis for the Riegel-style time estimate.
        var equivalentRunMeters: Double {
            switch self {
            case .mile: 1_609
            case .fiveK: 5_000
            case .tenK: 10_000
            case .halfMarathon: 21_097
            case .marathon: 42_195
            case .fiftyKUltra: 50_000
            case .fortyKTT: 40_000
            case .granFondo: 120_000
            case .century: 160_934
            case .sprintTri: 25_750            // 0.75 swim + 20 bike + 5 run
            case .olympicTri: 51_500
            case .seventyThree: 113_000
            case .ironman: 226_000
            case .sprintDuathlon: 27_500       // 5 run + 20 bike + 2.5 run
            case .standardDuathlon: 55_000     // 10 run + 40 bike + 5 run
            case .sprintBiathlon: 5_750        // 0.75 swim + 5 run
            case .standardBiathlon: 11_500     // 1.5 swim + 10 run
            }
        }

        /// The sports that make up this event, in race order.
        enum Discipline: String, CaseIterable, Sendable {
            case swim, bike, run
            var label: String {
                switch self {
                case .swim: "Swim"
                case .bike: "Bike"
                case .run: "Run"
                }
            }
            var symbol: String {
                switch self {
                case .swim: "figure.pool.swim"
                case .bike: "figure.outdoor.cycle"
                case .run: "figure.run"
                }
            }
        }

        var disciplines: [Discipline] {
            switch self {
            case .mile, .fiveK, .tenK, .halfMarathon, .marathon, .fiftyKUltra: [.run]
            case .fortyKTT, .granFondo, .century: [.bike]
            case .sprintTri, .olympicTri, .seventyThree, .ironman: [.swim, .bike, .run]
            case .sprintDuathlon, .standardDuathlon: [.run, .bike]
            case .sprintBiathlon, .standardBiathlon: [.swim, .run]
            }
        }
    }

    struct Reference: Sendable {
        let distanceMeters: Double
        let durationSeconds: Double
        let date: Date
    }

    struct Prediction: Equatable, Sendable {
        let distance: RaceDistance
        let predictedSeconds: Double
        let lowerBoundSeconds: Double      // ±5% optimistic
        let upperBoundSeconds: Double      // ±10% pessimistic (drift, untrained terrain)
        let durabilityPenaltyPercent: Double
        let confidence: Confidence
    }

    init() {}

    /// Jack Daniels' VDOT: a VO₂max-equivalent inferred from a race-effort
    /// distance/time. Combines the velocity→VO₂ cost regression with Daniels'
    /// %VO₂max-vs-duration curve. Valid for sustained efforts of ~3–120 min;
    /// it's the right currency for comparing runs of different lengths.
    static func vdot(distanceMeters d: Double, durationSeconds t: Double) -> Double {
        guard d > 0, t > 0 else { return 0 }
        let minutes = t / 60.0
        let v = d / minutes                                   // m/min
        let vo2 = -4.60 + 0.182258 * v + 0.000104 * v * v
        let pct = 0.8 + 0.1894393 * exp(-0.012778 * minutes)
                      + 0.2989558 * exp(-0.1932605 * minutes)
        return pct > 0 ? vo2 / pct : 0
    }

    /// Pick the best reference from recent runs — the effort with the highest
    /// VDOT (race-equivalent fitness), nudged by a mild recency weight so a
    /// stale PR can't out-rank a fresh, near-equal result. This means a faster
    /// 5K beats a slower 8K, which is what short-distance predictions need.
    func bestReference(from runs: [WorkoutSummary], minMeters: Double = 2_000) -> Reference? {
        let candidates = runs
            .filter { $0.kind == .run && ($0.distanceMeters ?? 0) >= minMeters && $0.duration > 0 }
        let best = candidates.max { lhs, rhs in
            let lScore = Self.vdot(distanceMeters: lhs.distanceMeters ?? 0, durationSeconds: lhs.duration)
                * (0.8 + 0.2 * recencyFactor(date: lhs.start))
            let rScore = Self.vdot(distanceMeters: rhs.distanceMeters ?? 0, durationSeconds: rhs.duration)
                * (0.8 + 0.2 * recencyFactor(date: rhs.start))
            return lScore < rScore
        }
        guard let best else { return nil }
        return Reference(distanceMeters: best.distanceMeters ?? 0, durationSeconds: best.duration, date: best.start)
    }

    func predict(_ distance: RaceDistance, from reference: Reference, longestRecentRunMeters: Double) -> Prediction {
        let d2 = distance.equivalentRunMeters
        let d1 = reference.distanceMeters
        let t1 = reference.durationSeconds
        let raw = t1 * pow(d2 / d1, 1.06)

        // Durability penalty: if the target distance is more than 1.5× longer
        // than anything the athlete has run recently, pad the estimate.
        let stretch = d2 / max(longestRecentRunMeters, 1)
        let penalty: Double = {
            switch stretch {
            case ..<1.5: 0
            case 1.5..<2.5: 0.05
            case 2.5..<4: 0.12
            default: 0.25
            }
        }()
        let predicted = raw * (1 + penalty)

        let confidence = Confidence(
            // Reduces with both staleness and extrapolation.
            max(0.05, 1.0 - 0.3 * stretch.bounded(in: 0...3) / 3.0 - 0.1 * recencyDecay(date: reference.date))
        )

        return Prediction(
            distance: distance,
            predictedSeconds: predicted,
            lowerBoundSeconds: predicted * 0.95,
            upperBoundSeconds: predicted * 1.10,
            durabilityPenaltyPercent: penalty * 100,
            confidence: confidence
        )
    }

    /// Fractional weight: 1.0 today, 0.5 at 60 days old, 0.0 at 180+ days old.
    private func recencyFactor(date: Date) -> Double {
        let days = Date().timeIntervalSince(date) / 86_400
        return max(0, 1.0 - days / 180.0)
    }

    private func recencyDecay(date: Date) -> Double {
        let days = Date().timeIntervalSince(date) / 86_400
        return min(1.0, days / 180.0)
    }
}

private extension Double {
    func bounded(in r: ClosedRange<Double>) -> Double { min(r.upperBound, max(r.lowerBound, self)) }
}
