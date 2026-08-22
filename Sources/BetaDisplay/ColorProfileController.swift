import ColorSync
import CoreGraphics
import Foundation

struct ColorProfileDescriptor: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isCurrent: Bool
    let isFactory: Bool

    var id: String { url.absoluteString }
}

@MainActor
final class ColorProfileController {
    private struct InitialProfileState {
        let defaultProfileID: String
        let customProfileURL: URL?
    }

    private let configurationStore: DisplayConfigurationStore
    private let displayDeviceClass: CFString = "mntr" as CFString
    private(set) var profiles: [ColorProfileDescriptor] = []
    private(set) var currentProfileURL: URL?
    private(set) var factoryProfileURL: URL?
    private var defaultProfileID: String?
    private var initialProfiles: [String: InitialProfileState] = [:]
    private var modifiedProfileSessionKeys: Set<String> = []
    private(set) var statusMessage = L10n.text("status.choose_display_for_profile")
    var onStateChanged: (() -> Void)?

    init(configurationStore: DisplayConfigurationStore) {
        self.configurationStore = configurationStore
    }

    /// Captures the ColorSync profile that was active before this process
    /// applies any remembered Beta Display profile.
    func captureInitialProfiles(for displayIDs: [CGDirectDisplayID]) {
        for displayID in displayIDs {
            captureInitialProfileIfNeeded(for: displayID)
        }
    }

    func refresh(for displayID: CGDirectDisplayID?) {
        guard let displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            profiles = []
            currentProfileURL = nil
            factoryProfileURL = nil
            defaultProfileID = nil
            statusMessage = L10n.text("status.no_display_selected")
            publish()
            return
        }
        guard let rawInfo = ColorSyncDeviceCopyDeviceInfo(displayDeviceClass, uuid)
        else {
            profiles = []
            currentProfileURL = nil
            factoryProfileURL = nil
            defaultProfileID = nil
            statusMessage = L10n.text("status.no_profile_info")
            publish()
            return
        }

        let info = rawInfo.takeRetainedValue() as NSDictionary
        let factoryProfiles = info["FactoryProfiles"] as? [String: Any]
        let defaultID = factoryProfiles?["DeviceDefaultProfileID"] as? String
        defaultProfileID = defaultID
        let factoryEntry = defaultID.flatMap { factoryProfiles?[$0] as? [String: Any] }
        factoryProfileURL = profileURL(from: factoryEntry?["DeviceProfileURL"])

        let customProfiles = info["CustomProfiles"] as? [String: Any]
        let customURL = defaultID.flatMap { profileURL(from: customProfiles?[$0]) }
        if let defaultID {
            captureInitialProfileIfNeeded(
                for: displayID,
                defaultProfileID: defaultID,
                customProfileURL: customURL
            )
        }
        currentProfileURL = customURL ?? factoryProfileURL

        var all = installedRGBDisplayProfiles()
        if let currentProfileURL, !all.contains(where: { $0.url == currentProfileURL }) {
            all.append(ColorProfileDescriptor(
                url: currentProfileURL,
                name: currentProfileURL.deletingPathExtension().lastPathComponent,
                isCurrent: true,
                isFactory: currentProfileURL == factoryProfileURL
            ))
        }
        if let factoryProfileURL, !all.contains(where: { $0.url == factoryProfileURL }) {
            all.append(ColorProfileDescriptor(
                url: factoryProfileURL,
                name: factoryProfileURL.deletingPathExtension().lastPathComponent,
                isCurrent: false,
                isFactory: true
            ))
        }
        profiles = all
            .map { profile in
                ColorProfileDescriptor(
                    url: profile.url,
                    name: profile.name,
                    isCurrent: profile.url == currentProfileURL,
                    isFactory: profile.url == factoryProfileURL
                )
            }
            .sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                if lhs.isFactory != rhs.isFactory { return lhs.isFactory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        statusMessage = profiles.isEmpty
            ? L10n.text("status.no_rgb_profiles")
            : L10n.text("status.profiles_loaded", profiles.count)
        publish()
    }

    @discardableResult
    func setProfile(url: URL, for displayID: CGDirectDisplayID?) -> Bool {
        guard let displayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let defaultProfileID
        else {
            statusMessage = L10n.text("status.no_display_selected")
            publish()
            return false
        }
        if currentProfileURL == url {
            return false
        }
        captureInitialProfileIfNeeded(for: displayID)
        let profileInfo: NSDictionary = [defaultProfileID: url as CFURL]
        guard ColorSyncDeviceSetCustomProfiles(displayDeviceClass, uuid, profileInfo) else {
            statusMessage = L10n.text("status.profile_rejected")
            publish()
            return false
        }
        refresh(for: displayID)
        configurationStore.update(for: displayID) {
            $0.colorProfile = PersistedColorProfile(
                profileURL: url.absoluteString,
                usesFactoryProfile: false
            )
        }
        modifiedProfileSessionKeys.insert(DisplayIdentity.sessionKey(for: displayID))
        statusMessage = L10n.text(
            "status.profile_set",
            url.deletingPathExtension().lastPathComponent
        )
        publish()
        return true
    }

