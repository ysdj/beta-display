import CoreGraphics
import Foundation

struct DisplayLUT: Sendable {
    let red: [CGGammaValue]
    let green: [CGGammaValue]
    let blue: [CGGammaValue]

    init(adjustments: ColorAdjustments, count: Int) {
        precondition(count >= 2, "A gamma table needs at least two samples")
        let safeAdjustments = adjustments.sanitizedForApplication()
        func entries(for channel: ColorChannel) -> [CGGammaValue] {
            (0 ..< count).map { index in
                let input = Double(index) / Double(count - 1)
                let transformed = safeAdjustments.transformed(input, channel: channel)
                return CGGammaValue(transformed.isFinite ? transformed : 0)
            }
        }
        red = entries(for: .red)
        green = entries(for: .green)
        blue = entries(for: .blue)
    }

    /// Composes an adjustment on top of a ColorSync-derived display table.
    /// This keeps the user's selected monitor profile in the pipeline instead
    /// of overwriting it with a synthetic identity table.
    init(base: DisplayLUT, adjustments: ColorAdjustments) {
        let safeAdjustments = adjustments.sanitizedForApplication()
        func entries(_ baseEntries: [CGGammaValue], channel: ColorChannel) -> [CGGammaValue] {
            baseEntries.map {
                let transformed = safeAdjustments.transformed(Double($0), channel: channel)
                return CGGammaValue(transformed.isFinite ? transformed : 0)
            }
        }
        red = entries(base.red, channel: .red)
        green = entries(base.green, channel: .green)
        blue = entries(base.blue, channel: .blue)
    }

    init(red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue]) {
        precondition(red.count == green.count && green.count == blue.count, "RGB gamma tables must have equal lengths")
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Compares the visual transfer curves instead of their sample counts.
    /// macOS can resample a table after a mode switch while preserving the
    /// actual curve, so a direct array comparison would be misleading.
    func approximatelyMatches(_ other: DisplayLUT, tolerance: Double = 0.0015) -> Bool {
        // Wake and mode changes may preserve broad portions of a table while
        // losing a narrow quantization edge or one RGB channel. Probe densely
        // enough to detect those resets before deciding a reapply is needless.
        let samplePositions = stride(from: 0.0, through: 1.0, by: 1.0 / 64.0)
        for position in samplePositions {
            guard abs(value(in: red, at: position) - other.value(in: other.red, at: position)) <= tolerance,
                  abs(value(in: green, at: position) - other.value(in: other.green, at: position)) <= tolerance,
                  abs(value(in: blue, at: position) - other.value(in: other.blue, at: position)) <= tolerance
            else {
                return false
            }
        }
        return true
    }

    private func value(in entries: [CGGammaValue], at position: Double) -> Double {
        guard let first = entries.first, !entries.isEmpty else { return 0 }
        guard entries.count > 1 else { return Double(first) }
        let scaled = position.clamped(to: 0 ... 1) * Double(entries.count - 1)
        let lowerIndex = Int(scaled.rounded(.down))
        let upperIndex = min(lowerIndex + 1, entries.count - 1)
        let fraction = scaled - Double(lowerIndex)
        return Double(entries[lowerIndex]) * (1 - fraction) + Double(entries[upperIndex]) * fraction
    }
}
