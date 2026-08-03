import CoreGraphics
import Foundation

@MainActor
final class DisplayLayoutController {
    private struct InitialDisplayState {
        let origin: CGPoint
        let mirrorMasterSessionKey: String?
    }

    private let configurationStore: DisplayConfigurationStore
    private(set) var mirroringStatusMessage = L10n.text("status.choose_layout_action")
    private(set) var positionStatusMessage = ""
    private var initialStates: [String: InitialDisplayState] = [:]
    private var didModifyLayout = false
    var onStateChanged: (() -> Void)?

    init(configurationStore: DisplayConfigurationStore) {
        self.configurationStore = configurationStore
    }

    /// Captures the arrangement that existed before this process applies a
    /// saved layout. The snapshot remains session-only and is restored on
    /// termination rather than during ordinary display recovery.
    func captureInitialLayout(for displayIDs: [CGDirectDisplayID]) {
        let activeBySessionKey = DisplayIdentity.activeDisplayIDsBySessionKey()
        for displayID in displayIDs {
            let sessionKey = DisplayIdentity.sessionKey(for: displayID)
            guard initialStates[sessionKey] == nil else { continue }
            let masterID = CGDisplayMirrorsDisplay(displayID)
            let masterSessionKey = masterID == kCGNullDirectDisplay
                ? nil
                : activeBySessionKey.first(where: { $0.value == masterID })?.key
            initialStates[sessionKey] = InitialDisplayState(
                origin: CGDisplayBounds(displayID).origin,
                mirrorMasterSessionKey: masterSessionKey
            )
        }
    }

    func mirror(displayID: CGDirectDisplayID, to masterID: CGDirectDisplayID) {
        guard displayID != masterID else {
            mirroringStatusMessage = L10n.text("status.source_target_same")
            publish()
            return
        }
        if CGDisplayMirrorsDisplay(displayID) == masterID {
            return
        }
        captureInitialLayout(for: [displayID])
        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success, let configuration else {
            mirroringStatusMessage = L10n.text("status.cannot_start_layout", begin.rawValue)
            publish()
            return
        }
        let configure = CGConfigureDisplayMirrorOfDisplay(configuration, displayID, masterID)
        guard configure == .success else {
            CGCancelDisplayConfiguration(configuration)
            mirroringStatusMessage = L10n.text("status.cannot_configure_mirroring", configure.rawValue)
            publish()
            return
        }
        let complete = CGCompleteDisplayConfiguration(configuration, .forAppOnly)
        if complete == .success {
            configurationStore.update(for: displayID) {
                $0.mirror = PersistedMirrorConfiguration(
                    targetDisplayKey: DisplayIdentity.key(for: masterID)
                )
            }
            didModifyLayout = true
        }
        mirroringStatusMessage = complete == .success
            ? L10n.text("status.mirroring_enabled")
            : L10n.text("status.cannot_apply_mirroring", complete.rawValue)
        publish()
    }

    func unmirror(displayID: CGDirectDisplayID) {
        if CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay {
            return
        }
        captureInitialLayout(for: [displayID])
        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success, let configuration else {
            mirroringStatusMessage = L10n.text("status.cannot_start_layout", begin.rawValue)
            publish()
            return
        }
        let configure = CGConfigureDisplayMirrorOfDisplay(configuration, displayID, kCGNullDirectDisplay)
        guard configure == .success else {
            CGCancelDisplayConfiguration(configuration)
            mirroringStatusMessage = L10n.text("status.cannot_remove_mirroring", configure.rawValue)
            publish()
            return
        }
        let complete = CGCompleteDisplayConfiguration(configuration, .forAppOnly)
        if complete == .success {
            configurationStore.update(for: displayID) {
                $0.mirror = PersistedMirrorConfiguration(targetDisplayKey: nil)
            }
            didModifyLayout = true
        }
        mirroringStatusMessage = complete == .success
            ? L10n.text("status.mirroring_disabled")
            : L10n.text("status.cannot_remove_mirroring", complete.rawValue)
        publish()
    }

