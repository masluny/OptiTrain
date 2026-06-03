import Foundation

struct ActivityAdvisor {
    struct Context {
        let readiness: ReadinessScore
        let recentWorkouts: [WorkoutSummary]   // last ~7 days, most recent last
        let consecutiveLowReadinessDays: Int   // count of trailing days with score < 55
        /// Athlete's chosen goal. nil → general advice.
        let goal: Goal?

        init(readiness: ReadinessScore,
             recentWorkouts: [WorkoutSummary],
             consecutiveLowReadinessDays: Int,
             goal: Goal? = nil) {
            self.readiness = readiness
            self.recentWorkouts = recentWorkouts
            self.consecutiveLowReadinessDays = consecutiveLowReadinessDays
            self.goal = goal
        }
    }

    func plan(for context: Context) -> AdvisorPlan {
        let caps = caps(for: context)
        var warnings: [String] = []

        if let acwr = context.readiness.acwr, acwr > 1.5 {
            warnings.append(String(format: "ACWR %.2f — acute load is well above your 28d baseline. Easy week.", acwr))
        }
        if context.consecutiveLowReadinessDays >= 3 {
            warnings.append("3+ consecutive low-readiness days. Take a full rest day or see a coach.")
        }
        if let limiter = context.readiness.subScores.min(by: { $0.value < $1.value }), limiter.value < 40 {
            warnings.append("\(limiter.kind.label) is the limiter today: \(limiter.detail)")
        }

        let yesterday = mostRecent(within: 1, in: context.recentWorkouts)
        let liftedRecently = recentlyDid(.lift, days: 1, in: context.recentWorkouts)
        let ranHardRecently = recentlyDidHardRun(in: context.recentWorkouts, days: 1)
        let longRunInLast7 = context.recentWorkouts.contains { $0.kind == .run && $0.duration >= 75 * 60 }

        var picks: [ActivityRecommendation] = []

        switch context.readiness.band {
        case .prime:
            // Big day. Alternate vs yesterday.
            if liftedRecently {
                picks.append(rec(.intervalRun, "6×3min @ 5K pace, 2min jog", 50, 8...9,
                                 "Prime readiness, you lifted yesterday — quality run is the right stress today.", 1))
                picks.append(rec(.accessoryLift, "Upper push + core, RPE 7", 45, 6...7,
                                 "Spare CNS capacity for accessory work without overlapping legs.", 2))
            } else if ranHardRecently {
                picks.append(rec(.heavyLift, "Lower-body strength, top set RPE 8-9", 60, 8...9,
                                 "Prime + ran hard yesterday → take the heavy lift opportunity.", 1))
                picks.append(rec(.easyRun, "30min Z2 shakeout", 30, 4...5,
                                 "Optional flush to keep aerobic frequency up.", 2))
            } else {
                picks.append(rec(.heavyLift, "Heavy compound day — squat or deadlift", 60, 8...9,
                                 "Readiness is prime and recent load is balanced. Spend the credit.", 1))
                picks.append(rec(.tempoRun, "20min tempo @ threshold + 10min easy", 40, 7...8,
                                 "Alternate: high-quality aerobic stimulus.", 2))
            }
            if !longRunInLast7 && Calendar.current.component(.weekday, from: context.readiness.date) == 1 {
                picks.append(rec(.longRun, "60-90min easy long run", 75, 5...6,
                                 "No long run in the last 7 days and it's Sunday — good time for one.", 3))
            }

        case .ready:
            if liftedRecently {
                picks.append(rec(.easyRun, "45min Z2 easy run", 45, 4...5,
                                 "Ready but you lifted yesterday — keep today aerobic.", 1))
                picks.append(rec(.mobility, "20min mobility + light core", 20, 3...4,
                                 "Stack a quality recovery block.", 2))
            } else {
                picks.append(rec(.heavyLift, "Moderate lift, top set RPE 7-8", 50, 7...8,
                                 "Ready but not prime — back off top-end intensity 1 notch.", 1))
                picks.append(rec(.tempoRun, "15min tempo + warmup/cooldown", 35, 6...7,
                                 "Alternate: controlled aerobic quality.", 2))
            }

        case .moderate:
            picks.append(rec(.easyRun, "30-40min Z2 easy run", 35, 4...5,
                             "Readiness is moderate. Aerobic work without taxing CNS keeps fitness ticking.", 1))
            picks.append(rec(.accessoryLift, "Accessory lift, RPE 6, no top sets", 35, 5...6,
                             "Skip the heavy day, do the rebuilding work.", 2))
            picks.append(rec(.walk, "30min outdoor walk", 30, 2...3,
                             "Safe default if you're underslept or unmotivated.", 3))

        case .low:
            picks.append(rec(.walk, "30-45min easy walk outdoors", 40, 2...3,
                             "Low readiness — active recovery beats nothing or hard training.", 1))
            picks.append(rec(.mobility, "20min mobility + breath work", 20, 1...2,
                             "Down-regulate the nervous system; prep tonight's sleep.", 2))

        case .depleted:
            picks.append(rec(.fullRest, "Full rest day", 0, 1...1,
                             "Readiness is depleted. Sleep, eat, hydrate. No training today.", 1))
            picks.append(rec(.walk, "Optional 15-20min flat walk", 20, 1...2,
                             "Only if you feel like it — gentle and short.", 2))
        }

        // Apply caps: trim anything above the RPE/duration ceiling.
        let capped = picks.map { rec -> ActivityRecommendation in
            guard caps.forbidHardWork == false || rec.modality == .fullRest || rec.modality == .walk || rec.modality == .mobility else {
                return ActivityRecommendation(
                    modality: .mobility,
                    title: "Mobility instead — hard work is blocked today",
                    durationMinutes: 20,
                    intensityRPE: 1...3,
                    rationale: "Caps from warnings forced a swap to recovery work.",
                    priority: rec.priority
                )
            }
            let trimmedRPE = min(rec.intensityRPE.upperBound, caps.maxRPE)
            let trimmedMinutes = min(rec.durationMinutes, caps.maxMinutes)
            if trimmedRPE == rec.intensityRPE.upperBound && trimmedMinutes == rec.durationMinutes {
                return rec
            }
            return ActivityRecommendation(
                modality: rec.modality,
                title: rec.title + " (capped)",
                durationMinutes: trimmedMinutes,
                intensityRPE: rec.intensityRPE.lowerBound...trimmedRPE,
                rationale: rec.rationale + " — capped to RPE \(trimmedRPE)/\(trimmedMinutes)min for safety.",
                priority: rec.priority
            )
        }

        // Goal-aware reordering and rationale anchoring. If the athlete picked
        // a race goal in Goal tab, recommendations tilt toward modalities that
        // serve that race; the top pick's rationale also leads with a one-line
        // goal anchor so the connection is visible. nil goal → no change.
        let goalShaped = applyGoalBias(to: capped, goal: context.goal)
            .sorted { $0.priority < $1.priority }

        return AdvisorPlan(
            date: context.readiness.date,
            recommendations: goalShaped,
            warnings: warnings,
            caps: caps
        )
    }

