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

/// A slight, ambient three-color shine: light blue, neon green and bright orange
/// bleeding in from different corners. Applied per-screen via `.shineBackground()`
/// (a single root-level layer gets painted over by `TabView`), so it sits behind
/// each screen's transparent `ScrollView` and tints the translucent card
/// materials. The base stays clear, so it works in both light and dark mode.
struct ShineBackground: View {
    var body: some View {
        ZStack {
            // A faint base wash so the shine reads even on pure white/black.
            RadialGradient(colors: [Color(red: 0.40, green: 0.75, blue: 1.00).opacity(0.20), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 460)
            RadialGradient(colors: [Color(red: 1.00, green: 0.55, blue: 0.15).opacity(0.16), .clear],
                           center: UnitPoint(x: 0.95, y: 0.10), startRadius: 0, endRadius: 400)
            RadialGradient(colors: [Color(red: 0.30, green: 1.00, blue: 0.55).opacity(0.17), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 520)
        }
        .blur(radius: 28)
    }
}

extension View {
    /// Places the ambient shine behind a screen's content. The screen's own
    /// `ScrollView` is transparent, so the shine shows through and bleeds under
    /// the navigation bar.
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
