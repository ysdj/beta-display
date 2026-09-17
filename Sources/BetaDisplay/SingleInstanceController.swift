import Darwin
import Foundation

/// Holds a per-user advisory file lock for the lifetime of the app. A second
/// launch signals the existing process to surface its settings window and exits.
@MainActor
final class SingleInstanceController {
    static let activationRequest = Notification.Name("io.github.ysdj.betadisplay.activateExistingWindow")

    enum ClaimResult: Equatable {
        /// This process owns the lock and should run normally.
        case acquired
        /// Another process owns the lock; it was asked to show its window.
        case existingInstance
        /// No usable lock location exists. The app still runs without
        /// single-instance protection instead of exiting silently. The reason
        /// is carried instead of logged so exercising this decision (the
        /// self-test does) cannot pollute the operational log.
        case unavailable(reason: String)
    }

    private var lockDescriptors: [Int32] = []

    /// Claims the instance lock for this process and reports the reason
    /// through the operational log when the app has to continue without
    /// single-instance protection.
    func claimAndReport() -> ClaimResult {
        let result = claim(lockURLs: Self.lockURLs())
        if case let .unavailable(reason) = result {
            AppLog.launch.error(
                "\(reason, privacy: .public); continuing without single-instance protection"
            )
        }
        return result
    }

    func claim() -> ClaimResult {
        claim(lockURLs: Self.lockURLs())
    }

    /// Lock handling with explicit locations. `nil` models a system where the
    /// lock cannot be located; the app must keep running in that case instead
    /// of exiting without a window.
    func claim(lockURLs: [URL]?) -> ClaimResult {
        guard lockDescriptors.isEmpty else { return .acquired }
        guard let lockURLs else {
            return .unavailable(reason: "instance lock locations are unavailable")
        }
        var descriptors: [Int32] = []
        for lockURL in lockURLs {
            let descriptor = lockURL.path.withCString {
                open(
                    $0,
                    O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            guard descriptor >= 0 else {
                descriptors.forEach { close($0) }
                return .unavailable(
                    reason: "cannot open the instance lock at \(lockURL.path)"
                )
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let lockError = errno
                close(descriptor)
                descriptors.forEach { close($0) }
                guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
                    return .unavailable(
                        reason: "cannot take the instance lock at \(lockURL.path): errno \(lockError)"
                    )
                }
                return .existingInstance
            }
            descriptors.append(descriptor)
        }
        lockDescriptors = descriptors
        return .acquired
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
        if let url = Self.activationRequestURL() {
            Self.writeActivationRequest(to: url)
        }
        DistributedNotificationCenter.default().postNotificationName(
            Self.activationRequest,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Consumes a pending activation request written by a second launch. The
    /// request is persisted before the distributed notification is posted and
    /// consumed after this process registered its observer, so a second
    /// launch that races the first launch's setup is not lost.
    func consumeActivationRequest() -> Bool {
        guard let url = Self.activationRequestURL() else { return false }
        return Self.consumeActivationRequest(at: url)
    }

    @discardableResult
    static func writeActivationRequest(to url: URL) -> Bool {
        do {
            try Data(String(Date().timeIntervalSince1970).utf8).write(to: url, options: .atomic)
            return true
        } catch {
            AppLog.launch.error(
                "cannot write the activation request: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    static func consumeActivationRequest(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLog.launch.error(
                "cannot remove the activation request: \(error.localizedDescription, privacy: .public)"
            )
        }
        return true
    }

    private static func activationRequestURL() -> URL? {
        guard let lockURL = temporaryLockURL() else { return nil }
        return lockURL.deletingLastPathComponent()
            .appendingPathComponent("io.github.ysdj.betadisplay.activate.request")
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
