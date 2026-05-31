import SwiftUI

/// The "Goal" tab. The athlete picks a target — a race, or a broader objective
/// like losing weight or raising their Athlete Level — and an on-device AI coach
/// turns today's numbers into a concrete weekly plan toward it.
struct GoalView: View {
    @Environment(AppSession.self) private var session
    @AppStorage(UserSettingsKey.selectedGoal) private var goalRaw: String = ""
    @State private var showingPicker = false

    private var goal: Goal? { Goal(rawValue: goalRaw) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let goal {
                    GoalHeaderCard(goal: goal) { showingPicker = true }

                    // State-aware below the header — same pattern as Today /
                    // Races / Trends, so a failed refresh shows a real error
                    // instead of a forever-spinner.
                    switch session.state {
                    case .idle, .requestingAuth:
                        LoadingProgressView(progress: 0,
                                            label: "Connecting to Apple Health…")
                    case .loading:
                        LoadingProgressView(progress: session.progress,
                                            label: "Reading your data…")
                    case .failed(let message):
                        ErrorBanner(message: message) {
                            Task { await session.bootstrap() }
                        }
                    case .ready:
                        if let score = session.todayReadiness, let snap = session.intelligence {
                            if case .race(let distance) = goal,
                               let r = snap.eventReadiness.first(where: { $0.event == distance }) {
                                GoalRaceStatusCard(
                                    readiness: r,
                                    prediction: snap.racePredictions.first(where: { $0.distance == distance })
                                )
                            }
                            GoalCoachCard(goal: goal, readiness: score, snapshot: snap)
                        } else {
                            LoadingProgressView(progress: session.progress,
                                                label: "Reading your data…")
                        }
                    }
                } else {
                    GoalEmptyState { showingPicker = true }
                }
            }
            .padding()
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Goal")
        .sheet(isPresented: $showingPicker) {
            GoalPickerSheet(current: goal) { selected in
                goalRaw = selected.rawValue
                showingPicker = false
            }
        }
    }
}

// MARK: - Empty state

