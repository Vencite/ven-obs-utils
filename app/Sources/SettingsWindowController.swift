import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    typealias SaveHandler = (SettingsDraft) throws -> Void

    private let initialDraft: SettingsDraft
    private let onSave: SaveHandler
    private let onOpenConfig: () -> Void

    private let obsHostField = NSTextField()
    private let obsPortField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let obsBreakRegexField = NSTextField()
    private let ontimeURLField = NSTextField()
    private let ontimeBreakRegexField = NSTextField()
    private let serverPortField = NSTextField()
    private let reconnectField = NSTextField()
    private let enterBreakCheckbox = NSButton(checkboxWithTitle: "Jump to next Ontime break when entering a break scene", target: nil, action: nil)
    private let leaveBreakCheckbox = NSButton(checkboxWithTitle: "Advance Ontime when leaving a break scene", target: nil, action: nil)
    private let dryRunCheckbox = NSButton(checkboxWithTitle: "Dry run - never start Ontime events", target: nil, action: nil)
    private let generalErrorLabel = NSTextField(labelWithString: "")
    private var errorLabels: [SettingsDraftField: NSTextField] = [:]

    init(draft: SettingsDraft, onSave: @escaping SaveHandler, onOpenConfig: @escaping () -> Void) {
        self.initialDraft = draft
        self.onSave = onSave
        self.onOpenConfig = onOpenConfig

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 590, height: 650),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "VEN OBS Utils - Settings"
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        populate(draft)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        clearErrors()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Menu-bar apps (.accessory) have no dock and often no active focus.
        // orderFrontRegardless forces the window above the current key window
        // even when the app is not active — without it Settings can silently
        // fail to appear when the app never received activation.
        window?.orderFrontRegardless()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            root.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
        ])

        root.addArrangedSubview(sectionHeader("OBS"))
        root.addArrangedSubview(fieldRow(label: "Host", field: obsHostField, key: .obsHost))
        root.addArrangedSubview(fieldRow(label: "Port", field: obsPortField, key: .obsPort))
        root.addArrangedSubview(fieldRow(label: "Password", field: passwordField, key: .password))
        root.addArrangedSubview(fieldRow(label: "Break scene regex", field: obsBreakRegexField, key: .obsBreakSceneRegex))

        root.addArrangedSubview(separator())
        root.addArrangedSubview(sectionHeader("Ontime"))
        root.addArrangedSubview(fieldRow(label: "URL", field: ontimeURLField, key: .ontimeBaseURL))
        root.addArrangedSubview(fieldRow(label: "Break CUE regex", field: ontimeBreakRegexField, key: .ontimeBreakCueRegex))

        root.addArrangedSubview(separator())
        root.addArrangedSubview(sectionHeader("Automation"))
        root.addArrangedSubview(enterBreakCheckbox)
        root.addArrangedSubview(leaveBreakCheckbox)
        root.addArrangedSubview(dryRunCheckbox)

        root.addArrangedSubview(separator())
        root.addArrangedSubview(sectionHeader("Advanced"))
        root.addArrangedSubview(fieldRow(label: "Local service port", field: serverPortField, key: .serverPort))
        root.addArrangedSubview(fieldRow(label: "Reconnect OBS every", field: reconnectField, key: .reconnectSeconds, suffix: "seconds"))

        let openConfigButton = NSButton(title: "Open config file", target: self, action: #selector(openConfig))
        openConfigButton.bezelStyle = .rounded
        root.addArrangedSubview(openConfigButton)

        generalErrorLabel.textColor = .systemRed
        generalErrorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        generalErrorLabel.maximumNumberOfLines = 2
        generalErrorLabel.lineBreakMode = .byWordWrapping
        generalErrorLabel.isHidden = true
        root.addArrangedSubview(generalErrorLabel)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        let save = NSButton(title: "Save & Restart", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"

        buttons.addArrangedSubview(spacer)
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(save)
        buttons.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        root.addArrangedSubview(buttons)
    }

    private func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 542).isActive = true
        return box
    }

    private func fieldRow(
        label: String,
        field: NSTextField,
        key: SettingsDraftField,
        suffix: String? = nil
    ) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 3

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 150).isActive = true

        field.widthAnchor.constraint(equalToConstant: suffix == nil ? 350 : 270).isActive = true
        row.addArrangedSubview(labelView)
        row.addArrangedSubview(field)

        if let suffix {
            let suffixLabel = NSTextField(labelWithString: suffix)
            suffixLabel.textColor = .secondaryLabelColor
            row.addArrangedSubview(suffixLabel)
        }

        let error = NSTextField(labelWithString: "")
        error.textColor = .systemRed
        error.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        error.isHidden = true
        error.maximumNumberOfLines = 2
        error.lineBreakMode = .byWordWrapping
        errorLabels[key] = error

        let errorIndent = NSStackView()
        errorIndent.orientation = .horizontal
        let blank = NSView()
        blank.widthAnchor.constraint(equalToConstant: 160).isActive = true
        errorIndent.addArrangedSubview(blank)
        errorIndent.addArrangedSubview(error)

        container.addArrangedSubview(row)
        container.addArrangedSubview(errorIndent)
        return container
    }

    private func populate(_ draft: SettingsDraft) {
        obsHostField.stringValue = draft.obsHost
        obsPortField.stringValue = draft.obsPort
        passwordField.stringValue = draft.password
        obsBreakRegexField.stringValue = draft.obsBreakSceneRegex
        ontimeURLField.stringValue = draft.ontimeBaseURL
        ontimeBreakRegexField.stringValue = draft.ontimeBreakCueRegex
        serverPortField.stringValue = draft.serverPort
        reconnectField.stringValue = draft.reconnectSeconds
        enterBreakCheckbox.state = draft.enterBreakEnabled ? .on : .off
        leaveBreakCheckbox.state = draft.leaveBreakEnabled ? .on : .off
        dryRunCheckbox.state = draft.dryRun ? .on : .off
    }

    private func makeDraft() -> SettingsDraft {
        var draft = initialDraft
        draft.obsHost = obsHostField.stringValue
        draft.obsPort = obsPortField.stringValue
        draft.password = passwordField.stringValue
        draft.obsBreakSceneRegex = obsBreakRegexField.stringValue
        draft.ontimeBaseURL = ontimeURLField.stringValue
        draft.ontimeBreakCueRegex = ontimeBreakRegexField.stringValue
        draft.serverPort = serverPortField.stringValue
        draft.reconnectSeconds = reconnectField.stringValue
        draft.enterBreakEnabled = enterBreakCheckbox.state == .on
        draft.leaveBreakEnabled = leaveBreakCheckbox.state == .on
        draft.dryRun = dryRunCheckbox.state == .on
        return draft
    }

    private func clearErrors() {
        for label in errorLabels.values {
            label.stringValue = ""
            label.isHidden = true
        }
        generalErrorLabel.stringValue = ""
        generalErrorLabel.isHidden = true
    }

    private func show(error: SettingsDraftError) {
        clearErrors()
        if error.field == .general {
            generalErrorLabel.stringValue = error.message
            generalErrorLabel.isHidden = false
        } else if let label = errorLabels[error.field] {
            label.stringValue = error.message
            label.isHidden = false
        } else {
            generalErrorLabel.stringValue = error.message
            generalErrorLabel.isHidden = false
        }
    }

    @objc private func save() {
        clearErrors()
        do {
            try onSave(makeDraft())
            window?.close()
        } catch let error as SettingsDraftError {
            show(error: error)
        } catch {
            show(error: SettingsDraftError(field: .general, message: error.localizedDescription))
        }
    }

    @objc private func cancel() {
        window?.close()
    }

    @objc private func openConfig() {
        onOpenConfig()
    }
}
