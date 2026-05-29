import Foundation

/// Cross-cutting "why" model. Every score in the system carries a vector of
/// `Factor`s so the UI can render a transparent breakdown — no magic numbers.
struct Factor: Identifiable, Equatable, Hashable, Sendable {
    enum Direction: String, Sendable { case positive, negative, neutral }
    let id = UUID()
    let label: String
    let direction: Direction
    let magnitude: Double      // 0...1, how strongly this factor moved the score
    let detail: String         // human-readable, with numbers
}

struct Explanation: Equatable, Sendable {
    let headline: String       // one-liner the UI can lead with
    let factors: [Factor]      // ordered most-impactful first
    let limitingFactor: Factor?

    init(headline: String, factors: [Factor], limitingFactor: Factor? = nil) {
        self.headline = headline
        self.factors = factors
        self.limitingFactor = limitingFactor ?? factors
            .filter { $0.direction == .negative }
            .max(by: { $0.magnitude < $1.magnitude })
    }
}
