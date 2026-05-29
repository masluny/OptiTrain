import Foundation
import FoundationModels

/// Turns the athlete's chosen ``Goal`` plus today's numeric snapshot into a
/// short, practical, on-device coaching plan. Same philosophy as ``AICoach``:
/// everything runs locally via Apple's Foundation Models, the numeric engines
/// stay authoritative, and the model only ever puts our numbers into words and
/// suggests concrete next steps toward the goal. Degrades gracefully when
/// Apple Intelligence isn't available (we reuse ``AICoach/availability()``).
enum GoalCoach {

    /// Compact, factual brief handed to the model. Pure Swift — no
    /// FoundationModels symbols — so it compiles on any OS.
    static func dataBlock(goal: Goal,
                          readiness: ReadinessScore,
                          snapshot: AdaptiveIntelligenceSnapshot) -> String {
        var lines: [String] = []
        lines.append("Goal: \(goal.title) — \(goal.subtitle)")
        lines.append("Today's readiness: \(readiness.value)/100 (\(readiness.band.label)).")

        let ath = snapshot.bodyEfficiency
        lines.append("Athlete Level: \(ath.formattedScore)/10 (\(ath.tier.rawValue)).")
        if let weak = ath.weakestSystem {
            lines.append("Weakest system: \(weak.kind.rawValue) (\(Int(weak.score))/100) — the best place to improve.")
        }
        if let strong = ath.strongestSystem {
            lines.append("Strongest system: \(strong.kind.rawValue) (\(Int(strong.score))/100).")
        }
        if let load = snapshot.load {
            lines.append("Training load — Fitness/CTL \(Int(load.ctl)), Fatigue/ATL \(Int(load.atl)), Form/TSB \(Int(load.tsb)). \(load.risk.headline)")
        }
        if let debt = snapshot.recoveryDebt {
            lines.append("14-day recovery debt: \(Int(debt.fourteenDay.debtPercent))% (\(debt.fourteenDay.stressClass.rawValue)).")
        }
        let risk = snapshot.injuryRisk
        lines.append("Risk guidance: \(risk.recommendation)")

        // For a race goal, fold in where they stand on that specific event.
        if case .race(let distance) = goal,
           let r = snapshot.eventReadiness.first(where: { $0.event == distance }) {
            lines.append("Race readiness for \(distance.rawValue): \(r.score)/100, finish probability \(Int(r.completionProbability * 100))%.")
            if let lim = r.limitingFactor {
                lines.append("Limiting factor for the race: \(lim.label) — \(lim.detail)")
            }
            if let pred = snapshot.racePredictions.first(where: { $0.distance == distance }) {
                lines.append("Predicted finish time: \(formatTime(pred.predictedSeconds)).")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Rule-based fallback (no AI)

extension GoalCoach {
    /// A deterministic, hand-written plan with the same shape as the AI one,
    /// used when AI features are turned off (e.g. where Apple Intelligence isn't
    /// available, like the EU) or when the on-device model can't run. Pure Swift
    /// — no model — built from the same numeric engines, so the Goal screen
    /// always has useful, personalised guidance.
    struct RuleBasedGuidance {
        var headline: String
        var weeklyFocus: String
        var steps: [String]
        var encouragement: String
    }

    static func fallbackPlan(goal: Goal,
                             readiness: ReadinessScore,
                             snapshot: AdaptiveIntelligenceSnapshot) -> RuleBasedGuidance {
        let debtPct = snapshot.recoveryDebt?.fourteenDay.debtPercent ?? 0
        let tsb = snapshot.load?.tsb ?? 0
        let needsRecovery = readiness.value < 50 || debtPct > 50 || tsb < -15
        let weakest = snapshot.bodyEfficiency.weakestSystem?.kind.rawValue

        // Headline: readiness band framed against the goal.
        let band: String
        switch readiness.value {
        case 80...:   band = "You're firing on all cylinders"
        case 65..<80: band = "You're in a good place"
        case 50..<65: band = "You've got a solid base to build on"
        case 35..<50: band = "Your body's asking for a little care"
        default:      band = "This is a week to recover and reset"
        }
        let headline = "\(band) as you work toward \(goalPhrase(goal))."

        // Focus + concrete steps tailored to the goal.
        var focus: String
        var steps: [String]
        switch goal {
        case .race(let distance):
            if let lim = snapshot.eventReadiness.first(where: { $0.event == distance })?.limitingFactor {
                focus = "Sharpen your \(distance.rawValue): your main limiter right now is \(lim.label)."
            } else {
                focus = "Build race-specific fitness for your \(distance.rawValue) with focused, race-like work."
            }
            steps = [
                "Do one quality session at your goal \(distance.rawValue) effort.",
                "Surround it with easy aerobic mileage to build endurance.",
                "Keep at least one full rest day so the hard work sticks."
            ]
        case .generic(let g):
            switch g {
            case .getFitter:
                focus = "Grow your aerobic engine with consistent, mostly-easy training."
                steps = [
                    "Get in 3–4 easy sessions where you can hold a conversation.",
                    "Add one harder session — intervals or a steady tempo effort.",
                    "Take one full rest day to absorb the work."
                ]
            case .loseWeight:
                focus = "Pair steady aerobic volume with a small, sustainable calorie deficit."
                steps = [
                    "Bank 3–4 easy aerobic sessions — fat burns best at easy effort.",
                    "Add daily movement and hit a step target you can repeat.",
                    "Protect protein and sleep so you lose fat, not muscle."
                ]
            case .buildMuscle:
                focus = "Progressive strength work with enough fuel and recovery to grow."
                steps = [
                    "Strength train 3 times, nudging load or reps up a little.",
                    "Eat enough protein across the day to repair and build muscle.",
                    "Keep cardio short and easy so it doesn't blunt recovery."
                ]
            case .raiseAthleteLevel:
                if let weak = weakest {
                    focus = "Your Athlete Level climbs fastest when you target your weakest system: \(weak)."
                    steps = [
                        "Give your \(weak) focused, specific work this week.",
                        "Keep your stronger systems ticking over with easy maintenance.",
                        "Sleep and recover well — you adapt on the rest days."
                    ]
                } else {
                    focus = "Train every system consistently and let recovery turn the work into gains."
                    steps = [
                        "Mix easy aerobic work with one or two quality sessions.",
                        "Add a short strength session to round out your fitness.",
                        "Guard your sleep and rest days so you actually adapt."
                    ]
                }
            case .sleepBetter:
                focus = "Build a steady sleep routine to lift recovery and daily readiness."
                steps = [
                    "Set a fixed bedtime and wake time — even on weekends.",
                    "Wind down screen-free for 30 minutes before bed.",
                    "Keep evening training easy so your system can settle."
                ]
            }
        }

        // If recovery is the priority, lead with it (and keep three steps).
        if needsRecovery {
            steps.insert("Make recovery the priority right now: easy days, solid sleep, and light movement until your readiness climbs.", at: 0)
            steps = Array(steps.prefix(3))
        }

        // Encouraging closer.
        let encouragement: String
        if needsRecovery {
            encouragement = "Rest is training too — be patient and you'll come back stronger."
        } else if readiness.value >= 65 {
            encouragement = "You've earned this fitness. Go enjoy the work."
        } else {
            encouragement = "Small, consistent steps compound. Keep showing up."
        }

        return RuleBasedGuidance(headline: headline,
                                 weeklyFocus: focus,
                                 steps: steps,
                                 encouragement: encouragement)
    }

    /// Natural phrasing of the goal for the fallback headline.
    private static func goalPhrase(_ goal: Goal) -> String {
        switch goal {
        case .race(let d): return "your \(d.rawValue)"
        case .generic(let g):
            switch g {
            case .getFitter:         return "getting fitter"
            case .loseWeight:        return "losing weight"
            case .buildMuscle:       return "building muscle"
            case .raiseAthleteLevel: return "a higher Athlete Level"
            case .sleepBetter:       return "better sleep and recovery"
            }
        }
    }
}

// MARK: - iOS 26 on-device generation

/// The structured plan the model fills in. `@Generable` returns a typed,
/// validated value; each `@Guide` steers one field.
@available(iOS 26.0, *)
@Generable
struct GoalPlanBriefing {
    @Guide(description: "A warm, motivating one-sentence summary of where the athlete stands relative to their goal, in the second person. No numbers.")
    var headline: String

    @Guide(description: "One or two sentences naming the single most important focus for this week to move toward the goal, grounded in the data provided.")
    var weeklyFocus: String

    @Guide(description: "Three short, concrete, actionable steps to take this week toward the goal. Each step is one imperative sentence under 15 words.")
    var steps: [String]

    @Guide(description: "One short encouraging closing line. No medical claims.")
    var encouragement: String
}

@available(iOS 26.0, *)
extension GoalCoach {
    /// Generate the plan on-device. Throws if the model fails or is busy.
    static func plan(goal: Goal,
                     readiness: ReadinessScore,
                     snapshot: AdaptiveIntelligenceSnapshot) async throws -> GoalPlanBriefing {
        let session = LanguageModelSession(instructions: """
        You are OptiTrain's personal endurance and fitness coach. The athlete has \
        chosen a goal. Using only the data provided, write a short, encouraging, \
        practical plan that moves them toward that goal. Be specific and human, \
        like a good coach who knows the athlete. Never invent numbers, paces, or \
        times. Avoid medical claims and diagnoses. Keep every part concise.
        """)

        let prompt = """
        Here is the athlete's goal and today's data:
        \(dataBlock(goal: goal, readiness: readiness, snapshot: snapshot))

        Write this week's plan toward the goal.
        """

        let response = try await session.respond(to: prompt, generating: GoalPlanBriefing.self)
        return response.content
    }
}
