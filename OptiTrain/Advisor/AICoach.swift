import Foundation
import FoundationModels

/// Wraps Apple's on-device Foundation Models LLM (iOS 26+) to turn the day's
/// numeric snapshot into a short, natural-language coaching briefing.
///
/// Everything runs on-device: no network, no API key, no token cost — and the
/// athlete's health data never leaves the phone, which is exactly why an
/// on-device model is the right call for a HealthKit app. The numeric engines
/// (TRIMP/CTL/VDOT/…) stay authoritative; the model is only ever asked to put
/// numbers we computed into words. It degrades gracefully: on hardware or OS
/// that can't run Apple Intelligence we return an `.unavailable` reason and the
/// UI falls back to the existing templated text.
enum AICoach {

    /// Why the on-device model can't be used right now.
    enum Unavailable: Equatable {
        case unsupportedOS          // device is on < iOS 26
        case deviceNotEligible      // hardware can't run Apple Intelligence
        case appleIntelligenceOff   // user hasn't enabled Apple Intelligence
        case modelNotReady          // model assets still downloading
        case unknown

        var message: String {
            switch self {
            case .unsupportedOS:        "On-device AI needs iOS 26 or later."
            case .deviceNotEligible:    "This device can't run Apple Intelligence."
            case .appleIntelligenceOff: "Turn on Apple Intelligence in Settings to get an AI briefing."
            case .modelNotReady:        "The on-device model is still downloading — try again shortly."
            case .unknown:              "On-device AI isn't available right now."
            }
        }
    }

    enum Availability: Equatable {
        case available
        case unavailable(Unavailable)
    }

    /// Safe to call on any OS version — it internally guards the iOS 26 API.
    static func availability() -> Availability {
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:           return .unavailable(.deviceNotEligible)
                case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceOff)
                case .modelNotReady:               return .unavailable(.modelNotReady)
                @unknown default:                  return .unavailable(.unknown)
                }
            }
        }
        return .unavailable(.unsupportedOS)
    }

    /// Compact, factual data block handed to the model. Pure Swift — no
    /// FoundationModels symbols — so it compiles regardless of OS.
    static func dataBlock(readiness: ReadinessScore,
                          snapshot: AdaptiveIntelligenceSnapshot,
                          plan: AdvisorPlan?,
                          goal: Goal? = nil) -> String {
        var lines: [String] = []
        if let goal {
            lines.append("Athlete's chosen goal: \(goal.title) — \(goal.subtitle)")
        } else {
            lines.append("No specific goal set — write general endurance-focused coaching.")
        }
        lines.append("Readiness: \(readiness.value)/100 (\(readiness.band.label)).")
        for s in readiness.subScores {
            lines.append("- \(s.kind.label): \(Int(s.value))/100 — \(s.detail)")
        }
        if let load = snapshot.load {
            lines.append("Training load — Fitness/CTL \(Int(load.ctl)), Fatigue/ATL \(Int(load.atl)), Form/TSB \(Int(load.tsb)).")
        }
        if let debt = snapshot.recoveryDebt {
            lines.append("Recovery debt (14-day): \(Int(debt.fourteenDay.debtPercent))% — \(debt.fourteenDay.stressClass.rawValue).")
        }
        if let aut = snapshot.autonomicStability {
            lines.append("Autonomic stability: \(Int(aut.stabilityScore))/100; illness signal \(aut.illnessRiskSignal.label), overreach signal \(aut.overtrainingSignal.label).")
        }
        let risk = snapshot.injuryRisk
        lines.append("Risk — soft-tissue \(Int(risk.softTissueRisk * 100))%, overreaching \(Int(risk.overreachingRisk * 100))%, burnout \(Int(risk.burnoutRisk * 100))%.")
        if let top = plan?.recommendations.first {
            lines.append("Plan's top suggested session today: \(top.modality.label).")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - iOS 26 on-device generation

/// The structured briefing we ask the model to fill in. `@Generable` makes the
/// model return a *typed, validated* value rather than a raw string we'd have to
/// parse, and each `@Guide` steers one field.
@available(iOS 26.0, *)
@Generable
struct CoachBriefing {
    @Guide(description: "A warm, motivating one-sentence summary of how the athlete is doing today, in the second person. No numbers.")
    var headline: String

    @Guide(description: "Two or three sentences of specific, practical coaching for today. Reference their recovery and training-load state in plain language. Encouraging, never alarming, no medical claims.")
    var guidance: String

    @Guide(description: "One short actionable focus for today, fewer than 12 words.")
    var focus: String
}

@available(iOS 26.0, *)
extension AICoach {
    /// Generate the briefing on-device. Throws if the model fails or is busy.
    /// When `goal` is set, the briefing is steered toward what that goal needs;
    /// when nil, the coach gives general endurance-focused advice.
    static func briefing(readiness: ReadinessScore,
                         snapshot: AdaptiveIntelligenceSnapshot,
                         plan: AdvisorPlan?,
                         goal: Goal? = nil) async throws -> CoachBriefing {
        let goalInstruction = goal.map {
            "The athlete is training for: \($0.title). Anchor the briefing on that goal — every piece of advice should move them toward it."
        } ?? "No specific goal is set — give general endurance-focused coaching."

        let session = LanguageModelSession(instructions: """
        You are OptiTrain's endurance running coach. You receive a runner's \
        readiness data for the day and write a brief, encouraging, practical \
        briefing. Be specific and human, like a good coach who knows the athlete. \
        Only use the numbers provided — never invent data, paces, or times. Avoid \
        medical claims and diagnoses. Keep it concise. \(goalInstruction)
        """)

        let prompt = """
        Here is today's data:
        \(dataBlock(readiness: readiness, snapshot: snapshot, plan: plan, goal: goal))

        Write today's briefing.
        """

        let response = try await session.respond(to: prompt, generating: CoachBriefing.self)
        return response.content
    }
}
