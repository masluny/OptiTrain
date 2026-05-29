import Foundation

/// Single snapshot of every engine output for a given moment. Held by the
/// orchestrator; consumed by the UI. Immutable value type.
struct AdaptiveIntelligenceSnapshot: Equatable, Sendable {
    let computedAt: Date
    let scoreDate: Date
    let usingPreviousDay: Bool

    // Existing v0 readiness — kept for backward compatibility with TodayView.
    let readiness: ReadinessScore

    // New v1 engine outputs.
    let load: TrainingLoadEngine.Snapshot?
    let recoveryDebt: RecoveryDebtModel.Snapshot?
    let autonomicStability: AutonomicStability.Snapshot?
    let vo2maxTrajectory: VO2maxTrajectory.Snapshot?
    let aerobicEfficiency: AerobicEfficiency.Snapshot?
    let racePredictions: [RaceTimePrediction.Prediction]
    let eventReadiness: [EventReadinessEngine.Readiness]
    let physiologyProfile: PhysiologyProfile
    let bodyEfficiency: BodyEfficiency.Snapshot
    let plateau: PlateauDetector.Snapshot?
    let injuryRisk: InjuryAndBurnoutRisk.Snapshot
    let sleepIntelligence: SleepIntelligence.Snapshot?
    let responseProfile: ResponseProfile.Snapshot

    let features: [String: Double]
}
