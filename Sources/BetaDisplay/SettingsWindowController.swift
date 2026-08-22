import AppKit
import CoreGraphics
import Foundation

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onHideRequested: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    private var permitsClose = false

    init(
        displayController: DisplayController,
        groupController: DisplayGroupController,
        modeController: DisplayModeController,
        layoutController: DisplayLayoutController,
        framebufferController: FramebufferController,
        colorProfileController: ColorProfileController,
        colorModesController: DisplayColorModesController,
        preferences: AppPreferences,
        launchAtLoginController: LaunchAtLoginController
    ) {
        let viewController = SettingsViewController(
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Beta Display"
        window.contentViewController = viewController
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !permitsClose else { return true }
        guard let onHideRequested else {
            assertionFailure("Beta Display settings window has no hide handler")
            return false
        }
        onHideRequested()
        return false
    }

    func windowDidBecomeVisible(_ notification: Notification) {
        onVisibilityChanged?(true)
    }

    func closeForInterfaceReload() {
        permitsClose = true
        close()
        permitsClose = false
    }
}

private enum SettingsPage: Int, CaseIterable {
    case general
    case displays
    case image
    case about

    var title: String {
        switch self {
        case .general: L10n.text("nav.general")
        case .displays: L10n.text("nav.displays")
        case .image: L10n.text("nav.image")
        case .about: L10n.text("nav.about")
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .displays: "display.2"
        case .image: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }

    var requiresDisplay: Bool {
        self == .displays || self == .image
    }
}

private final class SettingsViewController: NSViewController, NSTextFieldDelegate {
    private let displayController: DisplayController
    private let groupController: DisplayGroupController
    private let modeController: DisplayModeController
    private let layoutController: DisplayLayoutController
    private let framebufferController: FramebufferController
    private let colorProfileController: ColorProfileController
    private let colorModesController: DisplayColorModesController
    private let preferences: AppPreferences
    private let launchAtLoginController: LaunchAtLoginController

    private let displayPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displayPickerContainer = NSStackView()
    private let pageTitleLabel = NSTextField(labelWithString: "")
    private let pageScrollView = NSScrollView()
    private let pageContent = FlippedStackView()
    private let hardwareBrightnessSlider = NSSlider(
        value: 0,
        minValue: 0,
        maxValue: 1,
        target: nil,
        action: nil
    )
    private let nightShiftCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let nightShiftStrengthSlider = NSSlider(
        value: 0,
        minValue: 0,
        maxValue: 1,
        target: nil,
        action: nil
    )
    private let trueToneCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var navigationButtons: [SettingsPage: SidebarButton] = [:]
    private var currentPage: SettingsPage = .general
    private var isRendering = false
    private var systemStateTimer: Timer?
    private var positionUpdateWorkItem: DispatchWorkItem?
    private var isCheckingForUpdate = false
    private var updateStatusText = ""
    private var releaseURL: URL?

    init(
        displayController: DisplayController,
        groupController: DisplayGroupController,
        modeController: DisplayModeController,
        layoutController: DisplayLayoutController,
        framebufferController: FramebufferController,
        colorProfileController: ColorProfileController,
        colorModesController: DisplayColorModesController,
        preferences: AppPreferences,
        launchAtLoginController: LaunchAtLoginController
    ) {
        self.displayController = displayController
        self.groupController = groupController
        self.modeController = modeController
        self.layoutController = layoutController
        self.framebufferController = framebufferController
        self.colorProfileController = colorProfileController
        self.colorModesController = colorModesController
        self.preferences = preferences
        self.launchAtLoginController = launchAtLoginController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        startSystemStateMonitoring()
        displayController.refreshHardwareBrightness()
        colorModesController.refresh()
    }

