import SwiftUI

struct TodayView: View {
    @Environment(AppSession.self) private var session
    @AppStorage(UserSettingsKey.aiFeaturesEnabled) private var aiFeaturesEnabled: Bool = true
    /// The athlete's chosen goal, read here so AICoachCard regenerates its
    /// briefing when the goal changes in Settings. nil → general advice.
    @AppStorage(UserSettingsKey.selectedGoal) private var goalRaw: String = ""
    private var goal: Goal? { Goal(rawValue: goalRaw) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                switch session.state {
                case .idle, .requestingAuth:
                    LoadingProgressView(progress: 0,
                                        label: session.loadingStatus)
                case .loading:
                    // session.loadingStatus updates per phase, e.g.
                    // "Loading daily metrics (14/35)…", so the ring's caption
                    // changes every second instead of sitting on one frozen
                    // line.
                    LoadingProgressView(progress: session.progress,
                                        label: session.loadingStatus)
                case .failed(let message):
                    ErrorBanner(message: message) {
                        Task { await session.bootstrap() }
                    }
                case .ready:
                    if !session.dataQualityNotes.isEmpty {
                        DataQualityBanner(notes: session.dataQualityNotes)
                    }
                    if session.showingPreviousDay, let date = session.sleepCarriedFrom {
                        StaleDayBanner(date: date)
                    }
                    // Two square cards side-by-side at the top: Training
                    // Readiness on the left, Athlete Level on the right.
                    if let score = session.todayReadiness, let snap = session.intelligence {
                        HStack(spacing: 12) {
                            ReadinessHeroCard(score: score)
                            NavigationLink {
                                BodyEfficiencyView(snapshot: snap.bodyEfficiency,
                                                   date: session.scoreDate ?? Date())
                            } label: {
                                BodyEfficiencyCard(snapshot: snap.bodyEfficiency)
                            }
                            .buttonStyle(.plain)
                        }
                        ReadinessBreakdownView(score: score)
                        // Activity Advisor first — concrete picks for today —
                        // then the AI Coach gives the narrative read on the
                        // numbers. Both are goal-aware when one is set.
                        if let plan = session.plan {
                            AdvisorCardView(plan: plan)
                        }
                        if aiFeaturesEnabled {
                            AICoachCard(readiness: score,
                                        snapshot: snap,
                                        plan: session.plan,
                                        goal: goal)
                        }
                    }
                    if let snap = session.intelligence {
                        if let load = snap.load { LoadCard(snapshot: load) }
                        if let debt = snap.recoveryDebt { RecoveryDebtCard(snapshot: debt) }
                        if let aut = snap.autonomicStability { AutonomicCard(snapshot: aut) }
                        InjuryRiskCard(snapshot: snap.injuryRisk)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("OptiTrain")
        .refreshable { await session.refresh() }
    }
}

/// A bullet list of the per-input gaps the AppSession noticed during refresh
/// — surfaces honestly to the user *why* certain scores might look neutral,
/// instead of letting them blame the app.
private struct DataQualityBanner: View {
    let notes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Some health inputs are missing", systemImage: "info.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                Text("• \(note)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct StaleDayBanner: View {
    let date: Date
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text("Using your sleep from \(date.formatted(.dateTime.weekday(.wide).month().day()))")
                    .font(.subheadline).bold()
                Text("No sleep was recorded for last night, so today's readiness reuses your most recent night. Wear your watch to bed for a fresh score.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}

#Preview {
    NavigationStack { TodayView() }
        .environment(AppSession())
}
