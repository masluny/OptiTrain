import Foundation

/// Per-event component weights. Each row sums to 1.0 by construction.
/// These weights are deliberately exposed: they're product/coaching opinions,
/// not magic, and an athlete (or a future personalization layer) can override
/// them. Numeric values are derived from elite-coaching consensus:
///   • 5K leans hard on VO₂max + anaerobic capacity
///   • Half/Marathon shifts weight to threshold + durability
///   • 70.3 / Ironman dominate by durability + fueling + heat
///   • Triathlons add modality specificity and fatigue resistance
enum EventWeightingMatrix {

    struct Weights: Equatable, Sendable {
        let vo2max: Double
        let threshold: Double
        let anaerobic: Double
        let durability: Double
        let fueling: Double
        let heat: Double
        let recoveryResilience: Double
        let sleepConsistency: Double
        let volumeTolerance: Double
        let fatigueResistance: Double
        let specificity: Double
        let freshness: Double

        var sum: Double {
            vo2max + threshold + anaerobic + durability + fueling + heat +
            recoveryResilience + sleepConsistency + volumeTolerance +
            fatigueResistance + specificity + freshness
        }

        func apply(to p: PhysiologyProfile) -> Double {
            let raw = vo2max*p.vo2maxScore + threshold*p.thresholdScore +
                anaerobic*p.anaerobicCapacityScore + durability*p.durabilityScore +
                fueling*p.fuelingScore + heat*p.heatScore +
                recoveryResilience*p.recoveryResilienceScore +
                sleepConsistency*p.sleepConsistencyScore +
                volumeTolerance*p.volumeToleranceScore +
                fatigueResistance*p.fatigueResistanceScore +
                specificity*p.specificityScore + freshness*p.freshnessScore
            return raw / max(sum, 0.0001)
        }
    }