private struct GoalEmptyState: View {
    let choose: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "target")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 50)
            Text("Pick a goal").font(.title2.bold())
            Text("Choose a race or a fitness goal, and your on-device AI coach will build a weekly plan from your own data.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button(action: choose) {
                Label("Choose a goal", systemImage: "flag.checkered")
                    .font(.headline)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - Header

private struct GoalHeaderCard: View {
    let goal: Goal
    let change: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: goal.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text("Current goal").font(.caption).foregroundStyle(.secondary)
                Text(goal.title).font(.headline)
            }
            Spacer(minLength: 8)
            Button("Change", action: change)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - AI plan card

private struct GoalCoachCard: View {
    let goal: Goal
    let readiness: ReadinessScore
    let snapshot: AdaptiveIntelligenceSnapshot

    @AppStorage(UserSettingsKey.aiFeaturesEnabled) private var aiEnabled: Bool = true
    @State private var phase: Phase = .idle
    /// True when the currently shown plan came from the rule-based fallback
    /// rather than the on-device model — keeps the header label honest.
    @State private var usedFallback = false
    /// The `taskKey` we last produced a `.ready` plan for. Lets us skip a
    /// regeneration when the user revisits the Goal tab with nothing changed —
    /// same pattern AICoachCard on the Today screen uses, so the on-device
    /// model only runs when there's actually new input to coach on.
    @State private var generatedForKey: String?

    /// Whether the card is presenting genuine AI output (vs. rule-based tips).
    private var showingAI: Bool { aiEnabled && !usedFallback }

    enum Phase: Equatable {
        case idle
        case generating
        case ready(headline: String, focus: String, steps: [String], encouragement: String)
        case unavailable(String)
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label(showingAI ? "AI Coach" : "Coach",
                      systemImage: showingAI ? "sparkles" : "figure.run")
                    .font(.headline)
                Spacer()
                if showingAI {
                    // Manual regenerate. Bypasses the `generatedForKey` cache
                    // because the user explicitly asked for a fresh plan;
                    // disabled mid-generation to block double-taps.
                    Button {
                        Task { await generate() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .background(Color.secondary.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(phase == .generating)
                    .accessibilityLabel("Regenerate plan")
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .task(id: taskKey) {
            // Skip work if we already have a plan for this exact key —
            // matches the cache check in AICoachCard so revisiting the tab
            // doesn't re-prompt the model when nothing's actually changed.
            if generatedForKey == taskKey, case .ready = phase { return }
            await generate()
        }
    }

    /// Regenerate when the goal, the scored day, or the AI toggle changes.
    private var taskKey: String { "\(goal.rawValue)|\(snapshot.scoreDate.timeIntervalSince1970)|\(aiEnabled)" }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .generating:
            HStack(spacing: 10) {
                ProgressView()
                Text("Building your plan…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)

        case let .ready(headline, focus, steps, encouragement):
            VStack(alignment: .leading, spacing: 12) {
                Text(headline)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !focus.isEmpty {
                    Label(focus, systemImage: "target")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !steps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This week").font(.subheadline.weight(.semibold))
                        ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(idx + 1)")
                                    .font(.caption.bold().monospacedDigit())
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 22, height: 22)
                                    .background(Color.accentColor.opacity(0.12), in: Circle())
                                Text(step)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if !encouragement.isEmpty {
                    Text(encouragement)
                        .font(.footnote.italic())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .transition(.opacity)

        case let .unavailable(message):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .failed:
            HStack(spacing: 8) {
                Text("Couldn't build a plan this time.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Retry") { Task { await generate() } }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func generate() async {
        // AI turned off, or Apple Intelligence isn't available here → rule-based.
        guard aiEnabled, case .available = AICoach.availability() else {
            applyFallback()
            return
        }
        withAnimation { usedFallback = false; phase = .generating }
        guard #available(iOS 26.0, *) else {
            applyFallback()
            return
        }
        do {
            let plan = try await GoalCoach.plan(goal: goal, readiness: readiness, snapshot: snapshot)
            generatedForKey = taskKey
            withAnimation {
                usedFallback = false
                phase = .ready(headline: plan.headline,
                               focus: plan.weeklyFocus,
                               steps: plan.steps,
                               encouragement: plan.encouragement)
            }
        } catch {
            // Don't dead-end — fall back to the built-in plan.
            applyFallback()
        }
    }

    /// Show the deterministic, hand-written plan (no model required).
    private func applyFallback() {
        let plan = GoalCoach.fallbackPlan(goal: goal, readiness: readiness, snapshot: snapshot)
        generatedForKey = taskKey
        withAnimation {
            usedFallback = true
            phase = .ready(headline: plan.headline,
                           focus: plan.weeklyFocus,
                           steps: plan.steps,
                           encouragement: plan.encouragement)
        }
    }
}

// MARK: - Race status (race goals only)

private struct GoalRaceStatusCard: View {
    let readiness: EventReadinessEngine.Readiness
    let prediction: RaceTimePrediction.Prediction?

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Race readiness").font(.subheadline.weight(.semibold))
                if let prediction {
                    Text("Predicted \(formatTime(prediction.predictedSeconds))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("Finish probability \(Int(readiness.completionProbability * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ReadinessRing(value: readiness.score, size: 56, lineWidth: 6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Picker

private struct GoalPickerSheet: View {
    let current: Goal?
    let onSelect: (Goal) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Fitness goals") {
                    ForEach(GenericGoal.allCases) { g in
                        row(symbol: g.symbol, title: g.title, subtitle: g.subtitle,
                            isSelected: current == .generic(g)) {
                            onSelect(.generic(g))
                        }
                    }
                }
                ForEach(RaceTimePrediction.RaceDistance.Category.allCases, id: \.self) { category in
                    Section(category.rawValue) {
                        ForEach(racesIn(category), id: \.self) { distance in
                            row(symbol: category.symbol, title: distance.rawValue, subtitle: nil,
                                isSelected: current == .race(distance)) {
                                onSelect(.race(distance))
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Choose a goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func racesIn(_ category: RaceTimePrediction.RaceDistance.Category) -> [RaceTimePrediction.RaceDistance] {
        RaceTimePrediction.RaceDistance.allCases.filter { $0.category == category }
    }

    @ViewBuilder
    private func row(symbol: String, title: String, subtitle: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}
