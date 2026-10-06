import Cocoa

/// The shared floating surface of the bar, the options panel and the size pill.
class ToolbarSurfaceView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = ToolbarLayout.appearance
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)
    }
    required init?(coder: NSCoder) { fatalError() }

    // An explicit shadow path keeps moving surfaces cheap (no offscreen shadow pass).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let radius = min(ToolbarLayout.cornerRadius, newSize.height / 2)
        layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: newSize),
                                   cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

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