    static func weights(for event: RaceTimePrediction.RaceDistance) -> Weights {
        switch event {
        case .mile:
            return Weights(vo2max: 0.28, threshold: 0.12, anaerobic: 0.28,
                           durability: 0.00, fueling: 0.00, heat: 0.01,
                           recoveryResilience: 0.05, sleepConsistency: 0.03,
                           volumeTolerance: 0.03, fatigueResistance: 0.03,
                           specificity: 0.12, freshness: 0.05)
        case .fiveK:
            return Weights(vo2max: 0.30, threshold: 0.20, anaerobic: 0.15,
                           durability: 0.02, fueling: 0.00, heat: 0.01,
                           recoveryResilience: 0.05, sleepConsistency: 0.03,
                           volumeTolerance: 0.04, fatigueResistance: 0.05,
                           specificity: 0.10, freshness: 0.05)
        case .tenK:
            return Weights(vo2max: 0.25, threshold: 0.28, anaerobic: 0.08,
                           durability: 0.04, fueling: 0.01, heat: 0.02,
                           recoveryResilience: 0.05, sleepConsistency: 0.03,
                           volumeTolerance: 0.05, fatigueResistance: 0.06,
                           specificity: 0.10, freshness: 0.03)
        case .halfMarathon:
            return Weights(vo2max: 0.14, threshold: 0.28, anaerobic: 0.02,
                           durability: 0.15, fueling: 0.03, heat: 0.03,
                           recoveryResilience: 0.05, sleepConsistency: 0.04,
                           volumeTolerance: 0.08, fatigueResistance: 0.08,
                           specificity: 0.07, freshness: 0.03)
        case .marathon:
            return Weights(vo2max: 0.08, threshold: 0.18, anaerobic: 0.00,
                           durability: 0.25, fueling: 0.10, heat: 0.05,
                           recoveryResilience: 0.05, sleepConsistency: 0.04,
                           volumeTolerance: 0.10, fatigueResistance: 0.10,
                           specificity: 0.03, freshness: 0.02)
        case .fiftyKUltra:
            return Weights(vo2max: 0.03, threshold: 0.08, anaerobic: 0.00,
                           durability: 0.28, fueling: 0.15, heat: 0.06,
                           recoveryResilience: 0.06, sleepConsistency: 0.05,
                           volumeTolerance: 0.12, fatigueResistance: 0.12,
                           specificity: 0.03, freshness: 0.02)
        case .fortyKTT:
            return Weights(vo2max: 0.18, threshold: 0.30, anaerobic: 0.05,
                           durability: 0.06, fueling: 0.02, heat: 0.03,
                           recoveryResilience: 0.05, sleepConsistency: 0.03,
                           volumeTolerance: 0.05, fatigueResistance: 0.06,
                           specificity: 0.15, freshness: 0.02)
        case .granFondo:
            return Weights(vo2max: 0.06, threshold: 0.16, anaerobic: 0.00,
                           durability: 0.22, fueling: 0.10, heat: 0.06,
                           recoveryResilience: 0.05, sleepConsistency: 0.04,
                           volumeTolerance: 0.10, fatigueResistance: 0.09,
                           specificity: 0.10, freshness: 0.02)
        case .century:
            return Weights(vo2max: 0.04, threshold: 0.12, anaerobic: 0.00,
                           durability: 0.26, fueling: 0.14, heat: 0.07,
                           recoveryResilience: 0.06, sleepConsistency: 0.05,
                           volumeTolerance: 0.11, fatigueResistance: 0.08,
                           specificity: 0.05, freshness: 0.02)
        case .sprintTri:
            return Weights(vo2max: 0.20, threshold: 0.20, anaerobic: 0.10,
                           durability: 0.05, fueling: 0.00, heat: 0.02,
                           recoveryResilience: 0.05, sleepConsistency: 0.03,
                           volumeTolerance: 0.05, fatigueResistance: 0.05,
                           specificity: 0.20, freshness: 0.05)
        case .olympicTri:
            return Weights(vo2max: 0.14, threshold: 0.25, anaerobic: 0.04,
                           durability: 0.12, fueling: 0.03, heat: 0.04,
                           recoveryResilience: 0.05, sleepConsistency: 0.03,
                           volumeTolerance: 0.06, fatigueResistance: 0.06,
                           specificity: 0.15, freshness: 0.03)
        case .seventyThree:
            return Weights(vo2max: 0.07, threshold: 0.17, anaerobic: 0.00,
                           durability: 0.22, fueling: 0.12, heat: 0.07,
                           recoveryResilience: 0.05, sleepConsistency: 0.04,
                           volumeTolerance: 0.09, fatigueResistance: 0.09,
                           specificity: 0.06, freshness: 0.02)
        case .ironman:
            return Weights(vo2max: 0.04, threshold: 0.10, anaerobic: 0.00,
                           durability: 0.28, fueling: 0.18, heat: 0.10,
                           recoveryResilience: 0.06, sleepConsistency: 0.05,
                           volumeTolerance: 0.10, fatigueResistance: 0.06,
                           specificity: 0.02, freshness: 0.01)
        case .sprintDuathlon:
            return Weights(vo2max: 0.20, threshold: 0.22, anaerobic: 0.08,
                           durability: 0.05, fueling: 0.01, heat: 0.02,
                           recoveryResilience: 0.05, sleepConsistency: 0.03,
                           volumeTolerance: 0.05, fatigueResistance: 0.07,
                           specificity: 0.17, freshness: 0.05)
        case .standardDuathlon:
            return Weights(vo2max: 0.13, threshold: 0.24, anaerobic: 0.03,
                           durability: 0.13, fueling: 0.03, heat: 0.04,
                           recoveryResilience: 0.05, sleepConsistency: 0.04,
                           volumeTolerance: 0.07, fatigueResistance: 0.08,
                           specificity: 0.13, freshness: 0.03)
        case .sprintBiathlon:
            return Weights(vo2max: 0.22, threshold: 0.22, anaerobic: 0.08,
                           durability: 0.04, fueling: 0.00, heat: 0.02,
                           recoveryResilience: 0.05, sleepConsistency: 0.03,
                           volumeTolerance: 0.04, fatigueResistance: 0.05,
                           specificity: 0.20, freshness: 0.05)
        case .standardBiathlon:
            return Weights(vo2max: 0.15, threshold: 0.26, anaerobic: 0.03,
                           durability: 0.10, fueling: 0.02, heat: 0.04,
                           recoveryResilience: 0.05, sleepConsistency: 0.04,
                           volumeTolerance: 0.06, fatigueResistance: 0.07,
                           specificity: 0.15, freshness: 0.03)
        }
    }
}
