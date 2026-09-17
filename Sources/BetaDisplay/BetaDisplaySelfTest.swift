import CoreGraphics
import Foundation

/// Lightweight, dependency-free verification for environments that only have
/// the macOS Command Line Tools instead of XCTest/Swift Testing.
@MainActor
enum BetaDisplaySelfTest {
    static func run() -> [String] {
        var failures: [String] = []
        let neutral = ColorAdjustments.neutral
        for channel in ColorChannel.allCases {
            for input in [0.0, 0.5, 1.0] {
                if abs(neutral.transformed(input, channel: channel) - input) >= 0.0001 {
                    failures.append(L10n.text("self_test.neutral_transform", String(describing: channel), input))
                }
            }
        }

        // Gain follows the native quadratic control curve.
        let gainCases: [(Double, Double)] = [
            (0, 0), (0.25, 0.75), (0.5, 1), (0.75, 1.25), (1, 2)
        ]
        for (control, expectedMultiplier) in gainCases {
            let raw = ColorAdjustments.rawGain(for: control)
            if abs(ColorAdjustments.gainMultiplier(forRawValue: raw) - expectedMultiplier) >= 0.0001 {
                failures.append(L10n.text("self_test.gain_scale"))
                break
            }
        }

        var gain = ColorAdjustments.neutral
        gain.gain = 0.75
        if abs(gain.transformed(0.5, channel: .green) - 0.625) >= 0.0001 {
            failures.append(L10n.text("self_test.gain_scale"))
        }
        gain.redGain = 0.75
        // The global and channel gain offsets combine around unity.
        if abs(gain.transformed(0.5, channel: .red) - 0.75) >= 0.0001 {
            failures.append(L10n.text("self_test.gain_scale"))
        }

        for preferredChannel in ColorChannel.allCases {
            var unsafeRGBGains = ColorAdjustments.neutral
            unsafeRGBGains.redGain = 0
            unsafeRGBGains.greenGain = 0
            unsafeRGBGains.blueGain = 0
            let safeRGBGains = unsafeRGBGains.sanitizedForApplication(
                preferredChannel: preferredChannel
            )
            let preservedGain: Double
            switch preferredChannel {
            case .red: preservedGain = safeRGBGains.redGain
            case .green: preservedGain = safeRGBGains.greenGain
            case .blue: preservedGain = safeRGBGains.blueGain
            }
            guard preservedGain >= ColorAdjustments.minimumVisibleControl else {
                failures.append(L10n.text("self_test.rgb_gain_safety"))
                break
            }
            if abs(preservedGain * 100 - (preservedGain * 100).rounded()) >= 0.000_001 {
                failures.append(L10n.text("self_test.rgb_gain_safety"))
                break
            }
            let safeLUT = DisplayLUT(adjustments: unsafeRGBGains, count: 17)
            guard [safeLUT.red.last, safeLUT.green.last, safeLUT.blue.last]
                .compactMap({ $0 })
                .contains(where: { $0 > 0 })
            else {
                failures.append(L10n.text("self_test.rgb_gain_safety"))
                break
            }
        }

        var unsafeGlobalGain = ColorAdjustments.neutral
        unsafeGlobalGain.gain = 0
        let safeGlobalGainLUT = DisplayLUT(adjustments: unsafeGlobalGain, count: 17)
        if ![safeGlobalGainLUT.red.last, safeGlobalGainLUT.green.last, safeGlobalGainLUT.blue.last]
            .compactMap({ $0 })
            .contains(where: { $0 > 0 }) {
            failures.append(L10n.text("self_test.rgb_gain_safety"))
        }

        var unsafeBrightness = ColorAdjustments.neutral
        unsafeBrightness.brightness = 0
        if unsafeBrightness.sanitizedForApplication().brightness
            < ColorAdjustments.minimumVisibleControl {
            failures.append(L10n.text("self_test.rgb_gain_safety"))
        }

        var unsafeGlobalGainAndRGB = ColorAdjustments.neutral
        unsafeGlobalGainAndRGB.gain = 0
        unsafeGlobalGainAndRGB.redGain = 0
        unsafeGlobalGainAndRGB.greenGain = 0
        unsafeGlobalGainAndRGB.blueGain = 0
        let safeCombinedLUT = DisplayLUT(adjustments: unsafeGlobalGainAndRGB, count: 17)
        if ![safeCombinedLUT.red.last, safeCombinedLUT.green.last, safeCombinedLUT.blue.last]
            .compactMap({ $0 })
            .contains(where: { $0 > 0 }) {
            failures.append(L10n.text("self_test.rgb_gain_safety"))
        }

        var gamma = ColorAdjustments.neutral
        gamma.gamma = 0.75 // native +0.4
        if abs(gamma.transformed(0.25, channel: .green) - pow(0.25, 1 / 1.4)) >= 0.0001 {
            failures.append(L10n.text("self_test.gamma_scale"))
        }
        gamma = .neutral
        gamma.redGamma = 0.75 // native +0.4, the RGB control has the same direction.
        if abs(gamma.transformed(0.25, channel: .red) - pow(0.25, 1 / 1.4)) >= 0.0001 {
            failures.append(L10n.text("self_test.gamma_scale"))
        }

        var warm = ColorAdjustments.neutral
        warm.temperature = 0.6 // native +0.1
        if abs(warm.transformed(0.5, channel: .red) - 0.5) >= 0.0001
            || abs(warm.transformed(0.5, channel: .green) - 0.475) >= 0.0001
            || abs(warm.transformed(0.5, channel: .blue) - 0.45) >= 0.0001 {
            failures.append(L10n.text("self_test.temperature_scale"))
        }

        var quantized = ColorAdjustments.neutral
        quantized.quantization = 0.4
        // At the 0.40 control point, the source table has 86 levels. Input
        // 0.37 maps to source code 379, then bucket 31.
        let expectedQuantized = 31.0 / 85.0
        if abs(quantized.transformed(0.37, channel: .red) - expectedQuantized) >= 0.0001 {
            failures.append(L10n.text("self_test.quantization"))
        }
        quantized.quantization = 1
        if abs(quantized.transformed(0.4, channel: .red) - 0.4) >= 0.0001 {
            failures.append(L10n.text("self_test.quantization"))
        }

        let lut = DisplayLUT(adjustments: .neutral, count: 17)
        if lut.red.count != 17 || lut.green.count != 17 || lut.blue.count != 17 || lut.red.first != 0 || lut.red.last != 1 {
            failures.append(L10n.text("self_test.lut"))
        }

        // Reapplying an adjustment from a stable baseline must be idempotent.
        var reducedGain = ColorAdjustments.neutral
        reducedGain.redGain = 0.2
        reducedGain.greenGain = 0.2
        reducedGain.blueGain = 0.2
        let firstGainLUT = DisplayLUT(base: lut, adjustments: reducedGain)
        let repeatedGainLUT = DisplayLUT(base: lut, adjustments: reducedGain)
        let compoundedGainLUT = DisplayLUT(base: firstGainLUT, adjustments: reducedGain)
        if !repeatedGainLUT.approximatelyMatches(firstGainLUT, tolerance: 0.000_01)
            || compoundedGainLUT.approximatelyMatches(firstGainLUT, tolerance: 0.000_01)
            || abs(Double(firstGainLUT.red.last ?? 0) - 0.64) >= 0.000_01
            || abs(Double(compoundedGainLUT.red.last ?? 0) - 0.4096) >= 0.000_01 {
            failures.append(L10n.text("self_test.lut"))
        }

        // This is the reported path: global gain 0.20 must always compose
        // from the same clean baseline, never from a prior recovery result.
        var globalReducedGain = ColorAdjustments.neutral
        globalReducedGain.gain = 0.2
        let firstGlobalGainLUT = DisplayLUT(base: lut, adjustments: globalReducedGain)
        for _ in 0 ..< 12 {
            let recoveredLUT = DisplayLUT(base: lut, adjustments: globalReducedGain)
            if !recoveredLUT.approximatelyMatches(firstGlobalGainLUT, tolerance: 0.000_01) {
                failures.append(L10n.text("self_test.lut"))
                break
            }
        }
        let compoundedGlobalGainLUT = DisplayLUT(base: firstGlobalGainLUT, adjustments: globalReducedGain)
        if abs(Double(firstGlobalGainLUT.red.last ?? 0) - 0.64) >= 0.000_01
            || abs(Double(compoundedGlobalGainLUT.red.last ?? 0) - 0.4096) >= 0.000_01 {
            failures.append(L10n.text("self_test.lut"))
        }

        // The table this process installed can be replaced by WindowServer or
        // by another process. Drift detection must notice a replacement while
        // accepting the resampled copy macOS may install for the same curve.
        let integrityBase = DisplayLUT(adjustments: .neutral, count: 1024)
        let ownedLUT = DisplayLUT(base: integrityBase, adjustments: reducedGain)
        let resampledOwnedLUT = DisplayLUT(
            base: DisplayLUT(adjustments: .neutral, count: 512),
            adjustments: reducedGain
        )
        if !DisplayLUTIntegrity.driftedDisplayKeys(
            expected: ["a": ownedLUT],
            installed: ["a": ownedLUT],
            presentKeys: ["a"]
        ).isEmpty
            || !DisplayLUTIntegrity.driftedDisplayKeys(
                expected: ["a": ownedLUT],
                installed: ["a": resampledOwnedLUT],
                presentKeys: ["a"]
            ).isEmpty
            || DisplayLUTIntegrity.driftedDisplayKeys(
                expected: ["a": ownedLUT],
                installed: ["a": integrityBase],
                presentKeys: ["a"]
            ) != ["a"]
            || DisplayLUTIntegrity.driftedDisplayKeys(
                expected: ["a": ownedLUT],
                installed: [:],
                presentKeys: ["a"]
            ) != ["a"]
            || DisplayLUTIntegrity.driftedDisplayKeys(
                expected: ["a": ownedLUT, "b": ownedLUT],
                installed: ["a": integrityBase, "b": ownedLUT],
                presentKeys: ["a", "b"]
            ) != ["a"]
            // A disconnected display keeps its saved table but has nothing to
            // verify; it must not be reported as drift and must not trigger a
            // rewrite of the displays that are still present.
            || !DisplayLUTIntegrity.driftedDisplayKeys(
                expected: ["a": ownedLUT, "gone": ownedLUT],
                installed: ["a": ownedLUT],
                presentKeys: ["a"]
            ).isEmpty {
            failures.append(L10n.text("self_test.lut"))
        }
        // An unchanged drift set must be retried with a growing interval so a
        // sleeping or unplugged display cannot cause a write every pass.
        let backoffStart = Date()
        var backoff = DisplayLUTIntegrity.DriftRepairBackoff()
        if !backoff.shouldAttempt(signature: ["a"], now: backoffStart) {
            failures.append(L10n.text("self_test.lut"))
        }
        backoff.recordAttempt(signature: ["a"], now: backoffStart)
        if backoff.shouldAttempt(signature: ["a"], now: backoffStart.addingTimeInterval(1))
            || !backoff.shouldAttempt(signature: ["a"], now: backoffStart.addingTimeInterval(31))
            || !backoff.shouldAttempt(
                signature: ["a", "b"],
                now: backoffStart.addingTimeInterval(1)
            )
            || backoff.currentInterval > DisplayLUTIntegrity.DriftRepairBackoff.maximumInterval {
            failures.append(L10n.text("self_test.lut"))
        }
        backoff.recordAttempt(signature: ["a"], now: backoffStart.addingTimeInterval(31))
        if backoff.shouldAttempt(signature: ["a"], now: backoffStart.addingTimeInterval(90))
            || !backoff.shouldAttempt(signature: ["a"], now: backoffStart.addingTimeInterval(91)) {
            failures.append(L10n.text("self_test.lut"))
        }
        for step in 2 ... 6 {
            backoff.recordAttempt(
                signature: ["a"],
                now: backoffStart.addingTimeInterval(Double(step) * 1_000)
            )
        }
        if backoff.currentInterval != DisplayLUTIntegrity.DriftRepairBackoff.maximumInterval {
            failures.append(L10n.text("self_test.lut"))
        }
        backoff.reset()
        if !backoff.shouldAttempt(signature: ["a"], now: backoffStart) {
            failures.append(L10n.text("self_test.lut"))
        }
        let verificationDelays = DisplayLUTIntegrity.startupVerificationDelays
        var delaysAscend = !verificationDelays.isEmpty
        for (previous, next) in zip(verificationDelays, verificationDelays.dropFirst())
            where previous >= next {
            delaysAscend = false
        }
        if !delaysAscend
            || (verificationDelays.last ?? 0) > 30
            || DisplayLUTIntegrity.steadyVerificationInterval <= 0
            || DisplayLUTIntegrity.steadyVerificationInterval > 15 {
            failures.append(L10n.text("self_test.lut"))
        }

        // The clean baseline must survive an unclean process restart and be
        // removed only after a successful restore.
        let suiteName = "BetaDisplay.self-test.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suiteName) {
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let displayKey = "self-test-display"
            let writer = DisplayLUTRecoveryStore(defaults: defaults)
            writer.recordBaseline(lut, forDisplayKey: displayKey)
            let reader = DisplayLUTRecoveryStore(defaults: defaults)
            if reader.baseline(forDisplayKey: displayKey)?.approximatelyMatches(
                lut,
                tolerance: 0.000_01
            ) != true {
                failures.append(L10n.text("self_test.lut"))
            }
            reader.removeBaseline(forDisplayKey: displayKey)
            if DisplayLUTRecoveryStore(defaults: defaults)
                .baseline(forDisplayKey: displayKey) != nil {
                failures.append(L10n.text("self_test.lut"))
            }
        } else {
            failures.append(L10n.text("self_test.lut"))
        }
        let group = DisplayGroup(name: "self-test", displayKeys: ["one", "two"])
        if group.name != "self-test" || group.displayKeys != ["one", "two"] {
            failures.append(L10n.text("self_test.group"))
        }
        if !AppMetadata.isVersion("v1.1.2", newerThan: "1.1.1")
            || AppMetadata.isVersion("v1.1.2", newerThan: "1.1.2")
            || AppMetadata.isVersion("v1.1.1", newerThan: "1.1.2") {
            failures.append(L10n.text("self_test.version_comparison"))
        }
        // The instance lock must distinguish "another instance" from "no
        // usable lock location": the latter still starts the app, and the
        // activation request file must survive a second launch that races the
        // first launch's observer registration.
        let lockDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("BetaDisplay.self-test-lock-\(UUID().uuidString)", isDirectory: true)
        if (try? FileManager.default.createDirectory(
            at: lockDirectory,
            withIntermediateDirectories: true
        )) != nil {
            defer { try? FileManager.default.removeItem(at: lockDirectory) }
            let lockURL = lockDirectory.appendingPathComponent("instance.lock")
            let firstClaim = SingleInstanceController()
            let secondClaim = SingleInstanceController()
            let standaloneClaim = SingleInstanceController()
            let firstResult = firstClaim.claim(lockURLs: [lockURL])
            let secondResult = secondClaim.claim(lockURLs: [lockURL])
            let holdingResult = firstClaim.claim(lockURLs: nil)
            firstClaim.release()
            let reclaimedResult = secondClaim.claim(lockURLs: [lockURL])
            secondClaim.release()
            var unavailableReason: String?
            if case let .unavailable(reason) = standaloneClaim.claim(lockURLs: nil) {
                unavailableReason = reason
            }
            if firstResult != .acquired
                || secondResult != .existingInstance
                || holdingResult != .acquired
                || reclaimedResult != .acquired
                || (unavailableReason?.isEmpty ?? true) {
                failures.append(L10n.text("self_test.instance_lock"))
                standaloneClaim.release()
            }
            let requestURL = lockDirectory.appendingPathComponent("activate.request")
            if SingleInstanceController.consumeActivationRequest(at: requestURL)
                || !SingleInstanceController.writeActivationRequest(to: requestURL)
                || !SingleInstanceController.consumeActivationRequest(at: requestURL)
                || SingleInstanceController.consumeActivationRequest(at: requestURL) {
                failures.append(L10n.text("self_test.instance_lock"))
            }
        } else {
            failures.append(L10n.text("self_test.instance_lock"))
        }
        let resolutionChange: CGDisplayChangeSummaryFlags = [
            .setModeFlag,
            .desktopShapeChangedFlag
        ]
        let mainDisplayChange: CGDisplayChangeSummaryFlags = [.setMainFlag]
        if !DisplayRecoveryCoordinator.shouldRecover(for: resolutionChange)
            || DisplayRecoveryCoordinator.shouldRestoreTopology(for: resolutionChange)
            // A topology event must still be scheduled while a previous
            // recovery settles; dropping it would lose the saved layout for a
            // display that appeared during that window.
            || !DisplayRecoveryCoordinator.shouldScheduleRecovery(for: .setModeFlag)
            || !DisplayRecoveryCoordinator.shouldScheduleRecovery(for: .addFlag)
            || DisplayRecoveryCoordinator.shouldScheduleRecovery(for: .beginConfigurationFlag)
            || !DisplayRecoveryCoordinator.shouldRecover(for: mainDisplayChange)
            || DisplayRecoveryCoordinator.shouldRestoreTopology(for: mainDisplayChange)
            || !DisplayRecoveryCoordinator.shouldRecover(for: .addFlag)
            || !DisplayRecoveryCoordinator.shouldRestoreTopology(for: .addFlag) {
            failures.append(L10n.text("self_test.resolution_not_locked"))
        }
        return failures
    }
}
