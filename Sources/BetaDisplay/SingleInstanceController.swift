import Darwin
import Foundation

/// Holds a per-user advisory file lock for the lifetime of the app. A second
/// launch signals the existing process to surface its settings window and exits.
@MainActor
final class SingleInstanceController {
    static let activationRequest = Notification.Name("io.github.ysdj.betadisplay.activateExistingWindow")

    private var lockDescriptors: [Int32] = []

    func claim() -> Bool {
        guard lockDescriptors.isEmpty else { return true }
        guard let lockURLs = Self.lockURLs() else { return false }
        var descriptors: [Int32] = []
        for lockURL in lockURLs {
            let descriptor = lockURL.path.withCString {
                open(
                    $0,
                    O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            guard descriptor >= 0,
                  flock(descriptor, LOCK_EX | LOCK_NB) == 0
            else {
                if descriptor >= 0 { close(descriptor) }
                descriptors.forEach { close($0) }
                return false
            }
            descriptors.append(descriptor)
        }
        lockDescriptors = descriptors
        return true
    }

    private static func lockURLs() -> [URL]? {
        guard let temporaryURL = temporaryLockURL() else { return nil }
        guard let legacyURL = legacyLockURL(), legacyURL != temporaryURL else {
            return [temporaryURL]
        }
        return [temporaryURL, legacyURL]
    }

    private static func temporaryLockURL() -> URL? {
        // Application Support follows CFFIXED_USER_HOME, which allowed a test
        // bundle with isolated preferences to run beside the installed app.
        // confstr bypasses Foundation preference-home overrides and returns the
        // stable Darwin temporary directory for the current login user.
        let requiredLength = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard requiredLength > 0 else { return nil }
        var directory = Array(repeating: CChar(0), count: requiredLength)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &directory, requiredLength) > 0 else { return nil }
        guard var directoryPath = directory.withUnsafeBufferPointer({ buffer -> String? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return String(cString: baseAddress)
        }) else { return nil }
        if !directoryPath.hasSuffix("/") { directoryPath.append("/") }
        return URL(fileURLWithPath: directoryPath)
            .appendingPathComponent("io.github.ysdj.betadisplay.instance.lock")
    }

    private static func legacyLockURL() -> URL? {
        guard let passwordEntry = getpwuid(getuid()),
              let homeDirectory = passwordEntry.pointee.pw_dir
        else { return nil }
        let directory = URL(fileURLWithPath: String(cString: homeDirectory), isDirectory: true)
            .appendingPathComponent("Library/Application Support/BetaDisplay", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // The temporary lock still protects normal launches when this
            // compatibility path is unavailable or read-only.
            return nil
        }
        return directory.appendingPathComponent("instance.lock", isDirectory: false)
    }

    func requestActivationOfExistingInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.activationRequest,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    func release() {
        guard !lockDescriptors.isEmpty else { return }
        lockDescriptors.forEach {
            _ = flock($0, LOCK_UN)
            close($0)
        }
        lockDescriptors.removeAll(keepingCapacity: false)
    }
}
