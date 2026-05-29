import Foundation

/// The physiological "components" that any race readiness score weighs.
/// Each component is a 0-100 score derived from the user's data, and each
/// race weights them differently in `EventWeightingMatrix`.
struct PhysiologyProfile: Equatable, Sendable {
    let vo2maxScore: Double          // current vs goal-time-required
    let thresholdScore: Double       // lactate threshold proxy via tempo efforts
    let anaerobicCapacityScore: Double
    let durabilityScore: Double      // long-effort tolerance
    let fuelingScore: Double         // hours of time-on-feet history
    let heatScore: Double            // exposure (placeholder until env data)
    let recoveryResilienceScore: Double   // inverse of recovery debt
    let sleepConsistencyScore: Double
    let volumeToleranceScore: Double // current weekly km vs event need
    let fatigueResistanceScore: Double // 1 − pace-HR decoupling
    let specificityScore: Double     // recent training that matches event modality
    let freshnessScore: Double       // TSB-based
    let autonomicScore: Double       // durable HRV+RHR steadiness (recovery backbone)
    let sleepQualityScore: Double    // habitual nightly sleep quality (~14d mean)

    init(vo2maxScore: Double, thresholdScore: Double, anaerobicCapacityScore: Double,
                durabilityScore: Double, fuelingScore: Double, heatScore: Double,
                recoveryResilienceScore: Double, sleepConsistencyScore: Double,
                volumeToleranceScore: Double, fatigueResistanceScore: Double,
                specificityScore: Double, freshnessScore: Double,
                autonomicScore: Double = 50, sleepQualityScore: Double = 50) {
        self.vo2maxScore = vo2maxScore
        self.thresholdScore = thresholdScore
        self.anaerobicCapacityScore = anaerobicCapacityScore
        self.durabilityScore = durabilityScore
        self.fuelingScore = fuelingScore
        self.heatScore = heatScore
        self.recoveryResilienceScore = recoveryResilienceScore
        self.sleepConsistencyScore = sleepConsistencyScore
        self.volumeToleranceScore = volumeToleranceScore
        self.fatigueResistanceScore = fatigueResistanceScore
        self.specificityScore = specificityScore
        self.freshnessScore = freshnessScore
        self.autonomicScore = autonomicScore
        self.sleepQualityScore = sleepQualityScore
    }
}
