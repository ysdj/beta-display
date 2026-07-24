import AppKit
import CoreGraphics
import Foundation
import IOKit

struct DisplayDiagnostics: Sendable {
    let displayID: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let pixelWidth: Int
    let pixelHeight: Int
    let physicalWidthMM: Int
    let physicalHeightMM: Int
    let gammaCapacity: Int
    let currentMode: String
    let edidHex: String?
    let edidNote: String

    static func make(for descriptor: DisplayDescriptor?) -> DisplayDiagnostics? {
        guard let descriptor else { return nil }
        let id = descriptor.id
        let size = CGDisplayScreenSize(id)
        let mode = CGDisplayCopyDisplayMode(id)
        let modeDescription: String
        if let mode {
            modeDescription = L10n.text(
                "diagnostics.mode_description",
                mode.width,
                mode.height,
                mode.pixelWidth,
                mode.pixelHeight,
                mode.refreshRate
            )
        } else {
            modeDescription = L10n.text("diagnostics.no_current_mode")
        }
        let (edid, note) = readEDID(displayID: id)
        return DisplayDiagnostics(
            displayID: id,
            name: descriptor.name,
            isBuiltIn: descriptor.isBuiltIn,
            vendor: CGDisplayVendorNumber(id),
            model: CGDisplayModelNumber(id),
            serial: CGDisplaySerialNumber(id),
            pixelWidth: CGDisplayPixelsWide(id),
            pixelHeight: CGDisplayPixelsHigh(id),
            physicalWidthMM: Int(size.width.rounded()),
            physicalHeightMM: Int(size.height.rounded()),
            gammaCapacity: descriptor.gammaCapacity,
            currentMode: modeDescription,
            edidHex: edid,
            edidNote: note
        )
    }

    private static func readEDID(displayID: CGDirectDisplayID) -> (String?, String) {
        // CGDisplayIOServicePort is unavailable on modern macOS. Reading EDID
        // through it would deliberately rely on a deprecated path, so this
        // app exposes only the public CoreGraphics identifiers by default.
        if CGDisplayIsBuiltin(displayID) != 0 {
            return (nil, L10n.text("diagnostics.built_in_edid_unavailable"))
        }
        return (nil, L10n.text("diagnostics.edid_unavailable"))
    }

    var copyableText: String {
        [
            L10n.text("diagnostics.name", name),
            L10n.text("diagnostics.id", String(displayID)),
            L10n.text("diagnostics.type", isBuiltIn ? L10n.text("display.built_in") : L10n.text("display.external")),
            L10n.text("diagnostics.vendor", String(vendor), String(model), String(serial)),
            L10n.text("diagnostics.pixels", pixelWidth, pixelHeight),
            L10n.text("diagnostics.physical", physicalWidthMM, physicalHeightMM),
            L10n.text("diagnostics.mode", currentMode),
            L10n.text("diagnostics.gamma", gammaCapacity),
            L10n.text("diagnostics.edid", edidHex ?? edidNote)
        ].joined(separator: "\n")
    }
}
