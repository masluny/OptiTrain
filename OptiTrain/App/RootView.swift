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

#Preview {
    RootView()
        .environment(AppSession())
}
