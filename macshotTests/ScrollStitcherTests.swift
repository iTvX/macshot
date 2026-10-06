import CoreGraphics
import XCTest

/// Scroll capture's stitching, end to end on synthetic pages: a long document
/// seen through a viewport with a pinned header, a pinned footer and a
/// scrollbar whose thumb moves. Every test compares the stitched image with the
/// page itself, row by row.
final class ScrollStitcherTests: XCTestCase {

    // MARK: - Synthetic page

    /// A page `rows` tall, viewed `height` rows at a time.
    struct Page {
        var width = 160
        var height = 240
        var header = 0
        var footer = 0
        var scrollbar = 10
        var rows = 3000
        /// Page rows drawn blank, like the gaps between paragraphs.
        var blankRows: Set<Int> = []
        /// The footer is translucent: the page shows through it, washed out.
        var translucentFooter = false
        /// Columns at the left that never scroll (a sidebar).
        var sidebar = 0
        /// Every page row drawn as two identical pixel rows, as on Retina.
        var retina = false

        /// The colour of page row `row` at column `x`: distinct for every row,
        /// with text-like variation across it.
        func pageColour(row pixelRow: Int, x: Int) -> (UInt8, UInt8, UInt8) {
            let row = retina ? pixelRow / 2 : pixelRow
            if blankRows.contains(row) { return (250, 250, 250) }
            let seed = UInt32(truncatingIfNeeded: row &* 2654435761) ^ UInt32(truncatingIfNeeded: (x / 5) &* 40503)
            let v = seed ^ (seed >> 13)
            return (UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16))
        }

        func headerColour(row: Int, x: Int) -> (UInt8, UInt8, UInt8) {
            (30, UInt8(truncatingIfNeeded: 40 + row * 3), UInt8(truncatingIfNeeded: x))
        }

        func footerColour(row: Int, x: Int) -> (UInt8, UInt8, UInt8) {
            (UInt8(truncatingIfNeeded: 200 - row * 2), 60, UInt8(truncatingIfNeeded: 255 - x))
        }

        /// The page seen through a translucent bar: washed out.
        func veiled(_ c: (UInt8, UInt8, UInt8)) -> (UInt8, UInt8, UInt8) {
            (UInt8((Int(c.0) + 3 * 220) / 4), UInt8((Int(c.1) + 3 * 220) / 4), UInt8((Int(c.2) + 3 * 220) / 4))
        }

        func sidebarColour(y: Int, x: Int) -> (UInt8, UInt8, UInt8) {
            (UInt8(truncatingIfNeeded: y * 7 + x), 90, UInt8(truncatingIfNeeded: y * 3))
        }

        /// What the viewport shows when scrolled to `position`.
        func colour(position: Int, y: Int, x: Int) -> (UInt8, UInt8, UInt8) {
            if scrollbar > 0 && x >= width - scrollbar {
                let thumbTop = 10 + position * (height - 60) / max(1, rows)
                return (y >= thumbTop && y < thumbTop + 40) ? (90, 90, 90) : (235, 235, 235)
            }
            if x < sidebar { return sidebarColour(y: y, x: x) }
            if y < header { return headerColour(row: y, x: x) }
            if y >= height - footer {
                return translucentFooter ? veiled(pageColour(row: position + y, x: x))
                                         : footerColour(row: y - (height - footer), x: x)
            }
            return pageColour(row: position + y, x: x)
        }

        /// The stitched page after scrolling as far as `furthest`, without
        /// the scrollbar columns (they differ from strip to strip).
        func expectedRow(_ row: Int, furthest: Int, x: Int) -> (UInt8, UInt8, UInt8) {
            let contentEnd = furthest + height - footer
            if row < header { return headerColour(row: row, x: x) }
            if row < contentEnd { return pageColour(row: row, x: x) }
            // The footer comes from the furthest frame; through a translucent
            // bar that frame shows the page rows just past the content.
            return translucentFooter ? veiled(pageColour(row: row, x: x)) : footerColour(row: row - contentEnd, x: x)
        }

