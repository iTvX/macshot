import Cocoa
import ApplicationServices

/// The window a scroll capture reads from, and the focus hand-over that lets it
/// take scroll input the way it would after the user clicked into it.
nonisolated struct ScrollCaptureTarget: Sendable {
    let windowID: CGWindowID
    let processID: pid_t
    /// Global display coordinates, top-left origin.
    let bounds: CGRect

    /// The frontmost ordinary window under `point` (global, top-left origin),
    /// skipping `excluded` windows and invisible or tiny ones.
    static func window(at point: CGPoint, excluding excluded: Set<CGWindowID>) -> ScrollCaptureTarget? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  !excluded.contains(CGWindowID(number)) else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            guard bounds.width >= 20, bounds.height >= 20, bounds.contains(point) else { continue }
            return ScrollCaptureTarget(windowID: CGWindowID(number), processID: pid, bounds: bounds)
        }
        return nil
    }

    /// Whether this is its app's focused window. Blocks on the target app via
    /// Accessibility, so call it off the main thread.
    func isFocusedWindow() -> Bool {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        return Self.frame(of: value as! AXUIElement).map { Self.sameFrame($0, bounds) } ?? false
    }

    /// Raises the window within its app and makes it the main window, so that
    /// activating the app focuses it — rather than another of the app's windows,
    /// possibly on another Space. Blocks on the target app via Accessibility,
    /// so call it off the main thread.
    func raiseWindow() {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        let matches = windows.filter { Self.frame(of: $0).map { Self.sameFrame($0, bounds) } ?? false }
        // Tabbed windows can share one frame; raising the wrong one would
        // change what's on screen, so only an unambiguous match is raised.
        guard matches.count == 1, let window = matches.first else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    private static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
            && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}

/// Synthetic input for scroll capture. Posting events needs Accessibility
/// access, which scroll capture checks before it starts.
nonisolated enum ScrollCaptureInput {

    /// Where the pointer is, in global top-left coordinates.
    static var pointerLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// A mouse-moved event where the pointer already is: the window under it
    /// updates its hover state and scroll target as if the mouse had been
    /// nudged.
    static func refreshPointer() {
        postMouseMoved(at: pointerLocation)
    }

    static func movePointer(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        postMouseMoved(at: point)
    }

    private static func postMouseMoved(at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
                mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// One scroll wheel event; positive `amount` scrolls the content down.
    ///
    /// Posted into the login session, past the HID level: mouse utilities
    /// (Mac Mouse Fix, BetterTouchTool…) tap there and rewrite wheel events
    /// into smoothed, possibly reversed gestures, which would make every step
    /// unpredictable.
    static func postScroll(_ step: AutoScrollPlanner.Step) {
        let units: CGScrollEventUnit = step.unit == .pixel ? .pixel : .line
        CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1,
                wheel1: -step.amount, wheel2: 0, wheel3: 0)?.post(tap: .cgSessionEventTap)
    }
}
