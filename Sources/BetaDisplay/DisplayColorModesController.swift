import Foundation
import Darwin

/// Reads and updates the macOS Night Shift and True Tone switches through the
/// private CoreBrightness framework. The framework is loaded dynamically so
/// unsupported macOS versions degrade to disabled controls.
@MainActor
final class DisplayColorModesController {
    struct State: Equatable {
        var nightShiftSupported = false
        var nightShiftEnabled: Bool?
        var nightShiftStrength: Double?
        var trueToneSupported = false
        var trueToneEnabled: Bool?
    }

    private struct BlueLightTime {
        var hour: Int32 = 0
        var minute: Int32 = 0
    }

    private struct BlueLightSchedule {
        var from: BlueLightTime = .init()
        var to: BlueLightTime = .init()
    }

    private struct BlueLightStatus {
        var active: UInt8 = 0
        var enabled: UInt8 = 0
        var sunsetToSunrise: UInt8 = 0
        var mode: Int32 = 0
        var schedule: BlueLightSchedule = .init()
        var disableFlags: UInt64 = 0
        var available: UInt8 = 0
    }

    private typealias NoArgumentBool = @convention(c) (AnyObject, Selector) -> Bool
    private typealias BoolArgument = @convention(c) (AnyObject, Selector, Bool) -> Bool
    private typealias FloatGetter = @convention(c) (
        AnyObject,
        Selector,
        UnsafeMutablePointer<Float>
    ) -> Bool
    private typealias FloatCommit = @convention(c) (AnyObject, Selector, Float, Bool) -> Bool
    private typealias BlueLightStatusGetter = @convention(c) (
        AnyObject,
        Selector,
        UnsafeMutableRawPointer
    ) -> Bool

    private let coreBrightnessHandle: UnsafeMutableRawPointer?
    private let blueLightClient: NSObject?
    private let trueToneClient: NSObject?
    private(set) var state = State()
    private(set) var actionError = ""
    private var initialState: State?
    private var didModifyNightShift = false
    private var didModifyNightShiftStrength = false
    private var didModifyTrueTone = false
    var onStateChanged: (() -> Void)?

    init() {
        let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
        coreBrightnessHandle = dlopen(path, RTLD_LAZY | RTLD_LOCAL)
        if coreBrightnessHandle != nil,
           let blueLightClass = NSClassFromString("CBBlueLightClient") as? NSObject.Type {
            blueLightClient = blueLightClass.init()
        } else {
            blueLightClient = nil
        }
        if coreBrightnessHandle != nil,
           let trueToneClass = NSClassFromString("CBTrueToneClient") as? NSObject.Type {
            trueToneClient = trueToneClass.init()
        } else {
            trueToneClient = nil
        }
    }

    /// Captures the system-wide color-mode state that existed before Beta
    /// Display changes it. Night Shift and True Tone are macOS settings, not
    /// app preferences, so their baseline stays in memory for this process.
    func captureInitialState() {
        guard initialState == nil else { return }
        let current = readState()
        initialState = current
        state = current
    }

    var statusText: String {
        var unavailable: [String] = []
        if !state.nightShiftSupported {
            unavailable.append(L10n.text("system_modes.night_shift_unavailable"))
        }
        if !state.trueToneSupported {
            unavailable.append(L10n.text("system_modes.true_tone_unavailable"))
        }
        let messages = ([actionError] + unavailable)
            .filter { !$0.isEmpty }
            .joined(separator: L10n.text("system_modes.status_separator"))
        return messages.isEmpty ? L10n.text("system_modes.synced") : messages
    }

    @discardableResult
    func refresh() -> Bool {
        let next = readState()
        guard next != state else { return false }
        state = next
        onStateChanged?()
        return true
    }

    @discardableResult
    func setNightShift(_ enabled: Bool) -> Bool {
        captureInitialState()
        guard let client = blueLightClient,
              state.nightShiftSupported
        else {
            actionError = L10n.text("system_modes.night_shift_unavailable")
            onStateChanged?()
            return false
        }

        guard callBool(client, selector: "setEnabled:", value: enabled) else {
            actionError = L10n.text("system_modes.night_shift_set_failed")
            onStateChanged?()
            return false
        }
        actionError = ""
        didModifyNightShift = initialState?.nightShiftEnabled != enabled
        if !refresh() { onStateChanged?() }
        return true
    }

