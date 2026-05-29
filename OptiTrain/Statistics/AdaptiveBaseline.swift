import Foundation

/// Rolling, adaptive baseline for a physiological signal — what "normal"
/// means for this user, right now. Combines a 28-day median (robust to
/// outliers) with an EWMA-smoothed slow trend so the baseline drifts as the
/// athlete's fitness changes, but doesn't get yanked by a single bad night.
struct AdaptiveBaseline: Equatable, Sendable {
    let median: Double
    let mad: Double
    let trend: Double          // EWMA(τ=21) slow trend
    let sampleCount: Int

    /// Computed sigma estimate from MAD (1.4826 × MAD ≈ σ under normality).
    var sigma: Double { 1.4826 * mad }

    init(median: Double, mad: Double, trend: Double, sampleCount: Int) {
        self.median = median
        self.mad = mad
        self.trend = trend
        self.sampleCount = sampleCount
    }

    /// Robust z-score against this baseline. 0 → at baseline; +1 → 1σ above.
    func z(of value: Double) -> Double {
        guard sigma > 0 else { return 0 }
        return (value - median) / sigma
    }

    /// Build a baseline from up to ~28 days of samples (oldest first).
    /// Returns nil if there aren't enough samples to be meaningful.
    static func build(from samples: [Double], minSamples: Int = 7) -> AdaptiveBaseline? {
        let filtered = samples.filter { $0.isFinite }
        guard filtered.count >= minSamples else { return nil }
        guard let med = RobustStatistics.median(filtered),
              let m = RobustStatistics.mad(filtered) else { return nil }
        let trend = EWMA.series(of: filtered, tau: 21).last ?? med
        return AdaptiveBaseline(median: med, mad: m, trend: trend, sampleCount: filtered.count)
    }
}
