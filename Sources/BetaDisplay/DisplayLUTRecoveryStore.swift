import CoreGraphics
import Foundation

/// Persists the unadjusted transfer table while Beta Display owns a display's
/// LUT. The record survives an unclean exit, preventing the next launch from
/// adopting the still-adjusted table as a new baseline. A successful normal
/// restore removes it.
@MainActor
final class DisplayLUTRecoveryStore {
    private struct PersistedLUT: Codable, Equatable {
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]

        init(_ lut: DisplayLUT) {
            red = lut.red
            green = lut.green
            blue = lut.blue
        }

        var displayLUT: DisplayLUT? {
            guard red.count >= 2,
                  red.count == green.count,
                  green.count == blue.count,
                  red.allSatisfy(\.isFinite),
                  green.allSatisfy(\.isFinite),
                  blue.allSatisfy(\.isFinite)
            else { return nil }
            return DisplayLUT(red: red, green: green, blue: blue)
        }
    }

    private let defaults: UserDefaults
    private let storageKey = "BetaDisplay.displayLUTRecovery.v1"
    private var baselines: [String: PersistedLUT]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? PropertyListDecoder().decode(
               [String: PersistedLUT].self,
               from: data
           ) {
            baselines = decoded.filter { $0.value.displayLUT != nil }
        } else {
            baselines = [:]
        }
    }

    func baseline(for displayID: CGDirectDisplayID) -> DisplayLUT? {
        guard let key = DisplayIdentity.key(for: displayID) else { return nil }
        return baseline(forDisplayKey: key)
    }

    func recordBaseline(_ lut: DisplayLUT, for displayID: CGDirectDisplayID) {
        guard let key = DisplayIdentity.key(for: displayID) else { return }
        recordBaseline(lut, forDisplayKey: key)
    }

    func removeBaseline(for displayID: CGDirectDisplayID) {
        guard let key = DisplayIdentity.key(for: displayID) else { return }
        removeBaseline(forDisplayKey: key)
    }

    func baseline(forDisplayKey key: String) -> DisplayLUT? {
        baselines[key]?.displayLUT
    }

    func recordBaseline(_ lut: DisplayLUT, forDisplayKey key: String) {
        let persisted = PersistedLUT(lut)
        guard persisted.displayLUT != nil,
              baselines[key] != persisted
        else { return }
        baselines[key] = persisted
        save()
    }

    func removeBaseline(forDisplayKey key: String) {
        guard baselines.removeValue(forKey: key) != nil
        else { return }
        save()
    }

    private func save() {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(baselines) else { return }
        defaults.set(data, forKey: storageKey)
        defaults.synchronize()
    }
}
