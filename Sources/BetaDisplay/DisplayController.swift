import AppKit
import CoreGraphics
import Foundation

@MainActor
final class DisplayController {
    enum ImageStatusRegion {
        case adjustments
        case channels
        case recovery
    }

    private let configurationStore: DisplayConfigurationStore
    private(set) var displays: [DisplayDescriptor] = []
    var selectedDisplayID: CGDirectDisplayID?
    private var adjustmentsByDisplay: [String: ColorAdjustments] = [:]
    var adjustments: ColorAdjustments {
        guard let selectedDisplayID else { return .neutral }
        return (adjustmentsByDisplay[DisplayIdentity.sessionKey(for: selectedDisplayID)] ?? .neutral)
            .sanitizedForApplication()
    }
    private(set) var imageStatusMessage = ""
    private(set) var imageStatusRegion = ImageStatusRegion.adjustments
    var onStateChanged: (() -> Void)?
    private var sessionOriginalLUTs: [String: DisplayLUT] = [:]
    private var workingBaseLUTs: [String: DisplayLUT] = [:]
    /// The last transfer table submitted by this process. Wake notifications
    /// can arrive again after a successful restore; retaining this lets us
    /// distinguish an app-owned table from a new ColorSync baseline.
    private var lastAppliedLUTs: [String: DisplayLUT] = [:]
    private var applyWorkItem: DispatchWorkItem?
    private let hardwareBrightness = HardwareBrightnessController()
    private(set) var hardwareBrightnessValue: Double?

    init(configurationStore: DisplayConfigurationStore) {
        self.configurationStore = configurationStore
        refreshDisplays()
        selectedDisplayID = CGMainDisplayID()
        refreshHardwareBrightness()
    }

    var selectedDisplay: DisplayDescriptor? {
        displays.first { $0.id == selectedDisplayID }
    }

