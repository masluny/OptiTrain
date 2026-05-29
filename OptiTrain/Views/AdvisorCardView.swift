import SwiftUI

struct AdvisorCardView: View {
    let plan: AdvisorPlan
    @State private var selected: ActivityRecommendation?
    @State private var showWarnings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label("Activity Advisor", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                // Warnings live behind a quiet badge so the card stays calm.
                if !plan.warnings.isEmpty {
                    Button { showWarnings = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("\(plan.warnings.count)")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                // The "RPE ≤ X · ≤ Ym" caps chip lived here; removed to keep
                // the header calm. The caps still show in each recommendation's
                // detail sheet under "Today's limits."
            }

            VStack(spacing: 8) {
                ForEach(plan.recommendations) { rec in
                    Button { selected = rec } label: {
                        RecommendationRow(rec: rec)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .sheet(item: $selected) { rec in
            RecommendationDetailView(rec: rec, caps: plan.caps)
        }
        .sheet(isPresented: $showWarnings) {
            AdvisorWarningsView(warnings: plan.warnings)
        }
    }
}

/// The full list of advisor warnings, presented on demand so the main card can
/// stay minimalistic.
private struct AdvisorWarningsView: View {
    let warnings: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Heads up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct RecommendationRow: View {
    let rec: ActivityRecommendation

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: rec.modality.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(rec.modality.tint)
                .frame(width: 40, height: 40)
                .background(rec.modality.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rec.modality.label).font(.subheadline).bold()
                    if rec.priority == 1 {
                        Text("TOP").font(.caption2).bold()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                Text(meta).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private var meta: String {
        rec.durationMinutes > 0 ? "\(rec.durationMinutes) min · \(rpeText)" : rpeText
    }

    private var rpeText: String {
        let lo = rec.intensityRPE.lowerBound, hi = rec.intensityRPE.upperBound
        return lo == hi ? "RPE \(lo)" : "RPE \(lo)–\(hi)"
    }
}

struct RecommendationDetailView: View {
    let rec: ActivityRecommendation
    let caps: AdvisorPlan.Caps
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if !rec.title.isEmpty {
                        Text(rec.title)
                            .font(.title3.bold())
                    }

                    HStack(spacing: 12) {
                        if rec.durationMinutes > 0 {
                            DetailStat(label: "Duration", value: "\(rec.durationMinutes) min", systemImage: "clock")
                        }
                        DetailStat(label: "Intensity", value: rpeText, systemImage: "flame")
                    }

                    DetailSection(title: "Why this, today", systemImage: "lightbulb.fill") {
                        Text(rec.rationale)
                    }

                    DetailSection(title: "How to do it", systemImage: "list.bullet.clipboard") {
                        Text(rec.modality.guidance)
                    }

                    DetailSection(title: "Today's limits", systemImage: "gauge.with.dots.needle.67percent") {
                        Text("Your readiness caps today's work at RPE \(caps.maxRPE) and \(caps.maxMinutes) minutes\(caps.forbidHardWork ? ". Hard training is off the table — keep it recovery-focused." : ". Stay at or below these and you're training in the safe zone.")")
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .navigationTitle(rec.modality.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: rec.modality.symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(rec.modality.tint)
                .frame(width: 64, height: 64)
                .background(rec.modality.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(rec.modality.label).font(.title2.bold())
                if rec.priority == 1 {
                    Text("Top pick for today")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var rpeText: String {
        let lo = rec.intensityRPE.lowerBound, hi = rec.intensityRPE.upperBound
        return lo == hi ? "RPE \(lo)" : "RPE \(lo)–\(hi)"
    }
}

/// Section block used in the recommendation detail sheet.
private struct DetailSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            content
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailStat: View {
    let label: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: systemImage)
                .font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }
}

private extension ActivityRecommendation.Modality {
    var tint: Color {
        switch self {
        case .heavyLift, .accessoryLift: .purple
        case .intervalRun, .tempoRun: .orange
        case .easyRun, .longRun: .blue
        case .walk: .teal
        case .mobility: .mint
        case .fullRest: .indigo
        }
    }
}
