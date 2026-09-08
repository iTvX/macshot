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
    check(HotkeyManager.readHotkey(for: .captureArea) == originalPrimary, "reset primary restores original default")
    click("resetShortcut:", 1001)
    check(field(1001).stringValue == "None", "reset alternative returns to empty")

    click("recordShortcut:", 1001)
    selectTab("capture")
    check(!manager.isRecordingShortcut && !manager.registeredBindings.isEmpty, "switching tabs cancels recorder")
    selectTab("shortcuts")
    click("recordShortcut:", 1001)
    controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
    check(!manager.isRecordingShortcut, "loss of focus cancels recorder")

    // Switching between the two types must not orphan their shared event monitor.
    click("recordShortcut:", 1001)
    click("recordToolShortcut:", 0)
    check(!manager.isRecordingShortcut, "tool recorder restores globals")
    press(kVK_ANSI_J, characters: "j")
    check(ToolShortcutManager.key(for: .pencil) == "j", "single tool shortcut still records")
    click("recordToolShortcut:", 0)
    click("recordShortcut:", 1001)
    press(kVK_F18, characters: "\u{F715}")
    check(HotkeyManager.readHotkey(for: .captureArea, kind: .alternative) == (UInt32(kVK_F18), 0), "global recorder works after tool recorder")
    check(ToolShortcutManager.key(for: .pencil) == "j", "switching recorders preserves tool binding")
    click("recordShortcut:", 1001)
    window.close()
    check(!manager.isRecordingShortcut && !manager.registeredBindings.isEmpty, "closing settings resumes hotkeys")
    check(fired == 0, "no action triggered by any recorder test")
    print("Shortcut AppKit UI tests passed (\(assertions) assertions).")
}

try MainActor.assumeIsolated { try runTests() }
