import Foundation
import SwiftUI

/// User-tunable settings persisted to UserDefaults. Read via `@AppStorage` in
/// SwiftUI views, or via `UserSettings.current` from non-view code.
enum UserSettingsKey {
    static let useWristTemperature = "useWristTemperature"
    /// Persisted `Goal.rawValue` for the athlete's currently selected goal. Empty = none chosen.
    static let selectedGoal = "selectedGoal"
    /// Whether on-device AI (Apple Intelligence) features are enabled. Off = use
    /// built-in rule-based guidance instead (e.g. where Apple Intelligence isn't
    /// available, like the EU). Defaults to ON.
    static let aiFeaturesEnabled = "aiFeaturesEnabled"
}

struct UserSettings: Equatable {
    var useWristTemperature: Bool

    static var current: UserSettings {
        let defaults = UserDefaults.standard
        // First run: default to ON (turning off is opt-out for users on Series 7-)
        let useTemp = defaults.object(forKey: UserSettingsKey.useWristTemperature) as? Bool ?? true
        return UserSettings(useWristTemperature: useTemp)
    }
}
