import Cocoa
import Carbon

// Localization is orthogonal to these storage / Carbon integration tests.
func L(_ key: String) -> String { key }

let app = NSApplication.shared
let defaults = UserDefaults.standard
let domain = ProcessInfo.processInfo.processName
precondition(domain == "MacShotShortcutTests")
defaults.removePersistentDomain(forName: domain)
defer { defaults.removePersistentDomain(forName: domain) }

typealias Manager = HotkeyManager
typealias Binding = Manager.Binding
let manager = Manager.shared
defer { manager.unregisterAll() }
var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}
func read(_ binding: Binding) -> (UInt32, UInt32) {
    Manager.readHotkey(for: binding.slot, kind: binding.kind)
}

// Factory settings are first-install state, not a migration that overwrites users.
check(FactorySettings.installIfNeeded(defaults: defaults, domainName: domain), "fresh install receives factory profile")
check(read(.init(slot: .captureArea)) == (UInt32(kVK_ANSI_5), UInt32(cmdKey | shiftKey)), "factory area shortcut")
check(read(.init(slot: .captureOCR)) == (UInt32(kVK_ANSI_3), UInt32(cmdKey | shiftKey)), "factory OCR shortcut")
check(read(.init(slot: .quickCapture)) == (UInt32(kVK_ANSI_S), UInt32(optionKey)), "factory quick capture primary")
check(read(.init(slot: .quickCapture, kind: .alternative)) == (UInt32(kVK_ANSI_4), UInt32(cmdKey | shiftKey)), "factory quick capture alternative")
check(read(.init(slot: .captureFullScreen)) == (0, 0) && read(.init(slot: .recordArea)) == (0, 0), "factory disabled bindings stay disabled")
var factoryChords = Set<String>()
for binding in Binding.all {
    let chord = read(binding)
    check(chord == FactorySettings.hotkey(for: binding), "seeded binding agrees with reset target")
    if chord != (0, 0) {
        check(factoryChords.insert("\(chord.0):\(chord.1)").inserted, "no duplicate factory shortcuts")
    }
}
check(CaptureExclusionStore.applications.map(\.bundleIdentifier) == ["com.itvx.lotus"], "factory Lotus exclusion")
check(!defaults.bool(forKey: "playCopySound") && defaults.integer(forKey: "ocrAction") == 2, "factory capture behavior")
check(defaults.bool(forKey: "launchAtLogin") && defaults.bool(forKey: "disableSelectionOutsideShadow"), "factory application and selection preferences")
check(FactorySettings.preferences.keys.allSatisfy(SettingsPortability.isPortable), "factory profile contains only portable preferences")
check(!SettingsPortability.isPortable(FactorySettings.installationKey), "installation marker is never exported or imported")
check(!SettingsPortability.isPortable(FactorySettings.pendingLoginItemKey), "login registration marker stays local")
check(defaults.bool(forKey: FactorySettings.pendingLoginItemKey), "first launch schedules login registration")
check(defaults.bool(forKey: "SUEnableAutomaticChecks"), "factory automatic update preference is applied")
defaults.set(true, forKey: "playCopySound")
defaults.removeObject(forKey: "captureExcludedApplications")
let customizedFactoryDomain = defaults.persistentDomain(forName: domain)! as NSDictionary
check(!FactorySettings.installIfNeeded(defaults: defaults, domainName: domain), "factory profile is installed once")
check(customizedFactoryDomain.isEqual(to: defaults.persistentDomain(forName: domain)!), "relaunch preserves changes and removed keys")