    func refreshDisplays() {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            displays = []
            selectedDisplayID = nil
            publishState()
            return
        }
        var ids = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            publishState()
            return
        }
        let screenNames: [CGDirectDisplayID: String] = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (CGDirectDisplayID(number.uint32Value), screen.localizedName)
        })
        displays = ids.prefix(Int(count)).map { id in
            DisplayDescriptor(
                id: id,
                name: screenNames[id] ?? (CGDisplayIsBuiltin(id) != 0
                    ? L10n.text("display.built_in_display")
                    : L10n.text("display.external_display")),
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                gammaCapacity: Int(CGDisplayGammaTableCapacity(id))
            )
        }
        let activeSessionKeys = Set(displays.map { DisplayIdentity.sessionKey(for: $0.id) })
        adjustmentsByDisplay = adjustmentsByDisplay.filter { activeSessionKeys.contains($0.key) }
        workingBaseLUTs = workingBaseLUTs.filter { activeSessionKeys.contains($0.key) }
        lastAppliedLUTs = lastAppliedLUTs.filter { activeSessionKeys.contains($0.key) }
        if let selectedDisplayID, displays.contains(where: { $0.id == selectedDisplayID }) {
            publishState()
            return
        }
        selectedDisplayID = displays.first?.id
        imageStatusMessage = ""
        publishState()
    }

    func selectDisplay(_ id: CGDirectDisplayID) {
        selectedDisplayID = id
        imageStatusMessage = ""
        refreshHardwareBrightness()
        publishState()
    }

    func update(_ keyPath: WritableKeyPath<ColorAdjustments, Double>, to value: Double) {
        guard let selectedDisplayID else { return }
        let sessionKey = DisplayIdentity.sessionKey(for: selectedDisplayID)
        var values = adjustmentsByDisplay[sessionKey] ?? .neutral
        values[keyPath: keyPath] = value
        let safetyAdjusted = values.enforceVisibleRGBGain(
            preferredChannel: rgbGainChannel(for: keyPath)
        )
        imageStatusRegion = rgbControlKeyPaths.contains(keyPath) ? .channels : .adjustments
        adjustmentsByDisplay[sessionKey] = values
        configurationStore.update(for: selectedDisplayID) { $0.adjustments = values }
        applyCurrentAdjustments(safetyAdjusted: safetyAdjusted)
    }

    func applyCurrentAdjustments(
        safetyAdjusted: Bool = false,
        reportsStatus: Bool = true
    ) {
        applyWorkItem?.cancel()
        guard let displayID = selectedDisplayID else {
            if reportsStatus {
                imageStatusMessage = L10n.text("status.display_lut_unsupported")
                publishState()
            }
            return
        }
        // Coalesce high-frequency slider actions before submitting a new LUT
        // to WindowServer. The work item is created on the main actor, so it
        // has no cross-thread UI or display-state access.
        let values = adjustments
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            _ = self.applyImmediately(
                displayID: displayID,
                adjustments: values,
                reportStatus: reportsStatus
            )
            if safetyAdjusted, reportsStatus {
                self.imageStatusMessage = L10n.text("status.display_safeguarded")
                self.publishState()
            }
        }
        applyWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012, execute: work)
    }

    /// Applies one set of RGB transfer-table controls to every target display.
    /// Each display keeps its own captured ColorSync baseline LUT.
    @discardableResult
    func apply(adjustments: ColorAdjustments, to displayIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID: Bool] {
        var results: [CGDirectDisplayID: Bool] = [:]
        let safeAdjustments = adjustments.sanitizedForApplication()
        for displayID in displayIDs {
            adjustmentsByDisplay[DisplayIdentity.sessionKey(for: displayID)] = safeAdjustments
            configurationStore.update(for: displayID) { $0.adjustments = safeAdjustments }
            results[displayID] = applyImmediately(displayID: displayID, adjustments: safeAdjustments, reportStatus: false)
        }
        publishState()
        return results
    }

    func resetSelectedDisplay() {
        guard let selectedDisplayID else { return }
        imageStatusRegion = .recovery
        adjustmentsByDisplay[DisplayIdentity.sessionKey(for: selectedDisplayID)] = .neutral
        configurationStore.update(for: selectedDisplayID) { $0.adjustments = .neutral }
        applyCurrentAdjustments()
    }

    var supportsHardwareBrightness: Bool {
        hardwareBrightness.supports(selectedDisplayID)
    }

    @discardableResult
    func refreshHardwareBrightness() -> Bool {
        let currentValue = hardwareBrightness.value(for: selectedDisplayID)
        guard hardwareBrightnessDidChange(from: hardwareBrightnessValue, to: currentValue) else {
            return false
        }
        hardwareBrightnessValue = currentValue
        publishState()
        return true
    }

    func setHardwareBrightness(_ value: Double) {
        guard hardwareBrightness.setValue(value, for: selectedDisplayID) else {
            publishState()
            return
        }
        hardwareBrightnessValue = value.clamped(to: 0 ... 1)
        publishState()
    }

    private func hardwareBrightnessDidChange(from oldValue: Double?, to newValue: Double?) -> Bool {
        switch (oldValue, newValue) {
        case (nil, nil):
            false
        case let (oldValue?, newValue?):
            abs(oldValue - newValue) > 0.000_5
        default:
            true
        }
    }

    /// Restores only the display tables captured by this process. Used on quit
    /// so this app does not reset color tables managed by another app.
    func captureSessionState() {
        for display in displays {
            let sessionKey = DisplayIdentity.sessionKey(for: display.id)
            if sessionOriginalLUTs[sessionKey] == nil,
               let table = readCurrentLUT(for: display.id, reportsErrors: false) {
                sessionOriginalLUTs[sessionKey] = table
                workingBaseLUTs[sessionKey] = table
            }
        }
    }

    func rebaseWorkingLUTs() {
        workingBaseLUTs.removeAll()
        lastAppliedLUTs.removeAll()
        for display in displays {
            if let table = readCurrentLUT(for: display.id, reportsErrors: false) {
                workingBaseLUTs[DisplayIdentity.sessionKey(for: display.id)] = table
            }
        }
    }

    func rebaseSelectedDisplayAndApply() {
        guard let selectedDisplayID else { return }
        let sessionKey = DisplayIdentity.sessionKey(for: selectedDisplayID)
        lastAppliedLUTs[sessionKey] = nil
        if let table = readCurrentLUT(for: selectedDisplayID, reportsErrors: false) {
            workingBaseLUTs[sessionKey] = table
        }
        applyCurrentAdjustments(reportsStatus: false)
    }

    func applySavedAdjustments() {
        for display in displays {
            guard let saved = configurationStore.configuration(for: display.id) else { continue }
            if let adjustments = saved.adjustments {
                let safeAdjustments = adjustments.sanitizedForApplication()
                adjustmentsByDisplay[DisplayIdentity.sessionKey(for: display.id)] = safeAdjustments
                if safeAdjustments != adjustments {
                    configurationStore.update(for: display.id) { $0.adjustments = safeAdjustments }
                }
                _ = applyImmediately(
                    displayID: display.id,
                    adjustments: safeAdjustments,
                    reportStatus: false
                )
            }
        }
        publishState()
    }

    /// Rewrites the saved color tables after the system has supplied a fresh
    /// ColorSync baseline. A repeated wake notification is ignored when the
    /// current table is still the result of this process's previous restore;
    /// otherwise the new system table becomes the working baseline.
    @discardableResult
    func rebaseAndApplySavedAdjustmentsAfterSystemChange() -> Bool {
        var currentLUTs: [String: DisplayLUT] = [:]
        var alreadyApplied = Set<String>()

        // A wake can emit more than one notification. If the current table is
        // still the one submitted by the previous recovery pass, retaining the
        // original working base is essential: rebasing from this table would
        // apply the selected gain a second time.
        for display in displays {
            let sessionKey = DisplayIdentity.sessionKey(for: display.id)
            guard let current = readCurrentLUT(for: display.id, reportsErrors: false) else {
                continue
            }
            currentLUTs[sessionKey] = current
            if let lastApplied = lastAppliedLUTs[sessionKey],
               lastApplied.approximatelyMatches(current) {
                alreadyApplied.insert(sessionKey)
                continue
            }
            workingBaseLUTs[sessionKey] = current
            lastAppliedLUTs[sessionKey] = nil
        }

        var restoredAny = false
        for display in displays {
            guard let saved = configurationStore.configuration(for: display.id)?.adjustments else { continue }
            let sessionKey = DisplayIdentity.sessionKey(for: display.id)
            let safeAdjustments = saved.sanitizedForApplication()
            adjustmentsByDisplay[sessionKey] = safeAdjustments
            if safeAdjustments != saved {
                configurationStore.update(for: display.id) { $0.adjustments = safeAdjustments }
            }
            guard currentLUTs[sessionKey] != nil,
                  !alreadyApplied.contains(sessionKey)
            else {
                continue
            }
            if applyImmediately(displayID: display.id, adjustments: safeAdjustments, reportStatus: false) {
                restoredAny = true
            }
        }
        publishState()
        return restoredAny
    }

    func restoreSessionState() {
        applyWorkItem?.cancel()
        let activeDisplays = DisplayIdentity.activeDisplayIDsBySessionKey()
        for (sessionKey, lut) in sessionOriginalLUTs {
            guard let displayID = activeDisplays[sessionKey] else { continue }
            _ = lut.red.withUnsafeBufferPointer { red in
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
    }

    private func applyImmediately(
        displayID: CGDirectDisplayID,
        adjustments: ColorAdjustments,
        reportStatus: Bool
    ) -> Bool {
        guard let base = workingBaseLUT(for: displayID, reportsErrors: reportStatus) else {
            return false
        }
        let lut = DisplayLUT(base: base, adjustments: adjustments)
        let result = lut.red.withUnsafeBufferPointer { red in
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
        guard result == .success else {
            if reportStatus {
                imageStatusMessage = L10n.text("status.cannot_apply_lut", result.rawValue)
                publishState()
            }
            return false
        }
        lastAppliedLUTs[DisplayIdentity.sessionKey(for: displayID)] = lut
        if reportStatus {
            imageStatusMessage = adjustments.isNeutral
                ? L10n.text("status.display_lut_restored")
                : L10n.text(
                    "status.adjustments_applied",
                    selectedDisplay?.name ?? L10n.text("nav.displays")
                )
            publishState()
        }
        return true
    }

    private func rgbGainChannel(
        for keyPath: WritableKeyPath<ColorAdjustments, Double>
    ) -> ColorChannel? {
        if keyPath == \ColorAdjustments.redGain { return .red }
        if keyPath == \ColorAdjustments.greenGain { return .green }
        if keyPath == \ColorAdjustments.blueGain { return .blue }
        return nil
    }

    private var rgbControlKeyPaths: [WritableKeyPath<ColorAdjustments, Double>] {
        [
            \ColorAdjustments.redGamma,
            \ColorAdjustments.greenGamma,
            \ColorAdjustments.blueGamma,
            \ColorAdjustments.redGain,
            \ColorAdjustments.greenGain,
            \ColorAdjustments.blueGain
        ]
    }

    private func workingBaseLUT(
        for displayID: CGDirectDisplayID,
        reportsErrors: Bool
    ) -> DisplayLUT? {
        let sessionKey = DisplayIdentity.sessionKey(for: displayID)
        if let known = workingBaseLUTs[sessionKey] { return known }
        guard let table = readCurrentLUT(for: displayID, reportsErrors: reportsErrors) else {
            return nil
        }
        workingBaseLUTs[sessionKey] = table
        if sessionOriginalLUTs[sessionKey] == nil { sessionOriginalLUTs[sessionKey] = table }
        return table
    }

    private func readCurrentLUT(
        for displayID: CGDirectDisplayID,
        reportsErrors: Bool
    ) -> DisplayLUT? {
        let capacity = Int(CGDisplayGammaTableCapacity(displayID))
        guard capacity >= 2 else {
            if reportsErrors {
                imageStatusMessage = L10n.text("status.lut_unavailable")
                publishState()
            }
            return nil
        }
        var red = Array(repeating: CGGammaValue.zero, count: capacity)
        var green = Array(repeating: CGGammaValue.zero, count: capacity)
        var blue = Array(repeating: CGGammaValue.zero, count: capacity)
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
        guard result == .success, sampleCount >= 2 else {
            if reportsErrors {
                imageStatusMessage = L10n.text("status.cannot_read_lut", result.rawValue)
                publishState()
            }
            return nil
        }
        let count = Int(sampleCount)
        let table = DisplayLUT(
            red: Array(red.prefix(count)),
            green: Array(green.prefix(count)),
            blue: Array(blue.prefix(count))
        )
        return table
    }

    private func publishState() {
        onStateChanged?()
    }

}

struct DisplayDescriptor: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    let gammaCapacity: Int

    var origin: CGPoint {
        CGDisplayBounds(id).origin
    }
}
