import Cocoa
import XCTest

@MainActor
final class ToolbarPresentationTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
    private let notch = NSRect(x: 652, y: 943, width: 208, height: 41)
    private let bar = NSSize(width: 930, height: ToolbarStripView.barHeight)
    private let allEnabled: [String: Any?] = [
        "enabledTools": nil, "knownToolRawValues": nil, "enabledActions": nil, "knownActionTags": nil,
        OverlayView.toolOptionsOpenKey: nil,
    ]

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

    // MARK: - Bar contents

    private func strip(_ buttons: [ToolbarButton], maximumWidth: CGFloat = .greatestFiniteMagnitude) -> ToolbarStripView {
        let strip = ToolbarStripView()
        strip.setButtons(buttons)
        strip.maximumWidth = maximumWidth
        return strip
    }

    private func isEssential(_ button: ToolbarButtonView, _ data: ToolbarButton) -> Bool {
        data.isEssential || button.isOn
    }

    func testEveryEnabledActionStaysReachableAtAnyWidth() throws {
        try withDefaults(allEnabled) {
            for mode in [ToolbarBarMode.overlay, .editor, .recording] {
                let buttons = ToolbarLayout.barButtons(mode: mode, selectedTool: .arrow,
                                                       toolOptions: (title: "3 px", isOpen: false))
                for width in [CGFloat.greatestFiniteMagnitude, 1100, 700, 420, 240] {
                    let bar = strip(buttons, maximumWidth: width)
                    let visible = bar.buttonViews.indices.filter { !bar.buttonViews[$0].isHidden }
                    XCTAssertEqual(Set(visible).union(bar.overflowIndices), Set(buttons.indices), "\(mode) \(width)")
                    XCTAssertTrue(Set(visible).isDisjoint(with: bar.overflowIndices))
                    let menuItems = bar.makeOverflowMenu().items.filter { !$0.isSeparatorItem }
                    XCTAssertEqual(menuItems.count, bar.overflowIndices.count)
                    XCTAssertEqual(bar.overflowButton.isHidden, bar.overflowIndices.isEmpty)
                    for (index, data) in buttons.enumerated() where isEssential(bar.buttonViews[index], data) {
                        XCTAssertFalse(bar.buttonViews[index].isHidden, "\(mode) \(width): \(data.action)")
                    }
                    let essentialsOnly = strip(buttons.filter { $0.isEssential || $0.isSelected })
                    if width >= essentialsOnly.frame.width + ToolbarButtonView.size + 13 {
                        XCTAssertLessThanOrEqual(bar.frame.width, width, "\(mode) \(width)")
                    }
                    XCTAssertEqual(bar.frame.height, ToolbarStripView.barHeight)
                }
            }
        }
    }

    func testOverlayBarKeepsCommonItemsInlineAndRestInMore() throws {
        try withDefaults(allEnabled) {
            let buttons = ToolbarLayout.barButtons(mode: .overlay, selectedTool: .arrow,
                                                   toolOptions: (title: "3 px", isOpen: false))
            let bar = strip(buttons)
            func isInline(_ match: (ToolbarButtonAction) -> Bool) -> Bool {
                bar.buttonViews.contains { match($0.action) && !$0.isHidden }
            }
            XCTAssertTrue(isInline { if case .tool(.arrow) = $0 { return true }; return false })
            XCTAssertTrue(isInline { if case .tool(.text) = $0 { return true }; return false })
            XCTAssertFalse(isInline { if case .tool(.measure) = $0 { return true }; return false })
            XCTAssertTrue(isInline { if case .copy = $0 { return true }; return false })
            XCTAssertTrue(isInline { if case .save = $0 { return true }; return false })
            XCTAssertTrue(isInline { if case .pin = $0 { return true }; return false })
            XCTAssertFalse(isInline { if case .share = $0 { return true }; return false })
            XCTAssertFalse(isInline { if case .detach = $0 { return true }; return false })
            // Copy is the last control and the primary one; sections keep their order.
            XCTAssertEqual(bar.buttonViews.last?.style, .prominent)
            if case .copy = bar.buttonViews.last!.action {} else { XCTFail("Copy should end the bar") }
            let sections = bar.buttonViews.filter { !$0.isHidden }.map(\.section)
            XCTAssertEqual(sections, sections.sorted())

            // A specialist tool in use, and active toggles, come back to the bar.
            let selected = strip(ToolbarLayout.barButtons(mode: .overlay, selectedTool: .measure,
                                                          translateEnabled: true, effectsActive: true))
            XCTAssertTrue(selected.buttonViews.contains { if case .tool(.measure) = $0.action { return !$0.isHidden }; return false })
            XCTAssertTrue(selected.buttonViews.contains { if case .translate = $0.action { return !$0.isHidden }; return false })
            XCTAssertTrue(selected.buttonViews.contains { if case .effects = $0.action { return !$0.isHidden }; return false })
        }
    }

    func testRecordingBarEndsWithCancelAndRecord() {
        let buttons = ToolbarLayout.barButtons(mode: .recording)
        if case .moveSelection = buttons.first!.action {} else { XCTFail("Move leads the bar") }
        if case .startRecord = buttons.last!.action {} else { XCTFail("Record ends the bar") }
        XCTAssertEqual(buttons.last?.style, .prominent)
        if case .stopRecord = buttons[buttons.count - 2].action {} else { XCTFail("Cancel precedes Record") }
        XCTAssertFalse(buttons.contains { if case .copy = $0.action { return true }; return false })
    }

    func testOverflowPreservesActionsContextOptionsAndPopoverAnchor() async {
        var share = ToolbarButton(action: .share, sfSymbol: "square.and.arrow.up", tooltip: "Share")
        share.prefersMenu = true
        var translate = ToolbarButton(action: .translate, sfSymbol: "translate", tooltip: "Translate", hasContextMenu: true)
        translate.prefersMenu = true
        translate.menuGroup = 3
        var copy = ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", tooltip: "Copy")
        copy.section = .finish
        copy.isEssential = true
        let bar = strip([share, translate, copy])
        XCTAssertTrue(bar.anchorView(for: bar.buttonViews[0]) === bar.overflowButton)
        XCTAssertTrue(bar.anchorView(for: bar.buttonViews[2]) === bar.buttonViews[2])
        let menu = bar.makeOverflowMenu()
        XCTAssertEqual(menu.items.map(\.title), ["Share", "", "Translate"])
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        var shared = false
        var optionsAnchor: NSView?
        bar.onClick = { if case .share = $0 { shared = true } }
        bar.onRightClick = { action, anchor in if case .translate = action { optionsAnchor = anchor } }
        let shareItem = menu.items[0]
        _ = bar.perform(shareItem.action!, with: shareItem)
        let option = menu.items[2].submenu!.items[1]
        _ = bar.perform(option.action!, with: option)
        await Task.yield()
        // Menu dispatch deliberately waits until tracking has ended.
        let done = expectation(description: "menu callbacks")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 1)
        XCTAssertTrue(shared)
        XCTAssertTrue(optionsAnchor === bar.overflowButton)
    }

    func testNarrowBarKeepsSelectedToolAndLeadingToolOrder() {
        let data = [AnnotationTool.pencil, .arrow, .rectangle, .ellipse, .marker, .text, .number, .pixelate, .loupe].map {
            var button = ToolbarButton(action: .tool($0), sfSymbol: "pencil", tooltip: String(describing: $0), isSelected: $0 == .loupe)
            button.section = .tools
            button.keepPriority = 50
            return button
        }
        let bar = strip(data, maximumWidth: 250)
        XCTAssertLessThanOrEqual(bar.frame.width, 250)
        XCTAssertFalse(bar.buttonViews.last!.isHidden)
        XCTAssertFalse(bar.buttonViews.first!.isHidden, "leading tools keep their place")
        XCTAssertEqual(bar.makeOverflowMenu().items.count + bar.buttonViews.filter { !$0.isHidden }.count, data.count)
        bar.updateState(from: data.map {
            var button = $0
            button.isSelected = false
            return button
        })
        XCTAssertTrue(bar.buttonViews.last!.isHidden)
    }

    // MARK: - Placement

    func testBarSitsBelowSelectionRightAligned() {
        let selection = NSRect(x: 400, y: 300, width: 600, height: 400)
        let frames = ToolbarPlacement.place(in: screen, around: selection, bar: bar)
        XCTAssertEqual(frames.side, .below)
        XCTAssertEqual(frames.bar.maxX, selection.maxX, accuracy: 0.5)
        XCTAssertEqual(frames.bar.maxY, selection.minY - ToolbarPlacement.barGap, accuracy: 0.5)
        XCTAssertEqual(frames.panel, .zero)
    }

    func testBarFlipsAboveThenInsideAndPanelHangsOutward() {
        let panel = NSSize(width: 520, height: 40)
        let nearBottom = NSRect(x: 300, y: 40, width: 820, height: 300)
        let above = ToolbarPlacement.place(in: screen, around: nearBottom, bar: bar, panel: panel, panelAnchorX: 400)
        XCTAssertEqual(above.side, .above)
        XCTAssertGreaterThan(above.bar.minY, nearBottom.maxY)
        XCTAssertGreaterThanOrEqual(above.panel.minY, above.bar.maxY, "panel sits on the far side")
        XCTAssertEqual(above.panel.midX, above.bar.minX + 400, accuracy: 0.5)

        let below = ToolbarPlacement.place(in: screen, around: NSRect(x: 300, y: 400, width: 820, height: 300),
                                           bar: bar, panel: panel, panelAnchorX: 400)
        XCTAssertEqual(below.side, .below)
        XCTAssertLessThanOrEqual(below.panel.maxY, below.bar.minY)

        let full = ToolbarPlacement.place(in: screen, around: screen, bar: bar, panel: panel, obstacles: [notch])
        XCTAssertEqual(full.side, .inside)
        for frame in [full.bar, full.panel] {
            XCTAssertTrue(screen.contains(frame), "\(frame)")
            XCTAssertFalse(frame.intersects(notch))
        }
        XCTAssertFalse(full.bar.intersects(full.panel))
    }

    func testBarStaysOnScreenAndOffTheSelectionWhenThereIsRoom() {
        let selections = [NSRect(x: 0, y: 300, width: 300, height: 300), NSRect(x: 1300, y: 300, width: 212, height: 300),
                          NSRect(x: 700, y: 60, width: 100, height: 860), NSRect(x: 500, y: 600, width: 400, height: 380)]
        for selection in selections {
            let frames = ToolbarPlacement.place(in: screen, around: selection, bar: bar,
                                                panel: NSSize(width: 600, height: 40), obstacles: [notch])
            XCTAssertTrue(screen.contains(frames.bar), "\(selection): \(frames.bar)")
            XCTAssertTrue(screen.contains(frames.panel), "\(selection): \(frames.panel)")
            XCTAssertFalse(frames.bar.intersects(notch))
            if frames.side != .inside {
                XCTAssertFalse(frames.bar.intersects(selection), "\(selection)")
                XCTAssertFalse(frames.panel.intersects(selection), "\(selection)")
            }
        }
    }

    func testSizePillPrefersTopLeftAndKeepsClearOfChrome() {
        let pill = NSSize(width: 150, height: 30)
        let selection = NSRect(x: 400, y: 300, width: 600, height: 400)
        let above = ToolbarPlacement.placeBadge(size: pill, selection: selection, in: screen)
        XCTAssertEqual(above.minX, selection.minX)
        XCTAssertGreaterThan(above.minY, selection.maxY)

        // No room above: inside the top-left corner, clear of its resize handle.
        let atTop = NSRect(x: 400, y: 600, width: 600, height: 380)
        let inside = ToolbarPlacement.placeBadge(size: pill, selection: atTop, in: screen)
        XCTAssertTrue(atTop.contains(inside))
        XCTAssertGreaterThanOrEqual(inside.minX, atTop.minX + 6)
        XCTAssertLessThanOrEqual(inside.maxY, atTop.maxY - 6)

        // The bar above the selection pushes the pill inside too.
        let barAbove = NSRect(x: 300, y: selection.maxY + 8, width: 930, height: 44)
        let avoided = ToolbarPlacement.placeBadge(size: pill, selection: selection, in: screen, avoiding: [barAbove])
        XCTAssertFalse(avoided.intersects(barAbove))
        XCTAssertTrue(selection.contains(avoided))

        // Under the notch the pill moves out of the camera housing.
        let underNotch = NSRect(x: 700, y: 500, width: 500, height: 430)
        let clearOfNotch = ToolbarPlacement.placeBadge(size: pill, selection: underNotch, in: screen, avoiding: [notch])
        XCTAssertFalse(clearOfNotch.intersects(notch))
    }

    // MARK: - Overlay behaviour

    private func bar(in overlay: NSView) -> ToolbarStripView {
        overlay.subviews.compactMap { $0 as? ToolbarStripView }.first!
    }

    private func panel(in overlay: NSView) -> ToolOptionsRowView? {
        overlay.subviews.compactMap { $0 as? ToolOptionsRowView }.first
    }

    func testSmallSelectionKeepsResolutionAndToolbarsOutsideContent() throws {
        try withDefaults(allEnabled) {
            let overlay = OverlayView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
            let selection = NSRect(x: 540, y: 365, width: 120, height: 70)
            overlay.applySelection(selection)
            overlay.rebuildToolbarLayout()
            let badge = overlay.subviews.compactMap { $0 as? ResolutionBoxView }.first!
            XCTAssertFalse(badge.frame.intersects(selection))
            let toolbar = bar(in: overlay)
            XCTAssertFalse(toolbar.isHidden)
            XCTAssertFalse(toolbar.frame.intersects(selection))
            XCTAssertFalse(toolbar.frame.intersects(badge.frame))
            XCTAssertEqual(overlay.toolbarRect, toolbar.frame)
        }
    }

    func testMovingSelectionTowardBottomKeepsChromeOutsideIt() throws {
        try withDefaults(allEnabled) {
            let overlay = OverlayView(frame: NSRect(x: 0, y: 0, width: 1512, height: 982))
            overlay.applySelection(NSRect(x: 300, y: 400, width: 700, height: 300))
            // Same order as the move-selection drag loop: badge first, then toolbars.
            for y in stride(from: 360, through: 40, by: -40) {
                let selection = NSRect(x: 300, y: CGFloat(y), width: 700, height: 300)
                overlay.applySelection(selection)
                overlay.updateResolutionBox()
                overlay.rebuildToolbarLayout()
                let badge = overlay.subviews.compactMap { $0 as? ResolutionBoxView }.first!
                let toolbar = bar(in: overlay)
                XCTAssertFalse(toolbar.frame.intersects(selection), "y \(y): \(toolbar.frame)")
                XCTAssertFalse(toolbar.frame.intersects(badge.frame), "y \(y): \(toolbar.frame) vs \(badge.frame)")
                XCTAssertFalse(badge.frame.intersects(selection.insetBy(dx: -4, dy: -4)) && !selection.contains(badge.frame),
                               "pill straddles the selection edge at y \(y)")
            }
        }
    }

    func testOptionsChipTogglesRememberedPanel() throws {
        try withDefaults(allEnabled) {
            let overlay = OverlayView(frame: NSRect(x: 0, y: 0, width: 1512, height: 982))
            overlay.currentTool = .arrow
            overlay.applySelection(NSRect(x: 300, y: 400, width: 700, height: 300))
            XCTAssertFalse(overlay.optionsPanelVisible, "closed by default")
            XCTAssertEqual(panel(in: overlay)?.isHidden ?? true, true)
            let chip = bar(in: overlay).buttonViews.first { if case .toolOptions = $0.action { return true }; return false }
            XCTAssertEqual(chip?.title, "\(Int(overlay.activeStrokeWidthForTool(.arrow).rounded())) px")
            XCTAssertEqual(chip?.isOn, false)

            overlay.handleToolbarAction(.toolOptions)
            XCTAssertTrue(overlay.optionsPanelVisible)
            let opened = try XCTUnwrap(panel(in: overlay))
            XCTAssertFalse(opened.isHidden)
            XCTAssertFalse(opened.frame.intersects(bar(in: overlay).frame))
            XCTAssertTrue(UserDefaults.standard.bool(forKey: OverlayView.toolOptionsOpenKey))
            XCTAssertEqual(bar(in: overlay).buttonViews.first { if case .toolOptions = $0.action { return true }; return false }?.isOn, true)

            // Remembered by the next capture.
            let next = OverlayView(frame: NSRect(x: 0, y: 0, width: 1512, height: 982))
            next.currentTool = .rectangle
            next.applySelection(NSRect(x: 300, y: 400, width: 700, height: 300))
            XCTAssertTrue(next.optionsPanelVisible)

            overlay.handleToolbarAction(.toolOptions)
            XCTAssertFalse(overlay.optionsPanelVisible)
            XCTAssertTrue(panel(in: overlay)!.isHidden)
            XCTAssertEqual(overlay.optionsRowRect, .zero)
        }
    }

    func testChipFollowsStrokeWidth() throws {
        try withDefaults(allEnabled) {
            let overlay = OverlayView(frame: NSRect(x: 0, y: 0, width: 1512, height: 982))
            overlay.currentTool = .rectangle
            overlay.applySelection(NSRect(x: 300, y: 400, width: 700, height: 300))
            let original = overlay.activeStrokeWidthForTool(.rectangle)
            defer { overlay.setActiveStrokeWidth(original, for: .rectangle) }
            overlay.setActiveStrokeWidth(9, for: .rectangle)
            overlay.refreshToolOptionsChip()
            let chip = bar(in: overlay).buttonViews.first { if case .toolOptions = $0.action { return true }; return false }
            XCTAssertEqual(chip?.title, "9 px")
            // Tools without options have no chip.
            overlay.handleToolbarAction(.tool(.colorSampler))
            XCTAssertFalse(bar(in: overlay).buttonViews.contains { if case .toolOptions = $0.action { return true }; return false })
        }
    }

    func testBeautifyButtonTogglesItsPanel() throws {
        try withDefaults(allEnabled.merging(["beautifyEnabled": nil]) { $1 }) {
            let overlay = OverlayView(frame: NSRect(x: 0, y: 0, width: 1512, height: 982))
            overlay.currentTool = .arrow
            overlay.applySelection(NSRect(x: 300, y: 400, width: 700, height: 300))
            overlay.handleToolbarAction(.beautify)
            XCTAssertTrue(overlay.showBeautifyInOptionsRow)
            XCTAssertTrue(overlay.optionsPanelVisible)
            let beautify = bar(in: overlay).buttonViews.first { if case .beautify = $0.action { return true }; return false }
            XCTAssertEqual(beautify?.isOn, true)
            XCTAssertFalse(bar(in: overlay).buttonViews.contains { if case .tool = $0.action { return $0.isOn }; return false },
                           "tools read as inactive while Beautify is being set up")
            overlay.handleToolbarAction(.beautify)
            XCTAssertFalse(overlay.showBeautifyInOptionsRow)
            XCTAssertFalse(overlay.optionsPanelVisible)
            // The chip switches straight from Beautify to the tool's options.
            overlay.handleToolbarAction(.beautify)
            overlay.handleToolbarAction(.toolOptions)
            XCTAssertFalse(overlay.showBeautifyInOptionsRow)
            XCTAssertTrue(overlay.optionsPanelVisible)
        }
    }

    func testRecordingSetupShowsRecordingBarWithoutPanel() throws {
        try withDefaults(allEnabled.merging([OverlayView.toolOptionsOpenKey: true]) { $1 }) {
            let overlay = RecordingLabOverlay(frame: NSRect(x: 0, y: 0, width: 1512, height: 982))
            overlay.applySelection(NSRect(x: 300, y: 400, width: 700, height: 300))
            overlay.isRecording = true
            overlay.rebuildToolbarLayout()
            let actions = bar(in: overlay).buttonViews.map(\.action)
            XCTAssertTrue(actions.contains { if case .startRecord = $0 { return true }; return false })
            XCTAssertFalse(actions.contains { if case .tool = $0 { return true }; return false })
            XCTAssertFalse(overlay.optionsPanelVisible)
            XCTAssertTrue(panel(in: overlay)?.isHidden ?? true)
        }
    }

    func testEditorChromeFollowsWindowResize() throws {
        try withDefaults(allEnabled.merging([OverlayView.toolOptionsOpenKey: true]) { $1 }) {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
            let editor = ToolbarTestEditor(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
            editor.chromeParentView = container
            container.addSubview(editor)
            editor.currentTool = .arrow
            editor.applySelection(NSRect(x: 0, y: 0, width: 800, height: 500))
            let toolbar = bar(in: container)
            let options = try XCTUnwrap(panel(in: container))
            XCTAssertFalse(toolbar.buttonViews.contains { if case .cancel = $0.action { return true }; return false })
            for size in [NSSize(width: 1400, height: 1000), NSSize(width: 760, height: 520), NSSize(width: 460, height: 420)] {
                container.setFrameSize(size)
                if size.width > 1000 {
                    // Growing: the autoresizing masks alone keep the chrome centred.
                    XCTAssertEqual(toolbar.frame.midX, container.bounds.midX, accuracy: 1)
                    XCTAssertEqual(toolbar.frame.minY, 16, accuracy: 0.5)
                }
                // windowDidResize re-fits widths (overflow into More) for every size.
                editor.relayoutEditorChrome()
                XCTAssertTrue(container.bounds.contains(toolbar.frame), "\(size): \(toolbar.frame)")
                XCTAssertEqual(toolbar.frame.midX, container.bounds.midX, accuracy: 1)
                XCTAssertEqual(toolbar.frame.minY, 16, accuracy: 0.5)
                XCTAssertFalse(options.isHidden)
                XCTAssertGreaterThanOrEqual(options.frame.minY, toolbar.frame.maxY)
                XCTAssertTrue(container.bounds.contains(options.frame), "\(size): \(options.frame)")
            }
        }
    }

    // MARK: - Options panel

    func testOptionsPanelWrapsGroupsInsteadOfScrolling() {
        let overlay = OverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let row = ToolOptionsRowView(frame: .zero)
        row.overlayView = overlay
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            row.appearance = NSAppearance(named: appearance)
            for tool in [AnnotationTool.arrow, .text, .rectangle, .pixelate, .number, .loupe, .highlight, .stamp] {
                row.rebuild(for: tool)
                for width: CGFloat in [2000, 600, 360, 260] {
                    row.setMaximumWidth(width)
                    let visible = row.subviews.filter { !$0.isHidden }
                    for control in visible {
                        XCTAssertTrue(row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(control.frame),
                                      "\(tool) @\(width): \(control.frame) outside \(row.bounds)")
                    }
                    // Controls never overlap one another.
                    for (i, a) in visible.enumerated() {
                        for b in visible[(i + 1)...] {
                            XCTAssertFalse(a.frame.insetBy(dx: 0.5, dy: 0.5).intersects(b.frame.insetBy(dx: 0.5, dy: 0.5)),
                                           "\(tool) @\(width): \(a) overlaps \(b)")
                        }
                    }
                    if width >= row.contentWidth { XCTAssertEqual(row.lineCount, 1, "\(tool) @\(width)") }
                    XCTAssertFalse(row.subviews.contains { $0 is NSScrollView })
                }
            }
        }
    }

    func testOptionsPanelGapsPassThroughInEditor() {
        let overlay = ToolbarTestEditor(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let row = ToolOptionsRowView(frame: .zero)
        row.overlayView = overlay
        overlay.addSubview(row)
        row.rebuild(for: .text)
        row.frame.origin = NSPoint(x: 30, y: 30)
        XCTAssertNil(row.hitTest(NSPoint(x: 31, y: 31)), "editor gaps reach the canvas")
        let plain = OverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let overlayRow = ToolOptionsRowView(frame: .zero)
        overlayRow.overlayView = plain
        plain.addSubview(overlayRow)
        overlayRow.rebuild(for: .text)
        overlayRow.frame.origin = NSPoint(x: 30, y: 30)
        XCTAssertTrue(overlayRow.hitTest(NSPoint(x: 31, y: 31)) === overlayRow, "overlay gaps stay on the panel")
    }
}

@MainActor
private final class ToolbarTestEditor: OverlayView {
    override var isEditorMode: Bool { true }
}

@MainActor
private final class RecordingLabOverlay: OverlayView {
    override var hasRecordingInputMonitoringPermission: Bool { true }
}
