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
    /// table this process last wrote. Only keys that still belong to a display
    /// present in the current active list are considered: a disconnected
    /// display keeps its saved state but has no table to verify. A missing
    /// entry for a present display means the table could not be read during
    /// this pass; that counts as drift so the caller rewrites it from the
    /// stable baseline.
    static func driftedDisplayKeys(
        expected: [String: DisplayLUT],
        installed: [String: DisplayLUT],
        presentKeys: Set<String>,
        tolerance: Double = matchTolerance
    ) -> [String] {
        expected.compactMap { key, lut in
            guard presentKeys.contains(key) else { return nil }
            guard let installedLUT = installed[key] else { return key }
            return installedLUT.approximatelyMatches(lut, tolerance: tolerance) ? nil : key
        }
        .sorted()
    }

    /// Bounded retry schedule for an unchanged drift set. A sleeping or
    /// unplugged display cannot be repaired by rewriting its table, so the
    /// interval doubles up to a cap instead of submitting the same repair on
    /// every steady-state verification pass. A different drift set retries
    /// immediately.
    struct DriftRepairBackoff {
        static let initialInterval: TimeInterval = 30
        static let maximumInterval: TimeInterval = 300

        private(set) var signature: [String] = []
        private(set) var consecutiveAttempts = 0
        private var lastAttemptDate: Date?

        var currentInterval: TimeInterval {
            guard consecutiveAttempts > 0 else { return 0 }
            let interval = Self.initialInterval * pow(2, Double(consecutiveAttempts - 1))
            return min(interval, Self.maximumInterval)
        }

        func shouldAttempt(signature newSignature: [String], now: Date = Date()) -> Bool {
            guard newSignature == signature, let lastAttemptDate else { return true }
            return now.timeIntervalSince(lastAttemptDate) >= currentInterval
        }

        mutating func recordAttempt(signature newSignature: [String], now: Date = Date()) {
            if newSignature == signature {
                consecutiveAttempts += 1
            } else {
                signature = newSignature
                consecutiveAttempts = 1
            }
            lastAttemptDate = now
        }

        mutating func reset() {
            signature = []
            consecutiveAttempts = 0
            lastAttemptDate = nil
        }
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
