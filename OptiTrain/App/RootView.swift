import SwiftUI

struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        TabView {
            NavigationStack { TodayView().shineBackground() }
                .tabItem { Label("Today", systemImage: "sun.max.fill") }
            NavigationStack { EventReadinessView().shineBackground() }
                .tabItem { Label("Races", systemImage: "flag.checkered") }
            NavigationStack { TrendsView().shineBackground() }
                .tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") }
            NavigationStack { GoalView().shineBackground() }
                .tabItem { Label("Goal", systemImage: "target") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

/// Subtle grouped-system background to keep the UI close to native iOS surfaces.
struct ShineBackground: View {
    var body: some View {
        Color(uiColor: .systemGroupedBackground)
    }
}

extension View {
    /// Places a native grouped background behind each screen.
    func shineBackground() -> some View {
        background(ShineBackground().ignoresSafeArea())
    }
}

// MARK: - Shared loading + error views

/// Determinate loading ring with a live percentage in the middle. Used by every
/// top-level tab so the user always sees real-time evidence the app is working
/// (and isn't stuck) while HealthKit queries crunch through. `progress` is the
/// shared `AppSession.progress` value, 0.0 → 1.0.
struct LoadingProgressView: View {
    let progress: Double
    let label: String

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 7)
                Circle()
                    // Trim from a tiny floor so something is always visible —
                    // even at 0% the ring shows a hint of color so the user
                    // can see it before the first HealthKit query returns.
                    .trim(from: 0, to: max(0.015, progress))
                    .stroke(
                        AngularGradient(
                            colors: [.cyan, .green, .mint, .cyan],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.35), value: progress)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.title2.weight(.bold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .frame(width: 92, height: 92)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

/// Error card used by every tab when `AppSession.state == .failed`. Lifted to
/// the shared layer so every screen tells the user the same story (instead of
/// some tabs showing an error card while others show a forever-spinner — the
/// bug your friend hit in the Races tab).
struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Something went wrong").font(.headline)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.top, 40)
    }
}

#Preview {
    RootView()
        .environment(AppSession())
}