    /// Re-orders + lightly re-titles the picks based on the athlete's chosen
    /// goal. Doesn't replace recommendations (the band-based logic stays
    /// authoritative on intensity safety) — it just promotes the ones that
    /// best serve the goal and prepends a goal-anchor line to the top pick.
    private func applyGoalBias(to picks: [ActivityRecommendation], goal: Goal?) -> [ActivityRecommendation] {
        guard let goal else { return picks }
        let preferred = preferredModalities(for: goal)
        // Re-rank: any pick whose modality appears in `preferred` moves to
        // priority 1; everything else falls down. Ties broken by original
        // priority so the band-based ordering still matters for like picks.
        var ranked = picks.enumerated().map { idx, rec -> (ActivityRecommendation, Int) in
            let rank = preferred.firstIndex(of: rec.modality)
                ?? (preferred.count + idx)   // unpreferred picks keep their relative order after the preferred ones
            return (rec, rank)
        }
        ranked.sort { $0.1 < $1.1 }
        guard !ranked.isEmpty else { return picks }
        let goalLine = goalAnchorLine(for: goal)
        let reassigned = ranked.enumerated().map { newIdx, pair -> ActivityRecommendation in
            let (rec, _) = pair
            // Top pick gets the goal-anchor rationale prefix so the user sees
            // the connection. Lower picks keep their original rationale.
            let rationale = newIdx == 0 ? "\(goalLine) \(rec.rationale)" : rec.rationale
            return ActivityRecommendation(
                modality: rec.modality,
                title: rec.title,
                durationMinutes: rec.durationMinutes,
                intensityRPE: rec.intensityRPE,
                rationale: rationale,
                priority: newIdx + 1
            )
        }
        return reassigned
    }

