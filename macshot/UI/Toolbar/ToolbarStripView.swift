import Cocoa

/// The single floating annotation bar: sections of ToolbarButtonViews separated by
/// hairline dividers, with a native More menu for the less frequent actions and for
/// anything that does not fit the available width.
class ToolbarStripView: ToolbarSurfaceView {

    static let controlHeight: CGFloat = 32
    static let padding: CGFloat = 6
    static let barHeight: CGFloat = controlHeight + padding * 2
    private let spacing: CGFloat = 2
    private let sectionGap: CGFloat = 13  // divider plus breathing room either side

    /// The bar never grows wider than this; overflow moves into More.
    var maximumWidth: CGFloat = .greatestFiniteMagnitude {
        didSet { if abs(oldValue - maximumWidth) > 0.5 { layoutButtons() } }
    }
    /// Indices into `buttonViews` currently offered from the More menu.
    private(set) var overflowIndices: [Int] = []
    private var dividerRects: [NSRect] = []
    private(set) var buttonViews: [ToolbarButtonView] = []
    private var buttonData: [ToolbarButton] = []

    private(set) lazy var overflowButton: ToolbarButtonView = {
        let button = ToolbarButtonView(action: .more, sfSymbol: "ellipsis", tooltip: L("More"))
        button.onClick = { [weak self] _ in self?.showOverflow() }
        button.onHover = { [weak self] action, hovered in self?.onHover?(action, hovered) }
        return button
    }()

    /// The view to anchor a popover for `button`: the button itself, or More when the
    /// button currently lives in the menu.
    func anchorView(for button: ToolbarButtonView?) -> NSView? {
        guard let button else { return nil }
        return button.isHidden ? overflowButton : button
    }

    /// Set in editor mode so gap clicks pass through to the image beneath.
    var passesThrough = false
    /// Suppress hover visuals/callbacks while a toolbar-initiated drag is moving
    /// the whole toolbar under the cursor.
    var suppressesHover = false {
        didSet {
            if suppressesHover {
                for bv in buttonViews { bv.setHovered(false) }
                overflowButton.setHovered(false)
            }
        }
    }