    override func viewDidDisappear() {
        stopSystemStateMonitoring()
        super.viewDidDisappear()
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 650))
        buildInterface()
        displayController.onStateChanged = { [weak self] in self?.renderCurrentPage() }
        groupController.onStateChanged = { [weak self] in self?.renderCurrentPage() }
        modeController.onStateChanged = { [weak self] in self?.renderCurrentPage() }
        layoutController.onStateChanged = { [weak self] in self?.renderCurrentPage() }
        framebufferController.onStateChanged = { [weak self] in self?.renderCurrentPage() }
        colorProfileController.onStateChanged = { [weak self] in self?.renderCurrentPage() }
        colorModesController.onStateChanged = { [weak self] in self?.renderCurrentPage() }
        launchAtLoginController.onStatusChanged = { [weak self] in self?.renderGeneralSettings() }
        modeController.refresh(for: displayController.selectedDisplayID)
        framebufferController.refresh(for: displayController.selectedDisplayID)
        colorProfileController.refresh(for: displayController.selectedDisplayID)
        colorModesController.refresh()
        select(page: .general)
    }

    private func buildInterface() {
        let sidebar = makeSidebar()
        let separator = verticalSeparator()
        let main = makeMainArea()

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        main.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebar)
        view.addSubview(separator)
        view.addSubview(main)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 210),
            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            main.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            main.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            main.topAnchor.constraint(equalTo: view.topAnchor),
            main.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func makeSidebar() -> NSView {
        let sidebar = NSVisualEffectView()
        sidebar.blendingMode = .withinWindow
        sidebar.material = .sidebar
        sidebar.state = .active

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 12, bottom: 14, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        ])

        let identity = NSStackView()
        identity.orientation = .horizontal
        identity.alignment = .centerY
        identity.spacing = 12
        identity.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 16, right: 8)
        let image = NSImageView(image: NSApp.applicationIconImage)
        image.imageScaling = .scaleProportionallyUpOrDown
        identity.addArrangedSubview(image)
        image.widthAnchor.constraint(equalToConstant: 28).isActive = true
        image.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let title = NSTextField(labelWithString: "Beta Display")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        identity.addArrangedSubview(title)
        stack.addArrangedSubview(identity)

        let divider = NSBox()
        divider.boxType = .separator
        stack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        stack.setCustomSpacing(11, after: divider)

        for page in SettingsPage.allCases where page != .about {
            let button = SidebarButton(title: page.title, image: page.icon)
            button.tag = page.rawValue
            button.target = self
            button.action = #selector(selectPage(_:))
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            navigationButtons[page] = button
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(spacer)

        let about = SidebarButton(title: SettingsPage.about.title, image: SettingsPage.about.icon)
        about.tag = SettingsPage.about.rawValue
        about.target = self
        about.action = #selector(selectPage(_:))
        stack.addArrangedSubview(about)
        about.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        navigationButtons[.about] = about
        return sidebar
    }

    private func makeMainArea() -> NSView {
        let main = NSView()
        let header = makePageHeader()
        let separator = horizontalSeparator()

        header.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        pageScrollView.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(header)
        main.addSubview(separator)
        main.addSubview(pageScrollView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            header.topAnchor.constraint(equalTo: main.topAnchor),
            separator.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            pageScrollView.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            pageScrollView.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            pageScrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            pageScrollView.bottomAnchor.constraint(equalTo: main.bottomAnchor)
        ])

        pageScrollView.drawsBackground = false
        pageScrollView.hasVerticalScroller = true
        pageScrollView.autohidesScrollers = true
        pageScrollView.borderType = .noBorder
        pageScrollView.documentView = pageContent

        pageContent.orientation = .vertical
        pageContent.alignment = .leading
        pageContent.spacing = 12
        pageContent.distribution = .fill
        pageContent.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 22, right: 22)
        pageContent.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pageContent.leadingAnchor.constraint(equalTo: pageScrollView.contentView.leadingAnchor),
            pageContent.trailingAnchor.constraint(equalTo: pageScrollView.contentView.trailingAnchor),
            pageContent.topAnchor.constraint(equalTo: pageScrollView.contentView.topAnchor),
            pageContent.widthAnchor.constraint(equalTo: pageScrollView.contentView.widthAnchor)
        ])
        return main
    }

    private func makePageHeader() -> NSView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 17, left: 22, bottom: 16, right: 22)

        pageTitleLabel.font = .systemFont(ofSize: 21, weight: .bold)
        header.addArrangedSubview(pageTitleLabel)
        header.addArrangedSubview(NSView())

        displayPickerContainer.orientation = .horizontal
        displayPickerContainer.alignment = .centerY
        displayPickerContainer.spacing = 8
        let displayLabel = NSTextField(labelWithString: L10n.text("header.target_display"))
        displayLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        displayPickerContainer.addArrangedSubview(displayLabel)
        displayPicker.target = self
        displayPicker.action = #selector(displayChanged(_:))
        displayPicker.widthAnchor.constraint(equalToConstant: 215).isActive = true
        displayPickerContainer.addArrangedSubview(displayPicker)
        let refresh = NSButton(
            image: NSImage(
                systemSymbolName: "arrow.clockwise",
                accessibilityDescription: L10n.text("app.refresh_displays")
            )!,
            target: self,
            action: #selector(refreshDisplays(_:))
        )
        refresh.bezelStyle = .texturedRounded
        refresh.toolTip = L10n.text("app.refresh_displays")
        displayPickerContainer.addArrangedSubview(refresh)
        header.addArrangedSubview(displayPickerContainer)
        return header
    }

    @objc private func selectPage(_ sender: NSControl) {
        guard let page = SettingsPage(rawValue: sender.tag) else { return }
        select(page: page)
    }

    private func select(page: SettingsPage) {
        currentPage = page
        pageTitleLabel.stringValue = page.title
        displayPickerContainer.isHidden = !page.requiresDisplay
        navigationButtons.forEach { $0.value.isSelected = $0.key == page }
        rebuildPageContent()
        if page == .displays {
            displayController.refreshHardwareBrightness()
            modeController.refresh(for: displayController.selectedDisplayID)
        }
        if page == .image {
            framebufferController.refresh(for: displayController.selectedDisplayID)
            colorProfileController.refresh(for: displayController.selectedDisplayID)
            colorModesController.refresh()
        }
        renderCurrentPage()
        pageScrollView.contentView.scroll(to: .zero)
        pageScrollView.reflectScrolledClipView(pageScrollView.contentView)
    }

    private func rebuildPageContent() {
        pageContent.arrangedSubviews.forEach {
            pageContent.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        switch currentPage {
        case .displays:
            buildDisplaysPage()
            buildLayoutPage()
            buildGroupsPage()
            buildDiagnosticsPage()
        case .image: buildImagePage()
        case .general: buildGeneralPage()
        case .about: buildAboutPage()
        }
    }

    private func buildDisplaysPage() {
        let overview = card(title: L10n.text("display.current"))
        let overviewLabels = [
            L10n.text("display.name"),
            L10n.text("display.status"),
            L10n.text("display.pixels"),
            L10n.text("display.physical_size"),
            L10n.text("display.gamma_capacity")
        ]
        let overviewLabelWidth = sharedLabelWidth(overviewLabels)
        overview.content.addArrangedSubview(keyValueRow(L10n.text("display.name"), id: "displayName", labelColumnWidth: overviewLabelWidth))
        overview.content.addArrangedSubview(keyValueRow(L10n.text("display.status"), id: "displayStatus", labelColumnWidth: overviewLabelWidth))
        overview.content.addArrangedSubview(keyValueRow(L10n.text("display.pixels"), id: "displayPixels", labelColumnWidth: overviewLabelWidth))
        overview.content.addArrangedSubview(keyValueRow(L10n.text("display.physical_size"), id: "displayPhysical", labelColumnWidth: overviewLabelWidth))
        overview.content.addArrangedSubview(keyValueRow(L10n.text("display.gamma_capacity"), id: "displayGamma", labelColumnWidth: overviewLabelWidth))
        addCard(overview)

        let brightness = card(title: L10n.text("display.hardware_brightness"))
        hardwareBrightnessSlider.target = self
        hardwareBrightnessSlider.action = #selector(hardwareBrightnessChanged(_:))
        hardwareBrightnessSlider.identifier = NSUserInterfaceItemIdentifier("hardwareBrightnessSlider")
        hardwareBrightnessSlider.isContinuous = true
        hardwareBrightnessSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        brightness.content.addArrangedSubview(labeledRow(
            L10n.text("display.hardware_brightness"),
            hardwareBrightnessSlider
        ))
        brightness.content.addArrangedSubview(statusLabel(id: "hardwareBrightnessStatus"))
        addCard(brightness)
    }

    private func buildGroupsPage() {
        let groups = card(title: L10n.text("groups.title"))
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.identifier = NSUserInterfaceItemIdentifier("groupPicker")
        picker.target = self
        picker.action = #selector(groupChanged(_:))
        groups.content.addArrangedSubview(labeledRow(L10n.text("groups.current"), picker))
        let members = CheckboxListView()
        members.identifier = NSUserInterfaceItemIdentifier("groupMembers")
        members.onSelectionChanged = { [weak self] in
            self?.groupMembersChanged()
        }
        groups.content.addArrangedSubview(members)
        let actions = buttonRow([
            (L10n.text("groups.create"), #selector(createGroup(_:))),
            (L10n.text("groups.delete"), #selector(deleteGroup(_:))),
            (L10n.text("groups.sync_adjustments"), #selector(syncGroup(_:)))
        ])
        groups.content.addArrangedSubview(actions)
        groups.content.addArrangedSubview(statusLabel(id: "groupsStatus"))
        addCard(groups)
    }

    private func buildLayoutPage() {
        let modes = card(title: L10n.text("modes.title"))
        let modePicker = NSPopUpButton(frame: .zero, pullsDown: false)
        modePicker.identifier = NSUserInterfaceItemIdentifier("modePicker")
        modePicker.target = self
        modePicker.action = #selector(modeChanged(_:))
        modes.content.addArrangedSubview(labeledRow(L10n.text("modes.available"), modePicker))
        modes.content.addArrangedSubview(buttonRow([(L10n.text("modes.refresh"), #selector(refreshModes(_:)))]))
        modes.content.addArrangedSubview(statusLabel(id: "modesStatus"))
        addCard(modes)

        let layout = card(title: L10n.text("layout.title"))
        let target = NSPopUpButton(frame: .zero, pullsDown: false)
        target.identifier = NSUserInterfaceItemIdentifier("mirrorTargetPicker")
        target.target = self
        target.action = #selector(mirrorTargetChanged(_:))
        layout.content.addArrangedSubview(labeledRow(L10n.text("layout.mirror_to"), target))
        layout.content.addArrangedSubview(statusLabel(id: "layoutStatus"))
        addCard(layout)

        let placement = card(title: L10n.text("layout.position"))
        let xField = coordinateField(id: "layoutX")
        let yField = coordinateField(id: "layoutY")
        let positionLabelWidth = sharedLabelWidth([
            L10n.text("layout.horizontal"),
            L10n.text("layout.vertical")
        ])
        placement.content.addArrangedSubview(labeledRow(
            L10n.text("layout.horizontal"),
            xField,
            expandsControl: false,
            labelColumnWidth: positionLabelWidth
        ))
        placement.content.addArrangedSubview(labeledRow(
            L10n.text("layout.vertical"),
            yField,
            expandsControl: false,
            labelColumnWidth: positionLabelWidth
        ))
        placement.content.addArrangedSubview(statusLabel(id: "positionStatus"))
        addCard(placement)
    }

    private func buildImagePage() {
        let imageLabelWidth = sharedLabelWidth([
            L10n.text("image.contrast"),
            L10n.text("image.gamma"),
            L10n.text("image.gain"),
            L10n.text("image.temperature"),
            L10n.text("image.software_brightness"),
            L10n.text("image.quantization"),
            L10n.text("image.gamma_red"),
            L10n.text("image.gamma_green"),
            L10n.text("image.gamma_blue"),
            L10n.text("image.gain_red"),
            L10n.text("image.gain_green"),
            L10n.text("image.gain_blue")
        ])
        let adjustment = card(title: L10n.text("image.title"))
        adjustment.content.addArrangedSubview(adjustmentRow(L10n.text("image.contrast"), keyPath: \.contrast, range: 0 ... 1, step: 0.01, defaultValue: 0.5, formatter: normalizedControlString, parser: parseNormalizedControl, labelWidth: imageLabelWidth))
        adjustment.content.addArrangedSubview(adjustmentRow(L10n.text("image.gamma"), keyPath: \.gamma, range: 0 ... 1, step: 0.01, defaultValue: 0.5, formatter: normalizedControlString, parser: parseNormalizedControl, labelWidth: imageLabelWidth))
        adjustment.content.addArrangedSubview(adjustmentRow(L10n.text("image.gain"), keyPath: \.gain, range: 0 ... 1, step: 0.01, defaultValue: 0.5, formatter: normalizedControlString, parser: parseNormalizedControl, labelWidth: imageLabelWidth))
        adjustment.content.addArrangedSubview(adjustmentRow(L10n.text("image.temperature"), keyPath: \.temperature, range: 0 ... 1, step: 0.01, defaultValue: 0.5, formatter: normalizedControlString, parser: parseNormalizedControl, labelWidth: imageLabelWidth))
        adjustment.content.addArrangedSubview(adjustmentRow(L10n.text("image.software_brightness"), keyPath: \.brightness, range: 0 ... 1, step: 0.01, defaultValue: 1, formatter: normalizedControlString, parser: parseNormalizedControl, labelWidth: imageLabelWidth))
        adjustment.content.addArrangedSubview(adjustmentRow(L10n.text("image.quantization"), keyPath: \.quantization, range: 0 ... 1, step: 0.01, defaultValue: 1, formatter: { value in
            value >= 0.995
                ? L10n.text("image.quantization_off")
                : String(format: "%.2f", value)
        }, parser: { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed == L10n.text("image.quantization_off").lowercased() || trimmed == "off" || trimmed == "关闭" {
                return 1
            }
            return parseNormalizedControl(trimmed)
        }, labelWidth: imageLabelWidth))
        adjustment.content.addArrangedSubview(statusLabel(id: "adjustmentsStatus"))
        addCard(adjustment)

        let channels = card(title: L10n.text("image.rgb_channels"))
        channels.content.addArrangedSubview(adjustmentRow(L10n.text("image.gamma_red"), keyPath: \.redGamma, range: 0 ... 1, step: 0.01, defaultValue: 0.5, formatter: normalizedControlString, parser: parseNormalizedControl, labelWidth: imageLabelWidth))
        channels.content.addArrangedSubview(adjustmentRow(L10n.text("image.gamma_green"), keyPath: \.greenGamma, range: 0 ... 1, step: 0.01, defaultValue: 0.5, formatter: normalizedControlString, parser: parseNormalizedControl, labelWidth: imageLabelWidth))
        channels.content.addArrangedSubview(adjustmentRow(L10n.text("image.gamma_blue"), keyPath: \.blueGamma, range: 0 ... 1, step: 0.01, defaultValue: 0.5, formatter: normalizedControlString, parser: parseNormalizedControl, labelWidth: imageLabelWidth))
        channels.content.addArrangedSubview(adjustmentRow(L10n.text("image.gain_red"), keyPath: \.redGain, range: 0 ... 1, step: 0.01, defaultValue: 0.5, formatter: normalizedControlString, parser: parseNormalizedControl, labelWidth: imageLabelWidth))
        channels.content.addArrangedSubview(adjustmentRow(L10n.text("image.gain_green"), keyPath: \.greenGain, range: 0 ... 1, step: 0.01, defaultValue: 0.5, formatter: normalizedControlString, parser: parseNormalizedControl, labelWidth: imageLabelWidth))
        channels.content.addArrangedSubview(adjustmentRow(L10n.text("image.gain_blue"), keyPath: \.blueGain, range: 0 ... 1, step: 0.01, defaultValue: 0.5, formatter: normalizedControlString, parser: parseNormalizedControl, labelWidth: imageLabelWidth))
        channels.content.addArrangedSubview(statusLabel(id: "channelsStatus"))
        addCard(channels)

        let profile = card(title: L10n.text("profile.title"))
        let profilePicker = NSPopUpButton(frame: .zero, pullsDown: false)
        profilePicker.identifier = NSUserInterfaceItemIdentifier("colorProfilePicker")
        profilePicker.target = self
        profilePicker.action = #selector(colorProfileChanged(_:))
        profile.content.addArrangedSubview(labeledRow(L10n.text("profile.current"), profilePicker))
        profile.content.addArrangedSubview(buttonRow([
            (L10n.text("profile.restore_factory"), #selector(restoreFactoryProfile(_:))),
            (L10n.text("profile.refresh"), #selector(refreshColorProfiles(_:)))
        ]))
        profile.content.addArrangedSubview(statusLabel(id: "colorProfileStatus"))
        addCard(profile)

        let systemModes = card(title: L10n.text("system_modes.title"))
        nightShiftCheckbox.title = L10n.text("system_modes.night_shift")
        nightShiftCheckbox.identifier = NSUserInterfaceItemIdentifier("nightShiftCheckbox")
        nightShiftCheckbox.target = self
        nightShiftCheckbox.action = #selector(nightShiftChanged(_:))
        systemModes.content.addArrangedSubview(nightShiftCheckbox)
        nightShiftStrengthSlider.target = self
        nightShiftStrengthSlider.action = #selector(nightShiftStrengthChanged(_:))
        nightShiftStrengthSlider.identifier = NSUserInterfaceItemIdentifier("nightShiftStrengthSlider")
        nightShiftStrengthSlider.isContinuous = true
        nightShiftStrengthSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        systemModes.content.addArrangedSubview(labeledRow(
            L10n.text("system_modes.night_shift_strength"),
            nightShiftStrengthSlider
        ))
        trueToneCheckbox.title = L10n.text("system_modes.true_tone")
        trueToneCheckbox.identifier = NSUserInterfaceItemIdentifier("trueToneCheckbox")
        trueToneCheckbox.target = self
        trueToneCheckbox.action = #selector(trueToneChanged(_:))
        systemModes.content.addArrangedSubview(trueToneCheckbox)
        systemModes.content.addArrangedSubview(statusLabel(id: "systemModesStatus"))
        addCard(systemModes)

        let framebuffer = card(title: L10n.text("framebuffer.title"))
        let modePicker = NSPopUpButton(frame: .zero, pullsDown: false)
        modePicker.identifier = NSUserInterfaceItemIdentifier("framebufferModePicker")
        modePicker.target = self
        modePicker.action = #selector(framebufferModeChanged(_:))
        framebuffer.content.addArrangedSubview(labeledRow(L10n.text("framebuffer.mode"), modePicker))
        let autoDither = NSButton(checkboxWithTitle: L10n.text("framebuffer.auto_dither"), target: self, action: #selector(autoDitheringChanged(_:)))
        autoDither.identifier = NSUserInterfaceItemIdentifier("autoDitheringCheckbox")
        autoDither.toolTip = L10n.text("framebuffer.auto_dither_tooltip")
        framebuffer.content.addArrangedSubview(indented(autoDither))
        framebuffer.content.addArrangedSubview(buttonRow([
            (L10n.text("framebuffer.refresh"), #selector(refreshFramebuffer(_:))),
            (L10n.text("framebuffer.restore_startup"), #selector(restoreFramebuffer(_:)))
        ]))
        framebuffer.content.addArrangedSubview(statusLabel(id: "framebufferStatus"))
        addCard(framebuffer)

        let framebufferTools = card(title: L10n.text("framebuffer.tools"))
        let dithering = NSButton(checkboxWithTitle: L10n.text("framebuffer.enable_dithering"), target: self, action: #selector(ditheringChanged(_:)))
        dithering.identifier = NSUserInterfaceItemIdentifier("ditheringCheckbox")
        framebufferTools.content.addArrangedSubview(dithering)
        let uniformity = NSButton(checkboxWithTitle: L10n.text("framebuffer.enable_uniformity"), target: self, action: #selector(uniformityChanged(_:)))
        uniformity.identifier = NSUserInterfaceItemIdentifier("uniformityCheckbox")
        framebufferTools.content.addArrangedSubview(uniformity)
        framebufferTools.content.addArrangedSubview(statusLabel(id: "framebufferToolsStatus"))
        addCard(framebufferTools)

        let recovery = card(title: L10n.text("recovery.title"))
        recovery.content.addArrangedSubview(buttonRow([
            (L10n.text("recovery.reset"), #selector(resetImage(_:)))
        ]))
        recovery.content.addArrangedSubview(statusLabel(id: "recoveryStatus"))
        addCard(recovery)
    }

    private func buildDiagnosticsPage() {
        let diagnostic = card(title: L10n.text("diagnostics.title"))
        for id in ["diagName", "diagID", "diagType", "diagVendor", "diagPixels", "diagPhysical", "diagMode", "diagGamma", "diagEDID"] {
            diagnostic.content.addArrangedSubview(detailRow(id: id))
        }
        diagnostic.content.addArrangedSubview(buttonRow([(L10n.text("diagnostics.copy"), #selector(copyDiagnostics(_:)))]))
        addCard(diagnostic)

    }

    private func buildGeneralPage() {
        let general = card(title: L10n.text("general.title"))

        let language = NSPopUpButton(frame: .zero, pullsDown: false)
        language.identifier = NSUserInterfaceItemIdentifier("interfaceLanguagePicker")
        language.target = self
        language.action = #selector(interfaceLanguageChanged(_:))
        let languageChoices: [InterfaceLanguage] = [.automatic, .english, .simplifiedChinese]
        for choice in languageChoices {
            let title: String
            switch choice {
            case .automatic:
                title = L10n.text("general.language.automatic", language: choice)
            case .english:
                title = L10n.text("general.language.english", language: choice)
            case .simplifiedChinese:
                title = L10n.text("general.language.simplified_chinese", language: choice)
            }
            language.addItem(withTitle: title)
            language.lastItem?.representedObject = choice.rawValue
        }
        language.font = .systemFont(ofSize: NSFont.systemFontSize)
        language.controlSize = .regular
        general.content.addArrangedSubview(labeledRow(
            L10n.text("general.language"),
            language,
            labelFont: .systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            expandsControl: false
        ))

        let menuBar = NSButton(checkboxWithTitle: L10n.text("general.show_menu_icon"), target: self, action: #selector(menuBarIconChanged(_:)))
        menuBar.identifier = NSUserInterfaceItemIdentifier("menuBarIconCheckbox")
        general.content.addArrangedSubview(menuBar)

        let login = NSButton(checkboxWithTitle: L10n.text("general.launch_at_login"), target: self, action: #selector(launchAtLoginChanged(_:)))
        login.identifier = NSUserInterfaceItemIdentifier("launchAtLoginCheckbox")
        general.content.addArrangedSubview(login)
        let loginStatus = indented(statusLabel(id: "launchAtLoginStatus"))
        loginStatus.identifier = NSUserInterfaceItemIdentifier("launchAtLoginStatusContainer")
        general.content.addArrangedSubview(loginStatus)
        general.content.addArrangedSubview(buttonRow([
            (L10n.text("general.restore_defaults"), #selector(resetGeneralSettings(_:)))
        ]))
        addCard(general)
    }

    private func buildAboutPage() {
        let about = card(title: L10n.text("about.title"))
        let identity = NSStackView()
        identity.orientation = .horizontal
        identity.alignment = .centerY
        identity.spacing = 12

        let image = NSImageView(image: NSApp.applicationIconImage)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.widthAnchor.constraint(equalToConstant: 48).isActive = true
        image.heightAnchor.constraint(equalToConstant: 48).isActive = true
        identity.addArrangedSubview(image)

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let name = NSTextField(labelWithString: "Beta Display")
        name.font = .systemFont(ofSize: 17, weight: .semibold)
        text.addArrangedSubview(name)
        let version = NSTextField(labelWithString: L10n.text("about.version", AppMetadata.version))
        version.font = .systemFont(ofSize: NSFont.systemFontSize)
        version.textColor = .secondaryLabelColor
        text.addArrangedSubview(version)
        identity.addArrangedSubview(text)
        about.content.addArrangedSubview(identity)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        let checkUpdates = NSButton(
            title: L10n.text("about.check_updates"),
            target: self,
            action: #selector(checkForUpdates(_:))
        )
        checkUpdates.identifier = NSUserInterfaceItemIdentifier("checkUpdatesButton")
        checkUpdates.bezelStyle = .rounded
        actions.addArrangedSubview(checkUpdates)

        about.content.addArrangedSubview(actions)
        about.content.addArrangedSubview(statusLabel(id: "aboutUpdateStatus"))
        addCard(about)
    }

    private func addCard(_ card: SettingsCard) {
        pageContent.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: pageContent.widthAnchor, constant: -44).isActive = true
    }

    private func card(title: String) -> SettingsCard {
        SettingsCard(title: title)
    }

    private func keyValueRow(
        _ title: String,
        id: String,
        labelColumnWidth: CGFloat? = nil
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        let key = NSTextField(labelWithString: title)
        key.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        key.textColor = .secondaryLabelColor
        key.setContentHuggingPriority(.required, for: .horizontal)
        if let labelColumnWidth {
            key.alignment = .right
            key.widthAnchor.constraint(equalToConstant: labelColumnWidth).isActive = true
        }
        let value = NSTextField(wrappingLabelWithString: "—")
        value.identifier = NSUserInterfaceItemIdentifier(id)
        value.setContentHuggingPriority(.defaultLow, for: .horizontal)
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(key)
        row.addArrangedSubview(value)
        return row
    }

    private func detailRow(id: String) -> NSTextField {
        let value = NSTextField(wrappingLabelWithString: "—")
        value.identifier = NSUserInterfaceItemIdentifier(id)
        value.font = .systemFont(ofSize: NSFont.systemFontSize)
        value.textColor = .secondaryLabelColor
        value.maximumNumberOfLines = 2
        return value
    }

    private func labeledRow(
        _ title: String,
        _ control: NSView,
        labelFont: NSFont? = nil,
        expandsControl: Bool = true,
        labelColumnWidth: CGFloat? = nil
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let label = NSTextField(labelWithString: title)
        label.font = labelFont ?? .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.setContentHuggingPriority(.required, for: .horizontal)
        if let labelColumnWidth {
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: labelColumnWidth).isActive = true
        }
        row.addArrangedSubview(label)
        control.setContentHuggingPriority(
            expandsControl ? .defaultLow : .required,
            for: .horizontal
        )
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(control)
        if !expandsControl {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
        }
        return row
    }

    private func sharedLabelWidth(
        _ titles: [String],
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    ) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return (titles.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0) + 2
    }

    private func coordinateField(id: String) -> NSTextField {
        let field = NSTextField(string: "0")
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.alignment = .right
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.allowsFloats = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        field.formatter = formatter
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 120).isActive = true
        return field
    }

    private func adjustmentRow(
        _ title: String,
        keyPath: WritableKeyPath<ColorAdjustments, Double>,
        range: ClosedRange<Double>,
        step: Double,
        defaultValue: Double,
        formatter: @escaping (Double) -> String,
        parser: @escaping (String) -> Double? = parseAdjustmentNumber,
        labelWidth: CGFloat? = nil
    ) -> AdjustmentRow {
        AdjustmentRow(
            title: title,
            keyPath: keyPath,
            range: range,
            step: step,
            defaultValue: defaultValue,
            formatter: formatter,
            parser: parser,
            labelWidth: labelWidth
        ) { [weak self] value in
            guard let self else { return }
            self.displayController.update(keyPath, to: value)
            self.renderImagePage()
        }
    }

    private func buttonRow(_ entries: [(String, Selector)]) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        for (title, selector) in entries {
            let button = NSButton(title: title, target: self, action: selector)
            button.bezelStyle = .rounded
            row.addArrangedSubview(button)
        }
        return row
    }

    private func statusLabel(id: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.identifier = NSUserInterfaceItemIdentifier(id)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        return label
    }

    private func indented(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    @objc private func displayChanged(_ sender: NSPopUpButton) {
        guard !isRendering, let number = sender.selectedItem?.representedObject as? NSNumber else { return }
        displayController.selectDisplay(CGDirectDisplayID(number.uint32Value))
        modeController.refresh(for: displayController.selectedDisplayID)
        framebufferController.refresh(for: displayController.selectedDisplayID)
        colorProfileController.refresh(for: displayController.selectedDisplayID)
        renderCurrentPage()
    }

    @objc private func refreshDisplays(_ sender: Any?) {
        displayController.refreshDisplays()
        displayController.refreshHardwareBrightness()
        modeController.refresh(for: displayController.selectedDisplayID)
        framebufferController.refresh(for: displayController.selectedDisplayID)
        colorProfileController.refresh(for: displayController.selectedDisplayID)
        renderCurrentPage()
    }

    @objc private func hardwareBrightnessChanged(_ sender: NSSlider) {
        guard !isRendering else { return }
        displayController.setHardwareBrightness(sender.doubleValue)
    }

    private func startSystemStateMonitoring() {
        guard systemStateTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            guard self != nil else {
                timer.invalidate()
                return
            }
            Task { @MainActor [weak self] in
                self?.synchronizeSystemState()
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        systemStateTimer = timer
    }

    private func stopSystemStateMonitoring() {
        systemStateTimer?.invalidate()
        systemStateTimer = nil
    }

    private func synchronizeSystemState() {
        guard view.window?.isVisible == true else { return }
        if currentPage == .displays, displayController.refreshHardwareBrightness() {
            renderHardwareBrightness()
        }
        if currentPage == .image {
            colorModesController.refresh()
        }
    }

    @objc private func nightShiftChanged(_ sender: NSButton) {
        guard !isRendering else { return }
        colorModesController.setNightShift(sender.state == .on)
    }

    @objc private func nightShiftStrengthChanged(_ sender: NSSlider) {
        guard !isRendering else { return }
        colorModesController.setNightShiftStrength(sender.doubleValue)
    }

    @objc private func trueToneChanged(_ sender: NSButton) {
        guard !isRendering else { return }
        colorModesController.setTrueTone(sender.state == .on)
    }

    @objc private func groupChanged(_ sender: NSPopUpButton) {
        guard !isRendering else { return }
        groupController.selectedGroupID = sender.selectedItem?.representedObject as? UUID
        groupController.onStateChanged?()
    }

    @objc private func createGroup(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = L10n.text("groups.new_alert_title")
        alert.informativeText = L10n.text("groups.new_alert_body")
        let input = NSTextField(string: L10n.text("groups.default_name"))
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: L10n.text("action.create"))
        alert.addButton(withTitle: L10n.text("action.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        groupController.createGroup(name: input.stringValue, displayIDs: selectedGroupMemberIDs())
    }

    private func groupMembersChanged() {
        guard !isRendering else { return }
        groupController.updateSelectedGroup(displayIDs: selectedGroupMemberIDs())
    }

    @objc private func deleteGroup(_ sender: Any?) {
        groupController.deleteSelectedGroup()
    }

    @objc private func syncGroup(_ sender: Any?) {
        groupController.synchronize(adjustments: displayController.adjustments, displayController: displayController)
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        guard !isRendering,
              let id = sender.selectedItem?.representedObject as? String
        else { return }
        modeController.apply(modeID: id, to: displayController.selectedDisplayID)
    }

    @objc private func refreshModes(_ sender: Any?) {
        modeController.refresh(for: displayController.selectedDisplayID)
    }

    @objc private func mirrorTargetChanged(_ sender: NSPopUpButton) {
        guard !isRendering,
              let selectedID = displayController.selectedDisplayID
        else { return }
        guard let number = sender.selectedItem?.representedObject as? NSNumber,
              number.uint32Value != kCGNullDirectDisplay
        else {
            layoutController.unmirror(displayID: selectedID)
            return
        }
        layoutController.mirror(displayID: selectedID, to: CGDirectDisplayID(number.uint32Value))
    }

    private func applyPositionFromFields() {
        guard let selectedID = displayController.selectedDisplayID,
              let xField = viewWithID("layoutX") as? NSTextField,
              let yField = viewWithID("layoutY") as? NSTextField,
              let x = Int(xField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let y = Int(yField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        let origin = CGDisplayBounds(selectedID).origin
        guard Int(origin.x.rounded()) != x || Int(origin.y.rounded()) != y else { return }
        layoutController.move(displayID: selectedID, x: x, y: y)
    }

    @objc private func colorProfileChanged(_ sender: NSPopUpButton) {
        guard !isRendering,
              let url = sender.selectedItem?.representedObject as? URL
        else { return }
        displayController.performSelectedDisplayColorProfileChange {
            colorProfileController.setProfile(
                url: url,
                for: displayController.selectedDisplayID
            )
        }
    }

    @objc private func restoreFactoryProfile(_ sender: Any?) {
        displayController.performSelectedDisplayColorProfileChange {
            colorProfileController.restoreFactoryProfile(
                for: displayController.selectedDisplayID
            )
        }
    }

    @objc private func refreshColorProfiles(_ sender: Any?) {
        colorProfileController.refresh(for: displayController.selectedDisplayID)
    }

    @objc private func framebufferModeChanged(_ sender: NSPopUpButton) {
        guard !isRendering,
              let raw = sender.selectedItem?.representedObject as? NSNumber,
              let mode = FramebufferColorMode(rawValue: raw.int32Value)
        else { return }
        framebufferController.setMode(mode, for: displayController.selectedDisplayID)
        if preferences.enableDitheringForColorModes, mode != .standard {
            framebufferController.setDithering(true, for: displayController.selectedDisplayID)
        }
    }

    @objc private func refreshFramebuffer(_ sender: Any?) {
        framebufferController.refresh(for: displayController.selectedDisplayID)
    }

    @objc private func restoreFramebuffer(_ sender: Any?) {
        framebufferController.restoreInitialState(for: displayController.selectedDisplayID)
    }

    @objc private func ditheringChanged(_ sender: NSButton) {
        guard !isRendering else { return }
        framebufferController.setDithering(sender.state == .on, for: displayController.selectedDisplayID)
    }

    @objc private func autoDitheringChanged(_ sender: NSButton) {
        guard !isRendering else { return }
        preferences.setEnableDitheringForColorModes(sender.state == .on)
    }

    @objc private func uniformityChanged(_ sender: NSButton) {
        guard !isRendering else { return }
        framebufferController.setUniformityCorrection(sender.state == .on, for: displayController.selectedDisplayID)
    }

    @objc private func resetImage(_ sender: Any?) {
        displayController.resetSelectedDisplay()
    }

    @objc private func copyDiagnostics(_ sender: Any?) {
        guard let details = DisplayDiagnostics.make(for: displayController.selectedDisplay) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(details.copyableText, forType: .string)
    }

    @objc private func menuBarIconChanged(_ sender: NSButton) {
        preferences.setShowMenuBarIcon(sender.state == .on)
        renderGeneralSettings()
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        preferences.setLaunchAtLogin(sender.state == .on)
        renderGeneralSettings()
    }

    @objc private func resetGeneralSettings(_ sender: Any?) {
        preferences.resetGeneralSettings()
        renderGeneralSettings()
    }

    @objc private func interfaceLanguageChanged(_ sender: NSPopUpButton) {
        guard !isRendering,
              let rawValue = sender.selectedItem?.representedObject as? String,
              let language = InterfaceLanguage(rawValue: rawValue)
        else { return }
        preferences.setInterfaceLanguage(language)
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        if let releaseURL {
            NSWorkspace.shared.open(releaseURL)
            return
        }
        guard !isCheckingForUpdate else { return }
        isCheckingForUpdate = true
        releaseURL = nil
        updateStatusText = L10n.text("about.checking")
        renderAboutPage()

        Task { [weak self] in
            let result = await AppUpdateChecker.latestRelease()
            await MainActor.run {
                guard let self else { return }
                self.isCheckingForUpdate = false
                switch result {
                case .release(let release):
                    self.releaseURL = release.url
                    if AppMetadata.isVersion(release.tag, newerThan: AppMetadata.version) {
                        self.updateStatusText = L10n.text("about.update_available", release.tag)
                    } else {
                        self.releaseURL = nil
                        self.updateStatusText = L10n.text("about.up_to_date")
                    }
                case .noPublicRelease:
                    self.updateStatusText = L10n.text("about.no_public_release")
                case .failed:
                    self.updateStatusText = L10n.text("about.check_failed")
                }
                self.renderAboutPage()
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isRendering,
              currentPage == .displays,
              let field = obj.object as? NSTextField,
              isPositionField(field)
        else { return }
        positionUpdateWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyPositionFromFields()
        }
        positionUpdateWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isRendering,
              let field = obj.object as? NSTextField,
              isPositionField(field)
        else { return }
        positionUpdateWorkItem?.cancel()
        applyPositionFromFields()
    }

    private func isPositionField(_ field: NSTextField) -> Bool {
        field.identifier == NSUserInterfaceItemIdentifier("layoutX")
            || field.identifier == NSUserInterfaceItemIdentifier("layoutY")
    }

    private func selectedGroupMemberIDs() -> [CGDirectDisplayID] {
        guard let list = viewWithID("groupMembers") as? CheckboxListView else { return [] }
        return list.selectedValues.compactMap { ($0 as? NSNumber).map { CGDirectDisplayID($0.uint32Value) } }
    }

    private func renderCurrentPage() {
        guard isViewLoaded else { return }
        isRendering = true
        defer { isRendering = false }
        renderDisplayPicker()
        switch currentPage {
        case .displays:
            renderDisplaysPage()
            renderLayoutPage()
            renderGroupsPage()
            renderDiagnosticsPage()
        case .image: renderImagePage()
        case .general: renderGeneralSettings()
        case .about: renderAboutPage()
        }
    }

    private func renderDisplayPicker() {
        let selected = displayController.selectedDisplayID
        displayPicker.removeAllItems()
        for display in displayController.displays {
            displayPicker.addItem(withTitle: displayTitle(display, includeExternal: false))
            displayPicker.lastItem?.representedObject = NSNumber(value: display.id)
            if display.id == selected { displayPicker.selectItem(at: displayPicker.numberOfItems - 1) }
        }
    }

    private func renderDisplaysPage() {
        let diagnostic = DisplayDiagnostics.make(for: displayController.selectedDisplay)
        setText(
            "displayName",
            diagnostic.map { displayTitle($0.name, isBuiltIn: $0.isBuiltIn, includeExternal: true) } ?? "—"
        )
        if let display = displayController.selectedDisplay {
            setText(
                "displayStatus",
                CGDisplayIsInMirrorSet(display.id) != 0
                    ? L10n.text("display.mirroring")
                    : L10n.text("display.connected_extended")
            )
        } else {
            setText("displayStatus", "—")
        }
        setText("displayPixels", diagnostic.map { "\($0.pixelWidth) × \($0.pixelHeight)" } ?? "—")
        setText("displayPhysical", diagnostic.map { "\($0.physicalWidthMM) × \($0.physicalHeightMM) mm" } ?? "—")
        setText("displayGamma", diagnostic.map { L10n.text("display.sample_points", $0.gammaCapacity) } ?? "—")
        renderHardwareBrightness()
    }

    private func renderHardwareBrightness() {
        let value = displayController.hardwareBrightnessValue ?? 0
        hardwareBrightnessSlider.isEnabled = displayController.supportsHardwareBrightness
        hardwareBrightnessSlider.doubleValue = value
        hardwareBrightnessSlider.needsDisplay = true
        hardwareBrightnessSlider.displayIfNeeded()
        setText(
            "hardwareBrightnessStatus",
            displayController.supportsHardwareBrightness
                ? L10n.text(
                    "display.system_hardware_brightness",
                    Int((value * 100).rounded())
                )
                : L10n.text("display.hardware_brightness_unavailable")
        )
    }

    private func renderGroupsPage() {
        guard let picker = viewWithID("groupPicker") as? NSPopUpButton,
              let members = viewWithID("groupMembers") as? CheckboxListView
        else { return }
        picker.removeAllItems()
        if groupController.groups.isEmpty {
            picker.addItem(withTitle: L10n.text("groups.none"))
        } else {
            for group in groupController.groups {
                picker.addItem(withTitle: group.name)
                picker.lastItem?.representedObject = group.id
                if group.id == groupController.selectedGroupID { picker.selectItem(at: picker.numberOfItems - 1) }
            }
        }
        let selectedKeys = Set(groupController.selectedGroup?.displayKeys ?? [])
        let selected = Set(displayController.displays.compactMap { display -> NSNumber? in
            guard let key = DisplayIdentity.key(for: display.id), selectedKeys.contains(key) else { return nil }
            return NSNumber(value: display.id)
        })
        members.configure(
            entries: displayController.displays.map { (NSNumber(value: $0.id), displayTitle($0, includeExternal: false)) },
            selected: selected
        )
        setText("groupsStatus", groupController.statusMessage)
    }

    private func renderLayoutPage() {
        guard let modePicker = viewWithID("modePicker") as? NSPopUpButton,
              let targetPicker = viewWithID("mirrorTargetPicker") as? NSPopUpButton
        else { return }
        modePicker.removeAllItems()
        for mode in modeController.modes {
            modePicker.addItem(withTitle: mode.title)
            modePicker.lastItem?.representedObject = mode.id
            if mode.id == modeController.currentModeID { modePicker.selectItem(at: modePicker.numberOfItems - 1) }
        }
        targetPicker.removeAllItems()
        targetPicker.addItem(withTitle: L10n.text("layout.no_mirroring"))
        targetPicker.lastItem?.representedObject = NSNumber(value: kCGNullDirectDisplay)
        for display in displayController.displays where display.id != displayController.selectedDisplayID {
            targetPicker.addItem(withTitle: display.name)
            targetPicker.lastItem?.representedObject = NSNumber(value: display.id)
        }
        let mirrorTarget = displayController.selectedDisplayID.map(CGDisplayMirrorsDisplay)
        if let mirrorTarget,
           mirrorTarget != kCGNullDirectDisplay,
           let index = targetPicker.itemArray.firstIndex(where: {
               ($0.representedObject as? NSNumber)?.uint32Value == mirrorTarget
           }) {
            targetPicker.selectItem(at: index)
        } else {
            targetPicker.selectItem(at: 0)
        }
        targetPicker.isEnabled = displayController.selectedDisplayID != nil
        if let display = displayController.selectedDisplay {
            (viewWithID("layoutX") as? NSTextField)?.integerValue = Int(display.origin.x.rounded())
            (viewWithID("layoutY") as? NSTextField)?.integerValue = Int(display.origin.y.rounded())
        }
        setText("modesStatus", modeController.statusMessage)
        setText("layoutStatus", layoutController.mirroringStatusMessage)
        setText("positionStatus", layoutController.positionStatusMessage)
    }

    private func renderImagePage() {
        let adjustments = displayController.adjustments
        for row in allAdjustmentRows(in: pageContent) {
            row.setValue(adjustments[keyPath: row.keyPath])
        }
        if let picker = viewWithID("colorProfilePicker") as? NSPopUpButton {
            picker.removeAllItems()
            for profile in colorProfileController.profiles {
                picker.addItem(withTitle: profile.isCurrent
                    ? L10n.text("profile.current_suffix", profile.name)
                    : profile.name)
                picker.lastItem?.representedObject = profile.url
                if profile.isCurrent { picker.selectItem(at: picker.numberOfItems - 1) }
            }
            picker.isEnabled = picker.numberOfItems > 0
        }
        if let picker = viewWithID("framebufferModePicker") as? NSPopUpButton {
            picker.removeAllItems()
            for mode in FramebufferColorMode.allCases {
                picker.addItem(withTitle: mode.title)
                picker.lastItem?.representedObject = NSNumber(value: mode.rawValue)
                if mode == framebufferController.state.mode { picker.selectItem(at: picker.numberOfItems - 1) }
            }
            picker.isEnabled = framebufferController.state.supportsColorMode
        }
        if let dithering = viewWithID("ditheringCheckbox") as? NSButton {
            dithering.isEnabled = framebufferController.state.supportsDithering
            dithering.state = framebufferController.state.ditheringEnabled == true ? .on : .off
        }
        if let autoDithering = viewWithID("autoDitheringCheckbox") as? NSButton {
            autoDithering.state = preferences.enableDitheringForColorModes ? .on : .off
            autoDithering.isEnabled = framebufferController.state.supportsDithering
        }
        if let uniformity = viewWithID("uniformityCheckbox") as? NSButton {
            uniformity.isEnabled = framebufferController.state.supportsUniformityCorrection
            uniformity.state = framebufferController.state.uniformityCorrectionEnabled == true ? .on : .off
        }
        for region in ["adjustmentsStatus", "channelsStatus", "recoveryStatus"] {
            setText(region, "")
        }
        let imageStatusID: String
        switch displayController.imageStatusRegion {
        case .adjustments: imageStatusID = "adjustmentsStatus"
        case .channels: imageStatusID = "channelsStatus"
        case .recovery: imageStatusID = "recoveryStatus"
        }
        setText(imageStatusID, displayController.imageStatusMessage)
        setText("colorProfileStatus", colorProfileController.statusMessage)
        renderSystemColorModes()
        setText("framebufferStatus", framebufferController.modeStatusMessage)
        setText(
            "framebufferToolsStatus",
            [
                framebufferController.toolsStatusMessage,
                L10n.text(
                    "framebuffer.tools_status",
                    framebufferStateTitle(framebufferController.state.ditheringEnabled),
                    framebufferStateTitle(framebufferController.state.uniformityCorrectionEnabled)
                )
            ]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        )
    }

    private func renderSystemColorModes() {
        let state = colorModesController.state
        nightShiftCheckbox.isEnabled = state.nightShiftSupported
        nightShiftCheckbox.state = state.nightShiftEnabled == true ? .on : .off
        nightShiftStrengthSlider.isEnabled = state.nightShiftStrength != nil
        nightShiftStrengthSlider.doubleValue = state.nightShiftStrength ?? 0
        trueToneCheckbox.isEnabled = state.trueToneSupported
        trueToneCheckbox.state = state.trueToneEnabled == true ? .on : .off
        setText("systemModesStatus", colorModesController.statusText)
    }

    private func renderDiagnosticsPage() {
        let info = DisplayDiagnostics.make(for: displayController.selectedDisplay)
        setText("diagName", L10n.text("diagnostics.name", info?.name ?? "—"))
        setText("diagID", L10n.text("diagnostics.id", info.map { String($0.displayID) } ?? "—"))
        setText(
            "diagType",
            L10n.text(
                "diagnostics.type",
                info.map { $0.isBuiltIn ? L10n.text("display.built_in_display") : L10n.text("display.external_display") } ?? "—"
            )
        )
        setText(
            "diagVendor",
            info.map { L10n.text("diagnostics.vendor", String($0.vendor), String($0.model), String($0.serial)) }
                ?? L10n.text("diagnostics.vendor", "—", "—", "—")
        )
        setText(
            "diagPixels",
            info.map { L10n.text("diagnostics.pixels", $0.pixelWidth, $0.pixelHeight) }
                ?? L10n.text("diagnostics.pixels", 0, 0)
        )
        setText(
            "diagPhysical",
            info.map { L10n.text("diagnostics.physical", $0.physicalWidthMM, $0.physicalHeightMM) }
                ?? L10n.text("diagnostics.physical", 0, 0)
        )
        setText("diagMode", L10n.text("diagnostics.mode", info?.currentMode ?? "—"))
        setText("diagGamma", L10n.text("diagnostics.gamma", info?.gammaCapacity ?? 0))
        setText("diagEDID", L10n.text("diagnostics.edid", info?.edidHex ?? info?.edidNote ?? "—"))
    }

    private func renderGeneralSettings() {
        guard currentPage == .general else { return }
        if let language = viewWithID("interfaceLanguagePicker") as? NSPopUpButton {
            if let index = language.itemArray.firstIndex(where: {
                ($0.representedObject as? String) == preferences.interfaceLanguage.rawValue
            }) {
                language.selectItem(at: index)
            }
        }
        if let menuBar = viewWithID("menuBarIconCheckbox") as? NSButton {
            menuBar.state = preferences.showMenuBarIcon ? .on : .off
        }
        if let launch = viewWithID("launchAtLoginCheckbox") as? NSButton {
            launch.state = preferences.launchAtLogin ? .on : .off
        }
        let status = launchAtLoginController.status
        let shouldShowLoginStatus: Bool
        switch status {
        case .requiresApproval, .unavailable:
            shouldShowLoginStatus = true
        case .enabled, .disabled:
            shouldShowLoginStatus = false
        }
        setText("launchAtLoginStatus", shouldShowLoginStatus ? status.description : "")
        viewWithID("launchAtLoginStatusContainer")?.isHidden = !shouldShowLoginStatus
    }

    private func renderAboutPage() {
        guard currentPage == .about else { return }
        setText("aboutUpdateStatus", updateStatusText)
        if let checkButton = viewWithID("checkUpdatesButton") as? NSButton {
            if isCheckingForUpdate {
                checkButton.title = L10n.text("about.checking")
            } else if releaseURL != nil {
                checkButton.title = L10n.text("about.open_release")
            } else {
                checkButton.title = L10n.text("about.check_updates")
            }
            checkButton.isEnabled = !isCheckingForUpdate
        }
    }

    private func displayTitle(_ display: DisplayDescriptor, includeExternal: Bool) -> String {
        displayTitle(display.name, isBuiltIn: display.isBuiltIn, includeExternal: includeExternal)
    }

    private func displayTitle(_ name: String, isBuiltIn: Bool, includeExternal: Bool) -> String {
        if isBuiltIn {
            return "\(name) (\(L10n.text("display.built_in")))"
        }
        if includeExternal {
            return "\(name) (\(L10n.text("display.external")))"
        }
        return name
    }

    private func framebufferStateTitle(_ state: Bool?) -> String {
        guard let state else { return L10n.text("framebuffer.exposed") }
        return state ? L10n.text("state.enabled") : L10n.text("state.disabled")
    }

    private func setText(_ id: String, _ text: String) {
        (viewWithID(id) as? NSTextField)?.stringValue = text
    }

    private func viewWithID(_ id: String) -> NSView? {
        findView(in: pageContent, id: NSUserInterfaceItemIdentifier(id))
    }

    private func findView(in root: NSView, id: NSUserInterfaceItemIdentifier) -> NSView? {
        if root.identifier == id { return root }
        for child in root.subviews {
            if let found = findView(in: child, id: id) { return found }
        }
        return nil
    }

    private func allAdjustmentRows(in root: NSView) -> [AdjustmentRow] {
        var result: [AdjustmentRow] = []
        if let row = root as? AdjustmentRow { result.append(row) }
        for child in root.subviews { result += allAdjustmentRows(in: child) }
        return result
    }

    private func horizontalSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    private func verticalSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }
}

private final class SettingsCard: NSView {
    let content = FullWidthStackView()

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 15, left: 16, bottom: 15, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(titleLabel)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        stack.addArrangedSubview(content)
        content.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class FullWidthStackView: NSStackView {
    override func addArrangedSubview(_ view: NSView) {
        super.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class SidebarButton: NSButton {
    var isSelected = false {
        didSet { refreshAppearance() }
    }
    private var isPointerInside = false {
        didSet { refreshAppearance() }
    }
    private var trackingArea: NSTrackingArea?
    private let iconView = NSImageView()
    private let titleLabel: NSTextField = NSTextField(labelWithString: "")

    init(title: String, image: String) {
        super.init(frame: .zero)
        self.title = ""
        self.image = nil
        imagePosition = .noImage
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        layer?.cornerRadius = 7
        toolTip = title
        setAccessibilityLabel(title)
        titleLabel.stringValue = title
        iconView.image = NSImage(systemSymbolName: image, accessibilityDescription: title)
        iconView.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        iconView.imageScaling = .scaleProportionallyDown
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        refreshAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if bounds.contains(point) {
            return self
        }
        if let superview, bounds.contains(convert(point, from: superview)) {
            return self
        }
        return nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            iconView.contentTintColor = .controlAccentColor
            titleLabel.textColor = .controlAccentColor
            titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        } else if isPointerInside {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
            iconView.contentTintColor = .labelColor
            titleLabel.textColor = .labelColor
            titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            iconView.contentTintColor = .secondaryLabelColor
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        }
    }
}

private func parseAdjustmentNumber(_ text: String) -> Double? {
    let normalized = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "%", with: "")
        .replacingOccurrences(of: "％", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }

    let numberFormatter = NumberFormatter()
    numberFormatter.locale = .current
    numberFormatter.numberStyle = .decimal
    return numberFormatter.number(from: normalized)?.doubleValue
        ?? Double(normalized.replacingOccurrences(of: ",", with: "."))
}

private func normalizedControlString(_ value: Double) -> String {
    String(format: "%.2f", value.clamped(to: 0 ... 1))
}

private func parseNormalizedControl(_ text: String) -> Double? {
    guard let number = parseAdjustmentNumber(text) else { return nil }
    if text.contains("%") || text.contains("％") || abs(number) > 1 {
        return number / 100
    }
    return number
}

private final class AdjustmentRow: NSView, NSTextFieldDelegate {
    let keyPath: WritableKeyPath<ColorAdjustments, Double>
    private let slider: NSSlider
    private let valueField = NSTextField(string: "")
    private let resetButton: NSButton
    private let stepper: NSSegmentedControl
    private let range: ClosedRange<Double>
    private let step: Double
    private let defaultValue: Double
    private let formatter: (Double) -> String
    private let parser: (String) -> Double?
    private let change: (Double) -> Void

    init(
        title: String,
        keyPath: WritableKeyPath<ColorAdjustments, Double>,
        range: ClosedRange<Double>,
        step: Double,
        defaultValue: Double,
        formatter: @escaping (Double) -> String,
        parser: @escaping (String) -> Double?,
        labelWidth: CGFloat?,
        change: @escaping (Double) -> Void
    ) {
        self.keyPath = keyPath
        self.range = range
        self.step = step
        self.defaultValue = defaultValue.clamped(to: range)
        self.formatter = formatter
        self.parser = parser
        self.change = change
        slider = NSSlider(value: range.lowerBound, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        resetButton = NSButton(
            image: NSImage(
                systemSymbolName: "arrow.counterclockwise",
                accessibilityDescription: L10n.text("action.reset_default")
            )!,
            target: nil,
            action: nil
        )
        stepper = NSSegmentedControl(
            labels: ["−", "+"],
            trackingMode: .momentary,
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isContinuous = true
        resetButton.target = self
        resetButton.action = #selector(resetToDefault(_:))
        resetButton.bezelStyle = .texturedRounded
        resetButton.controlSize = .regular
        resetButton.toolTip = L10n.text("action.reset_default")
        resetButton.setAccessibilityLabel(L10n.text("action.reset_adjustment", title))
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))
        stepper.segmentStyle = .separated
        stepper.controlSize = .regular
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.alignment = labelWidth == nil ? .natural : .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        if let labelWidth {
            label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        }
        row.addArrangedSubview(label)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(slider)

        let valueControls = NSStackView()
        valueControls.orientation = .horizontal
        valueControls.alignment = .centerY
        valueControls.spacing = 5
        valueControls.setContentHuggingPriority(.required, for: .horizontal)
        valueControls.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueField.alignment = .right
        valueField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        valueField.controlSize = .regular
        valueField.delegate = self
        valueField.setAccessibilityLabel(title)
        valueField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        valueControls.addArrangedSubview(valueField)
        resetButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        valueControls.addArrangedSubview(resetButton)
        stepper.setWidth(23, forSegment: 0)
        stepper.setWidth(23, forSegment: 1)
        stepper.widthAnchor.constraint(equalToConstant: 46).isActive = true
        valueControls.addArrangedSubview(stepper)
        row.addArrangedSubview(valueControls)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        commit(sender.doubleValue, notifiesChange: true)
    }

    @objc private func stepperChanged(_ sender: NSSegmentedControl) {
        let direction = sender.selectedSegment == 0 ? -1.0 : 1.0
        commit(slider.doubleValue + (direction * step), notifiesChange: true)
    }

    @objc private func resetToDefault(_ sender: NSButton) {
        commit(defaultValue, notifiesChange: true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let value = parser(valueField.stringValue) else {
            setValue(slider.doubleValue)
            return
        }
        commit(value, notifiesChange: true)
    }

    func setValue(_ value: Double) {
        commit(value, notifiesChange: false)
    }

    private func commit(_ rawValue: Double, notifiesChange: Bool) {
        let value = normalized(rawValue)
        let changed = abs(value - slider.doubleValue) > 0.000_001
        slider.doubleValue = value
        valueField.stringValue = formatter(value)
        resetButton.isEnabled = abs(value - defaultValue) > 0.000_001
        if notifiesChange, changed {
            change(value)
        }
    }

    private func normalized(_ rawValue: Double) -> Double {
        let clamped = rawValue.clamped(to: range)
        let steps = ((clamped - range.lowerBound) / step).rounded()
        return (range.lowerBound + (steps * step)).clamped(to: range)
    }
}

private final class CheckboxListView: NSView {
    private let stack = NSStackView()
    private var entries: [(button: NSButton, value: NSNumber)] = []
    var onSelectionChanged: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var selectedValues: [Any] {
        entries.filter { $0.button.state == .on }.map(\.value)
    }

    func configure(entries: [(NSNumber, String)], selected: Set<NSNumber>) {
        self.entries.forEach { stack.removeArrangedSubview($0.button); $0.button.removeFromSuperview() }
        self.entries = entries.map { value, title in
            let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(selectionChanged(_:)))
            button.state = selected.contains(value) ? .on : .off
            stack.addArrangedSubview(button)
            return (button, value)
        }
    }

    @objc private func selectionChanged(_ sender: NSButton) {
        onSelectionChanged?()
    }
}