        func image(at position: Int, rowPadding: Int = 0, tweak: ((Int, Int, inout (UInt8, UInt8, UInt8)) -> Void)? = nil) -> CGImage {
            let bytesPerRow = width * 4 + rowPadding
            var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
            for y in 0..<height {
                for x in 0..<width {
                    var c = colour(position: position, y: y, x: x)
                    tweak?(x, y, &c)
                    let o = y * bytesPerRow + x * 4
                    bytes[o] = c.2; bytes[o + 1] = c.1; bytes[o + 2] = c.0; bytes[o + 3] = 255
                }
            }
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: ScrollFrameAnalyzer.bitmapInfo, provider: provider,
                           decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }

        func frame(at position: Int, tweak: ((Int, Int, inout (UInt8, UInt8, UInt8)) -> Void)? = nil) -> ScrollFrameAnalyzer.Frame {
            ScrollFrameAnalyzer.frame(from: image(at: position, tweak: tweak))!
        }
    }

    private func makeStitcher(_ page: Page, maximumHeight: Int = 100_000, separatesFooter: Bool = true,
                              previewWidth: Int = 40) throws -> ScrollStitcher {
        let configuration = ScrollStitcher.Configuration(
            maximumHeight: maximumHeight, separatesPinnedFooter: separatesFooter,
            scrollbarAllowance: page.scrollbar + 2, previewWidth: previewWidth)
        return try XCTUnwrap(ScrollStitcher(firstFrame: page.frame(at: 0), configuration: configuration))
    }

    @discardableResult
    private func feed(_ stitcher: ScrollStitcher, _ page: Page, position: Int,
                      tweak: ((Int, Int, inout (UInt8, UInt8, UInt8)) -> Void)? = nil) -> ScrollStitcher.Outcome {
        let frame = page.frame(at: position, tweak: tweak)
        return stitcher.process(frame, signature: stitcher.signature(for: frame))
    }

    /// The frame was placed `step` rows further down. How many rows that adds
    /// depends on what came before (nothing is added until the pinned rows
    /// are known), so only the final image is checked for those.
    private func assertMoved(_ outcome: ScrollStitcher.Outcome, by step: Int,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard case .scrolled(let shift, _) = outcome else {
            return XCTFail("expected a scroll of \(step), got \(outcome)", file: file, line: line)
        }
        XCTAssertEqual(shift, step, file: file, line: line)
    }

    /// Compares the stitched image with the page, ignoring scrollbar columns.
    private func assertStitched(_ image: CGImage?, _ page: Page, furthest: Int,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(image, file: file, line: line)
        let expectedHeight = furthest + page.height
        XCTAssertEqual(image.width, page.width, file: file, line: line)
        XCTAssertEqual(image.height, expectedHeight, "stitched height", file: file, line: line)
        guard image.height == expectedHeight else { return }
        let frame = try XCTUnwrap(ScrollFrameAnalyzer.frame(from: image), file: file, line: line)
        var mismatches = 0
        var firstMismatch: Int?
        frame.withPixels { base in
            for row in 0..<image.height {
                for x in stride(from: page.sidebar, to: page.width - page.scrollbar, by: 3) {
                    let expected = page.expectedRow(row, furthest: furthest, x: x)
                    let o = row * frame.bytesPerRow + x * 4
                    if base[o + 2] != expected.0 || base[o + 1] != expected.1 || base[o] != expected.2 {
                        mismatches += 1
                        if firstMismatch == nil { firstMismatch = row }
                        break
                    }
                }
            }
        }
        XCTAssertEqual(mismatches, 0, "rows differ from the page, first at row \(firstMismatch ?? -1)",
                       file: file, line: line)
    }

    // MARK: - Stitching

    func testScrollingDownStitchesThePageExactly() throws {
        var page = Page()
        page.header = 24
        page.footer = 30
        let stitcher = try makeStitcher(page)
        var position = 0
        for step in [37, 120, 5, 150, 90, 1, 63, 170] {
            position += step
            assertMoved(feed(stitcher, page, position: position), by: step)
        }
        XCTAssertEqual(stitcher.footerHeight, 30)
        XCTAssertEqual(stitcher.headerHeight, 24)
        XCTAssertEqual(stitcher.scrollingHeight, page.height - 24 - 30)
        try assertStitched(stitcher.makeImage(), page, furthest: position)
    }

    func testAPageWithoutPinnedRowsStitchesExactly() throws {
        let page = Page()
        let stitcher = try makeStitcher(page)
        var position = 0
        for step in [60, 60, 200, 13, 99] {
            position += step
            feed(stitcher, page, position: position)
        }
        try assertStitched(stitcher.makeImage(), page, furthest: position)
    }

    func testScrollingBackUpNeverDuplicatesContent() throws {
        var page = Page()
        page.header = 20
        page.footer = 16
        let stitcher = try makeStitcher(page)
        // Down, back up past the start, down again beyond the furthest point.
        for position in [100, 220, 140, 30, 0, 90, 260, 400, 330, 480] {
            let outcome = feed(stitcher, page, position: position)
            if case .scrolled = outcome {} else { XCTFail("position \(position): \(outcome)") }
        }
        try assertStitched(stitcher.makeImage(), page, furthest: 480)
    }

    func testScrollingAboveTheFirstFrameAddsNothing() throws {
        let page = Page()
        let configuration = ScrollStitcher.Configuration(
            maximumHeight: 100_000, separatesPinnedFooter: true, scrollbarAllowance: 12, previewWidth: 0)
        let stitcher = try XCTUnwrap(ScrollStitcher(firstFrame: page.frame(at: 500), configuration: configuration))
        let frame = page.frame(at: 420)
        XCTAssertEqual(stitcher.process(frame, signature: stitcher.signature(for: frame)),
                       .scrolled(shift: -80, appendedRows: 0))
        XCTAssertEqual(stitcher.outputHeight, page.height)
    }

    func testAFrameThatCantBePlacedIsSetAsideUntilTrackingResumes() throws {
        var page = Page()
        page.footer = 20
        let stitcher = try makeStitcher(page)
        feed(stitcher, page, position: 100)
        // Further than a screen in one go: no overlap with the last frame.
        XCTAssertEqual(feed(stitcher, page, position: 100 + page.height + 40), .lost)
        XCTAssertTrue(stitcher.isLost)
        XCTAssertEqual(stitcher.outputHeight, 100 + page.height, "nothing may be glued on across the gap")
        // Scrolling back to where the last placed frame overlaps carries on.
        XCTAssertEqual(feed(stitcher, page, position: 180), .scrolled(shift: 80, appendedRows: 80))
        XCTAssertFalse(stitcher.isLost)
        feed(stitcher, page, position: 300)
        try assertStitched(stitcher.makeImage(), page, furthest: 300)
    }

    func testRetinaLinesStitchWithoutSeams() throws {
        // Found on a real capture: with every line two identical pixel rows,
        // seams came out a pixel row off.
        var page = Page()
        page.retina = true
        page.header = 20
        page.footer = 24
        let stitcher = try makeStitcher(page)
        var position = 0
        for step in [57, 28, 84, 1, 112, 33] {
            position += step
            assertMoved(feed(stitcher, page, position: position), by: step)
        }
        try assertStitched(stitcher.makeImage(), page, furthest: position)
    }

    func testATranslucentFooterIsKeptOutOfTheStrips() throws {
        var page = Page()
        page.footer = 36
        page.translucentFooter = true
        let stitcher = try makeStitcher(page)
        var position = 0
        for step in [70, 45, 120] {
            position += step
            feed(stitcher, page, position: position)
        }
        XCTAssertEqual(stitcher.footerHeight, 36, "a bar showing the page through it is still a footer")
        try assertStitched(stitcher.makeImage(), page, furthest: position)
    }

    func testASlowStartStillFindsATranslucentFooter() throws {
        // A pixel or two per grab barely changes a translucent bar, so the
        // pinned rows wait until the page has moved far enough from the start.
        var page = Page()
        page.footer = 30
        page.translucentFooter = true
        let stitcher = try makeStitcher(page)
        var position = 0
        for step in [1, 1, 2, 3, 5, 8] {
            position += step
            XCTAssertEqual(feed(stitcher, page, position: position), .scrolled(shift: step, appendedRows: 0),
                           "nothing is appended before the pinned rows are known")
        }
        XCTAssertNil(stitcher.footerHeight)
        position += 40
        XCTAssertEqual(feed(stitcher, page, position: position), .scrolled(shift: 40, appendedRows: 60))
        XCTAssertEqual(stitcher.footerHeight, 30)
        position += 75
        feed(stitcher, page, position: position)
        try assertStitched(stitcher.makeImage(), page, furthest: position)
    }

    func testOnlyAFewPixelsOfScrollingKeepTheFirstFrame() throws {
        var page = Page()
        page.footer = 20
        let stitcher = try makeStitcher(page)
        feed(stitcher, page, position: 3)
        feed(stitcher, page, position: 5)
        try assertStitched(stitcher.makeImage(), page, furthest: 0)
    }

    func testASidebarInTheSelectionDoesNotBreakStitching() throws {
        var page = Page()
        page.sidebar = 30
        page.footer = 16
        let stitcher = try makeStitcher(page)
        var position = 0
        for step in [64, 9, 140, 77] {
            position += step
            assertMoved(feed(stitcher, page, position: position), by: step)
        }
        try assertStitched(stitcher.makeImage(), page, furthest: position)
    }

    func testAnUnmovedFrameChangesNothing() throws {
        let page = Page()
        let stitcher = try makeStitcher(page)
        XCTAssertEqual(feed(stitcher, page, position: 0), .unchanged)
        XCTAssertEqual(stitcher.outputHeight, page.height)
        try assertStitched(stitcher.makeImage(), page, furthest: 0)
    }

    func testABlinkingCaretDoesNotCountAsMovement() throws {
        let page = Page()
        let stitcher = try makeStitcher(page)
        let caret: (Int, Int, inout (UInt8, UInt8, UInt8)) -> Void = { x, y, c in
            if x >= 50 && x < 52 && y >= 100 && y < 120 { c = (0, 0, 0) }
        }
        XCTAssertEqual(feed(stitcher, page, position: 0, tweak: caret), .unchanged)
    }

    func testAnAnimatedBlockDoesNotStopAlignment() throws {
        var page = Page()
        page.height = 400
        let stitcher = try makeStitcher(page)
        var position = 0
        for (index, step) in [40, 70, 55, 160].enumerated() {
            position += step
            // A spinner pinned to the same spot of the screen, in a new state each frame.
            let spinner: (Int, Int, inout (UInt8, UInt8, UInt8)) -> Void = { x, y, c in
                if x >= 20 && x < 44 && y >= 150 && y < 174 { c = (UInt8(index * 60), 0, 255) }
            }
            assertMoved(feed(stitcher, page, position: position, tweak: spinner), by: step)
        }
    }

    func testBlankStretchesStillStitchExactly() throws {
        var page = Page()
        page.blankRows = Set(300..<420).union(600..<640)
        page.footer = 12
        let stitcher = try makeStitcher(page)
        var position = 0
        for step in [80, 80, 80, 80, 80, 80, 80, 80] {
            position += step
            XCTAssertNotEqual(feed(stitcher, page, position: position), .lost, "position \(position)")
        }
        try assertStitched(stitcher.makeImage(), page, furthest: position)
    }

    func testThePageStopsAtTheHeightLimit() throws {
        let page = Page()
        let limit = page.height + 150
        let stitcher = try makeStitcher(page, maximumHeight: limit)
        XCTAssertEqual(feed(stitcher, page, position: 100), .scrolled(shift: 100, appendedRows: 100))
        XCTAssertEqual(feed(stitcher, page, position: 200), .limitReached)
        XCTAssertEqual(feed(stitcher, page, position: 210), .limitReached, "a full page takes nothing more")
        try assertStitched(stitcher.makeImage(), page, furthest: 100)
    }

    func testTheFirstFrameIsKeptWholeEvenAboveTheLimit() throws {
        let page = Page()
        let stitcher = try makeStitcher(page, maximumHeight: 50)
        XCTAssertEqual(feed(stitcher, page, position: 90), .limitReached)
        try assertStitched(stitcher.makeImage(), page, furthest: 0)
    }

    func testFooterSeparationCanBeTurnedOff() throws {
        var page = Page()
        page.footer = 20
        let stitcher = try makeStitcher(page, separatesFooter: false)
        feed(stitcher, page, position: 90)
        XCTAssertEqual(stitcher.footerHeight, 0)
    }

    func testFramesOfAnotherSizeAreRejected() throws {
        let page = Page()
        let stitcher = try makeStitcher(page)
        var other = page
        other.height = 200
        let frame = other.frame(at: 10)
        XCTAssertEqual(stitcher.process(frame, signature: stitcher.signature(for: frame)), .rejected)
        XCTAssertEqual(stitcher.outputHeight, page.height)
    }

    func testPaddedRowsStitchLikeTightOnes() throws {
        var page = Page()
        page.footer = 18
        let configuration = ScrollStitcher.Configuration(
            maximumHeight: 100_000, separatesPinnedFooter: true, scrollbarAllowance: 12, previewWidth: 0)
        let first = try XCTUnwrap(ScrollFrameAnalyzer.frame(from: page.image(at: 0, rowPadding: 52)))
        XCTAssertEqual(first.bytesPerRow, page.width * 4 + 52, "already-native frames keep their stride")
        let stitcher = try XCTUnwrap(ScrollStitcher(firstFrame: first, configuration: configuration))
        for position in [70, 140, 260] {
            let frame = try XCTUnwrap(ScrollFrameAnalyzer.frame(from: page.image(at: position, rowPadding: 52)))
            XCTAssertEqual(stitcher.process(frame, signature: stitcher.signature(for: frame)),
                           .scrolled(shift: position == 260 ? 120 : 70, appendedRows: position == 260 ? 120 : 70))
        }
        try assertStitched(stitcher.makeImage(), page, furthest: 260)
    }

    // MARK: - Preview

    func testThePreviewFollowsTheStitchedPage() throws {
        var page = Page()
        page.footer = 20
        let stitcher = try makeStitcher(page, previewWidth: 40)
        var position = 0
        for step in [100, 100, 100] {
            position += step
            feed(stitcher, page, position: position)
        }
        let preview = try XCTUnwrap(stitcher.makePreviewImage())
        XCTAssertEqual(preview.width, 40)
        let expected = Double(stitcher.outputHeight) * 40 / Double(page.width)
        XCTAssertEqual(Double(preview.height), expected, accuracy: 2)
    }

    // MARK: - Engine

    func testTheEngineStitchesFromRawGrabs() async throws {
        var page = Page()
        page.header = 16
        page.footer = 24
        let engine = ScrollCaptureEngine(heightPreference: 0, separatesPinnedFooter: true,
                                         scrollbarAllowance: 12, previewWidth: 40)
        _ = await engine.ingest(page.image(at: 0), stitch: false)
        let second = await engine.ingest(page.image(at: 0), stitch: false)
        XCTAssertTrue(second.isSettled, "two identical grabs mean the page is at rest")
        let begun = await engine.beginWithLatest()
        XCTAssertNotNil(begun?.preview)
        var position = 0
        for step in [90, 45, 160] {
            position += step
            let report = await engine.ingest(page.image(at: position), stitch: true)
            XCTAssertEqual(report.outcome, .scrolled(shift: step, appendedRows: step))
            XCTAssertFalse(report.isSettled)
        }
        let image = await engine.finish()
        try assertStitched(image, page, furthest: position)
        let afterFinish = await engine.finish()
        XCTAssertNil(afterFinish, "a finished engine has nothing more to give")
    }

    func testADiscardedEngineIgnoresEverything() async throws {
        let page = Page()
        let engine = ScrollCaptureEngine(heightPreference: 0, separatesPinnedFooter: true,
                                         scrollbarAllowance: 12, previewWidth: 0)
        _ = await engine.ingest(page.image(at: 0), stitch: false)
        _ = await engine.beginWithLatest()
        engine.discard()
        let report = await engine.ingest(page.image(at: 50), stitch: true)
        XCTAssertNil(report.outcome)
        let image = await engine.finish()
        XCTAssertNil(image)
    }

    func testHeightLimitHonoursThePreferenceWithinHardCeilings() {
        XCTAssertEqual(ScrollCaptureEngine.heightLimit(preference: 30_000, width: 2000), 30_000)
        XCTAssertEqual(ScrollCaptureEngine.heightLimit(preference: 0, width: 100), ScrollCaptureEngine.maximumRows)
        XCTAssertEqual(ScrollCaptureEngine.heightLimit(preference: 0, width: 6000),
                       ScrollCaptureEngine.maximumBytes / (6000 * 4), "unlimited still stops at 1 GiB")
        XCTAssertEqual(ScrollCaptureEngine.heightLimit(preference: 500_000, width: 100), ScrollCaptureEngine.maximumRows)
    }
}
