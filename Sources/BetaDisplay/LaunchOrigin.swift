import AppKit
import Carbon

/// Why this process was started.
///
/// macOS marks a login-item start inside the `kAEOpenApplication` Apple event,
/// which is the only signal that reliably separates an automatic start from
/// the user opening the app. The decision itself is a pure function so the
/// self-test can exercise it without a real login.
enum LaunchOrigin {
    enum Source: Equatable {
        case user
        case loginItem

        var diagnosticName: String {
            switch self {
            case .user: "user"
            case .loginItem: "login item"
            }
        }
    }

    /// The login-item marker has appeared both as its own boolean parameter and
    /// as the property-data code of the open-application event, so both
    /// spellings are accepted.
    static func source(loginItemFlag: Bool?, propertyDataCode: OSType?) -> Source {
        if loginItemFlag == true { return .loginItem }
        if propertyDataCode == keyAELaunchedAsLogInItem { return .loginItem }
        return .user
    }

    static var current: Source {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return .user }
        return source(
            loginItemFlag: event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.booleanValue,
            propertyDataCode: event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        )
    }

    /// Log-safe description of the launch event. A terminal launch has no Apple
    /// event at all, and the parameter codes are recorded so a start that was
    /// not recognized can be diagnosed from the operational log.
    static var currentDiagnostic: String {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            return "no launch event"
        }
        let flag = event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.booleanValue
        let propertyData = event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        return "login flag \(flag.map(String.init) ?? "absent"), property data \(propertyData.map(fourCharacterCode) ?? "absent")"
    }

    private static func fourCharacterCode(_ code: OSType) -> String {
        let scalars = (0 ..< 4).compactMap { offset -> Unicode.Scalar? in
            let byte = UInt8((code >> UInt32((3 - offset) * 8)) & 0xFF)
            return (0x20 ... 0x7E).contains(byte) ? Unicode.Scalar(byte) : nil
        }
        return scalars.count == 4 ? String(String.UnicodeScalarView(scalars)) : String(code)
    }
}
