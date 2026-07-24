import Foundation

/// The persisted interface-language choice. `automatic` resolves to Chinese
/// for a Chinese system and English for every other system language.
enum InterfaceLanguage: String, CaseIterable, Sendable {
    case automatic
    case english
    case simplifiedChinese

    static let defaultsKey = "BetaDisplay.interfaceLanguage"

    static var storedPreference: InterfaceLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
              let language = InterfaceLanguage(rawValue: rawValue)
        else {
            return .automatic
        }
        return language
    }

    var resolved: InterfaceLanguage {
        switch self {
        case .automatic:
            let preferredLanguage = Locale.preferredLanguages.first?.lowercased() ?? ""
            return preferredLanguage.hasPrefix("zh") ? .simplifiedChinese : .english
        case .english, .simplifiedChinese:
            return self
        }
    }

    var localizationFolder: String {
        switch resolved {
        case .simplifiedChinese:
            "zh-Hans"
        case .automatic, .english:
            "en"
        }
    }
}

/// A small, explicit localization facade. We resolve the selected lproj
/// ourselves so a user-selected language works even when it differs from the
/// language picked by macOS for the process.
enum L10n {
    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let format = localizedBundle(for: InterfaceLanguage.storedPreference)
            .localizedString(forKey: key, value: key, table: "Localizable")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: arguments)
    }

    static func text(_ key: String, language: InterfaceLanguage) -> String {
        localizedBundle(for: language).localizedString(forKey: key, value: key, table: "Localizable")
    }

    static var locale: Locale {
        switch InterfaceLanguage.storedPreference.resolved {
        case .simplifiedChinese:
            Locale(identifier: "zh_Hans_CN")
        case .automatic, .english:
            Locale(identifier: "en_US_POSIX")
        }
    }

    private static func localizedBundle(for language: InterfaceLanguage) -> Bundle {
        let folder = language.localizationFolder
        if let resourceURL = Bundle.module.resourceURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent("\(folder).lproj")) {
            return bundle
        }
        return Bundle.module
    }
}
