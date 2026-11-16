import AppKit

@main
struct SettingsWindowLayoutTests {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root: [String: Any] = ["config_version": AppConfig.currentConfigVersion,
            "ontime": ["base_url": "http://127.0.0.1:4001"],
            "media_bridge": ["enabled": true, "source_mode": "follow_program",
                "timer": ["media_timer_source": "playlist", "ontime_output": "auxiliary_timer"]]]
        let configURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try JSONSerialization.data(withJSONObject: root).write(to: configURL)
        defer { try? FileManager.default.removeItem(at: configURL) }
        let config = try AppConfig.load(from: configURL)
        let draft = SettingsDraft(config: config, password: "")
        var saved: SettingsDraft?
        let controller = SettingsWindowController(draft: draft, onSave: { value in
            _ = try value.applying(to: config)
            saved = value
        }, onOpenConfig: {})
        guard let window = controller.window, let view = window.contentView else { fatalError("Missing settings window") }
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        var seen = Set<ObjectIdentifier>()
        func descendants(_ view: NSView) -> [NSView] {
            guard seen.insert(ObjectIdentifier(view)).inserted else { return [] }
            let children = view.subviews + ((view as? NSStackView)?.detachedViews ?? [])
            return [view] + children.flatMap { descendants($0) }
        }
        func allViews() -> [NSView] { seen.removeAll(); return descendants(view) }
        func button(_ title: String) -> NSButton {
            guard let result = allViews().compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { fatalError("Missing button: \(title)") }
            return result
        }
        func label(_ text: String) -> NSTextField {
            guard let result = allViews().compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == text }) else { fatalError("Missing label: \(text)") }
            return result
        }
        func visible(_ target: NSView) -> Bool {
            var item: NSView? = target
            while let current = item {
                if current.isHidden { return false }
                item = current.superview
            }
            return true
        }
        func rows() -> [AuxiliaryTimerRow] { allViews().compactMap { $0 as? AuxiliaryTimerRow } }
        precondition(rows().count == 1, "Legacy auxiliary output must become one editable row")
        precondition(rows()[0].slot.indexOfSelectedItem == 0 && rows()[0].source.indexOfSelectedItem == 1)
        let txtPath = label("Text file")
        precondition(!visible(txtPath), "TXT fields should collapse while export is disabled")
        button("Export current filename to a text file").performClick(nil)
        precondition(visible(txtPath))
        precondition(visible(button("Choose file…")) && visible(button("Choose folder…")))
        // Supply a path so save exercises real validation, not an unrelated TXT error.
        let pathField = allViews().compactMap { $0 as? NSTextField }.first { $0.placeholderString == "/Users/you/Show/current-media.txt" }!
        pathField.stringValue = "/tmp/current-media.txt"
        button("Add timer").performClick(nil)
        precondition(rows().count == 2 && rows()[1].slot.indexOfSelectedItem == 1)
        rows()[0].source.selectItem(at: 0)
        rows()[1].source.selectItem(at: 1)
        rows()[1].policy.selectItem(at: 1)
        rows()[1].slot.selectItem(at: 0)
        button("Save & Reconnect").performClick(nil)
        precondition(saved == nil, "Duplicate active slots must not save")
        rows()[1].slot.selectItem(at: 1)
        button("Add timer").performClick(nil)
        precondition(rows().count == 3 && !button("Add timer").isEnabled)
        rows()[2].onRemove?()
        precondition(rows().count == 2 && button("Add timer").isEnabled)
        let stage = allViews().compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("Do not change automatically") }!
        stage.selectItem(at: 2)
        func snapshot(_ name: String) throws {
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let tabs = allViews().compactMap { $0 as? NSTabView }.first!
            let scroll = tabs.selectedTabViewItem!.view as! NSScrollView
            let document = scroll.documentView!
            document.layoutSubtreeIfNeeded()
            let image = NSImage(size: document.bounds.size)
            image.lockFocus()
            NSColor.windowBackgroundColor.setFill()
            document.bounds.fill()
            document.displayIgnoringOpacity(document.bounds, in: NSGraphicsContext.current!)
            image.unlockFocus()
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            let folder = URL(fileURLWithPath: "/tmp/vos-ui-screenshots", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
        }
        try snapshot("vos-auxiliary-settings.png")
        button("Send a secondary message").performClick(nil)
        precondition(rows().allSatisfy { visible($0) }, "Secondary message must not hide auxiliary outputs")
        let variables = allViews().compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("Insert variable…") }!
        precondition(visible(variables))
        precondition(variables.numberOfItems == 4)
        controller.updateMediaStatus(["available": true, "source_name": "Test playlist", "current_file": "B_GREEN.mp4", "remaining_ms": 45000, "playlist_remaining_ms": 75000], output: "Multiple outputs", outputs: ["auxiliary_timers": [
            ["aux_timer_index": 1, "output_status": "synced"], ["aux_timer_index": 2, "output_status": "unknown_remaining"]]])
        precondition(rows()[0].status.stringValue.contains("synced"))
        precondition(rows()[1].status.stringValue.contains("unknown remaining"))
        variables.scrollToVisible(variables.bounds)
        try snapshot("vos-message-settings.png")
        button("Send a secondary message").performClick(nil)
        precondition(!visible(variables))
        precondition(rows().allSatisfy { visible($0) })
        button("Save & Reconnect").performClick(nil)
        guard let result = saved else { fatalError("Valid multi-timer configuration must save") }
        let outputs = result.mediaBridge["auxiliary_timers"] as! [[String: Any]]
        precondition(outputs.count == 2)
        precondition(outputs[0]["media_timer_source"] as? String == "current_item")
        precondition(outputs[1]["media_timer_source"] as? String == "playlist")
        precondition(outputs[1]["inactive_policy"] as? String == "keep_last")
        precondition(result.mediaBridge["stage_timer_source"] as? String == "aux2")
        controller.close()
        print("SettingsWindowLayoutTests: PASS")
    }
}
