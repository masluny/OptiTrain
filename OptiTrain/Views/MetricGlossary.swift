import SwiftUI

/// A plain-language explainer for the numbers on an intelligence card. Tapping a
/// card presents one of these as a sheet: each metric gets what it *is*, how to
/// *read* it, and — where useful — the athlete's current value called out, so the
/// glossary is grounded in their own data rather than a generic textbook.
struct MetricGlossary {
    let title: String
    let systemImage: String
    let intro: String
    let entries: [Entry]

    struct Entry: Identifiable {
        let id = UUID()
        let term: String
        let current: String?      // e.g. "Now: 42" — the athlete's live value, optional
        let meaning: String       // what it is, in one or two sentences
        let howToRead: String     // ranges / what good vs. bad looks like (or how to improve)
        var howToReadSymbol: String = "ruler"   // icon for the howToRead line
    }
}

struct MetricGlossarySheet: View {
    let glossary: MetricGlossary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(glossary.intro)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(glossary.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.term).font(.headline)
                                Spacer()
                                if let current = entry.current {
                                    Text(current)
                                        .font(.subheadline.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            Text(entry.meaning)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Label(entry.howToRead, systemImage: entry.howToReadSymbol)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding()
            }
            .scrollIndicators(.hidden)
            .navigationTitle(glossary.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Card-specific glossaries (grounded in the live snapshot)

extension MetricGlossary {

    /// Explains the Training Readiness sub-scores, grounded in today's values.
    /// When `focus` is set (the metric the athlete tapped), that entry is moved
    /// to the top so the sheet opens on what they asked about.
    static func readiness(_ score: ReadinessScore, focus: SubScore.Kind? = nil) -> MetricGlossary {
        var subs = score.subScores
        if let focus, let idx = subs.firstIndex(where: { $0.kind == focus }) {
            subs.insert(subs.remove(at: idx), at: 0)
        }

        var entries: [Entry] = subs.map { sub in
            // `sub.detail` ("7h 40m, solid", "Above baseline", etc.) used to
            // render below the breakdown bar; surface it here alongside the
            // sub-score so the sheet shows the full per-metric story.
            let current = sub.detail.isEmpty
                ? "\(Int(sub.value))/100"
                : "\(Int(sub.value))/100 · \(sub.detail)"
            return Entry(term: sub.kind.label,
                         current: current,
                         meaning: readinessMeaning(sub.kind),
                         howToRead: "\(readinessHowToRead(sub.kind)) Counts for about \(Int((sub.weight * 100).rounded()))% of today's score.")
        }

        if let acwr = score.acwr {
            entries.append(
                Entry(term: "ACWR (acute : chronic)",
                      current: String(format: "%.2f", acwr),
                      meaning: "The ratio of your recent (acute, ~7-day) training load to your habitual (chronic, ~28-day) load. It's a quick read on how fast your workload is changing.",
                      howToRead: "Roughly 0.8–1.3 is the sustainable range. Well above ~1.3 means you're ramping up fast (higher injury risk); well below ~0.8 means you're detraining.")
            )
        }

        // When opened from the gauge itself (no specific metric tapped), lead
        // with an overview of the headline number, the *verdict* (the one-line
        // "held back by HRV"-style read — moved here from the card body to keep
        // the Today page clean), and what each band means.
        if focus == nil {
            entries.insert(
                Entry(term: "Today's score",
                      current: "\(score.value) · \(score.band.label)",
                      meaning: "\(score.headline) Training Readiness is a single 0–100 score for how prepared your body is to train hard today — a weighted blend of the signals below.",
                      howToRead: "85+ Prime · 70–84 Ready · 55–69 Moderate · 40–54 Low · under 40 Depleted. Higher means you can push hard; lower means favour easy training and recovery."),
                at: 0)
        }

        return MetricGlossary(
            title: "Training Readiness",
            systemImage: "gauge.with.dots.needle.67percent",
            intro: "Your Training Readiness blends these signals into a single 0–100 score for how prepared your body is to train hard today. Here's what each one measures and how to read it — with today's value.",
            entries: entries
        )
    }

    private static func readinessMeaning(_ kind: SubScore.Kind) -> String {
        switch kind {
        case .sleep:
            "How much and how well you slept last night, scored against what your body needs. Sleep is when most physical recovery and adaptation actually happen."
        case .hrv:
            "Heart-rate variability — the beat-to-beat variation in your overnight heart rate. It reflects how recovered and balanced your nervous system is."
        case .restingHeartRate:
            "Your overnight resting heart rate. A low, stable RHR is the signature of a well-recovered, aerobically fit heart."
        case .load:
            "How today's recent training load sits against your habitual load. It scores whether your current training stress is sustainable."
        case .wristTemperature:
            "How far your overnight wrist temperature sat from your personal baseline. Deviations can flag illness, poor recovery, alcohol, or menstrual-cycle effects."
        }
    }

    private static func readinessHowToRead(_ kind: SubScore.Kind) -> String {
        switch kind {
        case .sleep:
            "Higher is better. Consistent, unbroken nights of around 7.5h+ keep this high; short or fragmented sleep pulls it down."
        case .hrv:
            "Higher is better, judged against your own baseline rather than absolute numbers. A clear drop often means fatigue, stress, or oncoming illness."
        case .restingHeartRate:
            "Lower is better, relative to your baseline. An elevated RHR usually means accumulated fatigue, stress, or that you're fighting something off."
        case .load:
            "Balanced is best. Both doing too little (detraining) and spiking volume too fast (overload) lower this."
        case .wristTemperature:
            "Balanced — near your baseline — is best. A notable rise or fall is an early nudge that something is off."
        }
    }

    /// Explains the four physiological systems behind Athlete Level — what each
    /// one is and the training that moves it — grounded in the athlete's current
    /// per-system scores. Listed head → legs to match the body figure.
    static func systems(_ snapshot: BodyEfficiency.Snapshot) -> MetricGlossary {
        let entries: [Entry] = snapshot.systems.map { system in
            Entry(term: system.kind.rawValue,
                  current: "\(Int(system.score.rounded()))/100",
                  meaning: systemMeaning(system.kind),
                  howToRead: systemTraining(system.kind),
                  howToReadSymbol: "figure.strengthtraining.traditional")
        }
        return MetricGlossary(
            title: "The four systems",
            systemImage: "figure.stand",
            intro: "Your Athlete Level reads long-term athleticism: how much fitness you've built across months of training, not how you feel today. Four components, each tied to a region of the body.",
            entries: entries
        )
    }

    private static func systemMeaning(_ kind: BodyEfficiency.System.Kind) -> String {
        switch kind {
        case .aerobic:
            "Your aerobic ceiling — how much oxygen the cardiovascular system can deliver and the working muscles can use (VO₂max). The single most predictive marker of long-term endurance fitness."
        case .endurance:
            "The durable training foundation you've built: weekly volume your body tolerates, plus a 90-day base of long-effort durability. Body composition nudges the headline up or down at the end."
        case .locomotion:
            "Demonstrated performance output — how fast you can sustain effort (lactate-threshold proxy), how well pace holds late in long runs (fatigue resistance), and how much of your training actually matches your event (specificity)."
        case .recovery:
            "Long-term cardiac adaptation — where your overnight HRV typically sits relative to your own personal baseline. Adapts slowly across weeks of consistent training and rest. Today's HRV alone doesn't move it."
        }
    }

    private static func systemTraining(_ kind: BodyEfficiency.System.Kind) -> String {
        switch kind {
        case .aerobic:
            "Build the engine with consistent easy aerobic volume (Zone 2). Layer in weekly threshold work and short VO₂max intervals (3–5 min hard) once the base is stable. The biggest gains come from years of consistency, not weeks."
        case .endurance:
            "Raise weekly volume gradually — about 10% per week, then a rest week every 3–4. Lengthen the long run progressively, add back-to-back long days, and keep BMI in a healthy/athletic range to round out the body-composition factor."
        case .locomotion:
            "Threshold runs (20–40 min comfortably hard), tempo intervals, and event-specific reps at goal pace. Strength + hills for fatigue resistance. Keep most weekly volume in the discipline you race to lift specificity."
        case .recovery:
            "Stack the basics: consistent sleep and wake times, 7+ hours most nights, well-spaced hard sessions, and life-stress management. HRV-baseline shifts up across months, not days — patience matters."
        }
    }

    static func trainingLoad(_ s: TrainingLoadEngine.Snapshot) -> MetricGlossary {
        MetricGlossary(
            title: "Training load",
            systemImage: "chart.line.uptrend.xyaxis.circle.fill",
            // Leads with today's verdict (moved here from under the Stat row on
            // the card), then the model behind the three numbers.
            intro: "\(s.risk.headline)\n\nEvery workout is scored for how much stress it put on your body (its TRIMP). These three numbers track that stress over different timescales — the classic Fitness / Fatigue / Form model used by TrainingPeaks and most coaches.",
            entries: [
                .init(term: "Fitness (CTL)",
                      current: String(format: "Now: %.0f", s.ctl),
                      meaning: "Your accumulated fitness — a 42-day weighted average of daily training stress. It rises slowly as you stack consistent weeks and fades just as slowly when you stop.",
                      howToRead: "Higher is fitter. What matters is the trend: a steady climb means you're building, a fall means you're detraining."),
                .init(term: "Fatigue (ATL)",
                      current: String(format: "Now: %.0f", s.atl),
                      meaning: "Your short-term tiredness — a 7-day weighted average of training stress. It spikes the day after a hard session and clears within a few easy days.",
                      howToRead: "High isn't bad on its own — it's the cost of training hard. It only matters relative to your fitness (see Form)."),
                .init(term: "Form (TSB)",
                      current: String(format: "Now: %+.0f", s.tsb),
                      meaning: "Fitness minus Fatigue — how fresh you are right now. Positive means you've absorbed your training and are rested; negative means fatigue is currently outweighing fitness.",
                      howToRead: "Roughly: +5 to +25 = tapered and race-ready · −10 to +5 = normal training · below −20 = deeply fatigued, back off. Deep training blocks are supposed to run negative.")
            ]
        )
    }

    static func recoveryDebt(_ s: RecoveryDebtModel.Snapshot) -> MetricGlossary {
        MetricGlossary(
            title: "Recovery debt",
            systemImage: "battery.50percent",
            intro: "The running gap between the recovery your body needed and the recovery it actually got. Think of it like sleep debt, but for total physiological stress — it accumulates when hard days aren't matched by real rest.",
            entries: [
                .init(term: "7-day debt",
                      current: "Now: \(Int(s.sevenDay.debtPercent))%",
                      meaning: "How much recovery you're behind on across the last week. The most reactive window — it jumps after a hard block and clears quickly with rest.",
                      howToRead: "0–20% green · 20–45% moderate · 45–65% high · 65%+ you're digging a hole."),
                .init(term: "14-day debt",
                      current: "Now: \(Int(s.fourteenDay.debtPercent))%",
                      meaning: "The same idea over two weeks — the best horizon for judging genuine race readiness, since it smooths out single bad nights.",
                      howToRead: "Lower is better. This is the number to watch before a goal event."),
                .init(term: "30-day debt",
                      current: "Now: \(Int(s.thirtyDay.debtPercent))%",
                      meaning: "Your long-term recovery balance. Slow to move; a persistently high value points to chronic under-recovery.",
                      howToRead: "If this stays elevated for weeks, your training load is structurally too high for your recovery."),
                .init(term: "Time to clear",
                      current: String(format: "%.1f days", s.fourteenDay.estimatedRecoveryDays),
                      meaning: "Estimated days of easy living needed to bring your 14-day debt back to baseline. Currently classed as “\(s.fourteenDay.stressClass.rawValue.capitalized)”.",
                      howToRead: "A rough planning number, not a countdown — sleep and easy days shrink it, hard days grow it.")
            ]
        )
    }

    static func autonomic(_ s: AutonomicStability.Snapshot) -> MetricGlossary {
        MetricGlossary(
            title: "Autonomic stability",
            systemImage: "waveform.path.ecg",
            intro: "Your autonomic nervous system controls the “rest-and-digest” vs. “fight-or-flight” balance. We read its steadiness from night-to-night heart-rate variability (HRV), resting heart rate and respiratory rate. A steady system is an adapted, healthy one.",
            entries: [
                .init(term: "Stability score",
                      current: "Now: \(Int(s.stabilityScore))",
                      meaning: "How consistent your overnight HRV and resting HR have been, scored 0–100. High means your nervous system is balanced and absorbing training well.",
                      howToRead: "80+ excellent · 60–80 solid · 40–60 unsettled · under 40 your system is being knocked around (stress, illness, or overload)."),
                .init(term: "Illness signal",
                      current: s.illnessRiskSignal.label,
                      meaning: "A flag that fires when HRV drops while resting HR and breathing rate rise together — the autonomic pattern that often shows up a day or two before you feel sick.",
                      howToRead: "Quiet → Watch → Elevated → Alarming. Anything past “Quiet” is a cue to add rest and watch for symptoms."),
                .init(term: "Overreach signal",
                      current: s.overtrainingSignal.label,
                      meaning: "A flag for training outrunning recovery — a sustained HRV suppression that suggests you're tipping from productive overload into non-functional overreaching.",
                      howToRead: "Quiet is the goal. Elevated or Alarming means pull back the load before it becomes overtraining.")
            ]
        )
    }

    static func injuryRisk(_ s: InjuryAndBurnoutRisk.Snapshot) -> MetricGlossary {
        MetricGlossary(
            title: "Risk panel",
            systemImage: "shield.lefthalf.filled.badge.checkmark",
            // Leads with today's recommendation (moved here from below the
            // three percentages on the card), then what the percentages mean.
            intro: "\(s.recommendation)\n\nThree forward-looking risk estimates, each a probability from 0–100%. They blend your training load, how fast it's ramping, and your recovery signals to flag where you're most exposed.",
            entries: [
                .init(term: "Soft tissue",
                      current: "Now: \(Int(s.softTissueRisk * 100))%",
                      meaning: "Risk of an overuse injury to tendons, muscles or bone. Driven mainly by how fast you're ramping volume — your acute (recent) load versus your chronic (habitual) load.",
                      howToRead: "Under 30% green · 30–50% caution · 50–75% high · 75%+ danger. Ramping mileage more than ~10%/week is the classic trigger."),
                .init(term: "Overreaching",
                      current: "Now: \(Int(s.overreachingRisk * 100))%",
                      meaning: "Risk that your current training is outpacing recovery — accumulated fatigue without enough easy days to absorb it.",
                      howToRead: "Lower is better. Rising values mean schedule a down week before performance and mood start to slide."),
                .init(term: "Burnout",
                      current: "Now: \(Int(s.burnoutRisk * 100))%",
                      meaning: "Risk of psychophysiological staleness — the deeper, slower-building combination of chronic high load, poor recovery and a suppressed nervous system.",
                      howToRead: "This should normally sit low. A sustained climb is the strongest signal to take real rest, not just an easy day.")
            ]
        )
    }
}
