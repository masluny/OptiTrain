import Foundation

/// Every score in the system carries a confidence value derived from data
/// density and recency. A score from 28 days of complete data is high-
/// confidence; the same score from 4 patchy days is low-confidence and the
/// UI should de-emphasize it (smaller ring, gray ramp, "early days" footnote).
struct Confidence: Equatable, Sendable, CustomStringConvertible {
    /// 0...1. Use `band` for human-readable display.
    let value: Double

    enum Band: String, Sendable { case veryLow, low, moderate, high, veryHigh }

    var band: Band {
        switch value {
        case ..<0.20: .veryLow
        case 0.20..<0.45: .low
        case 0.45..<0.70: .moderate
        case 0.70..<0.90: .high
        default: .veryHigh
        }
    }

    var description: String { String(format: "%.0f%%", value * 100) }

    init(_ value: Double) {
        self.value = max(0, min(1, value))
    }

    // MARK: - Combinators

    /// Combine n independent confidence sources via geometric mean. Strong
    /// signal from one source can't fully compensate for missing data
    /// elsewhere — that's the correct epistemic behavior.
    static func combine(_ parts: [Confidence]) -> Confidence {
        guard !parts.isEmpty else { return Confidence(0) }
        let product = parts.reduce(1.0) { $0 * max($1.value, 0.0001) }
        return Confidence(pow(product, 1.0 / Double(parts.count)))
    }

    /// Confidence as a function of "how many samples do I have out of the
    /// number I'd want". Saturates at 1.0 for `present >= target`.
    static func fromSampleDensity(present: Int, target: Int) -> Confidence {
        guard target > 0 else { return Confidence(0) }
        return Confidence(min(1.0, Double(present) / Double(target)))
    }

    /// Confidence as a function of staleness. Fresh = today's data → 1.0,
    /// half-life of `halfLifeDays`.
    static func fromRecency(daysOld: Int, halfLifeDays: Int = 2) -> Confidence {
        let h = max(1, halfLifeDays)
        return Confidence(pow(0.5, Double(daysOld) / Double(h)))
    }
}
