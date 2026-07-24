import Foundation

/// Image-adjustment controls use a normalized `0 ... 1` track, with `0.5`
/// neutral for centered controls. The renderer converts values to native
/// Color Table ranges only when it builds a LUT.
struct ColorAdjustments: Codable, Equatable, Sendable {
    /// Controls move in hundredths, so safety corrections must remain visible
    /// and editable in the value field.
    static let minimumVisibleControl = 0.01
    private static let minimumVisibleOutput = 0.01

    /// 0 ... 1 maps to native contrast -0.9 ... 0.9; 0.5 is neutral.
    var contrast: Double = 0.5
    /// 0 ... 1 maps to native global gamma -0.8 ... 0.8; 0.5 is neutral.
    var gamma: Double = 0.5
    /// 0 ... 1 maps to native gain -1 ... 1; 0.5 is neutral.
    var gain: Double = 0.5
    /// 0 ... 1 maps to native temperature -0.5 ... 0.5; 0.5 is neutral.
    var temperature: Double = 0.5
    /// 0 ... 1; 1 is neutral.
    var brightness: Double = 1
    /// 0 ... 1; 1 means unlimited / unquantized.
    var quantization: Double = 1
    /// 0 ... 1 maps to native per-channel gamma -0.8 ... 0.8.
    var redGamma: Double = 0.5
    var greenGamma: Double = 0.5
    var blueGamma: Double = 0.5
    /// 0 ... 1 maps to native per-channel gain -1 ... 1.
    var redGain: Double = 0.5
    var greenGain: Double = 0.5
    var blueGain: Double = 0.5

    static let neutral = ColorAdjustments()

    var isNeutral: Bool { self == .neutral }

    /// Sanitizes the combinations that would submit a fully black transfer
    /// table. This lives in the model so it protects sliders, typed values,
    /// display-group synchronization, restored preferences, and future
    /// callers alike.
    @discardableResult
    mutating func enforceVisibleRGBGain(preferredChannel: ColorChannel? = nil) -> Bool {
        let priorValues = self
        contrast = Self.boundedControl(contrast)
        gamma = Self.boundedControl(gamma)
        gain = Self.boundedControl(gain)
        temperature = Self.boundedControl(temperature)
        brightness = Self.boundedControl(brightness)
        quantization = Self.boundedControl(quantization)
        redGamma = Self.boundedControl(redGamma)
        greenGamma = Self.boundedControl(greenGamma)
        blueGamma = Self.boundedControl(blueGamma)
        redGain = Self.boundedControl(redGain)
        greenGain = Self.boundedControl(greenGain)
        blueGain = Self.boundedControl(blueGain)

        var adjusted = self != priorValues
        if brightness <= 0 {
            brightness = Self.minimumVisibleControl
            adjusted = true
        }

        let globalGainMultiplier = Self.gainMultiplier(forRawValue: Self.rawGain(for: gain))
        let channelMultiplier = { (control: Double) in
            Self.gainMultiplier(forRawValue: Self.rawGain(for: control))
        }
        let combinedGains = [redGain, greenGain, blueGain].map {
            globalGainMultiplier + channelMultiplier($0) - 1
        }
        guard !combinedGains.contains(where: { $0 > 0 }) else { return adjusted }

        switch preferredChannel ?? .red {
        case .red:
            redGain = Self.safeGainControl(globalGain: gain)
        case .green:
            greenGain = Self.safeGainControl(globalGain: gain)
        case .blue:
            blueGain = Self.safeGainControl(globalGain: gain)
        }
        return true
    }

    func sanitizedForApplication(preferredChannel: ColorChannel? = nil) -> ColorAdjustments {
        var sanitized = self
        _ = sanitized.enforceVisibleRGBGain(preferredChannel: preferredChannel)
        return sanitized
    }

    /// The gain control is quadratic around its centre: raw -1 ... 1 maps to
    /// a multiplier of 0 ... 2 by
    /// `1 + sign(raw) * raw²`.
    static func rawGain(for normalizedValue: Double) -> Double {
        (normalizedValue.clamped(to: 0 ... 1) * 2) - 1
    }

    static func normalizedGain(forRawValue raw: Double) -> Double {
        ((raw.clamped(to: -1 ... 1) + 1) / 2).clamped(to: 0 ... 1)
    }

    static func gainMultiplier(forRawValue raw: Double) -> Double {
        let clamped = raw.clamped(to: -1 ... 1)
        return 1 + (clamped < 0 ? -1 : 1) * clamped * clamped
    }