    var onClick: ((ToolbarButtonAction) -> Void)?
    var onRightClick: ((ToolbarButtonAction, NSView) -> Void)?
    var onHover: ((ToolbarButtonAction, Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        addSubview(overflowButton)
        overflowButton.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Strip-level tracking area: clears all button hovers when the cursor leaves
    /// the whole strip (covers the case where AppKit drops the last button's
    /// mouseExited in a non-activating panel).
    private var stripTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = stripTracking { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        stripTracking = ta
    }
    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseExited(with event: NSEvent) {
        clearInteractionState(clearPressed: !suppressesHover)
    }

    /// Rebuild buttons from ToolbarButton data.
    func setButtons(_ buttons: [ToolbarButton]) {
        for bv in buttonViews { bv.removeFromSuperview() }
        buttonViews.removeAll()

        for data in buttons {
            let bv = ToolbarButtonView(action: data.action, sfSymbol: data.sfSymbol, tooltip: data.tooltip)
            bv.configure(with: data)
            bv.onClick = { [weak self] action in self?.onClick?(action) }
            bv.onRightClick = { [weak self] action, view in self?.onRightClick?(action, view) }
            bv.onHover = { [weak self] action, hovered in self?.onHover?(action, hovered) }
            addSubview(bv)
            buttonViews.append(bv)
        }
        buttonData = buttons
        layoutButtons()
    }

    /// Clear hover on every button except `keep`. Called when a button is
    /// entered, to defensively reset any sibling AppKit failed to send
    /// mouseExited to.
    func clearHover(except keep: ToolbarButtonView) {
        if suppressesHover { return }
        for bv in buttonViews + [overflowButton] where bv !== keep { bv.setHovered(false) }
    }

    func clearInteractionState(
        suppressHoverUntilMouseMoved suppress: Bool = false,
        clearPressed: Bool = true
    ) {
        for bv in buttonViews + [overflowButton] {
            bv.clearInteractionState(
                suppressHoverUntilMouseMoved: suppress,
                clearPressed: clearPressed)
        }
    }

    /// Update button state without rebuilding views (same buttons, new state).
    func updateState(from buttons: [ToolbarButton]) {
        guard buttons.count == buttonViews.count else {
            setButtons(buttons)
            return
        }
        for (i, data) in buttons.enumerated() {
            buttonViews[i].configure(with: data)
        }
        buttonData = buttons
        layoutButtons()
    }

    // MARK: - Layout

    private func isEssential(_ index: Int) -> Bool {
        buttonData[index].isEssential || buttonViews[index].isOn
    }

    /// The items laid out on the bar, More inserted before the finish section.
    private func entries(for visible: [Int], showsMore: Bool)
        -> [(view: ToolbarButtonView, section: ToolbarSection, width: CGFloat)]
    {
        var result = visible.map {
            (view: buttonViews[$0], section: buttonData[$0].section, width: buttonViews[$0].preferredWidth)
        }
        if showsMore {
            let insertion = result.firstIndex { $0.section == .finish } ?? result.count
            let section: ToolbarSection = insertion > 0 ? max(result[insertion - 1].section, .outputs) : .outputs
            result.insert((view: overflowButton, section: section, width: overflowButton.preferredWidth), at: insertion)
        }
        return result
    }

    private func extent(_ items: [(view: ToolbarButtonView, section: ToolbarSection, width: CGFloat)]) -> CGFloat {
        var length = Self.padding * 2
        for (i, item) in items.enumerated() {
            if i > 0 { length += items[i - 1].section == item.section ? spacing : sectionGap }
            length += item.width
        }
        return length
    }

    private func layoutButtons() {
        guard !buttonViews.isEmpty, buttonData.count == buttonViews.count else {
            frame.size = .zero
            overflowButton.isHidden = true
            overflowIndices = []
            dividerRects = []
            return
        }
        var visible = buttonViews.indices.filter { !buttonData[$0].prefersMenu || buttonViews[$0].isOn }
        var showsMore = visible.count < buttonViews.count
        while extent(entries(for: visible, showsMore: showsMore)) > maximumWidth {
            // Lowest priority first; among equals the rightmost goes, so tools keep
            // their leading order.
            let candidates = visible.filter { !isEssential($0) }
            guard let victim = candidates.min(by: { lhs, rhs in
                let l = buttonData[lhs].keepPriority, r = buttonData[rhs].keepPriority
                return l == r ? lhs > rhs : l < r
            }) else { break }
            visible.removeAll { $0 == victim }
            showsMore = true
        }
        let visibleSet = Set(visible)
        overflowIndices = buttonViews.indices.filter { !visibleSet.contains($0) }
        for (i, button) in buttonViews.enumerated() { button.isHidden = !visibleSet.contains(i) }
        overflowButton.isHidden = overflowIndices.isEmpty

        let items = entries(for: visible, showsMore: !overflowIndices.isEmpty)
        let length = extent(items)
        frame.size = NSSize(width: length, height: Self.barHeight)
        dividerRects.removeAll()
        var cursor = Self.padding
        for (i, item) in items.enumerated() {
            if i > 0 {
                if items[i - 1].section != item.section {
                    let dividerHeight: CGFloat = 18
                    dividerRects.append(NSRect(x: cursor + (sectionGap - 1) / 2, y: (Self.barHeight - dividerHeight) / 2,
                                               width: 1, height: dividerHeight))
                    cursor += sectionGap
                } else {
                    cursor += spacing
                }
            }
            item.view.frame = NSRect(x: cursor, y: Self.padding, width: item.width, height: Self.controlHeight)
            cursor += item.width
        }
        needsDisplay = true
    }

    /// Centre x of a button in this bar's coordinates (for hanging panels from it).
    func midX(of action: (ToolbarButtonAction) -> Bool) -> CGFloat? {
        guard let view = buttonViews.first(where: { action($0.action) }), !view.isHidden else { return nil }
        return view.frame.midX
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        ToolbarLayout.iconColor.withAlphaComponent(0.12).setFill()
        for rect in dividerRects { rect.fill() }
    }

    // MARK: - More menu

    private final class MenuSelection: NSObject {
        let action: ToolbarButtonAction
        let options: Bool
        init(_ action: ToolbarButtonAction, options: Bool = false) { self.action = action; self.options = options }
    }

    /// Kept separate from presentation so tests can verify that every hidden
    /// enabled action (and its context options) remains reachable.
    func makeOverflowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var previous: (section: ToolbarSection, group: Int)?
        for index in overflowIndices {
            let button = buttonViews[index]
            let data = buttonData[index]
            if let previous, previous.section != data.section || previous.group != data.menuGroup {
                menu.addItem(.separator())
            }
            previous = (data.section, data.menuGroup)
            let item = NSMenuItem(title: button.tooltipText, action: #selector(performOverflow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuSelection(button.action)
            item.state = button.isOn ? .on : .off
            if let symbol = button.sfSymbol {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            if button.hasContextMenu {
                let submenu = NSMenu()
                let run = NSMenuItem(title: button.tooltipText, action: #selector(performOverflow(_:)), keyEquivalent: "")
                run.target = self; run.representedObject = MenuSelection(button.action)
                submenu.addItem(run)
                let options = NSMenuItem(title: L("Options"), action: #selector(performOverflow(_:)), keyEquivalent: "")
                options.target = self; options.representedObject = MenuSelection(button.action, options: true)
                submenu.addItem(options); item.submenu = submenu
            }
            menu.addItem(item)
        }
        return menu
    }

    private func showOverflow() {
        clearInteractionState()
        let menu = makeOverflowMenu()
        menu.appearance = effectiveAppearance
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: overflowButton)
    }

    @objc private func performOverflow(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? MenuSelection else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if selection.options { self.onRightClick?(selection.action, self.overflowButton) }
            else { self.onClick?(selection.action) }
        }
    }

    // Consume clicks on gaps between buttons so they don't fall through to OverlayView.
    // In editor mode (passesThrough), let gap clicks pass through so drawing works
    // over the toolbar area.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let result = super.hitTest(point), result !== self { return result }
        if passesThrough { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
