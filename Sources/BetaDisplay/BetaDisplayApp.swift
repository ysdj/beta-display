import AppKit
import Darwin

@main
struct BetaDisplayMain {
    private static let deploymentGateMarker = "beta-display-lut-baseline-guard-v2"

    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--deployment-gate") {
            let bundle = Bundle.main
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            print("BetaDisplay deployment-gate \(deploymentGateMarker) \(version) \(build)")
            return
        }
        if CommandLine.arguments.contains("--live-lut-test") {
            let failures = BetaDisplayLiveLUTTest.run()
            guard !failures.isEmpty else {
                print("Beta Display live LUT test passed")
                return
            }
            failures.forEach { print("FAIL: \($0)") }
            exit(EXIT_FAILURE)
        }
        if CommandLine.arguments.contains("--self-test") {
            let failures = BetaDisplaySelfTest.run()
            guard !failures.isEmpty else {
                print("Beta Display self-test passed")
                return
            }
            failures.forEach { print($0) }
            exit(EXIT_FAILURE)
        }
        let singleInstanceController = SingleInstanceController()
        guard singleInstanceController.claim() else {
            singleInstanceController.requestActivationOfExistingInstance()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(singleInstanceController: singleInstanceController)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let singleInstanceController: SingleInstanceController
    private let configurationStore = DisplayConfigurationStore()
    private let displayController: DisplayController
    private let groupController = DisplayGroupController()
    private let modeController: DisplayModeController
    private let layoutController: DisplayLayoutController
    private let framebufferController: FramebufferController
    private let colorProfileController: ColorProfileController
    private let colorModesController: DisplayColorModesController
    private let preferences = AppPreferences()
    private let launchAtLoginController = LaunchAtLoginController()
    private lazy var displayRecoveryCoordinator = DisplayRecoveryCoordinator { [weak self] restoresTopology in
        self?.restoreDisplayStateAfterSystemChange(restoresTopology: restoresTopology)
    }
    private var settingsWindowController: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var restoredProcessEffects = false
    private var dockVisibilityErrorReported = false

    init(singleInstanceController: SingleInstanceController) {
        self.singleInstanceController = singleInstanceController
        displayController = DisplayController(configurationStore: configurationStore)
        modeController = DisplayModeController(configurationStore: configurationStore)
        layoutController = DisplayLayoutController(configurationStore: configurationStore)
        framebufferController = FramebufferController(configurationStore: configurationStore)
        colorProfileController = ColorProfileController(configurationStore: configurationStore)
        colorModesController = DisplayColorModesController()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let failures = BetaDisplaySelfTest.run()
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = L10n.text("app.self_test_failed")
            alert.informativeText = failures.joined(separator: "\n")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        preferences.onChange = { [weak self] change in
            self?.applyPreference(change)
        }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(activateExistingWindow(_:)),
            name: SingleInstanceController.activationRequest,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        launchAtLoginController.synchronize(with: preferences.launchAtLogin)
        updateStatusItemVisibility()
        applySavedDisplayConfiguration()
        displayRecoveryCoordinator.start()
        showSettings(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: SingleInstanceController.activationRequest,
            object: nil
        )
        displayRecoveryCoordinator.stop()
        restoreProcessEffectsOnce()
        singleInstanceController.release()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        displayRecoveryCoordinator.stop()
        restoreProcessEffectsOnce()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard settingsWindowController?.window?.isVisible == true else { return }
        updateDockVisibility(settingsVisible: true)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettings(nil)
        return true
    }

    @objc private func activateExistingWindow(_ notification: Notification) {
        showSettings(nil)
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                displayController: displayController,
                groupController: groupController,
                modeController: modeController,
                layoutController: layoutController,
                framebufferController: framebufferController,
                colorProfileController: colorProfileController,
                colorModesController: colorModesController,
                preferences: preferences,
                launchAtLoginController: launchAtLoginController
            )
            settingsWindowController?.onHideRequested = { [weak self] in
                self?.hideSettings()
            }
            settingsWindowController?.onVisibilityChanged = { [weak self] isVisible in
                self?.updateDockVisibility(settingsVisible: isVisible)
            }
        }
        ensureDockVisibilityForSettings()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard self?.settingsWindowController?.window?.isVisible == true else { return }
            self?.updateDockVisibility(settingsVisible: true)
        }
    }

    private func hideSettings() {
        settingsWindowController?.window?.orderOut(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.settingsWindowController?.window?.isVisible != true
            else { return }
            self.updateDockVisibility(settingsVisible: false)
        }
    }

    private func updateDockVisibility(settingsVisible: Bool) {
        if settingsVisible {
            ensureDockVisibilityForSettings()
        } else if settingsWindowController?.window?.isVisible != true {
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }

    private func ensureDockVisibilityForSettings() {
        guard !(NSApp.setActivationPolicy(.regular) || NSApp.activationPolicy() == .regular) else {
            dockVisibilityErrorReported = false
            return
        }
        guard !dockVisibilityErrorReported else { return }
        dockVisibilityErrorReported = true
        let alert = NSAlert()
        alert.messageText = "Beta Display"
        alert.informativeText = "The settings window is open, but macOS could not show Beta Display in the Dock."
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 24)
        item.button?.image = StatusBarMark.image()
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Beta Display"
        item.button?.setAccessibilityLabel("Beta Display")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseDown])
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent, event.type == .rightMouseDown else {
            showSettings(nil)
            return
        }
        NSMenu.popUpContextMenu(statusMenu(), with: event, for: sender)
    }

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        let quit = NSMenuItem(title: L10n.text("app.quit"), action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func updateStatusItemVisibility() {
        if preferences.showMenuBarIcon {
            installStatusItem()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func applyPreference(_ change: AppPreferences.Change) {
        switch change {
        case .menuBarIcon:
            updateStatusItemVisibility()
        case .launchAtLogin:
            launchAtLoginController.synchronize(with: preferences.launchAtLogin)
        case .enableDitheringForColorModes:
            framebufferController.applySavedState(
                to: displayController.displays.map(\.id),
                automaticallyEnableDitheringForColorModes: preferences.enableDitheringForColorModes
            )
        case .interfaceLanguage:
            DispatchQueue.main.async { [weak self] in
                self?.reloadLocalizedInterface()
            }
        }
    }

    private func reloadLocalizedInterface() {
        let shouldShowWindow = settingsWindowController?.window?.isVisible ?? false
        settingsWindowController?.closeForInterfaceReload()
        settingsWindowController = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        updateStatusItemVisibility()
        if shouldShowWindow {
            showSettings(nil)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func applySavedDisplayConfiguration() {
        displayController.captureSessionState()
        modeController.applySavedModes(to: displayController.displays.map(\.id))
        displayController.refreshDisplays()
        displayController.captureSessionState()
        layoutController.applySavedLayout(to: displayController.displays.map(\.id))
        displayController.refreshDisplays()
        displayController.captureSessionState()
        let displayIDs = displayController.displays.map(\.id)
        colorProfileController.applySavedProfiles(to: displayIDs) { displayID, change in
            displayController.performColorProfileChange(for: displayID, change)
        }
        framebufferController.applySavedState(
            to: displayIDs,
            automaticallyEnableDitheringForColorModes: preferences.enableDitheringForColorModes
        )
        displayController.applySavedAdjustments()
    }

    private func restoreDisplayStateAfterSystemChange(restoresTopology: Bool) {
        displayController.refreshDisplays()
        guard !displayController.displays.isEmpty else { return }

        if restoresTopology {
            modeController.applySavedModes(to: displayController.displays.map(\.id))
            displayController.refreshDisplays()
            layoutController.applySavedLayout(to: displayController.displays.map(\.id))
            displayController.refreshDisplays()
        }

        let displayIDs = displayController.displays.map(\.id)
        colorProfileController.applySavedProfiles(to: displayIDs) { displayID, change in
            displayController.performColorProfileChange(for: displayID, change)
        }
        framebufferController.applySavedState(
            to: displayIDs,
            automaticallyEnableDitheringForColorModes: preferences.enableDitheringForColorModes
        )
        displayController.applySavedAdjustmentsAfterSystemChange()

        // The controllers keep selected-display presentation state, so finish
        // with the selected display after any all-display restoration.
        displayController.refreshHardwareBrightness()
        modeController.refresh(for: displayController.selectedDisplayID)
        framebufferController.refresh(for: displayController.selectedDisplayID)
        colorProfileController.refresh(for: displayController.selectedDisplayID)
    }

    private func restoreProcessEffectsOnce() {
        guard !restoredProcessEffects else { return }
        restoredProcessEffects = true
        framebufferController.restoreAllInitialStates()
        colorProfileController.restoreAllInitialProfiles()
        displayController.restoreSessionState()
    }
}
