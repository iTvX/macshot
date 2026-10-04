import Cocoa
import XCTest

@MainActor
final class ToolbarPresentationTests: XCTestCase {
    func testDefaultPaletteFollowsAppearanceAndCustomPaletteWins() throws {
        try withDefaults(["toolbarBgColor": nil, "toolbarIconColor": nil, "toolbarAccentColor": nil]) {
            XCTAssertNil(ToolbarLayout.appearance)
            var brightness: [CGFloat] = []
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                    brightness.append(ToolbarLayout.bgColor.usingColorSpace(.deviceRGB)!.brightnessComponent)
                }
            }
            XCTAssertGreaterThan(brightness[0], 0.9)
            XCTAssertLessThan(brightness[1], 0.3)
            let custom = NSColor(calibratedWhite: 0.2, alpha: 1)
            UserDefaults.standard.set(try NSKeyedArchiver.archivedData(withRootObject: custom, requiringSecureCoding: true), forKey: "toolbarBgColor")
            XCTAssertEqual(ToolbarLayout.appearance?.name, .darkAqua)
            XCTAssertEqual(ToolbarLayout.bgColor.usingColorSpace(.deviceRGB)!.brightnessComponent, custom.usingColorSpace(.deviceRGB)!.brightnessComponent, accuracy: 0.01)
        }
    }

    func testOverflowPreservesActionsContextOptionsAndPopoverAnchor() async {
        let strip = ToolbarStripView(orientation: .horizontal)
        strip.presentation = .actions
        strip.setButtons([
            ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", tooltip: "Copy"),
            ToolbarButton(action: .share, sfSymbol: "square.and.arrow.up", tooltip: "Share"),
            ToolbarButton(action: .translate, sfSymbol: "translate", tooltip: "Translate", hasContextMenu: true),
        ])
        XCTAssertEqual(strip.buttonViews.count, 3)
        XCTAssertTrue(strip.anchorView(for: strip.buttonViews[1]) === strip.overflowButton)
        XCTAssertTrue(strip.anchorView(for: strip.buttonViews[0]) === strip.buttonViews[0])
        let menu = strip.makeOverflowMenu()
        XCTAssertEqual(menu.items.map(\.title), ["Share", "Translate"])
        var shared = false
        var optionsAnchor: NSView?
        strip.onClick = { if case .share = $0 { shared = true } }
        strip.onRightClick = { action, anchor in if case .translate = action { optionsAnchor = anchor } }
        let share = menu.items[0]
        _ = strip.perform(share.action!, with: share)
        let option = menu.items[1].submenu!.items[1]
        _ = strip.perform(option.action!, with: option)
        await Task.yield()
        // Menu dispatch deliberately waits until tracking has ended.
        let done = expectation(description: "menu callbacks")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 1)
        XCTAssertTrue(shared)
        XCTAssertTrue(optionsAnchor === strip.overflowButton)
    }

    func testSelectedAdvancedToolStaysVisibleAndNarrowStripFits() {
        let strip = ToolbarStripView(orientation: .horizontal)
        strip.presentation = .tools
        strip.maximumWidth = 250
        let data = [AnnotationTool.pencil, .arrow, .rectangle, .ellipse, .marker, .text, .number, .pixelate, .loupe].map {
            ToolbarButton(action: .tool($0), sfSymbol: "pencil", tooltip: String(describing: $0), isSelected: $0 == .loupe)
        }
        strip.setButtons(data)
        XCTAssertLessThanOrEqual(strip.frame.width, 250)
        XCTAssertFalse(strip.buttonViews.last!.isHidden)
        XCTAssertEqual(strip.makeOverflowMenu().items.count + strip.buttonViews.filter { !$0.isHidden }.count, data.count)
        strip.updateState(from: data.map { ToolbarButton(action: $0.action, sfSymbol: $0.sfSymbol, tooltip: $0.tooltip, isSelected: false) })
        XCTAssertTrue(strip.buttonViews.last!.isHidden)
    }

    func testToolbarPlacementAtEdgesAndFullScreenAvoidsOverlap() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        let anchors = [bounds, NSRect(x: 0, y: 0, width: 50, height: 50), NSRect(x: 750, y: 550, width: 50, height: 50), NSRect(x: 370, y: 270, width: 60, height: 50)]
        for anchor in anchors {
            let notch = NSRect(x: 360, y: 570, width: 80, height: 30)
            let frames = ToolbarPlacement.place(in: bounds, around: anchor, tools: NSSize(width: 486, height: 50), actions: NSSize(width: 372, height: 50), options: NSSize(width: 486, height: 56), obstacles: [notch])
            for frame in [frames.tools, frames.actions, frames.options] {
                XCTAssertTrue(bounds.contains(frame), "\(anchor): \(frame)")
                XCTAssertFalse(frame.intersects(notch))
            }
            XCTAssertFalse(frames.tools.intersects(frames.actions))
            XCTAssertFalse(frames.options.intersects(frames.actions))
            XCTAssertFalse(frames.tools.intersects(frames.options))
        }
    }

    func testScrollableOptionsOwnGapHitsInEditor() {
        let overlay = ToolbarTestEditor(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let row = ToolOptionsRowView(frame: .zero)
        row.overlayView = overlay
        overlay.addSubview(row)
        row.rebuild(for: .text)
        row.setPresentationWidth(250)
        row.frame.origin = NSPoint(x: 30, y: 30)
        let hit = row.hitTest(NSPoint(x: 32, y: 32))
        XCTAssertTrue(hit is NSScrollView)
    }

    func testSmallSelectionKeepsResolutionAndToolbarsOutsideContent() {
        let overlay = OverlayView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let selection = NSRect(x: 540, y: 365, width: 120, height: 70)
        overlay.applySelection(selection)
        overlay.rebuildToolbarLayout()
        let badge = overlay.subviews.compactMap { $0 as? ResolutionBoxView }.first!
        XCTAssertFalse(badge.frame.intersects(selection))
        for strip in overlay.subviews.compactMap({ $0 as? ToolbarStripView }) {
            XCTAssertFalse(strip.frame.intersects(selection))
            XCTAssertFalse(strip.frame.intersects(badge.frame))
        }
    }

    func testOptionsControlsStayInsideViewportAcrossToolAndThemeChanges() {
        let overlay = OverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let row = ToolOptionsRowView(frame: .zero)
        row.overlayView = overlay
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            row.appearance = NSAppearance(named: appearance)
            for tool in [AnnotationTool.arrow, .text, .rectangle, .pixelate] {
                row.rebuild(for: tool)
                for width: CGFloat in [486, 250, 600] {
                    row.setPresentationWidth(width)
                    let scroll = row.subviews.first as! NSScrollView
                    let document = scroll.documentView!
                    XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.01)
                    XCTAssertEqual(document.frame.height, scroll.contentSize.height, accuracy: 0.01)
                    for control in document.subviews {
                        XCTAssertGreaterThanOrEqual(control.frame.minY, 0, "\(tool): \(control.frame), doc \(document.frame), clip \(scroll.contentView.bounds)")
                        XCTAssertLessThanOrEqual(control.frame.maxY, document.bounds.height, "\(tool): \(control.frame), doc \(document.frame), clip \(scroll.contentView.bounds)")
                    }
                    XCTAssertEqual(scroll.hasHorizontalScroller, row.contentWidth > width - 8)
                    XCTAssertFalse(scroll.hasVerticalScroller)
                    if let scroller = scroll.horizontalScroller {
                        XCTAssertGreaterThan(scroller.frame.width, scroller.frame.height)
                    }
                }
            }
        }
    }
}

@MainActor
private final class ToolbarTestEditor: OverlayView {
    override var isEditorMode: Bool { true }
}
