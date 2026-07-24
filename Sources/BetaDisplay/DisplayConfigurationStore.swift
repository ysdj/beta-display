import ColorSync
import CoreGraphics
import Foundation

struct PersistedColorProfile: Codable, Equatable, Sendable {
    var profileURL: String?
    var usesFactoryProfile: Bool
}

struct PersistedMirrorConfiguration: Codable, Equatable, Sendable {
    /// Nil means the display should be explicitly unmirrored. The enclosing
    /// optional distinguishes that choice from a display with no saved intent.
    var targetDisplayKey: String?
}

struct PersistedDisplayConfiguration: Codable, Equatable, Sendable {
    var adjustments: ColorAdjustments?
    var colorProfile: PersistedColorProfile?
    var framebufferMode: Int32?
    var ditheringEnabled: Bool?
    var uniformityCorrectionEnabled: Bool?
    var displayModeID: String?
    var originX: Int?
    var originY: Int?
    var mirror: PersistedMirrorConfiguration?

    init(
        adjustments: ColorAdjustments? = nil,
        colorProfile: PersistedColorProfile? = nil,
        framebufferMode: Int32? = nil,
        ditheringEnabled: Bool? = nil,
        uniformityCorrectionEnabled: Bool? = nil,
        displayModeID: String? = nil,
        originX: Int? = nil,
        originY: Int? = nil,
        mirror: PersistedMirrorConfiguration? = nil
    ) {
        self.adjustments = adjustments
        self.colorProfile = colorProfile
        self.framebufferMode = framebufferMode
        self.ditheringEnabled = ditheringEnabled
        self.uniformityCorrectionEnabled = uniformityCorrectionEnabled
        self.displayModeID = displayModeID
        self.originX = originX
        self.originY = originY
        self.mirror = mirror
    }
}

enum DisplayIdentity {
    static func key(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let value = CFUUIDCreateString(kCFAllocatorDefault, uuid)
        else { return nil }
        return value as String
    }

    /// A session-only key that stays useful even for a display that does not
    /// expose a UUID. Persistent settings intentionally use `key(for:)` only;
    /// this fallback is for restoring a value within the current process.
    static func sessionKey(for displayID: CGDirectDisplayID) -> String {
        key(for: displayID) ?? "display-id-\(displayID)"
    }

    static func activeDisplayIDsBySessionKey() -> [String: CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return [:]
        }
        var displayIDs = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else {
            return [:]
        }
        return Dictionary(
            uniqueKeysWithValues: displayIDs.prefix(Int(count)).map {
                (sessionKey(for: $0), $0)
            }
        )
    }
}

@MainActor
final class DisplayConfigurationStore {
    private let defaults: UserDefaults
    private let storageKey = "BetaDisplay.displayConfiguration"
    private var configurations: [String: PersistedDisplayConfiguration]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(
               [String: PersistedDisplayConfiguration].self,
               from: data
           ) {
            configurations = decoded
        } else {
            configurations = [:]
        }
    }

    func configuration(for displayID: CGDirectDisplayID) -> PersistedDisplayConfiguration? {
        guard let key = DisplayIdentity.key(for: displayID) else { return nil }
        return configurations[key]
    }

    func configuration(forDisplayKey key: String) -> PersistedDisplayConfiguration? {
        configurations[key]
    }

    func update(
        for displayID: CGDirectDisplayID,
        _ change: (inout PersistedDisplayConfiguration) -> Void
    ) {
        guard let key = DisplayIdentity.key(for: displayID) else { return }
        var configuration = configurations[key] ?? PersistedDisplayConfiguration()
        change(&configuration)
        configurations[key] = configuration
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
