import AppKit

enum StatusBarMark {
    static func image() -> NSImage {
        guard let url = Bundle.module.url(
            forResource: "BetaDisplayStatusBarTemplate",
            withExtension: "png"
        ), let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing BetaDisplayStatusBarTemplate.png")
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}