    @discardableResult
    func setNightShiftStrength(_ strength: Double) -> Bool {
        captureInitialState()
        guard let client = blueLightClient, state.nightShiftSupported else {
            actionError = L10n.text("system_modes.night_shift_unavailable")
            onStateChanged?()
            return false
        }
        let selector = NSSelectorFromString("setStrength:commit:")
        guard client.responds(to: selector),
              let implementation = client.method(for: selector)
        else {
            actionError = L10n.text("system_modes.night_shift_strength_failed")
            onStateChanged?()
            return false
        }
        let setter = unsafeBitCast(implementation, to: FloatCommit.self)
        guard setter(client, selector, Float(strength.clamped(to: 0 ... 1)), true) else {
            actionError = L10n.text("system_modes.night_shift_strength_failed")
            onStateChanged?()
            return false
        }
        actionError = ""
        didModifyNightShiftStrength = initialState.map {
            guard let initialStrength = $0.nightShiftStrength else { return false }
            return abs(initialStrength - strength.clamped(to: 0 ... 1)) > 0.000_5
        } ?? false
        if !refresh() { onStateChanged?() }
        return true
    }

    @discardableResult
    func setTrueTone(_ enabled: Bool) -> Bool {
        captureInitialState()
        guard let client = trueToneClient,
              callBool(client, selector: "supported") == true,
              callBool(client, selector: "available") == true,
              callBool(client, selector: "setEnabled:", value: enabled)
        else {
            actionError = state.trueToneSupported
                ? L10n.text("system_modes.true_tone_set_failed")
                : L10n.text("system_modes.true_tone_unavailable")
            onStateChanged?()
            return false
        }
        actionError = ""
        didModifyTrueTone = initialState?.trueToneEnabled != enabled
        if !refresh() { onStateChanged?() }
        return true
    }

    /// Restores only switches Beta Display successfully changed. This avoids
    /// overwriting a system setting the app merely observed during the session.
    func restoreInitialState() {
        guard let initialState else { return }
        if didModifyNightShiftStrength,
           let strength = initialState.nightShiftStrength {
            _ = setNightShiftStrengthSilently(strength)
        }
        if didModifyNightShift,
           let enabled = initialState.nightShiftEnabled {
            _ = setNightShiftSilently(enabled)
        }
        if didModifyTrueTone,
           let enabled = initialState.trueToneEnabled {
            _ = setTrueToneSilently(enabled)
        }
        actionError = ""
        state = readState()
        onStateChanged?()
    }

    private func readState() -> State {
        var next = State()
        if let client = blueLightClient,
           callBool(client, selector: "supported") == true,
           let status = readBlueLightStatus(from: client),
           status.available != 0 {
            next.nightShiftSupported = true
            next.nightShiftEnabled = status.enabled != 0
            next.nightShiftStrength = readFloat(client, selector: "getStrength:").map(Double.init)
        }
        if let client = trueToneClient,
           callBool(client, selector: "supported") == true,
           callBool(client, selector: "available") == true {
            next.trueToneSupported = true
            next.trueToneEnabled = callBool(client, selector: "enabled")
        }
        return next
    }

    private func setNightShiftSilently(_ enabled: Bool) -> Bool {
        guard let client = blueLightClient,
              callBool(client, selector: "supported") == true
        else { return false }
        return callBool(client, selector: "setEnabled:", value: enabled)
    }

    private func setNightShiftStrengthSilently(_ strength: Double) -> Bool {
        guard let client = blueLightClient else { return false }
        let selector = NSSelectorFromString("setStrength:commit:")
        guard client.responds(to: selector),
              let implementation = client.method(for: selector)
        else { return false }
        let setter = unsafeBitCast(implementation, to: FloatCommit.self)
        return setter(client, selector, Float(strength.clamped(to: 0 ... 1)), true)
    }

    private func setTrueToneSilently(_ enabled: Bool) -> Bool {
        guard let client = trueToneClient,
              callBool(client, selector: "supported") == true,
              callBool(client, selector: "available") == true
        else { return false }
        return callBool(client, selector: "setEnabled:", value: enabled)
    }

    private func readBlueLightStatus(from client: NSObject) -> BlueLightStatus? {
        let selector = NSSelectorFromString("getBlueLightStatus:")
        guard client.responds(to: selector),
              let implementation = client.method(for: selector)
        else { return nil }
        let getter = unsafeBitCast(implementation, to: BlueLightStatusGetter.self)
        var status = BlueLightStatus()
        let succeeded = withUnsafeMutablePointer(to: &status) { pointer in
            getter(client, selector, UnsafeMutableRawPointer(pointer))
        }
        return succeeded ? status : nil
    }

    private func callBool(_ object: NSObject, selector name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let implementation = object.method(for: selector)
        else { return nil }
        let function = unsafeBitCast(implementation, to: NoArgumentBool.self)
        return function(object, selector)
    }

    private func callBool(_ object: NSObject, selector name: String, value: Bool) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let implementation = object.method(for: selector)
        else { return false }
        let function = unsafeBitCast(implementation, to: BoolArgument.self)
        return function(object, selector, value)
    }

    private func readFloat(_ object: NSObject, selector name: String) -> Float? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let implementation = object.method(for: selector)
        else { return nil }
        let getter = unsafeBitCast(implementation, to: FloatGetter.self)
        var value: Float = 0
        return getter(object, selector, &value) ? value : nil
    }
}
