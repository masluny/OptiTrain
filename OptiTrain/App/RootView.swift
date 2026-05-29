import SwiftUI

struct RootView: View {
    @Environment(AppSession.self) private var session
    @State private var tab: AppTab = .today

    /// The five top-level pages, in swipe order. CaseIterable so the horizontal
    /// swipe gesture can walk through them deterministically.
    enum AppTab: Hashable, CaseIterable {
        case today, races, trends, goal, settings
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { TodayView().shineBackground() }
                .tabItem { Label("Today", systemImage: "sun.max.fill") }
                .tag(AppTab.today)
            NavigationStack { EventReadinessView().shineBackground() }
                .tabItem { Label("Races", systemImage: "flag.checkered") }
                .tag(AppTab.races)
            NavigationStack { TrendsView().shineBackground() }
                .tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(AppTab.trends)
            NavigationStack { GoalView().shineBackground() }
                .tabItem { Label("Goal", systemImage: "target") }
                .tag(AppTab.goal)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        // Runs *alongside* the embedded ScrollViews so vertical scrolling and
        // button taps still work — we only react in `onEnded` when the drag is
        // unambiguously horizontal.
        .simultaneousGesture(tabSwipeGesture)
    }

    /// Horizontal-swipe-to-walk-between-tabs. The shine background lives
    /// inside each tab (and is identical across tabs), so when we switch
    /// selection there's no slide — it reads as a static background.
    private var tabSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                // Don't fight NavigationStack's left-edge swipe-to-go-back.
                if value.startLocation.x < 30, dx > 0 { return }
                // Require a clearly horizontal drag of meaningful magnitude —
                // a vertical scroll has dx ≈ 0 and is rejected by both guards.
                guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                let cases = AppTab.allCases
                guard let idx = cases.firstIndex(of: tab) else { return }
                if dx < 0, idx < cases.count - 1 {
                    tab = cases[idx + 1]
                } else if dx > 0, idx > 0 {
                    tab = cases[idx - 1]
                }
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
