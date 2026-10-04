import Cocoa

/// Real NSView container for a row (horizontal) or column (vertical) of ToolbarButtonViews.
/// Groups common actions on an adaptive floating surface, with native overflow menus.
class ToolbarStripView: ToolbarSurfaceView {

    enum Orientation { case horizontal, vertical }
    enum Presentation { case all, tools, actions }
    var presentation: Presentation = .all
    var maximumWidth: CGFloat = .greatestFiniteMagnitude {
        didSet { if abs(oldValue - maximumWidth) > 0.5 { layoutButtons() } }
    }
    private(set) var overflowIndices: [Int] = []
    private var separatorRects: [NSRect] = []
    private(set) lazy var overflowButton: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: L("More"))!,
                              target: self, action: #selector(showOverflow))
        button.isBordered = false
        button.toolTip = L("More")
        button.setAccessibilityLabel(L("More"))
        button.imageScaling = .scaleNone
        return button
    }()

    func anchorView(for button: ToolbarButtonView?) -> NSView? {
        guard let button else { return nil }
        return button.isHidden ? overflowButton : button
    }

    let orientation: Orientation
    private(set) var buttonViews: [ToolbarButtonView] = []
    /// Set to true in editor mode so gap clicks pass through to the image beneath.
    var passesThrough = false
    /// Suppress hover visuals/callbacks while a toolbar-initiated drag is moving
    /// the whole toolbar panel under the cursor.
    var suppressesHover = false {
        didSet {
            if suppressesHover {
                for bv in buttonViews { bv.setHovered(false) }
            }
        }
    }

    var onClick: ((ToolbarButtonAction) -> Void)?
    var onRightClick: ((ToolbarButtonAction, NSView) -> Void)?
    var onHover: ((ToolbarButtonAction, Bool) -> Void)?

    private let padding: CGFloat = 8
    private let spacing: CGFloat = 3

    init(orientation: Orientation) {
        self.orientation = orientation
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
            bv.isOn = data.isSelected
            bv.tintColor = data.tintColor
            bv.selectedTintColor = data.selectedTintColor
            bv.swatchColor = data.bgColor
            bv.hasContextMenu = data.hasContextMenu
            bv.showsActionTitle = presentation == .actions
            bv.onClick = { [weak self] action in self?.onClick?(action) }
            bv.onRightClick = { [weak self] action, view in self?.onRightClick?(action, view) }
            bv.onHover = { [weak self] action, hovered in self?.onHover?(action, hovered) }
            addSubview(bv)
            buttonViews.append(bv)
        }
        layoutButtons()
    }

    /// Clear hover on every button except `keep`. Called when a button is
    /// entered, to defensively reset any sibling AppKit failed to send
    /// mouseExited to (happens in non-activating glass chrome panels).
    func clearHover(except keep: ToolbarButtonView) {
        if suppressesHover { return }
        for bv in buttonViews where bv !== keep { bv.setHovered(false) }
    }

    func clearInteractionState(
        suppressHoverUntilMouseMoved suppress: Bool = false,
        clearPressed: Bool = true
    ) {
        for bv in buttonViews {
            bv.clearInteractionState(
                suppressHoverUntilMouseMoved: suppress,
                clearPressed: clearPressed)
        }
    }

    /// Update button state without rebuilding views.
    func updateState(from buttons: [ToolbarButton]) {
        for (i, data) in buttons.enumerated() where i < buttonViews.count {
            buttonViews[i].configure(with: data)
        }
        layoutButtons()
    }

    private func isProminent(_ button: ToolbarButtonView) -> Bool {
        if presentation == .all || button.isOn { return true }
        if presentation == .tools {
            switch button.action {
            case .tool(let tool): return [.pencil, .arrow, .rectangle, .ellipse, .marker, .text, .number, .pixelate].contains(tool)
            case .color, .undo, .redo: return true
            default: return false
            }
        }
        if buttonViews.contains(where: { if case .startRecord = $0.action { return true }; return false }) { return true }
        switch button.action {
        case .cancel, .moveSelection, .detach, .pin, .save, .copy: return true
        default: return false
        }
    }

    private func isEssential(_ button: ToolbarButtonView) -> Bool {
        if button.isOn { return true }
        switch button.action {
        case .cancel, .moveSelection, .copy, .save, .color, .startRecord, .stopRecord: return true
        default: return false
        }
    }

    private func group(for action: ToolbarButtonAction) -> Int {
        if presentation == .actions {
            switch action {
            case .cancel, .stopRecord: return 0
            case .copy, .save, .startRecord: return 3
            default: return 1
            }
        }
        switch action {
        case .tool: return 0
        case .color: return 1
        case .undo, .redo: return 2
        default: return 3
        }
    }

    private func entries(for indices: [Int]) -> [(view: NSView, group: Int, width: CGFloat)] {
        var result = indices.map { (view: buttonViews[$0] as NSView, group: group(for: buttonViews[$0].action), width: buttonViews[$0].preferredWidth) }
        if indices.count < buttonViews.count {
            let entry = (view: overflowButton as NSView, group: presentation == .actions ? 2 : 3, width: ToolbarButtonView.size)
            let insertion = presentation == .actions ? (result.firstIndex { $0.group == 3 } ?? result.count) : result.count
            result.insert(entry, at: insertion)
        }
        return result
    }

    private func extent(_ entries: [(view: NSView, group: Int, width: CGFloat)]) -> CGFloat {
        var length = padding * 2
        for (i, entry) in entries.enumerated() {
            if i > 0 { length += entries[i - 1].group == entry.group ? spacing : 13 }
            length += orientation == .horizontal ? entry.width : ToolbarButtonView.size
        }
        return length
    }

    private func layoutButtons() {
        guard !buttonViews.isEmpty else {
            frame.size = .zero; overflowButton.isHidden = true; overflowIndices = []; return
        }
        for button in buttonViews { button.showsActionTitle = presentation == .actions && maximumWidth >= 300 }
        var visible = buttonViews.indices.filter { isProminent(buttonViews[$0]) }
        if presentation == .actions {
            func order(_ index: Int) -> Int {
                switch buttonViews[index].action {
                case .save, .startRecord: return 100
                case .copy: return 101
                default: return index
                }
            }
            visible.sort { order($0) < order($1) }
        }
        if orientation == .horizontal {
            while extent(entries(for: visible)) > maximumWidth,
                  let removal = visible.lastIndex(where: { !isEssential(buttonViews[$0]) }) {
                visible.remove(at: removal)
            }
        }
        let visibleSet = Set(visible)
        overflowIndices = buttonViews.indices.filter { !visibleSet.contains($0) }
        for (i, button) in buttonViews.enumerated() { button.isHidden = !visibleSet.contains(i) }
        overflowButton.isHidden = overflowIndices.isEmpty
        overflowButton.contentTintColor = ToolbarLayout.iconColor
        let items = entries(for: visible)
        let length = extent(items)
        let thickness = ToolbarButtonView.size + padding * 2
        frame.size = orientation == .horizontal ? NSSize(width: length, height: thickness) : NSSize(width: thickness, height: length)
        separatorRects.removeAll()
        var cursor = padding
        for (i, item) in items.enumerated() {
            if i > 0 {
                if items[i - 1].group != item.group {
                    let line = orientation == .horizontal
                        ? NSRect(x: cursor + 6, y: 16, width: 1, height: thickness - 32)
                        : NSRect(x: 16, y: length - cursor - 7, width: thickness - 32, height: 1)
                    separatorRects.append(line); cursor += 13
                } else { cursor += spacing }
            }
            item.view.frame = orientation == .horizontal
                ? NSRect(x: cursor, y: padding, width: item.width, height: ToolbarButtonView.size)
                : NSRect(x: padding, y: length - cursor - ToolbarButtonView.size, width: ToolbarButtonView.size, height: ToolbarButtonView.size)
            cursor += orientation == .horizontal ? item.width : ToolbarButtonView.size
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        ToolbarLayout.iconColor.withAlphaComponent(0.14).setFill()
        for rect in separatorRects { rect.fill() }
    }

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
        for index in overflowIndices {
            let button = buttonViews[index]
            let item = NSMenuItem(title: button.tooltipText, action: #selector(performOverflow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuSelection(button.action)
            item.state = button.isOn ? .on : .off
            if let symbol = button.sfSymbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
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

    @objc private func showOverflow() {
        clearInteractionState()
        makeOverflowMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: overflowButton)
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
