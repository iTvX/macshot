import Cocoa

/// The red frame around an active scroll capture: four thin click-through
/// strips laid entirely outside the captured rectangle. Nothing of macshot
/// covers the content being captured, so the app underneath gets its hover,
/// cursor and scroll events exactly as if macshot weren't there — and the
/// frame can never end up in a frame.
final class ScrollCaptureFrameWindows {

    static let thickness: CGFloat = 2

    private var panels: [NSPanel] = []

    /// Top, bottom, left and right strips around `rect` (screen coordinates).
    static func stripFrames(around rect: NSRect, thickness: CGFloat = thickness) -> [NSRect] {
        let outer = rect.insetBy(dx: -thickness, dy: -thickness)
        return [
            NSRect(x: outer.minX, y: rect.maxY, width: outer.width, height: thickness),
            NSRect(x: outer.minX, y: outer.minY, width: outer.width, height: thickness),
            NSRect(x: outer.minX, y: rect.minY, width: thickness, height: rect.height),
            NSRect(x: rect.maxX, y: rect.minY, width: thickness, height: rect.height),
        ]
    }

    var windowIDs: [CGWindowID] {
        panels.compactMap { $0.windowNumber > 0 ? CGWindowID($0.windowNumber) : nil }
    }

    func show(around rect: NSRect) {
        hide()
        for frame in Self.stripFrames(around: rect) {
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = true
            panel.backgroundColor = .systemRed
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            // The overlay's level: above ordinary windows, below the HUD.
            panel.level = NSWindow.Level(257)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.setFrame(frame, display: false)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    func hide() {
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
    }
}
