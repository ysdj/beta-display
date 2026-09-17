import Foundation

/// Ownership checks for the display transfer table.
///
/// Beta Display's image adjustments live in the WindowServer's per-display
/// transfer table, which any process (and the WindowServer itself) can
/// replace. A wake, a display-mode change, and the settle that follows a
/// session login or an auto-start can drop that table without reporting a
/// reconfiguration to the app that wrote it. The decision of "is the table
/// this process installed still there?" is kept here so the self-test can
/// exercise it directly instead of hiding inside the display calls.
enum DisplayLUTIntegrity {
    /// WindowServer can resample a submitted table, so drift is measured on
    /// the curve rather than on raw sample counts.
    static let matchTolerance = 0.002

    /// Session keys whose installed table is missing or no longer matches the
    /// table this process last wrote. A missing entry means the table could
    /// not be read during this pass; that counts as drift so the caller
    /// rewrites it from the stable baseline.
    static func driftedDisplayKeys(
        expected: [String: DisplayLUT],
        installed: [String: DisplayLUT],
        tolerance: Double = matchTolerance
    ) -> [String] {
        expected.compactMap { key, lut in
            guard let installedLUT = installed[key] else { return key }
            return installedLUT.approximatelyMatches(lut, tolerance: tolerance) ? nil : key
        }
        .sorted()
    }

    /// Verification passes that follow launch. Beta Display is auto-started
    /// while the login session is still settling, so the first seconds are
    /// checked repeatedly instead of trusting the single startup write.
    static let startupVerificationDelays: [TimeInterval] = [0.5, 1.5, 4, 10]

    /// Steady-state verification interval while the app owns a table. The
    /// check itself is a read-only comparison, so a short interval costs
    /// almost nothing and keeps a silent reset from lasting.
    static let steadyVerificationInterval: TimeInterval = 5
}