    @discardableResult
    func restoreFactoryProfile(for displayID: CGDirectDisplayID?) -> Bool {
        guard let displayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let defaultProfileID
        else {
            statusMessage = L10n.text("status.no_display_selected")
            publish()
            return false
        }
        if currentProfileURL == factoryProfileURL {
            return false
        }
        captureInitialProfileIfNeeded(for: displayID)
        let profileInfo: NSDictionary = [defaultProfileID: kCFNull as Any]
        guard ColorSyncDeviceSetCustomProfiles(displayDeviceClass, uuid, profileInfo) else {
            statusMessage = L10n.text("status.profile_restore_rejected")
            publish()
            return false
        }
        refresh(for: displayID)
        configurationStore.update(for: displayID) {
            $0.colorProfile = PersistedColorProfile(profileURL: nil, usesFactoryProfile: true)
        }
        modifiedProfileSessionKeys.insert(DisplayIdentity.sessionKey(for: displayID))
        statusMessage = L10n.text("status.profile_restored")
        publish()
        return true
    }

    func restoreAllInitialProfiles() {
        let activeDisplays = DisplayIdentity.activeDisplayIDsBySessionKey()
        for sessionKey in modifiedProfileSessionKeys {
            guard let displayID = activeDisplays[sessionKey],
                  let initial = initialProfiles[sessionKey],
                  let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
            else { continue }
            let value: Any = initial.customProfileURL.map { $0 as CFURL } ?? (kCFNull as Any)
            _ = ColorSyncDeviceSetCustomProfiles(
                displayDeviceClass,
                uuid,
                [initial.defaultProfileID: value] as NSDictionary
            )
        }
    }

    func applySavedProfiles(
        to displayIDs: [CGDirectDisplayID],
        applying change: (CGDirectDisplayID, () -> Bool) -> Void
    ) {
        for displayID in displayIDs {
            refresh(for: displayID)
            guard let saved = configurationStore.configuration(for: displayID)?.colorProfile else { continue }
            if saved.usesFactoryProfile,
               currentProfileURL != factoryProfileURL {
                change(displayID) { self.restoreFactoryProfile(for: displayID) }
            } else if let string = saved.profileURL,
                      let url = URL(string: string),
                      FileManager.default.fileExists(atPath: url.path),
                      currentProfileURL != url {
                change(displayID) { self.setProfile(url: url, for: displayID) }
            }
        }
    }

    private func installedRGBDisplayProfiles() -> [ColorProfileDescriptor] {
        final class Collector {
            var profiles: [ColorProfileDescriptor] = []
        }
        let collector = Collector()
        let callback: ColorSyncProfileIterateCallback = { info, userInfo in
            guard let info, let userInfo else { return false }
            let collector = Unmanaged<Collector>.fromOpaque(userInfo).takeUnretainedValue()
            let values = info as NSDictionary
            guard (values["com.apple.ColorSync.ProfileIsValid"] as? Bool) != false,
                  values["com.apple.ColorSync.ProfileClass"] as? String == "mntr",
                  values["com.apple.ColorSync.ProfileColorSpace"] as? String == "RGB ",
                  let url = values["com.apple.ColorSync.ProfileURL"] as? URL
            else { return true }
            let name = (values["com.apple.ColorSync.ProfileDescription"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            collector.profiles.append(ColorProfileDescriptor(
                url: url,
                name: name,
                isCurrent: false,
                isFactory: false
            ))
            return true
        }
        var seed: UInt32 = 0
        var error: Unmanaged<CFError>?
        ColorSyncIterateInstalledProfilesWithOptions(
            callback,
            &seed,
            Unmanaged.passUnretained(collector).toOpaque(),
            nil,
            &error
        )
        _ = error?.takeRetainedValue()
        var seen = Set<URL>()
        return collector.profiles.filter { seen.insert($0.url).inserted }
    }

    private func profileURL(from value: Any?) -> URL? {
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private func captureInitialProfileIfNeeded(
        for displayID: CGDirectDisplayID,
        defaultProfileID: String,
        customProfileURL: URL?
    ) {
        let sessionKey = DisplayIdentity.sessionKey(for: displayID)
        guard initialProfiles[sessionKey] == nil else { return }
        initialProfiles[sessionKey] = InitialProfileState(
            defaultProfileID: defaultProfileID,
            customProfileURL: customProfileURL
        )
    }

    private func captureInitialProfileIfNeeded(for displayID: CGDirectDisplayID) {
        guard initialProfiles[DisplayIdentity.sessionKey(for: displayID)] == nil else { return }
        refresh(for: displayID)
    }

    private func publish() {
        onStateChanged?()
    }
}