for oldDomain: [String: Any] in [
    ["NSViewUsesAutomaticLayerBackingStores": false],
    ["SUHasLaunchedBefore": true],
    ["hotkeyKeyCode": 40, "hotkeyModifiers": 768, "playCopySound": true],
    ["saveDirectory": "/tmp/screenshots"],
] {
    defaults.setPersistentDomain(oldDomain, forName: domain)
    check(!FactorySettings.installIfNeeded(defaults: defaults, domainName: domain), "existing installation is not seeded")
    var after = defaults.persistentDomain(forName: domain)!
    after.removeValue(forKey: FactorySettings.installationKey)
    check((oldDomain as NSDictionary).isEqual(to: after), "upgrade preserves sparse settings and implicit legacy defaults")
}
// Framework-only preferences should not hide a genuinely fresh installation.
defaults.setPersistentDomain(["NSNavPanelExpandedSizeForOpenMode": "{800, 500}"], forName: domain)
check(FactorySettings.installIfNeeded(defaults: defaults, domainName: domain), "unrelated OS state does not block first-run defaults")
check(defaults.string(forKey: "NSNavPanelExpandedSizeForOpenMode") == "{800, 500}", "first-run seed preserves OS state")
defaults.removePersistentDomain(forName: domain)
func save(_ binding: Binding, _ key: UInt32, _ mods: UInt32) {
    Manager.saveHotkey(for: binding.slot, kind: binding.kind, keyCode: key, modifiers: mods)
}
func disable(_ binding: Binding) {
    Manager.disableHotkey(for: binding.slot, kind: binding.kind)
}
func clearPreferences() {
    manager.unregisterAll()
    defaults.removePersistentDomain(forName: domain)
}

// Existing defaults, customizations and explicit disabling survive with no migration.
check(Binding.all.count == 24, "all 12 actions have exactly two bindings")
check(Set(Binding.all.map(\.id)).count == 24, "Carbon IDs are unique")
for binding in Binding.all {
    check(Binding(id: binding.id) == binding, "Carbon ID round trip")
    check(SettingsPortability.isPortable(binding.keyCodeKey), "key code exports")
    check(SettingsPortability.isPortable(binding.modifiersKey), "modifiers export")
    check(SettingsPortability.isPortable(binding.disabledKey), "disabled state exports")
    if binding.kind == .primary {
        check(binding.keyCodeKey == binding.slot.keyCodeKey, "legacy keys unchanged")
        check(read(binding) == (binding.slot.defaultKeyCode, binding.slot.defaultModifiers), "legacy defaults")
    } else {
        check(read(binding) == (0, 0), "alternatives opt in")
    }
}
for id in [-1, 0, 13, 999, 1000, 1013, 2001] {
    check(Binding(id: id) == nil, "unknown IDs rejected")
}
let primary = Binding(slot: .captureArea)
let alternative = Binding(slot: .captureArea, kind: .alternative)
let allMods = UInt32(cmdKey | controlKey | optionKey | shiftKey)
save(primary, UInt32(kVK_ANSI_A), UInt32(controlKey)) // A has virtual key code zero.
save(alternative, UInt32(kVK_F19), 0)
check(read(primary) == (0, UInt32(controlKey)), "key code zero remains a valid A binding")
check(read(alternative) == (UInt32(kVK_F19), 0), "unmodified function keys persist")
disable(primary)
check(read(primary) == (0, 0), "primary clears")
check(read(alternative) == (UInt32(kVK_F19), 0), "alternative works independently")
save(primary, UInt32(kVK_ANSI_X), UInt32(cmdKey | shiftKey))
disable(alternative)
check(read(primary) == (UInt32(kVK_ANSI_X), UInt32(cmdKey | shiftKey)), "clearing alternative preserves primary")
save(alternative, UInt32(kVK_F19), 0)
check(!defaults.bool(forKey: alternative.disabledKey), "saving re-enables only selected binding")
check(Manager.conflictingBinding(for: alternative, keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey | shiftKey)) == primary, "same-action duplicates detected")
check(Manager.conflictingBinding(for: Binding(slot: .recordArea), keyCode: UInt32(kVK_F19), modifiers: 0) == alternative, "other action alternative collision detected")

// Menu presentation, including special keys and stale equivalent removal.
let menu = NSMenuItem(title: "Capture", action: nil, keyEquivalent: "")
Manager.applyMenuShortcut(for: .captureArea, to: menu)
check(menu.keyEquivalent == "x", "menu still prefers primary")
check(!menu.allowsAutomaticKeyEquivalentLocalization, "physical global shortcut is not remapped twice")
check(menu.toolTip?.contains("F19") == true, "menu exposes alternative in tooltip")
disable(primary)
Manager.applyMenuShortcut(for: .captureArea, to: menu)
check(menu.keyEquivalent == "\u{F716}", "menu falls back to alternative function key")
check(menu.keyEquivalentModifierMask.isEmpty, "no default command modifier added to F key")
disable(alternative)
Manager.applyMenuShortcut(for: .captureArea, to: menu)
check(menu.keyEquivalent.isEmpty && menu.toolTip == nil, "cleared menu has no stale shortcut")

