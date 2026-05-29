import Foundation

/// Soft-tissue / overreaching / burnout risk estimation. Three independent
/// risk axes that combine into an actionable summary. Not predictive of any
/// specific injury — predicts the *conditions* under which injury and
/// burnout become substantially more likely (Gabbett / Jones 2017).
struct InjuryAndBurnoutRisk: Sendable {

    struct Snapshot: Equatable, Sendable {
        let softTissueRisk: Double         // 0...1
        let overreachingRisk: Double       // 0...1
        let burnoutRisk: Double            // 0...1
        let adherenceCollapseRisk: Double  // 0...1
        let topSignals: [String]
        let recommendation: String
        let confidence: Confidence
    }

    init() {}

    func snapshot(load: TrainingLoadEngine.Snapshot?,
                         debt: RecoveryDebtModel.Snapshot?,
                         stability: AutonomicStability.Snapshot?,
                         recentWorkouts: [WorkoutSummary]) -> Snapshot {
        var signals: [String] = []

        // Soft-tissue: load spike + monotony + ACWR. ACWR is intentionally a
        // minor, descriptive contributor here — it is mathematically coupled and
        // the 0.8–1.3 "sweet spot" lacks causal evidence (Impellizzeri 2020,
        // Wang 2020), so the more direct signals (an acute week far above chronic
        // load, and Foster monotony) carry the weight instead.
        let soft: Double = {
            var score = 0.0
            if (load?.weeklyLoad ?? 0) > (load?.ctl ?? 0) * 1.5 { score += 0.30; signals.append("Weekly load >1.5× chronic") }
            if let m = load?.monotony, m > 2.0 { score += 0.25; signals.append("Foster monotony \(String(format: "%.2f", m))") }
            if let a = load?.acwrRolling {
                if a > 1.5 { score += 0.25; signals.append("ACWR \(String(format: "%.2f", a)) (>1.5)") }
                else if a > 1.3 { score += 0.12 }
                else if a < 0.5 { score += 0.10 }
            }
            return min(1, score)
        }()

        // Overreaching: deep negative TSB + autonomic suppression.
        let over: Double = {
            var score = 0.0
            if (load?.tsb ?? 0) < -25 { score += 0.35; signals.append("TSB \(Int(load!.tsb)) — heavy fatigue") }
            if stability?.overtrainingSignal == .alarming { score += 0.40; signals.append("HRV trending down sharply") }
            if stability?.overtrainingSignal == .elevated { score += 0.20 }
            if (debt?.fourteenDay.debtPercent ?? 0) > 55 { score += 0.25 }
            return min(1, score)
        }()

        // Burnout: persistent negative outlook — sustained long-window recovery debt.
        let burnout: Double = {
            var score = 0.0
            if (debt?.thirtyDay.debtPercent ?? 0) > 50 { score += 0.35; signals.append("30-day recovery debt high") }
            return min(1, score)
        }()

        // Adherence collapse: gaps in training in last 14 days.
        let adherence: Double = {
            let cutoff = Date().addingTimeInterval(-14 * 86_400)
            let recent = recentWorkouts.filter { $0.start >= cutoff }
            let days = Set(recent.map { Calendar.current.startOfDay(for: $0.start) }).count
            // <3 active days / 14 = high risk of falling off.
            return max(0, min(1, 1.0 - Double(days) / 6.0))
        }()

        let recommendation: String = {
            if soft > 0.6 || over > 0.6 { return "Pull back this week. Replace one hard session with mobility or full rest." }
            if burnout > 0.5 { return "Schedule a true rest day in the next 48h. Sleep + low-intensity outdoor time." }
            if adherence > 0.5 { return "Consistency is slipping — try shorter, easier sessions to rebuild the habit." }
            return "Indicators look healthy. Train as planned."
        }()

        let confidence = Confidence.combine([
            Confidence(load == nil ? 0.3 : 0.85),
            Confidence(debt == nil ? 0.4 : 0.85),
            Confidence(stability == nil ? 0.4 : 0.85)
        ])

        return Snapshot(
            softTissueRisk: soft,
            overreachingRisk: over,
            burnoutRisk: burnout,
            adherenceCollapseRisk: adherence,
            topSignals: signals,
            recommendation: recommendation,
            confidence: confidence
        )
    }
}
