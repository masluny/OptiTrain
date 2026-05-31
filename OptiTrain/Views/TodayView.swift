import SwiftUI

struct TodayView: View {
    @Environment(AppSession.self) private var session
    @AppStorage(UserSettingsKey.aiFeaturesEnabled) private var aiFeaturesEnabled: Bool = true

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                switch session.state {
                case .idle, .requestingAuth:
                    LoadingProgressView(progress: 0,
                                        label: "Connecting to Apple Health…")
                case .loading:
                    LoadingProgressView(progress: session.progress,
                                        label: "Crunching your numbers…")
                case .failed(let message):
                    ErrorBanner(message: message) {
                        Task { await session.bootstrap() }
                    }
                case .ready:
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
                        if aiFeaturesEnabled {
                            AICoachCard(readiness: score, snapshot: snap, plan: session.plan)
                        }
                    }
                    if let plan = session.plan {
                        AdvisorCardView(plan: plan)
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
