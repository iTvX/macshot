import Cocoa

/// Real NSView for a single toolbar button. Handles its own hover, press, drawing.
/// Styles: glyph, colour dot, options chip, labelled pill and prominent pill.
class ToolbarButtonView: NSView {

    var action: ToolbarButtonAction
    var sfSymbol: String?
    var isOn: Bool = false { didSet { if oldValue != isOn { cachedIcon = nil; needsDisplay = true } } }
    var tintColor: NSColor = ToolbarLayout.iconColor { didSet { cachedIcon = nil; cachedIconIsOn = nil; needsDisplay = true } }
    var selectedTintColor: NSColor? { didSet { cachedIcon = nil; cachedIconIsOn = nil; needsDisplay = true } }
    var swatchColor: NSColor? { didSet { needsDisplay = true } }
    var hasContextMenu: Bool = false
    var style: ToolbarButtonStyle = .icon { didSet { if oldValue != style { cachedIcon = nil; needsDisplay = true } } }
    var section: ToolbarSection = .outputs { didSet { if oldValue != section { cachedIcon = nil; needsDisplay = true } } }
    var title: String? { didSet { needsDisplay = true } }
    var prominentColor: NSColor? { didSet { needsDisplay = true } }
    /// Mic input level (0–1). When > 0, draws a green fill from the bottom of the button.
    var micLevel: Float = 0 { didSet { if abs(oldValue - micLevel) > 0.005 { needsDisplay = true } } }

    private var isHovered: Bool = false
    var isPressed: Bool = false
    private var trackingArea: NSTrackingArea?
    private var suppressHoverStartPoint: NSPoint?
    private var cachedIcon: NSImage?       // cached tinted SF Symbol for current state
    private var cachedIconIsOn: Bool?       // the isOn state when icon was cached
    private var cachedIconColorKey: String?

    /// Shared cross-instance cache: avoids re-rasterizing SF Symbols when toolbar is rebuilt.
    /// Key: "symbolName|pointSize|colorHex"
    private static var iconCache: [String: NSImage] = [:]

    private static func cacheKey(name: String, pointSize: CGFloat, color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return "\(name)|\(pointSize)|\(Int(r*255)),\(Int(g*255)),\(Int(b*255)),\(Int(a*255))"
    }

    var onClick: ((ToolbarButtonAction) -> Void)?
    var onMouseDown: ((ToolbarButtonAction) -> Void)?
    var onRightClick: ((ToolbarButtonAction, NSView) -> Void)?
    var onHover: ((ToolbarButtonAction, Bool) -> Void)?  // (action, isHovered)

    static let size: CGFloat = 32
    private static let radius: CGFloat = 8
    private static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let chipFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    /// Width the bar gives this control; height is always `size`.
    var preferredWidth: CGFloat {
        switch style {
        case .icon, .swatch:
            return Self.size
        case .chip:
            let text = (title ?? "") as NSString
            let textWidth = text.length == 0 ? 0 : ceil(text.size(withAttributes: [.font: Self.chipFont]).width) + 6
            return max(40, 10 + textWidth + 9 + 10)
        case .labeled, .prominent:
            let text = (title ?? "") as NSString
            let textWidth = ceil(text.size(withAttributes: [.font: Self.titleFont]).width)
            return min(160, max(64, 11 + 16 + 6 + textWidth + 12))
        }
    }

    var tooltipText: String = ""

    init(action: ToolbarButtonAction, sfSymbol: String?, tooltip: String) {
        self.action = action
        self.sfSymbol = sfSymbol
        self.tooltipText = tooltip
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with data: ToolbarButton) {
        action = data.action
        isOn = data.isSelected
        tintColor = data.tintColor
        selectedTintColor = data.selectedTintColor
        swatchColor = data.bgColor
        sfSymbol = data.sfSymbol
        tooltipText = data.tooltip
        hasContextMenu = data.hasContextMenu
        style = data.style
        section = data.section
        title = data.title
        prominentColor = data.prominentColor
        cachedIcon = nil
        if case .micAudio = action {
            // Preserve the live mic meter while this reused view is still the
            // mic button.
        } else {
            micLevel = 0
        }
        // Only the move button uses onMouseDown for synchronous drag tracking.
        // Reset it when a reused slot changes meaning; OverlayView assigns it
        // again to the current move button after updating the strip.
        onMouseDown = nil
        dragForwardTarget = nil
        forwardingDrag = false
        isPressed = false
        needsDisplay = true
    }

    /// The selected annotation tool reads as a filled accent tile (CleanShot);
    /// other "on" toggles keep a quieter tinted state.
    private var isSelectedTool: Bool { isOn && section == .tools }

    private func glyph(named name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        let key = Self.cacheKey(name: name, pointSize: pointSize, color: color)
        if let cached = Self.iconCache[key] { return cached }
        let img: NSImage?
        if name == "_custom.checkerboard" {
            img = Self.checkerboardIcon(color: color)
        } else {
            let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(cfg) {
                let resolved = color.usingColorSpace(.sRGB) ?? color
                img = NSImage(size: symbol.size, flipped: false) { r in
                    symbol.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
                    resolved.setFill()
                    r.fill(using: .sourceAtop)
                    return true
                }
            } else {
                img = nil
            }
        }
        if let img {
            img.lockFocus(); img.unlockFocus()
            Self.iconCache[key] = img
        }
        return img
    }

