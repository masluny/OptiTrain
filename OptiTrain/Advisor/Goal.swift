import Foundation

/// What the athlete is training *toward*. Either a specific race (reusing the
/// race-prediction catalog so race goals plug straight into the existing event
/// engine) or a broader lifestyle/fitness objective.
///
/// `RawRepresentable` so it round-trips through `@AppStorage` as a single string
/// like `"race:Marathon"` or `"generic:loseWeight"`.
enum Goal: RawRepresentable, Hashable, Identifiable, Sendable {
    case race(RaceTimePrediction.RaceDistance)
    case generic(GenericGoal)

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .race(let d):    "race:\(d.rawValue)"
        case .generic(let g): "generic:\(g.rawValue)"
        }
    }

    init?(rawValue: String) {
        guard let sep = rawValue.firstIndex(of: ":") else { return nil }
        let kind = String(rawValue[..<sep])
        let value = String(rawValue[rawValue.index(after: sep)...])
        switch kind {
        case "race":
            guard let d = RaceTimePrediction.RaceDistance(rawValue: value) else { return nil }
            self = .race(d)
        case "generic":
            guard let g = GenericGoal(rawValue: value) else { return nil }
            self = .generic(g)
        default:
            return nil
        }
    }

    /// Short display title.
    var title: String {
        switch self {
        case .race(let d):    "\(d.rawValue) race"
        case .generic(let g): g.title
        }
    }

    /// SF Symbol for the goal.
    var symbol: String {
        switch self {
        case .race:           "flag.checkered"
        case .generic(let g): g.symbol
        }
    }

    /// One-line description of what success looks like.
    var subtitle: String {
        switch self {
        case .race(let d):    "Be ready to perform at \(d.rawValue)."
        case .generic(let g): g.subtitle
        }
    }
}

/// Non-race objectives. Phrased the way an athlete would say them.
enum GenericGoal: String, CaseIterable, Codable, Identifiable, Sendable {
    case getFitter
    case loseWeight
    case buildMuscle
    case raiseAthleteLevel
    case sleepBetter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .getFitter:        "Get more fit"
        case .loseWeight:        "Lose weight"
        case .buildMuscle:       "Build muscle mass"
        case .raiseAthleteLevel: "Raise my Athlete Level"
        case .sleepBetter:       "Sleep & recover better"
        }
    }

    var subtitle: String {
        switch self {
        case .getFitter:        "Build a bigger aerobic engine and everyday stamina."
        case .loseWeight:        "Drop body fat while protecting fitness and recovery."
        case .buildMuscle:       "Add strength and lean mass with smart training and fuel."
        case .raiseAthleteLevel: "Push your overall Athlete Level score higher."
        case .sleepBetter:       "Improve sleep, HRV and day-to-day readiness."
        }
    }

    var symbol: String {
        switch self {
        case .getFitter:        "figure.run"
        case .loseWeight:        "flame.fill"
        case .buildMuscle:       "figure.strengthtraining.traditional"
        case .raiseAthleteLevel: "chart.line.uptrend.xyaxis"
        case .sleepBetter:       "moon.zzz.fill"
        }
    }
}