    /// Which session modalities best serve each goal, listed in preference
    /// order. Distance races lean on long aerobic work; short fast races lean
    /// on VO₂max/threshold intensity; generic goals follow their stated focus.
    private func preferredModalities(for goal: Goal) -> [ActivityRecommendation.Modality] {
        switch goal {
        case .race(let event):
            switch event {
            case .mile, .fiveK:
                return [.intervalRun, .tempoRun, .easyRun, .heavyLift, .accessoryLift]
            case .tenK, .fortyKTT, .sprintTri, .sprintDuathlon, .sprintBiathlon:
                return [.tempoRun, .intervalRun, .easyRun, .heavyLift]
            case .halfMarathon, .olympicTri, .standardDuathlon, .standardBiathlon:
                return [.tempoRun, .longRun, .easyRun, .intervalRun]
            case .marathon, .seventyThree, .granFondo:
                return [.longRun, .easyRun, .tempoRun, .mobility]
            case .fiftyKUltra, .ironman, .century:
                return [.longRun, .easyRun, .walk, .mobility]
            }
        case .generic(let g):
            switch g {
            case .getFitter:         return [.tempoRun, .easyRun, .intervalRun, .heavyLift]
            case .loseWeight:        return [.easyRun, .walk, .tempoRun, .accessoryLift]
            case .buildMuscle:       return [.heavyLift, .accessoryLift, .easyRun]
            case .raiseAthleteLevel: return [.tempoRun, .longRun, .intervalRun, .heavyLift]
            case .sleepBetter:       return [.easyRun, .walk, .mobility]
            }
        }
    }

    /// One-line anchor prepended to the top recommendation's rationale so the
    /// user sees how the day's pick serves their goal.
    private func goalAnchorLine(for goal: Goal) -> String {
        "Toward your \(goal.title.lowercased()):"
    }

    // MARK: - Helpers

    private func caps(for context: Context) -> AdvisorPlan.Caps {
        let acwrHot = (context.readiness.acwr ?? 1) > 1.5
        let depleted = context.readiness.band == .depleted
        let lowStreak = context.consecutiveLowReadinessDays >= 3

        let forbid = depleted || lowStreak
        let maxRPE: Int
        let maxMinutes: Int
        switch context.readiness.band {
        case .prime: maxRPE = 10; maxMinutes = 90
        case .ready: maxRPE = 8; maxMinutes = 75
        case .moderate: maxRPE = 7; maxMinutes = 60
        case .low: maxRPE = 4; maxMinutes = 45
        case .depleted: maxRPE = 2; maxMinutes = 20
        }
        let adjustedRPE = acwrHot ? min(maxRPE, 7) : maxRPE
        return AdvisorPlan.Caps(maxRPE: adjustedRPE, maxMinutes: maxMinutes, forbidHardWork: forbid)
    }

    private func rec(_ modality: ActivityRecommendation.Modality, _ title: String, _ minutes: Int, _ rpe: ClosedRange<Int>, _ rationale: String, _ priority: Int) -> ActivityRecommendation {
        ActivityRecommendation(modality: modality, title: title, durationMinutes: minutes, intensityRPE: rpe, rationale: rationale, priority: priority)
    }

    private func mostRecent(within days: Int, in workouts: [WorkoutSummary]) -> WorkoutSummary? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date.distantPast
        return workouts.filter { $0.end >= cutoff }.max(by: { $0.end < $1.end })
    }

    private func recentlyDid(_ kind: WorkoutSummary.Kind, days: Int, in workouts: [WorkoutSummary]) -> Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date.distantPast
        return workouts.contains { $0.kind == kind && $0.end >= cutoff }
    }

    private func recentlyDidHardRun(in workouts: [WorkoutSummary], days: Int) -> Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date.distantPast
        return workouts.contains { w in
            guard w.kind == .run, w.end >= cutoff else { return false }
            if let hr = w.averageHeartRate, hr >= 155 { return true }
            if w.duration >= 60 * 60 { return true }
            return false
        }
    }
}