    /// Builds a color-table sample in this order: contrast → global gamma →
    /// RGB gamma → gain → white balance → quantization. A Color Table can
    /// intentionally contain values outside 0...1 for contrast/gain, so this
    /// method does not silently clip them.
    func transformed(_ input: Double, channel: ColorChannel) -> Double {
        let contrast = nativeContrast
        let globalGamma = nativeGlobalGamma
        let channelGamma = nativeChannelGamma(for: channel)
        let globalGain = Self.gainMultiplier(forRawValue: Self.rawGain(for: gain))
        let channelGain = Self.gainMultiplier(forRawValue: Self.rawGain(for: normalizedChannelGain(for: channel)))

        var value = ((input - 0.5) * (1 + contrast)) + 0.5
        // Contrast may leave the nominal range. Fractional gamma cannot be
        // evaluated for a negative real value, so only positive values receive
        // gamma shaping.
        if value > 0 {
            value = pow(value, 1 / (1 + globalGamma))
            value = pow(value, 1 / (1 + channelGamma))
        }
        // Global and channel gain are offsets from unity. For example, +0.5 /
        // +0.5 produces 1.50x, not 1.5625x; opposite offsets cancel.
        let combinedGain = globalGain + channelGain - 1
        value *= combinedGain * brightness.clamped(to: 0 ... 1) * temperatureMultiplier(for: channel)

        if quantization < 0.995 {
            value = quantized(value)
        }
        return value
    }

    private static let nativeContrastRange = -0.9 ... 0.9
    private static let nativeGammaRange = -0.8 ... 0.8
    private static let nativeTemperatureRange = -0.5 ... 0.5

    private var nativeContrast: Double {
        Self.native(control: contrast, range: Self.nativeContrastRange)
    }

    private var nativeGlobalGamma: Double {
        Self.native(control: gamma, range: Self.nativeGammaRange)
    }

    private func nativeChannelGamma(for channel: ColorChannel) -> Double {
        Self.native(control: normalizedChannelGamma(for: channel), range: Self.nativeGammaRange)
    }

    private func normalizedChannelGamma(for channel: ColorChannel) -> Double {
        switch channel {
        case .red: redGamma
        case .green: greenGamma
        case .blue: blueGamma
        }
    }

    private func normalizedChannelGain(for channel: ColorChannel) -> Double {
        switch channel {
        case .red: redGain
        case .green: greenGain
        case .blue: blueGain
        }
    }

    private func temperatureMultiplier(for channel: ColorChannel) -> Double {
        let temperature = Self.native(control: temperature, range: Self.nativeTemperatureRange)
        if temperature >= 0 {
            switch channel {
            case .red: return 1
            case .green: return 1 - temperature / 2
            case .blue: return 1 - temperature
            }
        }
        switch channel {
        case .red: return 1 + temperature
        case .green: return 1 + temperature / 2
        case .blue: return 1
        }
    }

    private func quantized(_ value: Double) -> Double {
        let levels = quantizationLevels
        guard levels > 1 else { return value >= 0.5 ? 1 : 0 }
        // Quantization is applied across the source transfer table's 1024
        // value domain, not by reducing to 8-bit first. CoreGraphics may
        // resample the submitted table afterwards, but preserving this source
        // domain gives the same visible control curve and avoids an artificial
        // 8-bit plateau at the upper end of the slider.
        let sourceCode = (value * 1023).rounded().clamped(to: 0 ... 1023)
        let bucket = (sourceCode * Double(levels - 1) / 1023).rounded()
        return bucket * 1023 / Double(levels - 1) / 1023
    }

    /// 1024-entry source-table milestones for the control. The display server
    /// can resample the table after submission.
    private var quantizationLevels: Int {
        let control = quantization.clamped(to: 0 ... 1)
        return Self.quantizationCodeLevels(for: control)
    }

    private static func native(control: Double, range: ClosedRange<Double>) -> Double {
        range.lowerBound + control.clamped(to: 0 ... 1) * (range.upperBound - range.lowerBound)
    }

    private static func boundedControl(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return value.clamped(to: 0 ... 1)
    }

    private static func safeGainControl(globalGain: Double) -> Double {
        let globalMultiplier = gainMultiplier(forRawValue: rawGain(for: globalGain))
        guard globalMultiplier <= 1 else { return 0 }
        let requiredMultiplier = 1 - globalMultiplier + minimumVisibleOutput
        let raw = requiredMultiplier <= 1
            ? -sqrt(1 - requiredMultiplier)
            : sqrt(requiredMultiplier - 1)
        return max(minimumVisibleControl, normalizedGain(forRawValue: raw))
    }

    private static let quantizationCodeLevelPoints: [(control: Double, levels: Double)] = [
        (0.00, 6),
        (0.15, 6),
        (0.20, 16),
        (0.25, 21),
        (0.30, 36),
        (0.333, 51),
        (0.40, 86),
        (0.50, 161),
        (0.60, 276),
        (0.70, 441),
        (0.75, 541),
        (0.80, 649),
        (0.90, 814),
        (0.99, 999),
        (1.00, 1024)
    ]

    private static func quantizationCodeLevels(for control: Double) -> Int {
        let clamped = control.clamped(to: 0 ... 1)
        let points = quantizationCodeLevelPoints
        guard let first = points.first, let last = points.last else { return 1024 }
        if clamped <= first.control { return Int(first.levels) }
        if clamped >= last.control { return Int(last.levels) }
        for (lower, upper) in zip(points, points.dropFirst()) {
            guard clamped <= upper.control else { continue }
            let fraction = (clamped - lower.control) / (upper.control - lower.control)
            return Int((lower.levels + (upper.levels - lower.levels) * fraction).rounded())
        }
        return Int(last.levels)
    }

}

enum ColorChannel: CaseIterable, Sendable {
    case red, green, blue
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
