import CoreGraphics
import Foundation

struct DisplayModeDescriptor: Identifiable, Hashable {
    let id: String
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isHiDPI: Bool
    let mode: CGDisplayMode

    init(mode: CGDisplayMode) {
        self.mode = mode
        width = mode.width
        height = mode.height
        pixelWidth = mode.pixelWidth
        pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate
        isHiDPI = pixelWidth > width || pixelHeight > height
        id = "\(width)x\(height)-\(pixelWidth)x\(pixelHeight)-\(Int((refreshRate * 100).rounded()))-\(mode.ioDisplayModeID)"
    }

    var title: String {
        let scale = isHiDPI ? L10n.text("modes.hidpi") : L10n.text("modes.low_resolution")
        let frequency = refreshRate > 1 ? String(format: " · %.0f Hz", refreshRate) : ""
        return "\(width) × \(height) · \(scale)\(frequency)"
    }
}

@MainActor
final class DisplayModeController {
    private let configurationStore: DisplayConfigurationStore
    private(set) var modes: [DisplayModeDescriptor] = []
    private(set) var currentModeID: String?
    private(set) var statusMessage = L10n.text("status.choose_display_for_modes")
    var onStateChanged: (() -> Void)?

    init(configurationStore: DisplayConfigurationStore) {
        self.configurationStore = configurationStore
    }

    func refresh(for displayID: CGDirectDisplayID?) {
        guard let displayID else {
            modes = []
            currentModeID = nil
            statusMessage = L10n.text("status.no_display_selected")
            publish()
            return
        }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let available = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
        modes = available.map(DisplayModeDescriptor.init(mode:))
            .sorted {
                if $0.width != $1.width { return $0.width > $1.width }
                if $0.height != $1.height { return $0.height > $1.height }
                if $0.isHiDPI != $1.isHiDPI { return $0.isHiDPI }
                return $0.refreshRate > $1.refreshRate
            }
        if let current = CGDisplayCopyDisplayMode(displayID) {
            currentModeID = DisplayModeDescriptor(mode: current).id
        } else {
            currentModeID = nil
        }
        statusMessage = modes.isEmpty
            ? L10n.text("status.no_modes")
            : L10n.text("status.modes_loaded", modes.count)
        publish()
    }

    func apply(modeID: String, to displayID: CGDirectDisplayID?) {
        guard let displayID, let mode = modes.first(where: { $0.id == modeID }) else {
            statusMessage = L10n.text("status.mode_unavailable")
            publish()
            return
        }
        if currentModeID == modeID {
            return
        }
        let result = CGDisplaySetDisplayMode(displayID, mode.mode, nil)
        if result == .success {
            configurationStore.update(for: displayID) { $0.displayModeID = modeID }
            statusMessage = L10n.text("status.mode_applied", mode.title)
            refresh(for: displayID)
        } else {
            statusMessage = L10n.text("status.cannot_switch_mode", result.rawValue)
            publish()
        }
    }

    func applySavedModes(to displayIDs: [CGDirectDisplayID]) {
        for displayID in displayIDs {
            refresh(for: displayID)
            guard let savedModeID = configurationStore.configuration(for: displayID)?.displayModeID,
                  let mode = resolvedSavedMode(savedModeID)
            else { continue }
            apply(modeID: mode.id, to: displayID)
        }
    }

    private func resolvedSavedMode(_ identifier: String) -> DisplayModeDescriptor? {
        if let exact = modes.first(where: { $0.id == identifier }) {
            return exact
        }
        let parts = identifier.split(separator: "-")
        guard let dimensions = parts.first?.split(separator: "x"),
              dimensions.count == 2,
              let width = Int(dimensions[0]),
              let height = Int(dimensions[1])
        else { return nil }
        return modes
            .filter { $0.width == width && $0.height == height }
            .sorted {
                if $0.isHiDPI != $1.isHiDPI { return $0.isHiDPI }
                return $0.refreshRate > $1.refreshRate
            }
            .first
    }

    private func publish() {
        onStateChanged?()
    }
}
