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

    func testDefaultPaletteStaysDynamicAfterAlphaChanges() throws {
        try withDefaults(["toolbarIconColor": nil, "toolbarAccentColor": nil]) {
            // Colors are often derived once (labels, tints) and drawn under another appearance.
            var derived: [NSColor] = []
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                derived = [ToolbarLayout.iconColor.withAlphaComponent(0.5), ToolbarLayout.accentColor.withAlphaComponent(0.5)]
            }
            for (name, expectedIconRed) in [(NSAppearance.Name.aqua, CGFloat(0)), (.darkAqua, 1)] {
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                    let icon = derived[0].usingColorSpace(.sRGB)!
                    XCTAssertEqual(icon.redComponent, expectedIconRed, accuracy: 0.01, "\(name)")
                    XCTAssertEqual(icon.alphaComponent, 0.5, accuracy: 0.01)
                }
            }
            var accentReds: [CGFloat] = []
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                    accentReds.append(derived[1].usingColorSpace(.sRGB)!.redComponent)
                }
            }
            XCTAssertNotEqual(accentReds[0], accentReds[1], accuracy: 0.01)
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

    func testActionsStayOutsideSelectionNearScreenTop() {
        let bounds = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let notch = NSRect(x: 652, y: 943, width: 208, height: 41)
        let anchors = [NSRect(x: 900, y: 600, width: 500, height: 360), NSRect(x: 200, y: 700, width: 600, height: 260),
                       NSRect(x: 0, y: 0, width: 756, height: 945), NSRect(x: 0, y: 700, width: 1512, height: 282)]
        for anchor in anchors {
            let frames = ToolbarPlacement.place(in: bounds, around: anchor, tools: NSSize(width: 487, height: 50),
                actions: NSSize(width: 372, height: 50), options: NSSize(width: 487, height: 56), obstacles: [notch])
            // Resize handles straddle the edges, so the actions must clear them too.
            XCTAssertFalse(frames.actions.intersects(anchor.insetBy(dx: -6, dy: -6)), "\(anchor): \(frames.actions)")
            XCTAssertTrue(bounds.contains(frames.actions))
            XCTAssertFalse(frames.actions.intersects(notch))
            XCTAssertFalse(frames.actions.intersects(frames.tools))
            XCTAssertFalse(frames.actions.intersects(frames.options))
        }
    }

    func testToolbarsStepAwayFromObstacleAboveSelection() {
        let bounds = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let anchor = NSRect(x: 300, y: 40, width: 700, height: 300)
        let badge = NSRect(x: 312, y: anchor.maxY + 12, width: 180, height: 28).insetBy(dx: -6, dy: -6)
        let frames = ToolbarPlacement.place(in: bounds, around: anchor, tools: NSSize(width: 487, height: 50),
            actions: NSSize(width: 372, height: 50), options: NSSize(width: 487, height: 56), obstacles: [badge])
        for frame in [frames.tools, frames.options, frames.actions] {
            XCTAssertFalse(frame.intersects(anchor), "\(frame)")
            XCTAssertFalse(frame.intersects(badge), "\(frame)")
        }
    }

    func testMovingSelectionTowardBottomKeepsToolbarsOutsideIt() {
        let overlay = OverlayView(frame: NSRect(x: 0, y: 0, width: 1512, height: 982))
        overlay.applySelection(NSRect(x: 300, y: 400, width: 700, height: 300))
        // Same order as the move-selection drag loop: badge first, then toolbars.
        for y in stride(from: 360, through: 40, by: -40) {
            let selection = NSRect(x: 300, y: CGFloat(y), width: 700, height: 300)
            overlay.applySelection(selection)
            overlay.updateResolutionBox()
            overlay.rebuildToolbarLayout()
            let badge = overlay.subviews.compactMap { $0 as? ResolutionBoxView }.first!
            var chrome = overlay.subviews.compactMap { $0 as? ToolbarStripView }.filter { !$0.isHidden }.map(\.frame)
            chrome += overlay.subviews.compactMap { $0 as? ToolOptionsRowView }.filter { !$0.isHidden }.map(\.frame)
            for frame in chrome {
                XCTAssertFalse(frame.intersects(selection), "y \(y): \(frame)")
                XCTAssertFalse(frame.intersects(badge.frame), "y \(y): \(frame) vs \(badge.frame)")
            }
        }
    }

    func testEditorChromeFollowsWindowResize() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let editor = ToolbarTestEditor(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        editor.chromeParentView = container
        container.addSubview(editor)
        editor.applySelection(NSRect(x: 0, y: 0, width: 800, height: 500))
        for size in [NSSize(width: 1400, height: 1000), NSSize(width: 760, height: 520)] {
            container.setFrameSize(size)
            for refit in [false, true] {
                if refit { editor.relayoutEditorChrome() }
                let strips = container.subviews.compactMap { $0 as? ToolbarStripView }.filter { !$0.isHidden }
                let tools = strips.first { $0.presentation == .tools }!
                let actions = strips.first { $0.presentation == .actions }!
                XCTAssertTrue(container.bounds.contains(tools.frame), "\(size): \(tools.frame)")
                XCTAssertTrue(container.bounds.contains(actions.frame), "\(size): \(actions.frame)")
                XCTAssertEqual(tools.frame.midX, container.bounds.midX, accuracy: 1)
                XCTAssertEqual(actions.frame.maxX, container.bounds.maxX - 16, accuracy: 1)
                XCTAssertEqual(actions.frame.maxY, container.bounds.maxY - 48, accuracy: 1)
            }
        }
    }

    func testLegacyPartialPaletteKeepsItsDarkSurface() throws {
        let reset: [String: Any?] = ["toolbarBgColor": nil, "toolbarIconColor": nil, "toolbarAccentColor": nil,
                                     ToolbarLayout.legacyPaletteMigratedKey: nil]
        try withDefaults(reset) {
            // Untouched palettes stay adaptive.
            ToolbarLayout.migrateLegacyPaletteIfNeeded()
            XCTAssertNil(ToolbarLayout.appearance)
            XCTAssertNil(UserDefaults.standard.data(forKey: "toolbarBgColor"))
        }
        try withDefaults(reset) {
            ToolbarLayout.saveIconColor(.white)
            ToolbarLayout.migrateLegacyPaletteIfNeeded()
            XCTAssertEqual(ToolbarLayout.appearance?.name, .darkAqua)
            let bg = try XCTUnwrap(ToolbarLayout.bgColor.usingColorSpace(.deviceRGB))
            XCTAssertEqual(bg.brightnessComponent, 0.12, accuracy: 0.01)
            XCTAssertNotNil(UserDefaults.standard.data(forKey: "toolbarAccentColor"))
            // Once migrated, palettes chosen in Settings are left as set.
            ToolbarLayout.resetColors()
            ToolbarLayout.saveIconColor(.systemBlue)
            ToolbarLayout.migrateLegacyPaletteIfNeeded()
            XCTAssertNil(UserDefaults.standard.data(forKey: "toolbarBgColor"))
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
