import AppKit
import CoreGraphics
import Foundation
import notify

@MainActor
final class DisplayRecoveryCoordinator {
    typealias Recovery = (_ restoresTopology: Bool) -> Void

    private let recover: Recovery
    private let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
    private var notificationTokens: [NSObjectProtocol] = []
    private var scheduledRecovery: DispatchWorkItem?
    private var retryRecovery: DispatchWorkItem?
    private var pendingTopologyRestore = false
    private var pendingApplicationEffectsRecovery = false
    private var recoveryRetriesRemaining = 0
    private var isRecovering = false
    private var isStarted = false
    private var ignoreReconfigurationUntil = Date.distantPast
    private var powerSourceNotificationToken: Int32?

    /// WindowServer can clear a transfer table more than once while a mode
    /// transition settles. Keep the recovery bounded, but give application-
    /// owned effects enough passes to survive the complete transition.
    private static let applicationEffectsRecoveryRetries = 3
    private static let normalRecoveryRetries = 1
    private static let recoveryDelay: TimeInterval = 1.5

    init(recover: @escaping Recovery) {
        self.recover = recover
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
              Self.shouldScheduleRecovery(
                for: flags,
                duringCooldown: Date() < ignoreReconfigurationUntil
              )
        else { return }
        scheduleRecovery(
            restoresTopology: Self.shouldRestoreTopology(for: flags),
            applicationEffects: Self.isApplicationEffectsReset(for: flags)
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

    static func shouldScheduleRecovery(
        for flags: CGDisplayChangeSummaryFlags,
        duringCooldown: Bool
    ) -> Bool {
        guard !flags.contains(.beginConfigurationFlag), shouldRecover(for: flags) else {
            return false
        }
        return !duringCooldown || isApplicationEffectsReset(for: flags)
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
        ignoreReconfigurationUntil = Date().addingTimeInterval(1.0)

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
