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
        let draft = SettingsDraft(config: try AppConfig.load(from: configURL), password: "")
        let controller = SettingsWindowController(draft: draft, onSave: { _ in }, onOpenConfig: {})
        guard let window = controller.window, let view = window.contentView else { fatalError("Missing settings window") }
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        var seen = Set<ObjectIdentifier>()
        func descendants(_ view: NSView) -> [NSView] {
            guard seen.insert(ObjectIdentifier(view)).inserted else { return [] }
            let children = view.subviews + ((view as? NSStackView)?.detachedViews ?? [])
            return [view] + children.flatMap { descendants($0) }
        }
        let views = descendants(view)
        func button(_ title: String) -> NSButton {
            guard let result = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { fatalError("Missing button: \(title)") }
            return result
        }
        func label(_ text: String) -> NSTextField {
            guard let result = views.compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == text }) else { fatalError("Missing label: \(text)") }
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
        let slot = label("Reserved slot")
        let txtPath = label("Text file")
        precondition(visible(slot), "Auxiliary slot must show for auxiliary output")
        precondition(!visible(txtPath), "TXT fields should collapse while export is disabled")
        button("Export current filename to a text file").performClick(nil)
        precondition(visible(txtPath))
        precondition(visible(button("Choose file…")) && visible(button("Choose folder…")))
        let output = views.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("Secondary text message") }!
        func snapshot(_ name: String) throws {
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let tabs = views.compactMap { $0 as? NSTabView }.first!
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
        output.selectItem(at: 1)
        NSApp.sendAction(output.action!, to: output.target, from: output)
        precondition(!visible(slot), "Auxiliary slot must hide for a text message")
        precondition(!visible(label("Time to send")), "Message chooses its variables, not a countdown scope")
        let variables = views.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("Insert variable…") }!
        precondition(visible(variables))
        precondition(variables.numberOfItems == 4)
        controller.updateMediaStatus(["available": true, "source_name": "Test playlist", "current_file": "B_GREEN.mp4", "remaining_ms": 45000, "playlist_remaining_ms": 75000], output: "Secondary message updated")
        variables.scrollToVisible(variables.bounds)
        try snapshot("vos-message-settings.png")
        button("Send media time to Ontime").performClick(nil)
        precondition(!visible(variables))
        controller.close()
        print("SettingsWindowLayoutTests: PASS")
    }
}
