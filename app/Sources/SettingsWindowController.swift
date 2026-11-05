import AppKit
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    typealias SaveHandler = (SettingsDraft) throws -> Void
    private let initialDraft: SettingsDraft
    private let onSave: SaveHandler
    private let onOpenConfig: () -> Void
    private let loadSources: () async throws -> [MPSSourceChoice]
    private var choices: [MPSSourceChoice] = []
    private var sourceTask: Task<Void, Never>?
    private var mediaState: [String: Any] = [:]

    private let obsHostField = NSTextField()
    private let obsPortField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let obsBreakRegexField = NSTextField()
    private let ontimeURLField = NSTextField()
    private let ontimeBreakRegexField = NSTextField()
    private let serverPortField = NSTextField()
    private let reconnectField = NSTextField()
    private let enterBreakCheckbox = NSButton(checkboxWithTitle: "Enter the next Ontime break when Program enters a break scene", target: nil, action: nil)
    private let leaveBreakCheckbox = NSButton(checkboxWithTitle: "Advance Ontime when Program leaves a break scene", target: nil, action: nil)
    private let dryRunCheckbox = NSButton(checkboxWithTitle: "Dry run — preview actions without changing Ontime", target: nil, action: nil)
    private let mediaEnabled = NSButton(checkboxWithTitle: "Enable media outputs", target: nil, action: nil)
    private let sourceMode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sourcePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sourceRefresh = NSButton(title: "Refresh", target: nil, action: nil)
    private let sourceStatus = NSTextField(wrappingLabelWithString: "Waiting for OBS…")
    private let txtEnabled = NSButton(checkboxWithTitle: "Export current filename to a text file", target: nil, action: nil)
    private let txtPath = NSTextField()
    private let txtPolicy = NSPopUpButton(frame: .zero, pullsDown: false)
    private let timerEnabled = NSButton(checkboxWithTitle: "Send media time to Ontime", target: nil, action: nil)
    private let timerSource = NSPopUpButton(frame: .zero, pullsDown: false)
    private let timerOutput = NSPopUpButton(frame: .zero, pullsDown: false)
    private let auxIndex = NSPopUpButton(frame: .zero, pullsDown: false)
    private let inactivePolicy = NSPopUpButton(frame: .zero, pullsDown: false)
    private let secondaryTemplate = NSTextField()
    private let insertVariable = NSPopUpButton(frame: .zero, pullsDown: false)
    private let messagePreview = NSTextField(wrappingLabelWithString: "")
    private let selectSecondary = NSButton(checkboxWithTitle: "Show this output in Stage Timer’s secondary area", target: nil, action: nil)
    private let outputStatus = NSTextField(wrappingLabelWithString: "Output status will appear after saving.")
    private let mediaBody = NSStackView()
    private let explicitBody = NSStackView()
    private let txtBody = NSStackView()
    private var timerSourceRow: NSView?
    private let timerBody = NSStackView()
    private let auxBody = NSStackView()
    private let messageBody = NSStackView()
    private let generalErrorLabel = NSTextField(wrappingLabelWithString: "")
    private var errorLabels: [SettingsDraftField: NSTextField] = [:]

    init(draft: SettingsDraft, onSave: @escaping SaveHandler, onOpenConfig: @escaping () -> Void,
         loadSources: @escaping () async throws -> [MPSSourceChoice] = { [] }) {
        initialDraft = draft
        self.onSave = onSave
        self.onOpenConfig = onOpenConfig
        self.loadSources = loadSources
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 740),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        window.title = "VOS — Settings"
        window.minSize = NSSize(width: 680, height: 540)
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        populate(draft)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        clearErrors()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        refreshSources()
    }

    func windowWillClose(_ notification: Notification) {
        sourceTask?.cancel()
        NSApp.setActivationPolicy(.accessory)
    }

    private func stack(_ target: NSStackView = NSStackView(), spacing: CGFloat = 12) -> NSStackView {
        target.orientation = .vertical
        target.alignment = .leading
        target.spacing = spacing
        target.detachesHiddenViews = true
        return target
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func card(_ title: String, _ detail: String, _ views: [NSView]) -> NSView {
        let content = stack(spacing: 10)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        content.addArrangedSubview(heading)
        if !detail.isEmpty { content.addArrangedSubview(note(detail)) }
        for view in views { content.addArrangedSubview(view) }
        let box = NSBox()
        box.boxType = .custom
        box.borderType = .lineBorder
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 8
        box.contentViewMargins = NSSize(width: 16, height: 16)
        box.contentView = content
        return box
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func row(_ label: String, _ control: NSView, key: SettingsDraftField? = nil) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.widthAnchor.constraint(equalToConstant: 132).isActive = true
        if let field = control as? NSTextField {
            field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }
        let body = stack(spacing: 3)
        body.addArrangedSubview(horizontal([title, control]))
        if let key {
            let error = note("")
            error.textColor = .systemRed
            error.isHidden = true
            errorLabels[key] = error
            body.addArrangedSubview(error)
        }
        return body
    }

    private func page(_ views: [NSView]) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let content = stack(spacing: 16)
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        for view in views {
            content.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
        ])
        return scroll
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        let connections = NSTabViewItem(identifier: "connections")
        connections.label = "Connections"
        connections.view = page([
            card("OBS Studio", "Connect to OBS to follow Program and Media Playlist Source.", [
                row("Host", obsHostField, key: .obsHost), row("Port", obsPortField, key: .obsPort),
                row("Password", passwordField, key: .password)]),
            card("Ontime", "The server receiving your media time and break actions.", [row("Server URL", ontimeURLField, key: .ontimeBaseURL)]),
            card("Operation mode", "Dry run applies to every Ontime action, including media timers and messages.", [dryRunCheckbox]),
            card("Advanced connection settings", "", [row("Helper port", serverPortField, key: .serverPort),
                row("Reconnect (seconds)", reconnectField, key: .reconnectSeconds),
                NSButton(title: "Open config file…", target: self, action: #selector(openConfig))]),
        ])
        tabs.addTabViewItem(connections)

        _ = stack(mediaBody)
        _ = stack(explicitBody, spacing: 8)
        _ = stack(txtBody, spacing: 8)
        _ = stack(timerBody)
        _ = stack(auxBody, spacing: 8)
        _ = stack(messageBody, spacing: 8)
        sourceMode.addItems(withTitles: ["Automatically follow Program", "Choose a specific playlist"])
        sourceMode.target = self
        sourceMode.action = #selector(optionsChanged)
        sourceRefresh.target = self
        sourceRefresh.action = #selector(refreshSources)
        sourcePicker.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        sourcePicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourcePicker.setAccessibilityLabel("Media Playlist Source to follow")
        sourceStatus.font = .systemFont(ofSize: 12)
        sourceStatus.textColor = .secondaryLabelColor
        explicitBody.addArrangedSubview(horizontal([sourcePicker, sourceRefresh]))
        explicitBody.addArrangedSubview(note("Sources are loaded from OBS. Your selection is saved by UUID, so renaming it is safe."))
        mediaBody.addArrangedSubview(card("Playlist source", "Automatic mode follows one visible MPS in Program, including nested scenes. Preview is ignored. Multiple playlists are reported instead of choosing one.", [sourceMode, explicitBody, sourceStatus]))

        txtPath.placeholderString = "/Users/you/Show/current-media.txt"
        txtPolicy.addItems(withTitles: ["Clear the text file when inactive", "Keep the last filename"])
        txtBody.addArrangedSubview(row("Text file", txtPath))
        txtBody.addArrangedSubview(horizontal([
            NSButton(title: "Choose file…", target: self, action: #selector(chooseFile)),
            NSButton(title: "Choose folder…", target: self, action: #selector(chooseFolder))]))
        txtBody.addArrangedSubview(note("Choose a folder to create current-media.txt there. The file contains only the filename and is updated when it changes."))
        txtBody.addArrangedSubview(txtPolicy)
        mediaBody.addArrangedSubview(card("Filename export", "Use the current filename in an OBS text source or another application.", [txtEnabled, txtBody]))

        timerSource.addItems(withTitles: ["Whole playlist — current pass", "Current file"])
        timerOutput.addItems(withTitles: ["Auxiliary countdown timer", "Secondary text message"])
        timerOutput.target = self
        timerOutput.action = #selector(optionsChanged)
        auxIndex.addItems(withTitles: ["Timer 1", "Timer 2", "Timer 3"])
        auxBody.addArrangedSubview(row("Reserved slot", auxIndex))
        auxBody.addArrangedSubview(note("Reserve this slot for VOS. VOS updates this auxiliary timer; it never advances the main rundown when media ends."))
        secondaryTemplate.delegate = self
        secondaryTemplate.widthAnchor.constraint(equalToConstant: 520).isActive = true
        insertVariable.addItem(withTitle: "Insert variable…")
        for variable in MediaMessageTemplate.variables { insertVariable.addItem(withTitle: variable.label) }
        insertVariable.target = self
        insertVariable.action = #selector(insertMessageVariable)
        messageBody.addArrangedSubview(secondaryTemplate)
        messageBody.addArrangedSubview(insertVariable)
        messagePreview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        messageBody.addArrangedSubview(note("Preview — live values when available, otherwise an example:"))
        messageBody.addArrangedSubview(messagePreview)
        inactivePolicy.addItems(withTitles: ["Stop / clear when unavailable", "Pause / keep last value when unavailable"])
        timerSourceRow = row("Time to send", timerSource)
        timerBody.addArrangedSubview(timerSourceRow!)
        timerBody.addArrangedSubview(row("Display as", timerOutput))
        timerBody.addArrangedSubview(auxBody)
        timerBody.addArrangedSubview(messageBody)
        timerBody.addArrangedSubview(selectSecondary)
        timerBody.addArrangedSubview(note("This optional setting changes Ontime’s Stage Timer secondary area to the chosen timer or message. Otherwise choose it in Ontime yourself."))
        timerBody.addArrangedSubview(inactivePolicy)
        outputStatus.font = .systemFont(ofSize: 12)
        outputStatus.textColor = .secondaryLabelColor
        mediaBody.addArrangedSubview(card("Ontime media output", "Unknown durations stay unknown. No guessed countdown is sent.", [timerEnabled, timerBody, outputStatus]))
        for button in [mediaEnabled, txtEnabled, timerEnabled] {
            button.target = self
            button.action = #selector(optionsChanged)
        }
        let media = NSTabViewItem(identifier: "media")
        media.label = "Media outputs"
        media.view = page([mediaEnabled, mediaBody])
        tabs.addTabViewItem(media)

        let breaks = NSTabViewItem(identifier: "breaks")
        breaks.label = "Break automation"
        breaks.view = page([card("Program scene transitions", "Only Program scene changes trigger this automation. Media playback does not advance the rundown.", [
            enterBreakCheckbox, leaveBreakCheckbox,
            row("OBS scene pattern", obsBreakRegexField, key: .obsBreakSceneRegex),
            row("Ontime CUE pattern", ontimeBreakRegexField, key: .ontimeBreakCueRegex)])])
        tabs.addTabViewItem(breaks)
        if initialDraft.mediaBridge["enabled"] as? Bool == true { tabs.selectTabViewItem(media) }

        generalErrorLabel.textColor = .systemRed
        generalErrorLabel.isHidden = true
        generalErrorLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(generalErrorLabel)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save & Reconnect", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let buttons = horizontal([cancel, save])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            generalErrorLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            generalErrorLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),
            generalErrorLabel.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
        ])
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
        let media = draft.mediaBridge
        mediaEnabled.state = media["enabled"] as? Bool == true ? .on : .off
        sourceMode.selectItem(at: media["source_mode"] as? String == "explicit" ? 1 : 0)
        let uuid = media["source_uuid"] as? String ?? ""
        let name = media["source_name"] as? String ?? ""
        if !uuid.isEmpty || !name.isEmpty { choices = [MPSSourceChoice(uuid: uuid, name: name.isEmpty ? "Saved playlist (not yet verified)" : name)] }
        fillSources()
        let txt = media["txt"] as? [String: Any] ?? [:]
        txtEnabled.state = txt["enabled"] as? Bool == true ? .on : .off
        txtPath.stringValue = txt["path"] as? String ?? ""
        txtPolicy.selectItem(at: txt["clear_policy"] as? String == "keep_last" ? 1 : 0)
        let timer = media["timer"] as? [String: Any] ?? [:]
        let mode = timer["media_timer_source"] as? String ?? "off"
        timerEnabled.state = mode == "off" ? .off : .on
        timerSource.selectItem(at: mode == "current_item" ? 1 : 0)
        timerOutput.selectItem(at: timer["ontime_output"] as? String == "secondary_message" ? 1 : 0)
        auxIndex.selectItem(at: min(2, max(0, (timer["aux_timer_index"] as? Int ?? 1) - 1)))
        inactivePolicy.selectItem(at: timer["inactive_policy"] as? String == "keep_last" ? 1 : 0)
        secondaryTemplate.stringValue = timer["secondary_message_template"] as? String ?? "{current_file} · {playlist_remaining_hhmmss}"
        selectSecondary.state = timer["change_stage_timer_secondary_source"] as? Bool == true ? .on : .off
        optionsChanged()
    }

    private func fillSources(selectedUUID: String? = nil) {
        let previous = selectedUUID ?? (sourcePicker.indexOfSelectedItem >= 0 && sourcePicker.indexOfSelectedItem < choices.count ? choices[sourcePicker.indexOfSelectedItem].uuid : "")
        sourcePicker.removeAllItems()
        if choices.isEmpty { sourcePicker.addItem(withTitle: "No MPS sources loaded") }
        else {
            sourcePicker.addItems(withTitles: choices.map(\.name))
            if let index = choices.firstIndex(where: { $0.uuid == previous }) { sourcePicker.selectItem(at: index) }
        }
        sourcePicker.isEnabled = !choices.isEmpty
    }

    @objc private func refreshSources() {
        sourceTask?.cancel()
        sourceRefresh.isEnabled = false
        sourcePicker.isEnabled = false
        sourceTask = Task { [weak self] in
            guard let self else { return }
            defer { sourceRefresh.isEnabled = true; sourcePicker.isEnabled = !choices.isEmpty }
            let old = sourcePicker.indexOfSelectedItem >= 0 && sourcePicker.indexOfSelectedItem < choices.count ? choices[sourcePicker.indexOfSelectedItem] : nil
            do {
                var loaded = try await loadSources()
                guard !Task.isCancelled else { return }
                var selected = old?.uuid
                if let old {
                    if old.uuid.isEmpty, let match = loaded.first(where: { $0.name == old.name }) { selected = match.uuid }
                    else if !loaded.contains(where: { $0.uuid == old.uuid }) { loaded.insert(old, at: 0) }
                }
                choices = loaded
                fillSources(selectedUUID: selected)
                if loaded.isEmpty { sourceStatus.stringValue = "No Media Playlist Source inputs found in OBS." }
            } catch {
                guard !Task.isCancelled else { return }
                sourceStatus.stringValue = "Could not load sources from OBS: \(error.localizedDescription)"
            }
        }
    }

    func updateMediaStatus(_ state: [String: Any], output: String) {
        mediaState = state
        if state["available"] as? Bool == true {
            sourceStatus.stringValue = "Currently following: \(state["source_name"] as? String ?? "MPS") · \(state["current_file"] as? String ?? "No current file")"
        } else { sourceStatus.stringValue = "Source: \(state["reason"] as? String ?? "waiting for OBS")" }
        outputStatus.stringValue = output
        outputStatus.textColor = output.lowercased().contains("error") ? .systemRed : .secondaryLabelColor
        refreshPreview()
    }

    @objc private func optionsChanged() {
        mediaBody.isHidden = mediaEnabled.state != .on
        explicitBody.isHidden = sourceMode.indexOfSelectedItem != 1
        txtBody.isHidden = txtEnabled.state != .on
        timerBody.isHidden = timerEnabled.state != .on
        auxBody.isHidden = timerOutput.indexOfSelectedItem == 1
        messageBody.isHidden = timerOutput.indexOfSelectedItem != 1
        timerSourceRow?.isHidden = timerOutput.indexOfSelectedItem == 1
        refreshPreview()
    }

    func controlTextDidChange(_ obj: Notification) { refreshPreview() }

    private func refreshPreview() {
        messagePreview.stringValue = MediaMessageTemplate.preview(secondaryTemplate.stringValue, state: mediaState)
    }

    @objc private func insertMessageVariable() {
        let index = insertVariable.indexOfSelectedItem - 1
        guard MediaMessageTemplate.variables.indices.contains(index) else { return }
        let token = "{\(MediaMessageTemplate.variables[index].key)}"
        if let editor = secondaryTemplate.currentEditor() as? NSTextView {
            editor.insertText(token, replacementRange: editor.selectedRange())
        } else { secondaryTemplate.stringValue += token }
        insertVariable.selectItem(at: 0)
        refreshPreview()
    }

    @objc private func chooseFile() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.title = "Choose filename export"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let current = URL(fileURLWithPath: txtPath.stringValue.isEmpty ? "current-media.txt" : txtPath.stringValue)
        panel.nameFieldStringValue = current.lastPathComponent
        if !txtPath.stringValue.isEmpty { panel.directoryURL = current.deletingLastPathComponent() }
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK, let url = panel.url { self?.txtPath.stringValue = url.path }
        }
    }

    @objc private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for current-media.txt"
        panel.prompt = "Use folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK, let url = panel.url { self?.txtPath.stringValue = url.appendingPathComponent("current-media.txt").path }
        }
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
        var media = draft.mediaBridge
        media["enabled"] = mediaEnabled.state == .on
        media["source_mode"] = sourceMode.indexOfSelectedItem == 1 ? "explicit" : "follow_program"
        if choices.indices.contains(sourcePicker.indexOfSelectedItem) {
            let selected = choices[sourcePicker.indexOfSelectedItem]
            media["source_uuid"] = selected.uuid
            media["source_name"] = selected.name
        }
        var txt = media["txt"] as? [String: Any] ?? [:]
        txt["enabled"] = txtEnabled.state == .on
        txt["path"] = txtPath.stringValue
        txt["clear_policy"] = txtPolicy.indexOfSelectedItem == 1 ? "keep_last" : "clear_when_inactive"
        media["txt"] = txt
        var timer = media["timer"] as? [String: Any] ?? [:]
        timer["media_timer_source"] = timerEnabled.state == .on ? (timerSource.indexOfSelectedItem == 1 ? "current_item" : "playlist") : "off"
        timer["ontime_output"] = timerOutput.indexOfSelectedItem == 1 ? "secondary_message" : "auxiliary_timer"
        timer["aux_timer_index"] = auxIndex.indexOfSelectedItem + 1
        timer["inactive_policy"] = inactivePolicy.indexOfSelectedItem == 1 ? "keep_last" : "stop"
        timer["secondary_message_template"] = secondaryTemplate.stringValue
        timer["change_stage_timer_secondary_source"] = selectSecondary.state == .on
        media["timer"] = timer
        media.removeValue(forKey: "http")
        draft.mediaBridge = media
        return draft
    }

    private func clearErrors() {
        for label in errorLabels.values { label.stringValue = ""; label.isHidden = true }
        generalErrorLabel.stringValue = ""
        generalErrorLabel.isHidden = true
    }

    @objc private func save() {
        clearErrors()
        do { try onSave(makeDraft()); window?.close() }
        catch let error as SettingsDraftError {
            if let label = errorLabels[error.field] { label.stringValue = error.message; label.isHidden = false }
            else { generalErrorLabel.stringValue = error.message; generalErrorLabel.isHidden = false }
        } catch { generalErrorLabel.stringValue = error.localizedDescription; generalErrorLabel.isHidden = false }
    }
    @objc private func cancel() { window?.close() }
    @objc private func openConfig() { onOpenConfig() }
}
