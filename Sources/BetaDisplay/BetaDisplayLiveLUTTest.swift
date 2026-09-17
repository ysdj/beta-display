import CoreGraphics
import Foundation

/// Opt-in integration coverage for the real WindowServer LUT path. Normal app
/// launches never execute this code. The caller must ensure no other display
/// utility is actively writing transfer tables during the test.
@MainActor
enum BetaDisplayLiveLUTTest {
    private static let matchTolerance = 0.002

    static func run() -> [String] {
        let configurationStore = DisplayConfigurationStore()
        let firstController = DisplayController(configurationStore: configurationStore)
        firstController.captureSessionState()
        guard let displayID = firstController.selectedDisplayID,
              let baseline = readCurrentLUT(for: displayID),
              let saved = configurationStore.configuration(for: displayID)?.adjustments
        else {
            return ["The main display, its LUT, or its saved adjustments are unavailable"]
        }

        let adjustments = saved.sanitizedForApplication()
        let expected = DisplayLUT(base: baseline, adjustments: adjustments)
        var failures: [String] = []
        var restoringController: DisplayController = firstController
        let originalMode = CGDisplayCopyDisplayMode(displayID)
        var coordinator: DisplayRecoveryCoordinator?
        defer {
            coordinator?.stop()
            if let originalMode {
                _ = CGDisplaySetDisplayMode(displayID, originalMode, nil)
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            }
            restoringController.restoreSessionState()
            if let restored = readCurrentLUT(for: displayID),
               !restored.approximatelyMatches(baseline, tolerance: matchTolerance) {
                print("FAIL: The test could not restore the original LUT")
            }
        }

        printSummary("baseline", lut: baseline)
        firstController.applySavedAdjustments()
        verify(
            stage: "initial application",
            displayID: displayID,
            expected: expected,
            failures: &failures
        )

        for iteration in 1 ... 12 {
            _ = firstController.applySavedAdjustmentsAfterSystemChange()
            verify(
                stage: "recovery \(iteration)",
                displayID: displayID,
                expected: expected,
                failures: &failures
            )
        }

        for iteration in 1 ... 4 {
            _ = firstController.performSelectedDisplayColorProfileChange { false }
            verify(
                stage: "no-op profile change \(iteration)",
                displayID: displayID,
                expected: expected,
                failures: &failures
            )
        }

        var recoveryPasses = 0
        var repairPasses = 0
        coordinator = DisplayRecoveryCoordinator(
            recover: { _ in
                recoveryPasses += 1
                firstController.refreshDisplays()
                _ = firstController.applySavedAdjustmentsAfterSystemChange()
            },
            verify: {
                let repaired = firstController.repairDriftedAdjustments()
                if repaired { repairPasses += 1 }
                return repaired
            }
        )

        guard let coordinator else {
            failures.append("could not create the display recovery coordinator")
            return failures
        }
        coordinator.start()
        coordinator.startIntegrityWatch()

        if let originalMode,
           let alternateMode = alternateMode(for: displayID, excluding: originalMode) {
            let startPasses = recoveryPasses
            let modeController = DisplayModeController()
            modeController.onModeApplied = {
                coordinator.scheduleApplicationEffectsRecovery()
            }
            modeController.refresh(for: displayID)
            let alternateModeID = DisplayModeDescriptor(mode: alternateMode).id
            modeController.apply(
                modeID: alternateModeID,
                to: displayID
            )
            if modeController.currentModeID != alternateModeID {
                failures.append("could not switch to an alternate mode for the live recovery test")
            } else {
                RunLoop.current.run(until: Date().addingTimeInterval(6.2))
                if recoveryPasses - startPasses < 4 {
                    failures.append(
                        "mode transition produced only \(recoveryPasses - startPasses) recovery passes"
                    )
                }
                verify(
                    stage: "display-mode recovery",
                    displayID: displayID,
                    expected: expected,
                    failures: &failures
                )
                _ = CGDisplaySetDisplayMode(displayID, originalMode, nil)
                coordinator.scheduleApplicationEffectsRecovery()
                RunLoop.current.run(until: Date().addingTimeInterval(6.2))
                verify(
                    stage: "display-mode restore recovery",
                    displayID: displayID,
                    expected: expected,
                    failures: &failures
                )
            }
        }

        if write(baseline, to: displayID) != .success {
            failures.append("could not simulate a power-source LUT reset")
        }
        for _ in 0 ..< 20 {
            coordinator.handlePowerSourceChange()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(6.2))
        if recoveryPasses < 4 {
            failures.append("power-source transition produced only \(recoveryPasses) recovery passes")
        }
        verify(
            stage: "power-source recovery",
            displayID: displayID,
            expected: expected,
            failures: &failures
        )

        // A settling login session (or any other writer) can replace the
        // transfer table without delivering a single notification. The
        // integrity watch must notice and repair that on its own. This runs
        // while the coordinator is still started.
        let repairsBeforeSilentReset = repairPasses
        if write(baseline, to: displayID) != .success {
            failures.append("could not simulate a silent transfer-table reset")
        }
        let silentResetDeadline = Date().addingTimeInterval(
            DisplayLUTIntegrity.steadyVerificationInterval + 3
        )
        while Date() < silentResetDeadline {
            if let installed = readCurrentLUT(for: displayID),
               installed.approximatelyMatches(expected, tolerance: matchTolerance) {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if repairPasses == repairsBeforeSilentReset {
            failures.append("the integrity watch did not repair a silent transfer-table reset")
        }
        verify(
            stage: "silent reset recovery",
            displayID: displayID,
            expected: expected,
            failures: &failures
        )
        coordinator.stop()

        // A second controller models a fresh process after an unclean exit.
        // It must load the persisted clean baseline rather than the currently
        // installed, already-adjusted LUT.
        let relaunchedController = DisplayController(configurationStore: configurationStore)
        relaunchedController.captureSessionState()
        relaunchedController.applySavedAdjustments()
        restoringController = relaunchedController
        verify(
            stage: "unclean-exit relaunch",
            displayID: displayID,
            expected: expected,
            failures: &failures
        )

        relaunchedController.restoreSessionState()
        guard let restored = readCurrentLUT(for: displayID) else {
            failures.append("restored LUT could not be read")
            return failures
        }
        printSummary("restored", lut: restored)
        if !restored.approximatelyMatches(baseline, tolerance: matchTolerance) {
            failures.append("normal exit did not restore the original LUT")
        }
        return failures
    }

    private static func alternateMode(
        for displayID: CGDirectDisplayID,
        excluding original: CGDisplayMode
    ) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
        return modes.first {
            $0.width != original.width
                || $0.height != original.height
                || $0.pixelWidth != original.pixelWidth
                || $0.pixelHeight != original.pixelHeight
                || abs($0.refreshRate - original.refreshRate) > 0.01
                || $0.ioDisplayModeID != original.ioDisplayModeID
        }
    }

    private static func write(_ lut: DisplayLUT, to displayID: CGDirectDisplayID) -> CGError {
        lut.red.withUnsafeBufferPointer { red in
            lut.green.withUnsafeBufferPointer { green in
                lut.blue.withUnsafeBufferPointer { blue in
                    CGSetDisplayTransferByTable(
                        displayID,
                        UInt32(lut.red.count),
                        red.baseAddress,
                        green.baseAddress,
                        blue.baseAddress
                    )
                }
            }
        }
    }

    private static func verify(
        stage: String,
        displayID: CGDirectDisplayID,
        expected: DisplayLUT,
        failures: inout [String]
    ) {
        guard let actual = readCurrentLUT(for: displayID) else {
            failures.append("\(stage): LUT could not be read")
            return
        }
        printSummary(stage, lut: actual)
        if !actual.approximatelyMatches(expected, tolerance: matchTolerance) {
            failures.append("\(stage): LUT drifted from the single-application target")
        }
    }

    private static func printSummary(_ stage: String, lut: DisplayLUT) {
        let red = Double(lut.red.last ?? 0)
        let green = Double(lut.green.last ?? 0)
        let blue = Double(lut.blue.last ?? 0)
        print(String(format: "%@: RGB max %.6f %.6f %.6f", stage, red, green, blue))
    }

    private static func readCurrentLUT(for displayID: CGDirectDisplayID) -> DisplayLUT? {
        let capacity = Int(CGDisplayGammaTableCapacity(displayID))
        guard capacity >= 2 else { return nil }
        var red = Array(repeating: CGGammaValue.zero, count: capacity)
        var green = red
        var blue = red
        var sampleCount: UInt32 = 0
        let result = red.withUnsafeMutableBufferPointer { redBuffer in
            green.withUnsafeMutableBufferPointer { greenBuffer in
                blue.withUnsafeMutableBufferPointer { blueBuffer in
                    CGGetDisplayTransferByTable(
                        displayID,
                        UInt32(capacity),
                        redBuffer.baseAddress,
                        greenBuffer.baseAddress,
                        blueBuffer.baseAddress,
                        &sampleCount
                    )
                }
            }
        }
        guard result == .success, sampleCount >= 2 else { return nil }
        let count = Int(sampleCount)
        return DisplayLUT(
            red: Array(red.prefix(count)),
            green: Array(green.prefix(count)),
            blue: Array(blue.prefix(count))
        )
    }
}