    func move(displayID: CGDirectDisplayID, x: Int, y: Int) {
        let currentOrigin = CGDisplayBounds(displayID).origin
        if Int(currentOrigin.x.rounded()) == x, Int(currentOrigin.y.rounded()) == y {
            return
        }
        captureInitialLayout(for: [displayID])
        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success, let configuration else {
            positionStatusMessage = L10n.text("status.cannot_start_layout", begin.rawValue)
            publish()
            return
        }
        let configure = CGConfigureDisplayOrigin(configuration, displayID, Int32(x), Int32(y))
        guard configure == .success else {
            CGCancelDisplayConfiguration(configuration)
            positionStatusMessage = L10n.text("status.cannot_move_display", configure.rawValue)
            publish()
            return
        }
        let complete = CGCompleteDisplayConfiguration(configuration, .forAppOnly)
        if complete == .success {
            configurationStore.update(for: displayID) {
                $0.originX = x
                $0.originY = y
            }
            didModifyLayout = true
        }
        positionStatusMessage = complete == .success
            ? L10n.text("status.display_moved", x, y)
            : L10n.text("status.cannot_move_display", complete.rawValue)
        publish()
    }

    func applySavedLayout(to displays: [CGDirectDisplayID]) {
        let availableByKey = Dictionary(
            uniqueKeysWithValues: displays.compactMap { id in
                DisplayIdentity.key(for: id).map { ($0, id) }
            }
        )
        for displayID in displays {
            guard let saved = configurationStore.configuration(for: displayID) else { continue }
            if let mirrorConfiguration = saved.mirror {
                if let targetKey = mirrorConfiguration.targetDisplayKey,
                   let target = availableByKey[targetKey] {
                    self.mirror(displayID: displayID, to: target)
                } else if mirrorConfiguration.targetDisplayKey == nil {
                    unmirror(displayID: displayID)
                }
            }
        }
        for displayID in displays {
            guard let saved = configurationStore.configuration(for: displayID),
                  let x = saved.originX,
                  let y = saved.originY,
                  CGDisplayIsInMirrorSet(displayID) == 0
            else { continue }
            move(displayID: displayID, x: x, y: y)
        }
    }

    /// Restores the original mirroring relationships first, then the original
    /// positions for unmirrored displays in one app-only transaction. This
    /// leaves system preferences untouched after Beta Display exits.
    func restoreInitialLayout() {
        guard didModifyLayout, !initialStates.isEmpty else { return }
        let activeBySessionKey = DisplayIdentity.activeDisplayIDsBySessionKey()
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success,
              let configuration
        else { return }

        var didConfigure = false
        for (sessionKey, initial) in initialStates {
            guard let displayID = activeBySessionKey[sessionKey] else { continue }
            let desiredMasterID: CGDirectDisplayID
            if let masterSessionKey = initial.mirrorMasterSessionKey {
                guard let masterID = activeBySessionKey[masterSessionKey] else { continue }
                desiredMasterID = masterID
            } else {
                desiredMasterID = kCGNullDirectDisplay
            }
            if CGDisplayMirrorsDisplay(displayID) != desiredMasterID,
               CGConfigureDisplayMirrorOfDisplay(configuration, displayID, desiredMasterID) == .success {
                didConfigure = true
            }
        }
        for (sessionKey, initial) in initialStates {
            guard let displayID = activeBySessionKey[sessionKey],
                  initial.mirrorMasterSessionKey == nil,
                  Int(CGDisplayBounds(displayID).origin.x.rounded()) != Int(initial.origin.x.rounded())
                    || Int(CGDisplayBounds(displayID).origin.y.rounded()) != Int(initial.origin.y.rounded()),
                  CGConfigureDisplayOrigin(
                    configuration,
                    displayID,
                    Int32(initial.origin.x.rounded()),
                    Int32(initial.origin.y.rounded())
                  ) == .success
            else { continue }
            didConfigure = true
        }
        if didConfigure {
            _ = CGCompleteDisplayConfiguration(configuration, .forAppOnly)
        } else {
            CGCancelDisplayConfiguration(configuration)
        }
    }

    private func publish() {
        onStateChanged?()
    }
}
