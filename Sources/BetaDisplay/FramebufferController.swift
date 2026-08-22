import CoreGraphics
import Darwin
import Foundation
import IOKit

/// The framebuffer color-remap modes exposed by IOMobileFramebuffer.
///
/// These names and values are queried from the system framework at runtime.
/// Apple does not publish a stable Swift interface for them, so all private
/// API access remains contained in this one controller.
enum FramebufferColorMode: Int32, CaseIterable, Sendable {
    case standard = 0
    case inverted = 1
    case grayscale = 2
    case invertedGrayscale = 4

    var title: String {
        switch self {
        case .standard: L10n.text("framebuffer.standard")
        case .inverted: L10n.text("framebuffer.inverted")
        case .grayscale: L10n.text("framebuffer.grayscale")
        case .invertedGrayscale: L10n.text("framebuffer.inverted_grayscale")
        }
    }
}

struct FramebufferState: Equatable, Sendable {
    var mode: FramebufferColorMode?
    var ditheringEnabled: Bool?
    var uniformityCorrectionEnabled: Bool?
    var servicePath: String?

    static let unavailable = FramebufferState(
        mode: nil,
        ditheringEnabled: nil,
        uniformityCorrectionEnabled: nil,
        servicePath: nil
    )

    var supportsColorMode: Bool { mode != nil }
    var supportsDithering: Bool { ditheringEnabled != nil }
    var supportsUniformityCorrection: Bool { uniformityCorrectionEnabled != nil }
}

@MainActor
final class FramebufferController {
    private let configurationStore: DisplayConfigurationStore
    private typealias DisplayInfo = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    private typealias FramebufferOpen = @convention(c) (
        io_service_t,
        mach_port_t,
        UInt32,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>
    ) -> kern_return_t
    private typealias GetColorRemapMode = @convention(c) (
        UnsafeMutableRawPointer,
        UnsafeMutablePointer<Int32>
    ) -> kern_return_t
    private typealias SetColorRemapMode = @convention(c) (
        UnsafeMutableRawPointer,
        Int32
    ) -> kern_return_t

    private let coreDisplayHandle: UnsafeMutableRawPointer?
    private let framebufferHandle: UnsafeMutableRawPointer?
    private let displayInfo: DisplayInfo?
    private let openFramebuffer: FramebufferOpen?
    private let getColorRemapMode: GetColorRemapMode?
    private let setColorRemapMode: SetColorRemapMode?
    private var initialStates: [String: FramebufferState] = [:]
    private var modifiedStateSessionKeys: Set<String> = []

    private(set) var state = FramebufferState.unavailable
    private(set) var modeStatusMessage = L10n.text("status.framebuffer_reading")
    private(set) var toolsStatusMessage = ""
    var onStateChanged: (() -> Void)?

    init(configurationStore: DisplayConfigurationStore) {
        self.configurationStore = configurationStore
        coreDisplayHandle = dlopen(
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
            RTLD_LAZY | RTLD_LOCAL
        )
        framebufferHandle = dlopen(
            "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
            RTLD_LAZY | RTLD_LOCAL
        )
        if let coreDisplayHandle {
            displayInfo = dlsym(coreDisplayHandle, "CoreDisplay_DisplayCreateInfoDictionary").map {
                unsafeBitCast($0, to: DisplayInfo.self)
            }
        } else {
            displayInfo = nil
        }
        if let framebufferHandle {
            openFramebuffer = dlsym(framebufferHandle, "IOMobileFramebufferOpen").map {
                unsafeBitCast($0, to: FramebufferOpen.self)
            }
            getColorRemapMode = dlsym(framebufferHandle, "IOMobileFramebufferGetColorRemapMode").map {
                unsafeBitCast($0, to: GetColorRemapMode.self)
            }
            setColorRemapMode = dlsym(framebufferHandle, "IOMobileFramebufferSetColorRemapMode").map {
                unsafeBitCast($0, to: SetColorRemapMode.self)
            }
        } else {
            openFramebuffer = nil
            getColorRemapMode = nil
            setColorRemapMode = nil
        }
    }

    /// Captures the process baseline before saved framebuffer settings are
    /// applied. Individual setters also capture lazily for displays connected
    /// after launch.
    func captureInitialStates(for displayIDs: [CGDirectDisplayID]) {
        for displayID in displayIDs {
            captureInitialStateIfNeeded(for: displayID)
        }
    }

    func refresh(for displayID: CGDirectDisplayID?) {
        guard let displayID else {
            state = .unavailable
            modeStatusMessage = L10n.text("status.no_display_selected")
            toolsStatusMessage = ""
            publish()
            return
        }
        let resolved = readState(for: displayID)
        state = resolved ?? .unavailable
        let sessionKey = DisplayIdentity.sessionKey(for: displayID)
        if initialStates[sessionKey] == nil, let resolved {
            initialStates[sessionKey] = resolved
        }
        modeStatusMessage = resolved == nil
            ? L10n.text("status.no_framebuffer_controls")
            : L10n.text("status.framebuffer_read")
        toolsStatusMessage = ""
        publish()
    }

