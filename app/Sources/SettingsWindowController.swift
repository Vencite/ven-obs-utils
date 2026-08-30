import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    typealias SaveHandler = (SettingsDraft) throws -> Void

    private let initialDraft: SettingsDraft
    private let onSave: SaveHandler
    private let onOpenConfig: () -> Void
    private let onDiagnostic: (String) -> Void

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

    init(
        draft: SettingsDraft,
        onSave: @escaping SaveHandler,
        onOpenConfig: @escaping () -> Void,
        onDiagnostic: @escaping (String) -> Void
    ) {
        onDiagnostic("settings panel init started")
        self.initialDraft = draft
        self.onSave = onSave
        self.onOpenConfig = onOpenConfig
        self.onDiagnostic = onDiagnostic

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 590, height: 650),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        onDiagnostic("settings panel created")
        window.title = "VEN OBS Utils - Settings"
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        super.init(window: window)
        window.delegate = self
        onDiagnostic("settings panel build_ui started")
        buildUI()
        onDiagnostic("settings panel build_ui completed")
        populate(draft)
        onDiagnostic("settings panel populate completed")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        clearErrors()
        // This is called only after the status-menu tracking loop has ended.
        // A menu-bar app must become a regular app before AppKit can make a
        // utility panel key and visible.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        // Restore menu-bar app state when the panel closes.
        NSApp.setActivationPolicy(.accessory)
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        contentView.addSubview(scrollView)
        onDiagnostic("settings panel scroll_view added")

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 12
        form.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(form)
        onDiagnostic("settings panel form created")

        form.addArrangedSubview(sectionHeader("OBS"))
        form.addArrangedSubview(fieldRow(label: "Host", field: obsHostField, key: .obsHost))
        form.addArrangedSubview(fieldRow(label: "Port", field: obsPortField, key: .obsPort))
        form.addArrangedSubview(fieldRow(label: "Password", field: passwordField, key: .password))
        form.addArrangedSubview(fieldRow(label: "Break scene regex", field: obsBreakRegexField, key: .obsBreakSceneRegex))

        form.addArrangedSubview(separator(in: form))
        form.addArrangedSubview(sectionHeader("Ontime"))
        form.addArrangedSubview(fieldRow(label: "URL", field: ontimeURLField, key: .ontimeBaseURL))
        form.addArrangedSubview(fieldRow(label: "Break CUE regex", field: ontimeBreakRegexField, key: .ontimeBreakCueRegex))

        form.addArrangedSubview(separator(in: form))
        form.addArrangedSubview(sectionHeader("Automation"))
        form.addArrangedSubview(enterBreakCheckbox)
        form.addArrangedSubview(leaveBreakCheckbox)
        form.addArrangedSubview(dryRunCheckbox)

        form.addArrangedSubview(separator(in: form))
        form.addArrangedSubview(sectionHeader("Advanced"))
        form.addArrangedSubview(fieldRow(label: "Local service port", field: serverPortField, key: .serverPort))
        form.addArrangedSubview(fieldRow(label: "Reconnect OBS every", field: reconnectField, key: .reconnectSeconds, suffix: "seconds"))

        let openConfigButton = NSButton(title: "Open config file", target: self, action: #selector(openConfig))
        openConfigButton.bezelStyle = .rounded
        form.addArrangedSubview(openConfigButton)
        onDiagnostic("settings panel form fields added")

        generalErrorLabel.textColor = .systemRed
        generalErrorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        generalErrorLabel.maximumNumberOfLines = 2
        generalErrorLabel.lineBreakMode = .byWordWrapping
        generalErrorLabel.isHidden = true
        form.addArrangedSubview(generalErrorLabel)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false

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
        contentView.addSubview(buttons)
        onDiagnostic("settings panel buttons added")

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            form.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
            form.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
            form.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 16),
            form.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -16),
        ])
        onDiagnostic("settings panel constraints activated")
    }

    private func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func separator(in form: NSStackView) -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
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
