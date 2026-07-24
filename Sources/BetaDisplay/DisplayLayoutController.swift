import CoreGraphics
import Foundation

@MainActor
final class DisplayLayoutController {
    private let configurationStore: DisplayConfigurationStore
    private(set) var mirroringStatusMessage = L10n.text("status.choose_layout_action")
    private(set) var positionStatusMessage = ""
    var onStateChanged: (() -> Void)?

    init(configurationStore: DisplayConfigurationStore) {
        self.configurationStore = configurationStore
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

    private func publish() {
        onStateChanged?()
    }
}
