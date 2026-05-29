import Foundation

/// Robust descriptive statistics — resistant to a few outlier days, which is
/// important when one bad night or one missed sample shouldn't poison weeks of
/// baseline. Use `RobustStatistics` instead of plain mean/std for physiology.
enum RobustStatistics {

    /// Median. O(n log n).
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        if s.count.isMultiple(of: 2) {
            return (s[s.count/2 - 1] + s[s.count/2]) / 2
        }
        return s[s.count / 2]
    }

    /// Median Absolute Deviation. MAD-based dispersion is ~50% efficient at the
    /// normal distribution but unaffected by outliers up to 50% of the sample.
    /// Returns nil for empty input.
    static func mad(_ values: [Double]) -> Double? {
        guard let med = median(values) else { return nil }
        let deviations = values.map { abs($0 - med) }
        return median(deviations)
    }

    /// Robust z-score: (x − median) / (1.4826 × MAD).
    /// The 1.4826 constant makes MAD a consistent estimator of σ under normality.
    /// Returns 0 when MAD == 0 (degenerate baseline).
    static func robustZ(_ x: Double, values: [Double]) -> Double {
        guard let med = median(values), let m = mad(values), m > 0 else { return 0 }
        return (x - med) / (1.4826 * m)
    }

    /// Coefficient of variation — std / mean. Used by AutonomicStability to
    /// measure HRV / RHR / RR volatility.
    static func coefficientOfVariation(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean != 0 else { return nil }
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return sqrt(variance) / abs(mean)
    }

    /// Slope (per index) of a least-squares linear fit. Used for VO2max
    /// trajectory and "rising effort, flat performance" plateau detection.
    static func linearSlope(_ values: [Double]) -> Double? {
        let n = values.count
        guard n >= 2 else { return nil }
        let xs = (0..<n).map(Double.init)
        let meanX = xs.reduce(0, +) / Double(n)
        let meanY = values.reduce(0, +) / Double(n)
        var num = 0.0, den = 0.0
        for i in 0..<n {
            num += (xs[i] - meanX) * (values[i] - meanY)
            den += (xs[i] - meanX) * (xs[i] - meanX)
        }
        guard den != 0 else { return nil }
        return num / den
    }
}
