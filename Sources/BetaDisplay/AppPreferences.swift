import Foundation
import ServiceManagement

@MainActor
final class AppPreferences {
    enum Change {
        case menuBarIcon
        case launchAtLogin
        case enableDitheringForColorModes
        case interfaceLanguage
    }

    private enum Key {
        static let showMenuBarIcon = "BetaDisplay.showMenuBarIcon"
        static let launchAtLogin = "BetaDisplay.launchAtLogin"
        static let enableDitheringForColorModes = "BetaDisplay.enableDitheringForColorModes"
        static let interfaceLanguage = "BetaDisplay.interfaceLanguage"
    }

    private let defaults: UserDefaults
    var onChange: ((Change) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showMenuBarIcon: true,
            Key.launchAtLogin: true,
            Key.enableDitheringForColorModes: true
        ])
    }

    var showMenuBarIcon: Bool {
        defaults.bool(forKey: Key.showMenuBarIcon)
    }

    var launchAtLogin: Bool {
        defaults.bool(forKey: Key.launchAtLogin)
    }

    /// Inversion and grayscale reduce usable color resolution. Mirror the
    /// display-tool behavior of enabling GPU dithering by default, while
    /// leaving the choice reversible and visible in the image settings.
    var enableDitheringForColorModes: Bool {
        defaults.bool(forKey: Key.enableDitheringForColorModes)
    }

    var interfaceLanguage: InterfaceLanguage {
        guard let rawValue = defaults.string(forKey: Key.interfaceLanguage),
              let language = InterfaceLanguage(rawValue: rawValue)
        else {
            return .automatic
        }
        return language
    }

    func setShowMenuBarIcon(_ enabled: Bool) {
        guard enabled != showMenuBarIcon else { return }
        defaults.set(enabled, forKey: Key.showMenuBarIcon)
        onChange?(.menuBarIcon)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != launchAtLogin else { return }
        defaults.set(enabled, forKey: Key.launchAtLogin)
        onChange?(.launchAtLogin)
    }

    func setEnableDitheringForColorModes(_ enabled: Bool) {
        guard enabled != enableDitheringForColorModes else { return }
        defaults.set(enabled, forKey: Key.enableDitheringForColorModes)
        onChange?(.enableDitheringForColorModes)
    }

    func setInterfaceLanguage(_ language: InterfaceLanguage) {
        guard language != interfaceLanguage else { return }
        defaults.set(language.rawValue, forKey: Key.interfaceLanguage)
        onChange?(.interfaceLanguage)
    }

    func resetGeneralSettings() {
        defaults.set(true, forKey: Key.showMenuBarIcon)
        defaults.set(true, forKey: Key.launchAtLogin)
        defaults.set(true, forKey: Key.enableDitheringForColorModes)
        defaults.set(InterfaceLanguage.automatic.rawValue, forKey: Key.interfaceLanguage)
        onChange?(.menuBarIcon)
        onChange?(.launchAtLogin)
        onChange?(.enableDitheringForColorModes)
        onChange?(.interfaceLanguage)
    }
}

@MainActor
final class LaunchAtLoginController {
    enum Status: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable(String)

        var description: String {
            switch self {
            case .enabled:
                L10n.text("login.enabled")
            case .disabled:
                L10n.text("login.disabled")
            case .requiresApproval:
                L10n.text("login.requires_approval")
            case let .unavailable(message):
                message
            }
        }

        /// A stable, log-safe name for diagnostics. The user-facing
        /// description is localized and may embed a system error message.
        var diagnosticName: String {
            switch self {
            case .enabled: "enabled"
            case .disabled: "not registered"
            case .requiresApproval: "requires approval"
            case .unavailable: "unavailable"
            }
        }
    }

    private(set) var status: Status = .disabled
    var onStatusChanged: (() -> Void)?

    init() {
        refresh()
    }

    func synchronize(with preference: Bool) {
        if preference {
            enable()
        } else {
            disable()
        }
    }

    func enable() {
        switch SMAppService.mainApp.status {
        case .enabled:
            refresh()
        case .requiresApproval:
            // The registration exists but needs approval in System Settings.
            // Registering again cannot approve it on the user's behalf and
            // would replace the actionable guidance with an error message.
            refresh()
            AppLog.launch.notice(
                "login item is registered but awaits approval in System Settings > General > Login Items"
            )
        case .notRegistered, .notFound:
            do {
                try SMAppService.mainApp.register()
                AppLog.launch.notice("login item registered")
                refresh()
            } catch {
                status = .unavailable(L10n.text("login.enable_failed", error.localizedDescription))
                AppLog.launch.error(
                    "login item registration failed: \(error.localizedDescription, privacy: .public)"
                )
                onStatusChanged?()
            }
        @unknown default:
            refresh()
        }
    }

    func disable() {
        if SMAppService.mainApp.status == .notRegistered {
            refresh()
            return
        }
        do {
            try SMAppService.mainApp.unregister()
            AppLog.launch.notice("login item unregistered")
            refresh()
        } catch {
            status = .unavailable(L10n.text("login.disable_failed", error.localizedDescription))
            AppLog.launch.error(
                "login item removal failed: \(error.localizedDescription, privacy: .public)"
            )
            onStatusChanged?()
        }
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            status = .enabled
        case .requiresApproval:
            status = .requiresApproval
        case .notRegistered, .notFound:
            status = .disabled
        @unknown default:
            status = .unavailable(L10n.text("login.status_unavailable"))
        }
        onStatusChanged?()
    }
}
