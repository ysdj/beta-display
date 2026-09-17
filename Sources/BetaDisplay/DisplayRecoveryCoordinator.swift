import AppKit
import CoreGraphics
import Foundation
import notify

@MainActor
final class DisplayRecoveryCoordinator {
    typealias Recovery = (_ restoresTopology: Bool) -> Void
    /// Returns true when application-owned effects had to be written again.
    typealias Verification = () -> Bool

    private let recover: Recovery
    private let verify: Verification
    private let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
    private var notificationTokens: [NSObjectProtocol] = []
    private var scheduledRecovery: DispatchWorkItem?
    private var retryRecovery: DispatchWorkItem?
    private var integrityVerification: DispatchWorkItem?
    private var startupVerifications: [DispatchWorkItem] = []
    private var pendingTopologyRestore = false
    private var pendingApplicationEffectsRecovery = false
    private var recoveryRetriesRemaining = 0
    private var isRecovering = false
    private var isStarted = false
    private var isWatchingIntegrity = false
    private var powerSourceNotificationToken: Int32?

    /// WindowServer can clear a transfer table more than once while a mode
    /// transition settles. Keep the recovery bounded, but give application-
    /// owned effects enough passes to survive the complete transition.
    private static let applicationEffectsRecoveryRetries = 3
    private static let normalRecoveryRetries = 1
    private static let recoveryDelay: TimeInterval = 1.5

    init(recover: @escaping Recovery, verify: @escaping Verification = { false }) {
        self.recover = recover
        self.verify = verify
    }