    func setMode(_ mode: FramebufferColorMode, for displayID: CGDirectDisplayID?) {
        guard let displayID else {
            modeStatusMessage = L10n.text("status.no_display_selected")
            publish()
            return
        }
        if readColorRemapMode(for: displayID) == mode {
            configurationStore.update(for: displayID) { $0.framebufferMode = mode.rawValue }
            return
        }
        captureInitialStateIfNeeded(for: displayID)
        guard let setColorRemapMode else {
            modeStatusMessage = L10n.text("status.framebuffer_api_unavailable")
            publish()
            return
        }
        let result = withFramebuffer(for: displayID) { framebuffer in
            setColorRemapMode(framebuffer, mode.rawValue)
        }
        guard let result else {
            modeStatusMessage = L10n.text("status.cannot_open_framebuffer")
            publish()
            return
        }
        guard result == KERN_SUCCESS else {
            modeStatusMessage = L10n.text("status.cannot_apply_framebuffer_mode", mode.title, result)
            publish()
            return
        }
        refresh(for: displayID)
        configurationStore.update(for: displayID) { $0.framebufferMode = mode.rawValue }
        modifiedStateSessionKeys.insert(DisplayIdentity.sessionKey(for: displayID))
        modeStatusMessage = L10n.text("status.framebuffer_mode_applied", mode.title)
        publish()
    }

    func setDithering(_ enabled: Bool, for displayID: CGDirectDisplayID?) {
        if let displayID { captureInitialStateIfNeeded(for: displayID) }
        _ = setRegistryBoolean(
            key: "enableDither",
            enabled: enabled,
            featureName: L10n.text("feature.gpu_dithering"),
            for: displayID
        )
    }

    func setUniformityCorrection(_ enabled: Bool, for displayID: CGDirectDisplayID?) {
        if let displayID { captureInitialStateIfNeeded(for: displayID) }
        _ = setRegistryBoolean(
            key: "uniformity2D",
            enabled: enabled,
            featureName: L10n.text("feature.gpu_uniformity"),
            for: displayID
        )
    }

    func restoreInitialState(for displayID: CGDirectDisplayID?) {
        guard let displayID,
              let initial = initialStates[DisplayIdentity.sessionKey(for: displayID)]
        else {
            modeStatusMessage = L10n.text("status.no_initial_framebuffer_state")
            publish()
            return
        }

        var failures: [String] = []
        if let mode = initial.mode, let setColorRemapMode {
            let result = withFramebuffer(for: displayID) { framebuffer in
                setColorRemapMode(framebuffer, mode.rawValue)
            }
            if result != KERN_SUCCESS { failures.append(L10n.text("feature.color_mode")) }
        }
        if let dithering = initial.ditheringEnabled,
           !setRegistryBoolean(
               key: "enableDither",
               enabled: dithering,
               featureName: L10n.text("feature.gpu_dithering"),
               for: displayID,
               publishes: false,
               persistsConfiguration: false
           ) {
            failures.append(L10n.text("feature.gpu_dithering"))
        }
        if let uniformity = initial.uniformityCorrectionEnabled,
           !setRegistryBoolean(
               key: "uniformity2D",
               enabled: uniformity,
               featureName: L10n.text("feature.gpu_uniformity"),
               for: displayID,
               publishes: false,
               persistsConfiguration: false
           ) {
            failures.append(L10n.text("feature.gpu_uniformity"))
        }
        refresh(for: displayID)
        modeStatusMessage = failures.isEmpty
            ? L10n.text("status.framebuffer_restored")
            : L10n.text("status.framebuffer_restore_failed", failures.joined(separator: ", "))
        publish()
    }

    func restoreAllInitialStates() {
        let activeDisplays = DisplayIdentity.activeDisplayIDsBySessionKey()
        for sessionKey in modifiedStateSessionKeys {
            guard let displayID = activeDisplays[sessionKey] else { continue }
            restoreInitialState(for: displayID)
        }
    }

    func applySavedState(
        to displayIDs: [CGDirectDisplayID],
        automaticallyEnableDitheringForColorModes: Bool = false
    ) {
        for displayID in displayIDs {
            guard let saved = configurationStore.configuration(for: displayID) else { continue }
            var restoredMode: FramebufferColorMode?
            if let raw = saved.framebufferMode,
               let mode = FramebufferColorMode(rawValue: raw) {
                setMode(mode, for: displayID)
                restoredMode = mode
            }
            if let dithering = saved.ditheringEnabled {
                setDithering(dithering, for: displayID)
            } else if automaticallyEnableDitheringForColorModes,
                      restoredMode != nil,
                      restoredMode != .standard {
                setDithering(true, for: displayID)
            }
            if let uniformity = saved.uniformityCorrectionEnabled {
                setUniformityCorrection(uniformity, for: displayID)
            }
        }
    }

