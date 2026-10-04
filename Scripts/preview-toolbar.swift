import Cocoa

// Private preview entry point. The launcher copies this over main.swift in a
// temporary app with its own bundle ID; production preferences/history are untouched.
@MainActor
final class ToolbarPreviewDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var overlay: ToolbarPreviewOverlay!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
        UserDefaults.standard.removeObject(forKey: "toolbarBgColor")
        UserDefaults.standard.removeObject(forKey: "toolbarIconColor")
        UserDefaults.standard.removeObject(forKey: "toolbarAccentColor")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "MacShot · Toolbar Preview"
        window.isReleasedWhenClosed = false
        overlay = ToolbarPreviewOverlay(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        overlay.autoresizingMask = [.width, .height]
        overlay.screenshotImage = Self.fixture()
        overlay.currentTool = .arrow
        overlay.applySelection(NSRect(x: 260, y: 210, width: 680, height: 400))
        window.contentView = overlay
        let control = NSSegmentedControl(labels: ["System", "Light", "Dark"], trackingMode: .selectOne, target: self, action: #selector(theme(_:)))
        control.selectedSegment = 0
        control.frame = NSRect(x: 18, y: 752, width: 210, height: 28)
        control.autoresizingMask = [.maxXMargin, .minYMargin]
        overlay.addSubview(control)
        let scenes = NSSegmentedControl(labels: ["Capture", "Small", "Edge", "Editor", "Record"], trackingMode: .selectOne, target: self, action: #selector(scene(_:)))
        scenes.selectedSegment = 0
        scenes.frame = NSRect(x: 242, y: 752, width: 370, height: 28)
        scenes.autoresizingMask = [.maxXMargin, .minYMargin]
        overlay.addSubview(scenes)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func theme(_ sender: NSSegmentedControl) {
        NSApp.appearance = sender.selectedSegment == 0 ? nil : NSAppearance(named: sender.selectedSegment == 1 ? .aqua : .darkAqua)
        NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
    }
    @objc func scene(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 3 {
            DetachedEditorWindowController.open(image: Self.fixture(), tool: .arrow, disableBeautify: true)
            return
        }
        overlay.isRecording = sender.selectedSegment == 4
        let rect: NSRect
        switch sender.selectedSegment {
        case 1: rect = NSRect(x: 540, y: 365, width: 120, height: 70)
        case 2: rect = NSRect(x: 0, y: 0, width: 250, height: 180)
        default: rect = NSRect(x: 260, y: 210, width: 680, height: 400)
        }
        overlay.applySelection(rect)
        overlay.rebuildToolbarLayout()
    }
    static func fixture() -> NSImage {
        NSImage(size: NSSize(width: 1200, height: 800), flipped: false) { _ in
            NSGradient(starting: NSColor(calibratedRed: 0.83, green: 0.88, blue: 0.94, alpha: 1), ending: NSColor(calibratedRed: 0.93, green: 0.9, blue: 0.86, alpha: 1))!.draw(in: NSRect(x: 0, y: 0, width: 1200, height: 800), angle: 35)
            let card = NSRect(x: 260, y: 210, width: 680, height: 400)
            NSColor.white.setFill(); NSBezierPath(roundedRect: card, xRadius: 18, yRadius: 18).fill()
            func text(_ string: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) {
                (string as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
            }
            let ink = NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.27, alpha: 1)
            text("PRODUCT NOTES", 300, 558, 11, .semibold, .systemBlue)
            text("Make every detail clear.", 300, 502, 29, .semibold, ink)
            text("Capture. Annotate. Share.", 300, 468, 15, .regular, .gray)
            for (i, title) in ["Choose your focus", "Add a clear annotation", "Copy it anywhere"].enumerated() {
                let y = CGFloat(402 - i * 61)
                NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 300, y: y - 7, width: 600, height: 45), xRadius: 9, yRadius: 9).fill()
                text("0\(i + 1)", 316, y + 7, 12, .semibold, .systemBlue)
                text(title, 358, y + 5, 14, .medium, ink)
            }
            return true
        }
    }
}
@MainActor
final class ToolbarPreviewOverlay: OverlayView {
    override var hasRecordingInputMonitoringPermission: Bool { true }
}
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { ToolbarPreviewDelegate() }
app.delegate = delegate
app.run()