// The new keys round-trip with existing tool shortcuts and capture exclusions.
defaults.set(["arrow": "j", "copy": "c"], forKey: "overlayToolShortcuts")
CaptureExclusionStore.add(CaptureExcludedApplication(bundleIdentifier: "org.example.Excluded", displayName: "Excluded"))
let excluded = CaptureExclusionStore.applications
let tools = defaults.dictionary(forKey: "overlayToolShortcuts")! as NSDictionary
save(alternative, UInt32(kVK_F18), allMods)
let exported = try SettingsPortability.exportData()
let savedDomain = defaults.persistentDomain(forName: domain)! as NSDictionary
clearPreferences()
try SettingsPortability.importData(exported.data)
check(savedDomain.isEqual(to: defaults.persistentDomain(forName: domain)!), "settings export/import round trip including disabled primary")
check(read(primary) == (0, 0) && read(alternative) == (UInt32(kVK_F18), allMods), "both states survive import")
check(CaptureExclusionStore.applications == excluded, "capture exclusions unchanged")
check(tools.isEqual(to: defaults.dictionary(forKey: "overlayToolShortcuts")!), "overlay/editor single bindings unchanged")
let legacyJSON = try JSONSerialization.data(withJSONObject: [
    "type": SettingsPortability.fileType, "schemaVersion": 1,
    "settings": [primary.keyCodeKey: kVK_ANSI_A, primary.modifiersKey: controlKey],
])
try SettingsPortability.importData(legacyJSON)
check(read(primary) == (UInt32(kVK_ANSI_A), UInt32(controlKey)), "old backup primary preserved")
check(read(alternative) == (0, 0), "old backup clears alternatives with replace semantics")
for (key, value) in [(alternative.keyCodeKey, -1), (alternative.keyCodeKey, 65536),
                     (alternative.modifiersKey, -1), (alternative.modifiersKey, Int(UInt32.max))] {
    save(alternative, UInt32(kVK_F19), allMods)
    defaults.set(value, forKey: key)
    check(read(alternative) == (0, 0), "invalid imported integer safely disabled")
}

// Exercise real Carbon registration and its installed event handler for all 24 IDs.
clearPreferences()

// Semantic editor commands stay distinct from physical global bindings.
func keyEvent(_ character: String, modifiers: NSEvent.ModifierFlags, keyCode: Int = kVK_ANSI_Z) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: 0, windowNumber: 0, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: UInt16(keyCode))!
}
check(KeyboardShortcutMatcher.matches(keyEvent("y", modifiers: [.command]), character: "y", modifiers: .command), "semantic character wins over physical Z key")
check(KeyboardShortcutMatcher.matches(keyEvent("Z", modifiers: [.command, .capsLock]), character: "z", modifiers: .command), "caps lock does not break command matching")
check(!KeyboardShortcutMatcher.matches(keyEvent("z", modifiers: [.command, .shift]), character: "z", modifiers: .command), "shift distinguishes redo from undo")
check(EditorCommandShortcutManager.action(for: keyEvent("z", modifiers: .command)) == .undo, "default undo")
check(EditorCommandShortcutManager.action(for: keyEvent("z", modifiers: [.command, .shift])) == .redo, "default redo")
EditorCommandShortcutManager.setShortcut(.init(character: "y", modifiers: .command), for: .undo)
check(EditorCommandShortcutManager.action(for: keyEvent("y", modifiers: .command)) == .undo, "assignment removes other command's conflicting default")
EditorCommandShortcutManager.reset(.redo)
check(EditorCommandShortcutManager.action(for: keyEvent("y", modifiers: .command)) == .redo, "reset also resolves cross-command collisions")
check(EditorCommandShortcutManager.shortcuts(for: .undo).isEmpty, "reset cannot leave a duplicate undo binding")
let invalid = EditorCommandShortcutManager.Shortcut(character: "zz", modifiers: .command)
EditorCommandShortcutManager.setShortcut(invalid, for: .redo)
check(EditorCommandShortcutManager.shortcuts(for: .redo).count == 2, "invalid assignment leaves valid bindings intact")
defaults.set(try JSONEncoder().encode([invalid]), forKey: "editorCommandShortcuts.redo")
check(EditorCommandShortcutManager.shortcuts(for: .redo).isEmpty, "malformed imported characters never become menu equivalents")
EditorCommandShortcutManager.disable(.undo)
check(EditorCommandShortcutManager.action(for: keyEvent("z", modifiers: .command)) == nil, "command can be disabled independently")
clearPreferences()

