import Cocoa

/// A shared floating surface for the tools and their contextual controls.
class ToolbarSurfaceView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = ToolbarLayout.appearance
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: ToolbarLayout.cornerRadius, yRadius: ToolbarLayout.cornerRadius)
        ToolbarLayout.bgColor.setFill()
        shape.fill()
        ToolbarLayout.iconColor.withAlphaComponent(0.13).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
