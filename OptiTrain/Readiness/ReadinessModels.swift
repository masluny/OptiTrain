import Foundation

struct SubScore: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case sleep, hrv, restingHeartRate, load, wristTemperature
        var label: String {
            switch self {
            case .sleep: "Sleep"
            case .hrv: "HRV"
            case .restingHeartRate: "Resting HR"
            case .load: "Training Load"
            case .wristTemperature: "Wrist Temp"
            }
        }

        /// Which way the *raw* signal should move for better readiness. Heart-rate
        /// and recovery signals are monotonic; load and temperature are best near
        /// a personal sweet spot, so neither extreme is "better".
        enum Direction { case higher, lower, balanced }
        var betterDirection: Direction {
            switch self {
            case .sleep, .hrv: .higher
            case .restingHeartRate: .lower
            case .load, .wristTemperature: .balanced
            }
        }
        var directionHint: String {
            switch betterDirection {
            case .higher: "Higher = better"
            case .lower: "Lower = better"
            case .balanced: "Balanced = better"
            }
        }
        var directionSymbol: String {
            switch betterDirection {
            case .higher: "arrow.up"
            case .lower: "arrow.down"
            case .balanced: "arrow.left.and.right"
            }
        }
    }
    let kind: Kind
    let value: Double        // 0...100
    let weight: Double       // 0...1, weights sum to 1
    let detail: String       // human-readable "why"
    var id: Kind.RawValue { kind.rawValue }
    var weighted: Double { value * weight }
}

struct ReadinessScore: Equatable {
    enum Band: String {
        case prime, ready, moderate, low, depleted
        var label: String {
            switch self {
            case .prime: "Prime"
            case .ready: "Ready"
            case .moderate: "Moderate"
            case .low: "Low"
            case .depleted: "Depleted"
            }
        }
    }
    let date: Date
    let value: Int           // 0...100
    let subScores: [SubScore]
    let acwr: Double?        // acute:chronic workload ratio
    let headline: String

    var band: Band {
        switch value {
        case 85...: .prime
        case 70..<85: .ready
        case 55..<70: .moderate
        case 40..<55: .low
        default: .depleted
        }
    }
}