    func start() {
        guard notificationTokens.isEmpty else { return }
        isStarted = true
        notificationTokens = [
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRecovery(restoresTopology: false, applicationEffects: true)
                }
            },
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRecovery(restoresTopology: false, applicationEffects: true)
                }
            },
            // A login (including the auto-start at login) and a fast user
            // switch back to this session can settle the display state after
            // Beta Display already wrote its tables.
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRecovery(restoresTopology: false, applicationEffects: true)
                }
            }
        ]
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        _ = CGDisplayRegisterReconfigurationCallback(displayRecoveryReconfigurationCallback, pointer)
        var powerSourceNotificationToken: Int32 = 0
        let registrationStatus = notify_register_dispatch(
            Self.powerSourceNotificationName,
            &powerSourceNotificationToken,
            DispatchQueue.main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePowerSourceChange()
            }
        }
        if registrationStatus == NOTIFY_STATUS_OK {
            self.powerSourceNotificationToken = powerSourceNotificationToken
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        scheduledRecovery?.cancel()
        retryRecovery?.cancel()
        scheduledRecovery = nil
        retryRecovery = nil
        stopIntegrityWatch()
        pendingTopologyRestore = false
        pendingApplicationEffectsRecovery = false
        recoveryRetriesRemaining = 0
        if let powerSourceNotificationToken {
            notify_cancel(powerSourceNotificationToken)
            self.powerSourceNotificationToken = nil
        }
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
            workspaceNotificationCenter.removeObserver(token)
        }
        notificationTokens.removeAll()
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        _ = CGDisplayRemoveReconfigurationCallback(displayRecoveryReconfigurationCallback, pointer)
    }

    func handleDisplayReconfiguration(_ flags: CGDisplayChangeSummaryFlags) {
        guard isStarted,
              Self.shouldScheduleRecovery(for: flags)
        else { return }
        AppLog.recovery.debug("display reconfiguration flags \(flags.rawValue, privacy: .public)")
        scheduleRecovery(
            restoresTopology: Self.shouldRestoreTopology(for: flags),
            applicationEffects: Self.isApplicationEffectsReset(for: flags)
        )
    }

    /// Verifies that application-owned effects are still installed and
    /// repairs them when they are not. Returns true when a repair was needed.
    @discardableResult
    func verifyApplicationEffects() -> Bool {
        guard isStarted else { return false }
        return verify()
    }

    /// Starts the launch ladder plus the steady verification pass. The
    /// WindowServer can replace the transfer tables while the login session
    /// that launched Beta Display is still settling, so the first seconds
    /// after launch are checked repeatedly and the state is then watched
    /// for as long as the app owns a table.
    func startIntegrityWatch() {
        guard isStarted, !isWatchingIntegrity else { return }
        isWatchingIntegrity = true
        for delay in DisplayLUTIntegrity.startupVerificationDelays {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isStarted else { return }
                self.performVerification(trigger: "launch + \(delay)s")
            }
            startupVerifications.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        scheduleIntegrityVerification()
    }

    func stopIntegrityWatch() {
        isWatchingIntegrity = false
        integrityVerification?.cancel()
        integrityVerification = nil
        startupVerifications.forEach { $0.cancel() }
        startupVerifications.removeAll()
    }

    private func scheduleIntegrityVerification() {
        guard isStarted, isWatchingIntegrity else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted, self.isWatchingIntegrity else { return }
            self.performVerification(trigger: "watch")
            self.scheduleIntegrityVerification()
        }
        integrityVerification = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + DisplayLUTIntegrity.steadyVerificationInterval,
            execute: work
        )
    }

    private func performVerification(trigger: String) {
        guard verify() else { return }
        AppLog.recovery.notice(
            "transfer table repaired after verification trigger \(trigger, privacy: .public)"
        )
    }

    /// Power-source changes can reset WindowServer's transfer table without
    /// producing a display reconfiguration callback. The Darwin notification
    /// used here is specific to AC/battery/UPS source transitions.
    func handlePowerSourceChange() {
        guard isStarted else { return }
        scheduleRecovery(restoresTopology: false, applicationEffects: true)
    }

    /// Main-display handoffs and mode changes can clear app-installed transfer
    /// tables and framebuffer effects, so they still need an
    /// application-effects recovery pass. The recovery callback receives
    /// `restoresTopology == false` for these events and must not write
    /// macOS-owned settings such as resolution, brightness, ColorSync, Night
    /// Shift, or True Tone.
    static func shouldRecover(for flags: CGDisplayChangeSummaryFlags) -> Bool {
        return shouldRestoreTopology(for: flags)
            || isApplicationEffectsReset(for: flags)
    }

    /// Duplicate callbacks are merged into a single pending pass by
    /// `scheduleRecovery`; they are never dropped. A topology change arriving
    /// while a previous recovery is still settling must still be scheduled,
    /// because the in-flight retries may be application-effects only (for
    /// example, a display attached during a mode-change recovery would
    /// otherwise keep its macOS default layout until the next event).
    static func shouldScheduleRecovery(for flags: CGDisplayChangeSummaryFlags) -> Bool {
        !flags.contains(.beginConfigurationFlag) && shouldRecover(for: flags)
    }

    /// A mode change initiated by Beta Display needs an explicit recovery
    /// request because some WindowServer versions do not report a usable
    /// post-change reconfiguration flag to the initiating process.
    func scheduleApplicationEffectsRecovery() {
        guard isStarted else { return }
        scheduleRecovery(restoresTopology: false, applicationEffects: true)
    }

    private static func isApplicationEffectsReset(for flags: CGDisplayChangeSummaryFlags) -> Bool {
        let applicationEffectsResetFlags: CGDisplayChangeSummaryFlags = [
            // Remote display sessions can hand the main-display role back to
            // the physical display after its panel wakes without reporting a
            // connect, disconnect, or mode change. The transfer table may
            // have been reset by then, so restore only Beta Display's
            // application-owned effects for this transition.
            .setMainFlag,
            .setModeFlag,
            .desktopShapeChangedFlag
        ]
        return !flags.intersection(applicationEffectsResetFlags).isEmpty
    }

    /// IOKit documents this Darwin notification as the AC/battery source
    /// transition signal, not a battery percentage/time-remaining update.
    private static let powerSourceNotificationName =
        "com.apple.system.powersources.source"

    static func shouldRestoreTopology(for flags: CGDisplayChangeSummaryFlags) -> Bool {
        let connectionOrMirroringFlags: CGDisplayChangeSummaryFlags = [
            .addFlag,
            .removeFlag,
            .enabledFlag,
            .disabledFlag,
            .mirrorFlag,
            .unMirrorFlag
        ]
        return !flags.intersection(connectionOrMirroringFlags).isEmpty
    }

    private func scheduleRecovery(
        restoresTopology: Bool,
        applicationEffects: Bool
    ) {
        pendingTopologyRestore = pendingTopologyRestore || restoresTopology
        pendingApplicationEffectsRecovery = pendingApplicationEffectsRecovery || applicationEffects
        guard !isRecovering else { return }
        recoveryRetriesRemaining = max(
            recoveryRetriesRemaining,
            applicationEffects
                ? Self.applicationEffectsRecoveryRetries
                : Self.normalRecoveryRetries
        )
        scheduledRecovery?.cancel()
        retryRecovery?.cancel()
        retryRecovery = nil
        let work = DispatchWorkItem { [weak self] in
            self?.performRecovery()
        }
        scheduledRecovery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func performRecovery() {
        guard !isRecovering else { return }
        isRecovering = true
        let restoresTopology = pendingTopologyRestore
        pendingTopologyRestore = false
        let applicationEffects = pendingApplicationEffectsRecovery
        pendingApplicationEffectsRecovery = false
        if applicationEffects {
            recoveryRetriesRemaining = max(
                recoveryRetriesRemaining,
                Self.applicationEffectsRecoveryRetries
            )
        }
        recover(restoresTopology)
        isRecovering = false

        // A callback can arrive while the recovery closure is writing the
        // tables. Preserve it for the next pass instead of dropping it behind
        // the `isRecovering` guard.
        if pendingApplicationEffectsRecovery {
            recoveryRetriesRemaining = max(
                recoveryRetriesRemaining,
                Self.applicationEffectsRecoveryRetries
            )
            pendingApplicationEffectsRecovery = false
        }
        if pendingTopologyRestore {
            recoveryRetriesRemaining = max(
                recoveryRetriesRemaining,
                Self.normalRecoveryRetries
            )
        }
        guard recoveryRetriesRemaining > 0 else {
            pendingTopologyRestore = false
            return
        }
        recoveryRetriesRemaining -= 1
        pendingTopologyRestore = pendingTopologyRestore || restoresTopology
        let retryWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.performRecovery()
        }
        retryRecovery?.cancel()
        retryRecovery = retryWork
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recoveryDelay, execute: retryWork)
    }
}

private let displayRecoveryReconfigurationCallback: CGDisplayReconfigurationCallBack = {
    _, flags, userInfo in
    guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
    let coordinator = Unmanaged<DisplayRecoveryCoordinator>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    Task { @MainActor in
        coordinator.handleDisplayReconfiguration(flags)
    }
}