    private func setRegistryBoolean(
        key: String,
        enabled: Bool,
        featureName: String,
        for displayID: CGDirectDisplayID?,
        publishes: Bool = true,
        persistsConfiguration: Bool = true
    ) -> Bool {
        guard let displayID else {
            toolsStatusMessage = L10n.text("status.no_display_selected")
            if publishes { publish() }
            return false
        }
        guard let service = service(for: displayID) else {
            toolsStatusMessage = L10n.text("status.cannot_locate_framebuffer")
            if publishes { publish() }
            return false
        }
        defer { IOObjectRelease(service) }
        guard registryBoolean(key, service: service) != nil else {
            toolsStatusMessage = L10n.text("status.framebuffer_feature_unavailable", featureName)
            if publishes { publish() }
            return false
        }
        if registryBoolean(key, service: service) == enabled {
            if persistsConfiguration, key == "enableDither" {
                configurationStore.update(for: displayID) { $0.ditheringEnabled = enabled }
            } else if persistsConfiguration, key == "uniformity2D" {
                configurationStore.update(for: displayID) { $0.uniformityCorrectionEnabled = enabled }
            }
            state = readState(for: displayID) ?? .unavailable
            toolsStatusMessage = L10n.text(
                "status.framebuffer_feature_set",
                featureName,
                enabled ? L10n.text("state.enabled") : L10n.text("state.disabled")
            )
            if publishes { publish() }
            return true
        }
        let result = IORegistryEntrySetCFProperty(
            service,
            key as CFString,
            enabled ? kCFBooleanTrue : kCFBooleanFalse
        )
        guard result == KERN_SUCCESS else {
            toolsStatusMessage = L10n.text("status.cannot_set_framebuffer_feature", featureName, result)
            if publishes { publish() }
            return false
        }
        let applied = registryBoolean(key, service: service)
        guard applied == enabled else {
            toolsStatusMessage = L10n.text("status.framebuffer_feature_unconfirmed", featureName)
            if publishes { publish() }
            return false
        }
        state = readState(for: displayID) ?? .unavailable
        if persistsConfiguration {
            modifiedStateSessionKeys.insert(DisplayIdentity.sessionKey(for: displayID))
        }
        if persistsConfiguration, key == "enableDither" {
            configurationStore.update(for: displayID) { $0.ditheringEnabled = enabled }
        } else if persistsConfiguration, key == "uniformity2D" {
            configurationStore.update(for: displayID) { $0.uniformityCorrectionEnabled = enabled }
        }
        toolsStatusMessage = L10n.text(
            "status.framebuffer_feature_set",
            featureName,
            enabled ? L10n.text("state.enabled") : L10n.text("state.disabled")
        )
        if publishes { publish() }
        return true
    }

    private func readState(for displayID: CGDirectDisplayID) -> FramebufferState? {
        guard let service = service(for: displayID) else { return nil }
        defer { IOObjectRelease(service) }
        let mode = readColorRemapMode(for: displayID)
        let dithering = registryBoolean("enableDither", service: service)
        let uniformity = registryBoolean("uniformity2D", service: service)
        guard mode != nil || dithering != nil || uniformity != nil else { return nil }
        return FramebufferState(
            mode: mode,
            ditheringEnabled: dithering,
            uniformityCorrectionEnabled: uniformity,
            servicePath: servicePath(for: displayID)
        )
    }

    private func captureInitialStateIfNeeded(for displayID: CGDirectDisplayID) {
        let sessionKey = DisplayIdentity.sessionKey(for: displayID)
        guard initialStates[sessionKey] == nil, let state = readState(for: displayID) else { return }
        initialStates[sessionKey] = state
    }

    private func servicePath(for displayID: CGDirectDisplayID) -> String? {
        guard let displayInfo,
              let info = displayInfo(displayID)?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return info["IODisplayLocation"] as? String
    }

    private func service(for displayID: CGDirectDisplayID) -> io_service_t? {
        guard let path = servicePath(for: displayID) else { return nil }
        let service = IORegistryEntryFromPath(kIOMainPortDefault, path)
        return service == IO_OBJECT_NULL ? nil : service
    }

    private func registryBoolean(_ key: String, service: io_service_t) -> Bool? {
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else { return nil }
        if let boolean = value as? Bool { return boolean }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private func readColorRemapMode(for displayID: CGDirectDisplayID) -> FramebufferColorMode? {
        guard let getColorRemapMode else { return nil }
        var rawMode: Int32 = -1
        let result: kern_return_t? = withFramebuffer(for: displayID) { framebuffer in
            getColorRemapMode(framebuffer, &rawMode)
        }
        guard result == KERN_SUCCESS else { return nil }
        return FramebufferColorMode(rawValue: rawMode)
    }

    private func withFramebuffer<T>(
        for displayID: CGDirectDisplayID,
        _ body: (UnsafeMutableRawPointer) -> T
    ) -> T? {
        guard let openFramebuffer, let service = service(for: displayID) else { return nil }
        defer { IOObjectRelease(service) }
        var framebuffer: UnsafeMutableRawPointer?
        let result = openFramebuffer(service, mach_task_self_, 0, &framebuffer)
        guard result == KERN_SUCCESS, let framebuffer else { return nil }
        defer { Unmanaged<AnyObject>.fromOpaque(framebuffer).release() }
        return body(framebuffer)
    }

    private func publish() {
        onStateChanged?()
    }
}
