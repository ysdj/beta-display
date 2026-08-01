import AppKit
import CoreGraphics
import Foundation

@MainActor
final class DisplayRecoveryCoordinator {
    typealias Recovery = (_ restoresTopology: Bool) -> Void

    private let recover: Recovery
    private let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
    private var notificationTokens: [NSObjectProtocol] = []
    private var scheduledRecovery: DispatchWorkItem?
    private var retryRecovery: DispatchWorkItem?
    private var pendingTopologyRestore = false
    private var retryRestoresTopology = false
    private var isRecovering = false
    private var isStarted = false
    private var ignoreReconfigurationUntil = Date.distantPast

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
                Task { @MainActor in self?.scheduleRecovery(restoresTopology: false) }
            },
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleRecovery(restoresTopology: false) }
            },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleRecovery(restoresTopology: false) }
            }
        ]
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        _ = CGDisplayRegisterReconfigurationCallback(displayRecoveryReconfigurationCallback, pointer)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        scheduledRecovery?.cancel()
        retryRecovery?.cancel()
        scheduledRecovery = nil
        retryRecovery = nil
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
              !flags.contains(.beginConfigurationFlag),
              Date() >= ignoreReconfigurationUntil
        else { return }
        scheduleRecovery(restoresTopology: Self.shouldRestoreTopology(for: flags))
    }

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

    private func scheduleRecovery(restoresTopology: Bool) {
        guard !isRecovering else { return }
        pendingTopologyRestore = pendingTopologyRestore || restoresTopology
        scheduledRecovery?.cancel()
        retryRecovery?.cancel()
        retryRecovery = nil
        let work = DispatchWorkItem { [weak self] in
            self?.performRecovery(retry: false)
        }
        scheduledRecovery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func performRecovery(retry: Bool) {
        guard !isRecovering else { return }
        isRecovering = true
        let restoresTopology = pendingTopologyRestore
        pendingTopologyRestore = false
        if !retry {
            retryRestoresTopology = retryRestoresTopology || restoresTopology
        }
        recover(restoresTopology)
        isRecovering = false
        ignoreReconfigurationUntil = Date().addingTimeInterval(1.0)

        guard !retry else {
            retryRestoresTopology = false
            return
        }
        retryRecovery?.cancel()
        let retryWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingTopologyRestore = self.retryRestoresTopology
            self.performRecovery(retry: true)
        }
        retryRecovery = retryWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: retryWork)
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
