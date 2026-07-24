import CoreGraphics
import Darwin
import Foundation

/// Resolves the macOS DisplayServices brightness symbols at runtime. They are
/// not part of the public SDK, so this capability stays isolated and is only
/// enabled when the system reports support for the selected display.
@MainActor
final class HardwareBrightnessController {
    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let handle: UnsafeMutableRawPointer?
    private let canChange: CanChangeBrightness?
    private let get: GetBrightness?
    private let set: SetBrightness?

    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        handle = dlopen(path, RTLD_LAZY)
        if let handle {
            canChange = dlsym(handle, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: CanChangeBrightness.self) }
            get = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetBrightness.self) }
            set = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetBrightness.self) }
        } else {
            canChange = nil
            get = nil
            set = nil
        }
    }

    var isAvailable: Bool { canChange != nil && get != nil && set != nil }

    func value(for displayID: CGDirectDisplayID?) -> Double? {
        guard let displayID, let get, supports(displayID) else { return nil }
        var value: Float = 0
        return get(displayID, &value) == 0 ? Double(value).clamped(to: 0 ... 1) : nil
    }

    func supports(_ displayID: CGDirectDisplayID?) -> Bool {
        guard let displayID, let canChange else { return false }
        return canChange(displayID)
    }

    @discardableResult
    func setValue(_ value: Double, for displayID: CGDirectDisplayID?) -> Bool {
        guard let displayID, let set, supports(displayID) else { return false }
        return set(displayID, Float(value.clamped(to: 0 ... 1))) == 0
    }
}
