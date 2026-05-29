import Foundation

/// Training-response profile. Learns what *kind* of training the athlete
/// adapts to best by correlating session types against subsequent fitness
/// changes. v1 is a rule-based classifier on observable history; v2 will be
/// a CoreML personalized model fed by `FeatureExtractor`.
struct ResponseProfile: Sendable {

    enum Archetype: String, Sendable {
        case highVolumeResponder
        case intervalResponder
        case mixedResponder
        case recoverySensitive
        case lowDurability
        case undetermined
    }

    struct Snapshot: Equatable, Sendable {
        let archetype: Archetype
        let responseDelayDays: Int           // typical lag for adaptation to appear
        let notes: [String]
        let confidence: Confidence
    }

    init() {}

    func classify(workouts: [WorkoutSummary],
                         vo2Trajectory: VO2maxTrajectory.Snapshot?,
                         debt: RecoveryDebtModel.Snapshot?) -> Snapshot {
        let cutoff = Date().addingTimeInterval(-60 * 86_400)
        let recent = workouts.filter { $0.start >= cutoff && $0.kind == .run }
        guard recent.count >= 6, let slope = vo2Trajectory?.trendSlopePerWeek else {
            return Snapshot(archetype: .undetermined, responseDelayDays: 14,
                            notes: ["Not enough history to characterize response yet."],
                            confidence: Confidence(0.2))
        }

        let hardRuns = recent.filter { ($0.averageHeartRate ?? 0) >= 160 }.count
        let longRuns = recent.filter { ($0.distanceMeters ?? 0) >= 16_000 }.count
        let hardShare = Double(hardRuns) / Double(recent.count)
        let longShare = Double(longRuns) / Double(recent.count)
        let debtPct = debt?.thirtyDay.debtPercent ?? 0

        var notes: [String] = []
        let archetype: Archetype = {
            if debtPct > 45 && slope < 0 {
                notes.append("Adaptation stalls when recovery debt exceeds ~40%.")
                return .recoverySensitive
            }
            if hardShare > 0.35 && slope > 0.1 {
                notes.append("Fitness improves on high-quality (interval/tempo) weeks.")
                return .intervalResponder
            }
            if longShare > 0.25 && slope > 0.05 {
                notes.append("Long aerobic work is your strongest stimulus.")
                return .highVolumeResponder
            }
            if longShare < 0.05 && slope <= 0 {
                notes.append("Few long runs in history; likely durability-limited for >half-marathon.")
                return .lowDurability
            }
            return .mixedResponder
        }()

        // Typical adaptation delay: 7-14 days for fitness gains to register in VO₂max.
        return Snapshot(
            archetype: archetype,
            responseDelayDays: 10,
            notes: notes,
            confidence: Confidence.fromSampleDensity(present: recent.count, target: 20)
        )
    }
}
