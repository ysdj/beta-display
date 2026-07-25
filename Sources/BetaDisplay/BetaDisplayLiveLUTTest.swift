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
        defer {
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
        let coordinator = DisplayRecoveryCoordinator { _ in
            recoveryPasses += 1
            firstController.refreshDisplays()
            _ = firstController.applySavedAdjustmentsAfterSystemChange()
        }
        coordinator.start()
        for _ in 0 ..< 20 {
            coordinator.handleDisplayReconfiguration(.setModeFlag)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(2.8))
        coordinator.stop()
        if recoveryPasses != 2 {
            failures.append("notification storm produced \(recoveryPasses) recovery passes instead of 2")
        }
        verify(
            stage: "notification storm",
            displayID: displayID,
            expected: expected,
            failures: &failures
        )

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
