import SwiftUI

struct WorkoutsView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        List {
            Section {
                if session.recentWorkouts.isEmpty {
                    Text("No workouts pulled from Health yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.recentWorkouts.sorted(by: { $0.start > $1.start })) { w in
                        NavigationLink(value: w) { WorkoutRow(workout: w) }
                    }
                }
            } header: {
                Text("Last 7 days")
            } footer: {
                if !session.recentWorkouts.isEmpty {
                    Text(weeklyTotals).font(.footnote)
                }
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Workouts")
        .navigationDestination(for: WorkoutSummary.self) { w in
            WorkoutDetailView(workout: w)
        }
    }

    private var weeklyTotals: String {
        let total = session.recentWorkouts.reduce(0.0) { $0 + $1.duration }
        let distance = session.recentWorkouts.compactMap(\.distanceMeters).reduce(0, +)
        let kcal = session.recentWorkouts.reduce(0.0) { $0 + $1.activeEnergyKcal }
        let mins = Int(total / 60)
        let km = distance / 1000
        return String(format: "Totals · %dm · %.1f km · %.0f kcal", mins, km, kcal)
    }
}

private struct WorkoutRow: View {
    let workout: WorkoutSummary

    var body: some View {
        HStack(spacing: 14) {
            WorkoutIcon(kind: workout.kind, size: 46)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(workout.kind.rawValue.capitalized).font(.subheadline).bold()
                    Spacer()
                    Text(workout.start.formatted(.relative(presentation: .named)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)],
                    alignment: .leading,
                    spacing: 7
                ) {
                    ForEach(metrics, id: \.symbol) { metric in
                        MetricChip(systemImage: metric.symbol, text: metric.text)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// The metrics shown as 2×2 tiles, built only for values that exist.
    private var metrics: [(symbol: String, text: String)] {
        var items: [(String, String)] = [("clock", "\(Int(workout.duration / 60)) min")]
        if let km = workout.distanceMeters.map({ $0 / 1000 }), km > 0.01 {
            items.append(("ruler", String(format: "%.2f km", km)))
        }
        if let pace = workout.paceSecondsPerKm {
            items.append(("stopwatch", WorkoutFormat.pace(secondsPerKm: pace) + " /km"))
        }
        if let hr = workout.averageHeartRate {
            items.append(("heart.fill", "\(Int(hr)) bpm"))
        }
        return items
    }
}

/// Icon + value tile used in the 2×2 metric grid of a workout row.
private struct MetricChip: View {
    let systemImage: String
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 10))
            Text(text).font(.caption2.monospacedDigit())
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// SF Symbol badge for a workout kind, used in lists and the detail header.
private struct WorkoutIcon: View {
    let kind: WorkoutSummary.Kind
    var size: CGFloat = 46

    var body: some View {
        Image(systemName: WorkoutFormat.symbol(for: kind))
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(WorkoutFormat.tint(for: kind))
            .frame(width: size, height: size)
            .background(
                WorkoutFormat.tint(for: kind).opacity(0.15),
                in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            )
    }
}

struct WorkoutDetailView: View {
    let workout: WorkoutSummary

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    WorkoutIcon(kind: workout.kind, size: 84)
                    Text(workout.kind.rawValue.capitalized).font(.title2).bold()
                    Text(workout.start.formatted(date: .complete, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatTile(label: "Duration", value: "\(Int(workout.duration / 60)) min", systemImage: "clock")
                    if let km = workout.distanceMeters.map({ $0 / 1000 }), km > 0.01 {
                        StatTile(label: "Distance", value: String(format: "%.2f km", km), systemImage: "ruler")
                    }
                    if let pace = workout.paceSecondsPerKm {
                        StatTile(label: "Pace", value: WorkoutFormat.pace(secondsPerKm: pace) + " /km", systemImage: "stopwatch")
                    }
                    if let avg = workout.averageHeartRate {
                        StatTile(label: "Avg HR", value: "\(Int(avg)) bpm", systemImage: "heart.fill")
                    }
                    if let max = workout.maxHeartRate {
                        StatTile(label: "Max HR", value: "\(Int(max)) bpm", systemImage: "heart.circle.fill")
                    }
                    StatTile(label: "Active kcal", value: "\(Int(workout.activeEnergyKcal))", systemImage: "flame.fill")
                    if let ele = workout.elevationAscendedMeters, ele > 0 {
                        StatTile(label: "Elevation", value: "\(Int(ele)) m", systemImage: "mountain.2.fill")
                    }
                    if let hrPct = hrAsPercentMax {
                        StatTile(label: "Effort", value: "\(Int(hrPct))% max HR", systemImage: "gauge.with.dots.needle.67percent")
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .navigationTitle(workout.kind.rawValue.capitalized)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Rough effort gauge using 220 − assumed age 30. Later: pull DOB from HealthKit.
    private var hrAsPercentMax: Double? {
        guard let avg = workout.averageHeartRate else { return nil }
        let estMax = 220.0 - 30.0
        return min(100, (avg / estMax) * 100)
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    var systemImage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption2)
                }
                Text(label).font(.caption)
            }
            .foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

enum WorkoutFormat {
    /// SF Symbol name for a workout kind.
    static func symbol(for kind: WorkoutSummary.Kind) -> String {
        switch kind {
        case .run: "figure.run"
        case .walk: "figure.walk"
        case .lift: "figure.strengthtraining.traditional"
        case .ride: "figure.outdoor.cycle"
        case .other: "figure.mixed.cardio"
        }
    }

    /// Accent color for a workout kind.
    static func tint(for kind: WorkoutSummary.Kind) -> Color {
        switch kind {
        case .run: .orange
        case .walk: .teal
        case .lift: .purple
        case .ride: .green
        case .other: .blue
        }
    }

    /// "5:23" for 323 s/km, "6:00" for 360 s/km.
    static func pace(secondsPerKm: Double) -> String {
        let total = Int(secondsPerKm.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