let keys: [UInt32] = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D,
                     kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
                     kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
                     kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P,
                     kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
                     kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_Y].map(UInt32.init)
for (binding, key) in zip(Binding.all, keys) { save(binding, key, allMods) }
var fired: [Manager.HotkeySlot: Int] = [:]
for slot in Manager.HotkeySlot.allCases {
    manager.register(slot: slot) { fired[slot, default: 0] += 1 }
}
check(manager.registeredBindings == Set(Binding.all), "24 native hotkeys registered concurrently")
check(manager.registrationErrors.isEmpty, "no native registration errors")
func sendCarbon(_ id: Int, signature: OSType = 0x4D53_4854) -> OSStatus {
    var event: EventRef?
    check(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                      GetCurrentEventTime(), 0, &event) == noErr, "create Carbon test event")
    guard let event = event else { fatalError("missing event") }
    defer { ReleaseEvent(event) }
    var hotkeyID = EventHotKeyID(signature: signature, id: UInt32(id))
    check(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                            MemoryLayout<EventHotKeyID>.size, &hotkeyID) == noErr, "set Carbon ID")
    return SendEventToEventTarget(event, GetEventDispatcherTarget())
}
for binding in Binding.all {
    check(sendCarbon(binding.id) == noErr, "registered Carbon event handled")
}
for slot in Manager.HotkeySlot.allCases {
    check(fired[slot] == 2, "primary and alternative each invoke exactly the same callback once")
}
let firedBeforeInvalid = fired
_ = sendCarbon(primary.id, signature: 0xDEAD_BEEF)
_ = sendCarbon(999)
check(fired == firedBeforeInvalid, "foreign / unknown Carbon events ignored")

manager.beginShortcutRecording()
check(manager.registeredBindings.isEmpty, "recording suspends both sets")
check(manager.validateShortcut(for: primary, keyCode: keys[0], modifiers: allMods) == nil, "can re-record existing shortcut")
check(manager.validateShortcut(for: alternative, keyCode: keys[0], modifiers: allMods) != nil, "recorder rejects duplicate without triggering action")
var occupied: EventHotKeyRef?
let occupiedID = EventHotKeyID(signature: 0x5445_5354, id: 1)
check(RegisterEventHotKey(UInt32(kVK_F20), allMods, occupiedID,
                          GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &occupied) == noErr, "reserve unavailable test shortcut")
check(manager.validateShortcut(for: alternative, keyCode: UInt32(kVK_F20), modifiers: allMods) != nil, "native registration failure reported")
if let occupied = occupied { UnregisterEventHotKey(occupied) }
check(read(alternative) == (keys[12], allMods), "failed validation preserves previous binding")
manager.endShortcutRecording()
check(manager.registeredBindings.count == 24, "cancel / completion resumes both sets")
manager.beginShortcutRecording()
manager.register(slot: .captureArea) { fired[.captureArea, default: 0] += 1 }
check(manager.registeredBindings.isEmpty, "refresh cannot re-enable shortcuts during recording")
manager.endShortcutRecording()
disable(primary)
manager.register(slot: .captureArea) { fired[.captureArea, default: 0] += 1 }
check(!manager.registeredBindings.contains(primary) && manager.registeredBindings.contains(alternative), "disable unregisters only selected binding")
let beforeDisabled = fired
_ = sendCarbon(primary.id)
check(fired == beforeDisabled, "stale event for disabled primary ignored")
_ = sendCarbon(alternative.id)
check(fired[.captureArea] == (beforeDisabled[.captureArea] ?? 0) + 1, "remaining alternative still triggers")

// Imported duplicates have deterministic priority and cannot activate two actions.
save(primary, keys[0], allMods)
save(Binding(slot: .captureFullScreen, kind: .alternative), keys[0], allMods)
manager.register(slot: .captureArea) { fired[.captureArea, default: 0] += 1 }
check(manager.registeredBindings.contains(primary), "primary wins imported alternative collision")
check(manager.registrationErrors[Binding(slot: .captureFullScreen, kind: .alternative)] != nil, "import conflict tracked")
manager.unregisterAll()
check(manager.registeredBindings.isEmpty, "all native handles released")
print("Shortcut regression tests passed (\(assertions) assertions; 24 native Carbon bindings).")
