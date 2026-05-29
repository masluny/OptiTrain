import Foundation

struct ActivityRecommendation: Identifiable, Equatable {
    enum Modality: String, CaseIterable {
        case heavyLift, accessoryLift, intervalRun, tempoRun, easyRun, longRun, walk, mobility, fullRest
        var label: String {
            switch self {
            case .heavyLift: "Heavy lift"
            case .accessoryLift: "Accessory lift"
            case .intervalRun: "Intervals"
            case .tempoRun: "Tempo run"
            case .easyRun: "Easy Z2 run"
            case .longRun: "Long run"
            case .walk: "Recovery walk"
            case .mobility: "Mobility / stretch"
            case .fullRest: "Full rest"
            }
        }
        /// Plain-language description of what the session is and how to execute
        /// it — shown in the recommendation detail view.
        var guidance: String {
            switch self {
            case .heavyLift:
                "Big compound barbell lifts — squat, deadlift, bench, press — in low reps. Warm up thoroughly, work up to a hard top set, then back off. Take long rests so each set is high quality."
            case .accessoryLift:
                "Supporting work: rows, presses, single-leg and core movements in moderate reps. Builds resilience and muscle without taxing the nervous system the way heavy lifting does."
            case .intervalRun:
                "Short, hard repeats at 5K pace or faster with easy jog recoveries. Develops VO₂max and top-end speed. Warm up well first — the work intervals should feel genuinely hard."
            case .tempoRun:
                "Sustained running at threshold — 'comfortably hard', roughly the fastest pace you could hold for an hour. Trains your body to clear lactate and hold strong paces longer."
            case .easyRun:
                "Relaxed Zone 2 running where you can hold a conversation. Builds your aerobic base and speeds recovery. Keep it truly easy — most of your weekly running should live here."
            case .longRun:
                "An extended easy-paced run to build endurance and durability. Keep the effort conversational throughout, and fuel and hydrate if it runs past an hour."
            case .walk:
                "Low-intensity outdoor walking. Keeps blood flowing and aids recovery without adding training stress — a dependable default on tired or underslept days."
            case .mobility:
                "Gentle mobility drills, stretching and breath work. Down-regulates the nervous system, restores range of motion and helps prime a good night's sleep."
            case .fullRest:
                "No structured training today. Prioritise sleep, food and hydration so your body can absorb recent work and rebound stronger."
            }
        }

        /// SF Symbol name used as the modality's icon.
        var symbol: String {
            switch self {
            case .heavyLift: "figure.strengthtraining.traditional"
            case .accessoryLift: "dumbbell.fill"
            case .intervalRun: "bolt.fill"
            case .tempoRun: "flame.fill"
            case .easyRun: "figure.run"
            case .longRun: "mountain.2.fill"
            case .walk: "figure.walk"
            case .mobility: "figure.cooldown"
            case .fullRest: "bed.double.fill"
            }
        }
    }

    let id = UUID()
    let modality: Modality
    let title: String
    let durationMinutes: Int
    let intensityRPE: ClosedRange<Int>   // Rate of perceived exertion 1-10
    let rationale: String
    let priority: Int                    // 1 = top pick
}

struct AdvisorPlan: Equatable {
    let date: Date
    let recommendations: [ActivityRecommendation]
    let warnings: [String]
    let caps: Caps

    struct Caps: Equatable {
        let maxRPE: Int
        let maxMinutes: Int
        let forbidHardWork: Bool
    }
}