    override func draw(_ dirtyRect: NSRect) {
        let surface = bounds.insetBy(dx: 1, dy: 1)
        let tile = NSBezierPath(roundedRect: surface, xRadius: Self.radius, yRadius: Self.radius)
        let icon = ToolbarLayout.iconColor
        let accent = ToolbarLayout.accentColor

        switch style {
        case .prominent:
            let base = prominentColor ?? accent
            base.withAlphaComponent(isPressed ? 0.72 : (isHovered ? 0.88 : 1)).setFill()
            tile.fill()
            drawGlyphAndTitle(color: .white)
            return
        case .labeled:
            icon.withAlphaComponent(isPressed ? 0.17 : (isHovered ? 0.12 : 0.07)).setFill()
            tile.fill()
            drawGlyphAndTitle(color: icon)
            if hasContextMenu { drawContextTriangle() }
            return
        case .chip:
            let fill = isOn ? accent.withAlphaComponent(isPressed ? 0.26 : 0.16)
                : icon.withAlphaComponent(isPressed ? 0.15 : (isHovered ? 0.11 : 0.06))
            fill.setFill()
            tile.fill()
            drawChip(color: isOn ? accent : icon)
            return
        case .swatch, .icon:
            break
        }

        let bg: NSColor
        if isSelectedTool {
            bg = accent.withAlphaComponent(isPressed ? 0.8 : 1)
        } else if isPressed {
            bg = icon.withAlphaComponent(0.15)
        } else if isOn {
            bg = accent.withAlphaComponent(0.15)
        } else if isHovered {
            bg = icon.withAlphaComponent(0.08)
        } else {
            bg = .clear
        }
        bg.setFill()
        tile.fill()

        // Mic level fill — green bar rising from the bottom inside the button
        if micLevel > 0.001 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius).addClip()
            let fillH = bounds.height * CGFloat(min(micLevel, 1.0))
            let fillRect = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: fillH)
            NSColor.systemGreen.withAlphaComponent(0.45).setFill()
            fillRect.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Colour dot
        if style == .swatch || swatchColor != nil {
            let diameter: CGFloat = 18
            let r = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
            (swatchColor ?? .clear).setFill()
            NSBezierPath(ovalIn: r).fill()
            icon.withAlphaComponent(0.28).setStroke()
            let border = NSBezierPath(ovalIn: r.insetBy(dx: -1.5, dy: -1.5))
            border.lineWidth = 1
            border.stroke()
            return
        }

        // SF Symbol or custom icon (static cache survives toolbar rebuilds)
        guard let name = sfSymbol else { return }
        let color: NSColor = isSelectedTool ? .white : (isOn ? (selectedTintColor ?? accent) : tintColor)
        let key = Self.cacheKey(name: name, pointSize: 15, color: color)
        if cachedIcon == nil || cachedIconIsOn != isOn || cachedIconColorKey != key {
            cachedIcon = glyph(named: name, pointSize: 15, color: color)
            cachedIconIsOn = isOn
            cachedIconColorKey = key
        }
        if let image = cachedIcon {
            let origin = NSPoint(x: round(bounds.midX - image.size.width / 2), y: round(bounds.midY - image.size.height / 2))
            image.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        if hasContextMenu { drawContextTriangle() }
    }

    private func drawGlyphAndTitle(color: NSColor) {
        var x: CGFloat = 11
        if let name = sfSymbol, let image = glyph(named: name, pointSize: 13, color: color) {
            image.draw(at: NSPoint(x: x + round((16 - image.size.width) / 2), y: round(bounds.midY - image.size.height / 2)),
                       from: .zero, operation: .sourceOver, fraction: 1.0)
            x += 16 + 6
        }
        guard let title else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.titleFont, .foregroundColor: color, .paragraphStyle: style]
        let height = ceil((title as NSString).size(withAttributes: attrs).height)
        (title as NSString).draw(in: NSRect(x: x, y: round(bounds.midY - height / 2), width: bounds.width - x - 8, height: height),
                                 withAttributes: attrs)
    }

    private func drawChip(color: NSColor) {
        let chevronWidth: CGFloat = 9
        var x: CGFloat = 10
        if let title, !title.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.chipFont, .foregroundColor: color]
            let size = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: NSPoint(x: x, y: round(bounds.midY - size.height / 2)), withAttributes: attrs)
            x += ceil(size.width) + 6
        } else if let image = glyph(named: "slider.horizontal.3", pointSize: 13, color: color) {
            image.draw(at: NSPoint(x: x, y: round(bounds.midY - image.size.height / 2)), from: .zero, operation: .sourceOver, fraction: 1)
            x += image.size.width + 4
        }
        if let chevron = glyph(named: isOn ? "chevron.up" : "chevron.down", pointSize: 9, color: color.withAlphaComponent(0.75)) {
            let origin = NSPoint(x: min(x, bounds.maxX - 10 - chevronWidth) + round((chevronWidth - chevron.size.width) / 2),
                                 y: round(bounds.midY - chevron.size.height / 2))
            chevron.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    private func drawContextTriangle() {
        let s: CGFloat = 4
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.maxX - s - 3, y: bounds.minY + 3))
        path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + 3))
        path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + 3 + s))
        path.close()
        let color = style == .prominent ? NSColor.white.withAlphaComponent(0.7) : ToolbarLayout.iconColor.withAlphaComponent(0.35)
        color.setFill()
        path.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cachedIcon = nil
        needsDisplay = true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        guard style == .chip, let title, !title.isEmpty else { return tooltipText }
        return "\(tooltipText), \(title)"
    }
    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool {
        // Drag controls need a real press/release pair; a synthetic accessibility
        // press must never enter the synchronous mouse-tracking loop.
        guard onMouseDown == nil else { return false }
        onClick?(action)
        return onClick != nil
    }

    // MARK: - Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        // `.activeAlways` (not `.activeInActiveApp`): macshot is a menu-bar
        // LSUIElement app and the toolbars can live in non-activating panels
        // (Liquid Glass chrome). With `.activeInActiveApp`, mouseExited wouldn't
        // fire when the app isn't frontmost, leaving a previous button stuck in
        // its hover state when moving to another.
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Toolbar buttons always show the arrow cursor, overriding the overlay's
    // crosshair / hidden drawing-cursor that would otherwise bleed through.
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    private var owningStrip: ToolbarStripView? {
        superview as? ToolbarStripView ?? superview?.superview as? ToolbarStripView
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
        guard owningStrip?.suppressesHover != true else {
            setHovered(false)
            return
        }
        guard suppressHoverStartPoint == nil else {
            setHovered(false)
            return
        }
        // Robustly clear any sibling that AppKit failed to send mouseExited to
        // (common in non-activating glass chrome panels) so only one button is
        // ever hovered.
        owningStrip?.clearHover(except: self)
        setHovered(true)
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
        guard owningStrip?.suppressesHover != true else {
            setHovered(false)
            return
        }
        if let start = suppressHoverStartPoint {
            let now = NSEvent.mouseLocation
            let dx = now.x - start.x
            let dy = now.y - start.y
            // AppKit can synthesize a mouseMoved/entered pass at the same
            // location after a toolbar drag loop unwinds. Keep hover suppressed
            // until the pointer actually moves away from the release point.
            guard dx * dx + dy * dy >= 9 else {
                setHovered(false)
                return
            }
            suppressHoverStartPoint = nil
        }
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            owningStrip?.clearHover(except: self)
            setHovered(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        suppressHoverStartPoint = nil
        setHovered(false)
    }

    /// Externally force the hover state (used by the strip to clear stale hovers).
    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
        onHover?(action, hovered)
    }

    func clearInteractionState(
        suppressHoverUntilMouseMoved suppress: Bool = false,
        clearPressed: Bool = true
    ) {
        suppressHoverStartPoint = suppress ? NSEvent.mouseLocation : nil
        forwardingDrag = false
        if clearPressed {
            isPressed = false
        }
        setHovered(false)
        needsDisplay = true
    }

    private var forwardingDrag = false
    /// The view that should receive forwarded drag events (set by onMouseDown handler).
    var dragForwardTarget: NSView?

    override func mouseDown(with event: NSEvent) {
        isPressed = true; needsDisplay = true
        if onMouseDown != nil {
            onMouseDown?(action)
            if dragForwardTarget != nil {
                forwardingDrag = true
            }
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if forwardingDrag, let target = dragForwardTarget {
            target.mouseDragged(with: event)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false; needsDisplay = true
        if forwardingDrag, let target = dragForwardTarget {
            forwardingDrag = false
            target.mouseUp(with: event)
            return
        }
        forwardingDrag = false
        if wasPressed && bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?(action)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(action, self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // MARK: - Custom checkerboard icon

    /// Generate a checkerboard icon matching the style of SF Symbols, tinted with the given color.
    /// The result is a rounded square with a 4x4 checkerboard pattern.
    private static func checkerboardIcon(color: NSColor) -> NSImage {
        let size: CGFloat = 16
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let cornerRadius: CGFloat = 3
            let cellSize = size / 4
            let clip = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                                    xRadius: cornerRadius, yRadius: cornerRadius)
            clip.addClip()

            for row in 0..<4 {
                for col in 0..<4 {
                    let isDark = (row + col) % 2 == 0
                    if isDark {
                        color.setFill()
                    } else {
                        color.withAlphaComponent(0.35).setFill()
                    }
                    let cellRect = NSRect(x: CGFloat(col) * cellSize, y: CGFloat(row) * cellSize,
                                          width: cellSize, height: cellSize)
                    cellRect.fill()
                }
            }
            return true
        }
        return img
    }
}
