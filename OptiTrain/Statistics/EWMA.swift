import Foundation

/// Exponentially-weighted moving average.
///
/// `α = 1 − e^(−1/τ)` so τ days is the "memory half-life-ish" of the series.
/// Used for Banister CTL (τ=42), ATL (τ=7), and any signal smoothing.
///
/// Pure value type — no hidden state beyond what you pass in. Update with
/// `step(_:)` to fold a single new sample, or `series(of:tau:seed:)` to compute
/// the whole trajectory at once.
struct EWMA: Equatable, Sendable {
    let tau: Double
    let alpha: Double
    var value: Double

    init(tau: Double, initialValue: Double = 0) {
        precondition(tau > 0, "tau must be positive")
        self.tau = tau
        self.alpha = 1 - exp(-1.0 / tau)
        self.value = initialValue
    }

    @inlinable
    mutating func step(_ sample: Double) {
        value = value + alpha * (sample - value)
    }

    /// Compute the full EWMA trajectory of `samples` (oldest first) using time
    /// constant `tau`. Returns one EWMA value per input sample.
    static func series(of samples: [Double], tau: Double, seed: Double? = nil) -> [Double] {
        guard !samples.isEmpty else { return [] }
        var s = EWMA(tau: tau, initialValue: seed ?? samples[0])
        var out: [Double] = []
        out.reserveCapacity(samples.count)
        for x in samples {
            s.step(x)
            out.append(s.value)
        }
        return out
    }
}
