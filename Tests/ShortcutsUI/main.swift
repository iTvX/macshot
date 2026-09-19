import Cocoa
import Carbon
@testable import macshot

@MainActor
func runTests() throws {
    let app = NSApplication.shared
    let defaults = UserDefaults.standard
    let domain = ProcessInfo.processInfo.processName
    precondition(domain == "MacShotShortcutUITests")
    defaults.removePersistentDomain(forName: domain)
    defer { defaults.removePersistentDomain(forName: domain) }
    var assertions = 0
    func check(_ condition: Bool, _ message: String) {
        assertions += 1
        if !condition {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
    func drainEvents() {
        let deadline = Date().addingTimeInterval(0.08)
        while let event = app.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            app.sendEvent(event)
        }
    }
    func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    let manager = HotkeyManager.shared
    defer { manager.unregisterAll() }
    var fired = 0
    for slot in HotkeyManager.HotkeySlot.allCases {
        manager.register(slot: slot) { fired += 1 }
    }
    let controller = SettingsWindowController()
    controller.onHotkeyChanged = {
        for slot in HotkeyManager.HotkeySlot.allCases {
            manager.register(slot: slot) { fired += 1 }
        }
    }
    controller.showWindow()
    let window = controller.window!
    func selectTab(_ id: String) {
        let item = window.toolbar!.items.first { $0.itemIdentifier.rawValue == id }!
        check(app.sendAction(item.action!, to: item.target, from: item), "select \(id) tab")
        window.contentView!.layoutSubtreeIfNeeded()
        drainEvents()
    }
    func button(_ selector: String, _ tag: Int) -> NSButton {
        descendants(window.contentView!).compactMap { $0 as? NSButton }.first {
            $0.action == NSSelectorFromString(selector) && $0.tag == tag
        }!
    }
    func click(_ selector: String, _ tag: Int) {
        button(selector, tag).performClick(nil)
        drainEvents()
    }
    func press(_ keyCode: Int, characters: String, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: UInt16(keyCode))!
        app.postEvent(event, atStart: false)
        drainEvents()
    }
    func field(_ id: Int) -> NSTextField {
        descendants(window.contentView!).compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue == "hotkey.\(id)"
        }!
    }
    selectTab("shortcuts")
    let fields = descendants(window.contentView!).compactMap { $0 as? NSTextField }.filter {
        $0.identifier?.rawValue.hasPrefix("hotkey.") == true
    }
    check(fields.count == 24, "all 12 primary and alternative controls exist")
    for view in fields {
        let rect = view.convert(view.bounds, to: window.contentView!)
        check(rect.minX >= 0 && rect.maxX <= window.contentView!.bounds.width,
              "shortcut field fits fixed settings width")
    }
    let toolButtons = descendants(window.contentView!).compactMap { $0 as? NSButton }.filter {
        $0.action == NSSelectorFromString("recordToolShortcut:")
    }
    check(toolButtons.count == ToolShortcutManager.Action.allCases.count, "tools retain exactly one recorder per action")

    if let path = ProcessInfo.processInfo.environment["MACSHOT_UI_TEST_SNAPSHOT"],
       let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }

    let originalPrimary = HotkeyManager.readHotkey(for: .captureArea)
    click("recordShortcut:", 1001)
    check(manager.isRecordingShortcut && manager.registeredBindings.isEmpty, "alternative recorder suspends all hotkeys")
    press(kVK_F19, characters: "\u{F716}", modifiers: [.command, .control, .option, .shift])
    check(!manager.isRecordingShortcut, "recording completes after key event")
    check(HotkeyManager.readHotkey(for: .captureArea, kind: .alternative) == (UInt32(kVK_F19), UInt32(cmdKey | controlKey | optionKey | shiftKey)), "actual event saves alternative")
    check(HotkeyManager.readHotkey(for: .captureArea) == originalPrimary, "UI leaves primary unchanged")
    check(field(1001).stringValue.contains("F19"), "field updates after recording")
    check(manager.registeredBindings.contains(.init(slot: .captureArea, kind: .alternative)), "new alternative registered immediately")

    click("recordShortcut:", 1001)
    press(kVK_Escape, characters: "\u{1B}")
    check(!manager.isRecordingShortcut && field(1001).stringValue.contains("F19"), "Escape cancels without mutation")
    click("recordShortcut:", 1001)
    click("recordShortcut:", 1001)
    check(!manager.isRecordingShortcut, "Cancel button restores hotkeys")

    // Entering an existing primary must show a conflict, never execute the action.
    click("recordShortcut:", 1001)
    press(kVK_ANSI_X, characters: "x", modifiers: [.command, .shift])
    check(fired == 0, "recording existing primary does not fire capture")
    check(window.attachedSheet != nil && !manager.isRecordingShortcut, "duplicate reports an alert and resumes hotkeys")
    check(field(1001).stringValue.contains("F19"), "duplicate preserves alternative")
    if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
    drainEvents()

    click("clearShortcut:", 1)
    check(field(1).stringValue == "None" && field(1001).stringValue.contains("F19"), "clear primary leaves alternative")
    click("resetShortcut:", 1)
    check(HotkeyManager.readHotkey(for: .captureArea) == (UInt32(kVK_ANSI_5), UInt32(cmdKey | shiftKey)), "reset primary restores fork factory default")
    click("resetShortcut:", 1001)
    check(field(1001).stringValue == "None", "reset alternative returns to empty")

    click("recordShortcut:", 1001)
    selectTab("capture")
    check(!manager.isRecordingShortcut && !manager.registeredBindings.isEmpty, "switching tabs cancels recorder")
    let finderCheckbox = descendants(window.contentView!).compactMap { $0 as? NSButton }.first {
        $0.action == NSSelectorFromString("finderClipboardChanged:")
    }!
    check(finderCheckbox.state == .off, "Finder compatibility is opt in")
    finderCheckbox.performClick(nil)
    check(defaults.bool(forKey: ImageEncoder.finderClipboardCompatibilityKey), "Finder compatibility control saves preference")
    finderCheckbox.performClick(nil)
    if let path = ProcessInfo.processInfo.environment["MACSHOT_UI_TEST_SNAPSHOT"],
       let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path + ".capture.png"))
    }
    selectTab("shortcuts")
    click("recordShortcut:", 1001)
    controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
    check(!manager.isRecordingShortcut, "loss of focus cancels recorder")

    // Switching between the two types must not orphan their shared event monitor.
    click("recordShortcut:", 1001)
    click("recordToolShortcut:", 0)
    check(manager.isRecordingShortcut && manager.registeredBindings.isEmpty, "tool recorder keeps globals suspended")
    press(kVK_ANSI_J, characters: "j")
    check(ToolShortcutManager.key(for: .pencil) == "j", "single tool shortcut still records")
    click("recordToolShortcut:", 0)
    click("recordShortcut:", 1001)
    press(kVK_F18, characters: "\u{F715}")
    check(HotkeyManager.readHotkey(for: .captureArea, kind: .alternative) == (UInt32(kVK_F18), 0), "global recorder works after tool recorder")
    check(ToolShortcutManager.key(for: .pencil) == "j", "switching recorders preserves tool binding")

    click("recordCommandShortcut:", 0)
    check(manager.isRecordingShortcut && manager.registeredBindings.isEmpty, "command recorder suspends both global bindings")
    press(kVK_ANSI_Z, characters: "z", modifiers: [.command, .option])
    check(EditorCommandShortcutManager.shortcuts(for: .undo) == [.init(character: "z", modifiers: [.command, .option])], "command recorder saves semantic chord")
    check(!manager.isRecordingShortcut, "command completion restores globals")
    click("recordCommandShortcut:", 0)
    selectTab("capture")
    check(!manager.isRecordingShortcut, "tab switch cancels command recording")
    selectTab("shortcuts")
    click("recordCommandShortcut:", 0)
    click("recordShortcut:", 1001)
    press(kVK_Escape, characters: "\u{1B}")
    check(!manager.isRecordingShortcut, "global recorder can replace command recorder without leaking monitor")
    click("recordCommandShortcut:", 0)
    click("recordToolShortcut:", 0)
    press(kVK_ANSI_J, characters: "j")
    check(!manager.isRecordingShortcut && ToolShortcutManager.key(for: .pencil) == "j", "tool recorder can replace command recorder")
    click("recordCommandShortcut:", 0)
    controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
    check(!manager.isRecordingShortcut, "focus loss cancels command recorder")
    click("recordCommandShortcut:", 0)
    click("clearShortcut:", 1001)
    check(!manager.isRecordingShortcut, "clearing a global binding cancels command recorder")
    click("recordShortcut:", 1001)
    window.close()
    check(!manager.isRecordingShortcut && !manager.registeredBindings.isEmpty, "closing settings resumes hotkeys")
    check(fired == 0, "no action triggered by any recorder test")

    // Editor command changes must not regress the scoped NSTextView undo lifetime.
    let textWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                              styleMask: .titled, backing: .buffered, defer: false)
    let textView = ScopedUndoTextView(frame: textWindow.contentView!.bounds)
    textView.allowsUndo = true
    textWindow.contentView!.addSubview(textView)
    textWindow.makeFirstResponder(textView)
    textView.insertText("abc", replacementRange: NSRange(location: 0, length: 0))
    check(textView.undoManager?.canUndo == true, "text editing registers scoped undo")
    check(textWindow.undoManager?.canUndo != true, "text edit never enters the window's undo manager")
    textView.undoManager?.undo()
    check(textView.string.isEmpty, "text undo still works")
    textView.undoManager?.redo()
    check(textView.string == "abc", "text redo still works")
    textView.discardUndoHistory()
    textView.removeFromSuperview()
    check(textView.undoManager?.canUndo != true && textWindow.undoManager?.canUndo != true, "disposing text editor leaves no stale undo target")

    func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { drainEvents() }
        check(condition(), "asynchronous operation completes")
    }

    // Exercise the actual image encoder using a private pasteboard, never the user's clipboard.
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let sample = NSImage(size: NSSize(width: 16, height: 16))
    sample.lockFocus()
    NSColor.red.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 16, height: 16)).fill()
    sample.unlockFocus()
    defaults.removeObject(forKey: ImageEncoder.finderClipboardCompatibilityKey)
    ImageEncoder.copyToClipboard(sample, pasteboard: pasteboard)
    waitUntil { pasteboard.data(forType: .png) != nil }
    check(pasteboard.data(forType: .tiff) != nil, "default clipboard includes TIFF fallback")
    check(pasteboard.string(forType: .fileURL) == nil, "default image copy has no sandbox URL")
    let png = pasteboard.data(forType: .png)!
    check(NSImage(data: png) != nil, "copied PNG decodes")
    defaults.set(true, forKey: ImageEncoder.finderClipboardCompatibilityKey)
    pasteboard.clearContents()
    ImageEncoder.copyToClipboard(sample, pasteboard: pasteboard)
    waitUntil { pasteboard.string(forType: .fileURL) != nil }
    let fileURL = URL(string: pasteboard.string(forType: .fileURL)!)!
    defer { try? FileManager.default.removeItem(at: fileURL) }
    check(fileURL.path.contains("com.itvx.macshot/clipboard/"), "Finder mode uses the fork's retained clipboard directory")
    check(try Data(contentsOf: fileURL) == pasteboard.data(forType: .png), "Finder file and image bytes match")
    check(pasteboard.data(forType: .tiff) != nil, "Finder mode retains image paste fallback")

    for value in [Double.nan, Double.infinity, -1, 0, 100] {
        check(VideoExportPreferences.validatedScale(value) == 1, "invalid imported export scale resets safely")
    }
    for value in [0.25, 0.33, 0.5, 0.75, 1] {
        check(VideoExportPreferences.validatedScale(value) == CGFloat(value), "valid export scale preserved")
    }
    check(OverlayView.SnapMode.window.next == .off && OverlayView.SnapMode.off.next == .element
          && OverlayView.SnapMode.element.next == .window, "three snap modes cycle as documented")

    // Stop before the startup task gets its first turn: no capture/permission request
    // should begin later, and completion must fire exactly once.
    defaults.set(false, forKey: "recordMicAudio")
    if let screen = NSScreen.main {
        let engine = RecordingEngine()
        var completions = 0
        engine.onCompletion = { url, error in
            check(url == nil && error == nil, "cancelled startup has no phantom output")
            completions += 1
        }
        engine.startRecording(rect: NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 32, height: 32), screen: screen)
        engine.stopRecording()
        waitUntil { engine.state == .idle }
        drainEvents()
        check(completions == 1, "immediate stop completes once after startup cancellation")
    }
    // A separate settings controller must display the shipped profile correctly,
    // including a nonempty alternative and default-disabled primary bindings.
    window.close()
    manager.unregisterAll()
    defaults.removePersistentDomain(forName: domain)
    check(FactorySettings.installIfNeeded(defaults: defaults, domainName: domain), "seed fresh settings UI")
    let factoryController = SettingsWindowController()
    factoryController.showWindow()
    let factoryWindow = factoryController.window!
    let shortcutsItem = factoryWindow.toolbar!.items.first { $0.itemIdentifier.rawValue == "shortcuts" }!
    check(app.sendAction(shortcutsItem.action!, to: shortcutsItem.target, from: shortcutsItem), "open factory shortcuts UI")
    factoryWindow.contentView!.layoutSubtreeIfNeeded()
    let factoryViews = descendants(factoryWindow.contentView!)
    func factoryField(_ id: Int) -> NSTextField {
        factoryViews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "hotkey.\(id)" }!
    }
    check(factoryField(1).stringValue == "⇧⌘5", "fresh UI shows capture area default")
    check(factoryField(2).stringValue == "None" && factoryField(3).stringValue == "None", "fresh UI shows disabled defaults")
    check(factoryField(7).stringValue == "⌥S" && factoryField(1007).stringValue == "⇧⌘4", "fresh UI shows both quick capture defaults")
    for id in [2, 1007] {
        let binding = HotkeyManager.Binding(id: id)!
        HotkeyManager.saveHotkey(for: binding.slot, kind: binding.kind, keyCode: UInt32(kVK_F19), modifiers: 0)
        let reset = factoryViews.compactMap { $0 as? NSButton }.first {
            $0.action == NSSelectorFromString("resetShortcut:") && $0.tag == id
        }!
        reset.performClick(nil)
        drainEvents()
        check(factoryWindow.attachedSheet == nil, "factory reset succeeds without conflict")
        check(HotkeyManager.readHotkey(for: binding.slot, kind: binding.kind) == FactorySettings.hotkey(for: binding), "reset restores disabled/nonempty alternative defaults")
    }
    factoryWindow.close()
    print("Shortcut AppKit UI tests passed (\(assertions) assertions).")
}

try MainActor.assumeIsolated { try runTests() }
