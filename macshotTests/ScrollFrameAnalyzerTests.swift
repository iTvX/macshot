import Cocoa
import XCTest

/// The pixel arithmetic behind scroll capture: normalising frames whatever
/// their layout, summarising rows, telling scrolling apart from local changes,
/// and finding the offset between two frames. Get the offset wrong by a row and
/// every seam of the stitched image shows it.
final class ScrollFrameAnalyzerTests: XCTestCase {

    private let layouts: [(CGImageAlphaInfo, CGBitmapInfo, [Int])] = [
        (.premultipliedFirst, .byteOrder32Little, [2, 1, 0]), // BGRA
        (.premultipliedFirst, .byteOrder32Big, [1, 2, 3]),    // ARGB
        (.premultipliedLast, .byteOrder32Little, [3, 2, 1]),  // ABGR
        (.premultipliedLast, .byteOrder32Big, [0, 1, 2]),     // RGBA
        (.noneSkipFirst, .byteOrder32Big, [1, 2, 3]),
        (.noneSkipLast, .byteOrder32Little, [3, 2, 1]),
        (.premultipliedFirst, .byteOrderDefault, [1, 2, 3]),
        (.premultipliedLast, .byteOrderDefault, [0, 1, 2]),
    ]

    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func layoutImage(_ layout: (CGImageAlphaInfo, CGBitmapInfo, [Int]), width: Int = 80, height: Int = 40,
                             rowPadding: Int = 16, unused: UInt8 = 255,
                             pixel: (Int, Int) -> [UInt8]) throws -> CGImage {
        let stride = width * 4 + rowPadding
        var bytes = [UInt8](repeating: unused, count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                let rgb = pixel(x, y)
                for component in 0..<3 { bytes[y * stride + x * 4 + layout.2[component]] = rgb[component] }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: stride, space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: layout.0.rawValue | layout.1.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixel(_ frame: ScrollFrameAnalyzer.Frame, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        frame.withPixels { base in
            let o = y * frame.bytesPerRow + x * 4
            return (base[o + 2], base[o + 1], base[o])
        }
    }

    /// Rows that differ from one another, like lines of text.
    private func textured(row: Int, x: Int) -> (UInt8, UInt8, UInt8) {
        let seed = UInt32(truncatingIfNeeded: row &* 2654435761) ^ UInt32(truncatingIfNeeded: (x / 4) &* 40503)
        let v = seed ^ (seed >> 15)
        return (UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16))
    }

    /// A native-layout frame whose rows come from `colour(row, x)`.
    private func frame(width: Int = 400, height: Int = 200,
                       colour: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> ScrollFrameAnalyzer.Frame {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = colour(y, x)
                let o = (y * width + x) * 4
                bytes[o] = c.2; bytes[o + 1] = c.1; bytes[o + 2] = c.0; bytes[o + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: sRGB, bitmapInfo: ScrollFrameAnalyzer.bitmapInfo, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try XCTUnwrap(ScrollFrameAnalyzer.frame(from: image))
    }

    /// The page scrolled to `position`, with optional pinned bands.
    private func page(_ position: Int, header: Int = 0, footer: Int = 0, height: Int = 200) throws -> ScrollFrameAnalyzer.Frame {
        try frame(height: height) { y, x in
            if y < header { return (20, UInt8(truncatingIfNeeded: y * 5), 40) }
            if y >= height - footer { return (200, 30, UInt8(truncatingIfNeeded: y * 3)) }
            return self.textured(row: position + y, x: x)
        }
    }

    private func signature(_ frame: ScrollFrameAnalyzer.Frame) -> ScrollFrameAnalyzer.RowSignature {
        ScrollFrameAnalyzer.signature(of: frame, columns: 0..<frame.width)
    }

    private func align(_ reference: ScrollFrameAnalyzer.Frame, _ current: ScrollFrameAnalyzer.Frame,
                       preferred: Int? = nil) -> ScrollFrameAnalyzer.Alignment? {
        // The same steps the stitcher takes.
        let a = signature(reference), b = signature(current)
        let comparison = ScrollFrameAnalyzer.compare(a, b)
        guard let estimate = ScrollFrameAnalyzer.alignment(reference: a, current: b,
                                                           unchanged: comparison.unchanged,
                                                           movingBins: comparison.movingBins,
                                                           preferredShift: preferred) else { return nil }
        let columns = ScrollFrameAnalyzer.columns(of: b, movingBins: estimate.bins ?? comparison.movingBins)
        return ScrollFrameAnalyzer.verify(estimate, reference: reference, current: current,
                                          unchanged: comparison.unchanged, columns: columns)
    }

    // MARK: - Normalisation

    func testEveryByteLayoutNormalisesToTheSameColours() throws {
        for layout in layouts {
            let image = try layoutImage(layout) { x, y in [UInt8(x * 3), UInt8(y * 5), 120] }
            let frame = try XCTUnwrap(ScrollFrameAnalyzer.frame(from: image), "\(layout)")
            for (x, y) in [(0, 0), (79, 39), (13, 27)] {
                let c = pixel(frame, x: x, y: y)
                XCTAssertEqual(c.0, UInt8(x * 3), "red, layout \(layout)")
                XCTAssertEqual(c.1, UInt8(y * 5), "green, layout \(layout)")
                XCTAssertEqual(c.2, 120, "blue, layout \(layout)")
            }
        }
    }

    func testNativeFramesKeepTheirPaddedStride() throws {
        let image = try layoutImage(layouts[0], rowPadding: 28) { x, _ in [UInt8(x), 0, 0] }
        let frame = try XCTUnwrap(ScrollFrameAnalyzer.frame(from: image))
        XCTAssertEqual(frame.bytesPerRow, 80 * 4 + 28, "rows must be addressed through the image's own stride")
        XCTAssertEqual(pixel(frame, x: 70, y: 39).0, 70)
    }

    func testOtherLayoutsAreRedrawnIntoTightRows() throws {
        let image = try layoutImage(layouts[3], rowPadding: 44) { x, y in [UInt8(x), UInt8(y), 9] }
        let frame = try XCTUnwrap(ScrollFrameAnalyzer.frame(from: image))
        XCTAssertEqual(frame.bytesPerRow, 80 * 4)
        XCTAssertEqual(pixel(frame, x: 33, y: 21).0, 33)
        XCTAssertEqual(pixel(frame, x: 33, y: 21).1, 21)
    }

    func testTheUnusedByteDoesNotLeakIntoColours() throws {
        for layout in layouts where layout.0 == .noneSkipFirst || layout.0 == .noneSkipLast {
            let a = try layoutImage(layout, unused: 0) { _, _ in [40, 80, 120] }
            let b = try layoutImage(layout, unused: 255) { _, _ in [40, 80, 120] }
            let fa = try XCTUnwrap(ScrollFrameAnalyzer.frame(from: a))
            let fb = try XCTUnwrap(ScrollFrameAnalyzer.frame(from: b))
            XCTAssertTrue(ScrollFrameAnalyzer.compare(signature(fa), signature(fb)).isIdentical)
        }
    }

    func testGrayscaleFramesAreConvertedRatherThanMisread() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 10,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let frame = try XCTUnwrap(ScrollFrameAnalyzer.frame(from: try XCTUnwrap(context.makeImage())))
        XCTAssertEqual(frame.bytesPerRow, 40, "an 8-bit buffer must be converted, not indexed as BGRA")
        XCTAssertEqual(frame.colorSpace.model, .rgb)
        XCTAssertGreaterThan(pixel(frame, x: 5, y: 5).0, 240)
    }

    func testTinyFramesAreHandled() throws {
        for size in [1, 2, 3, 5] {
            let a = try frame(width: size, height: size) { y, x in (UInt8(x * 10), UInt8(y), 0) }
            let b = try frame(width: size, height: size) { y, x in (UInt8(x * 20), 0, UInt8(y)) }
            let sa = signature(a), sb = signature(b)
            XCTAssertEqual(sa.rows, size)
            _ = ScrollFrameAnalyzer.compare(sa, sb)
            XCTAssertNil(ScrollFrameAnalyzer.alignment(reference: sa, current: sb,
                                                       unchanged: ScrollFrameAnalyzer.unchangedRows(sa, sb)))
        }
    }

    // MARK: - Row signatures

    func testBlankRowsCarryNoInformationButEdgesDo() throws {
        let f = try frame { y, x in
            if y == 50 { return (100, 100, 100) }              // a rule across the page
            if y >= 100 { return self.textured(row: y, x: x) } // text
            return (255, 255, 255)                             // margin
        }
        let s = signature(f)
        XCTAssertFalse(s.informative[10], "a blank row matches anything")
        XCTAssertTrue(s.informative[50], "a uniform rule still marks a position")
        XCTAssertTrue(s.informative[49] && s.informative[51], "so do the rows beside it")
        XCTAssertTrue(s.informative[150])
    }

    func testMatchingColumnsLeaveOutTheScrollbarButNeverEverything() {
        XCTAssertEqual(ScrollFrameAnalyzer.matchingColumns(width: 1000, scrollbarAllowance: 36), 0..<964)
        XCTAssertEqual(ScrollFrameAnalyzer.matchingColumns(width: 80, scrollbarAllowance: 36), 0..<70,
                       "a narrow frame keeps most of its width")
        XCTAssertEqual(ScrollFrameAnalyzer.matchingColumns(width: 1, scrollbarAllowance: 36), 0..<1)
    }

    // MARK: - Rest and motion

    func testIdenticalFramesAreAtRest() throws {
        let a = try page(0)
        let comparison = ScrollFrameAnalyzer.compare(signature(a), signature(a))
        XCTAssertTrue(comparison.isAtRest)
        XCTAssertTrue(comparison.isIdentical)
    }

    func testALocalChangeIsNotScrolling() throws {
        let a = try page(0)
        // A caret and a spinner: a few rows change, the page doesn't move.
        let b = try frame { y, x in
            if (x >= 40 && x < 42 && y >= 60 && y < 80) || (x >= 280 && x < 340 && y >= 120 && y < 135) {
                return (0, 0, 0)
            }
            return self.textured(row: y, x: x)
        }
        let comparison = ScrollFrameAnalyzer.compare(signature(a), signature(b))
        XCTAssertTrue(comparison.isAtRest)
        XCTAssertFalse(comparison.isIdentical, "it did change, so it can't stand in for the reference")
    }

    func testScrollingASparsePageIsStillMotion() throws {
        // Mostly blank: only every tenth row has content. Scrolling changes
        // few rows overall, but nearly all of the rows that matter.
        func sparse(_ position: Int) throws -> ScrollFrameAnalyzer.Frame {
            try frame { y, x in (position + y) % 10 == 0 ? self.textured(row: position + y, x: x) : (250, 250, 250) }
        }
        let comparison = ScrollFrameAnalyzer.compare(signature(try sparse(0)), signature(try sparse(23)))
        XCTAssertFalse(comparison.isAtRest)
    }

    func testPinnedBandsAreCountedFromBothEdges() {
        let unchanged = [true, true, false, false, true, false, true, true, true]
        let bands = ScrollFrameAnalyzer.pinnedBands(unchanged)
        XCTAssertEqual(bands.top, 2)
        XCTAssertEqual(bands.bottom, 3)
        XCTAssertEqual(ScrollFrameAnalyzer.pinnedBands([true, true]).top, 2)
        XCTAssertEqual(ScrollFrameAnalyzer.pinnedBands([true, true]).bottom, 0)
    }

    // MARK: - Alignment

    func testAlignmentFindsTheExactOffsetEitherWay() throws {
        let reference = try page(500)
        for shift in [1, 2, 7, 40, 99, 150, 180, -1, -33, -120, -185] {
            let current = try page(500 + shift)
            let alignment = try XCTUnwrap(align(reference, current), "shift \(shift)")
            XCTAssertEqual(alignment.shift, shift)
            XCTAssertGreaterThan(alignment.agreement, 0.95)
        }
    }

    func testPinnedHeaderAndFooterDoNotDragTheOffset() throws {
        let reference = try page(0, header: 30, footer: 40)
        for shift in [5, 64, 110] {
            let current = try page(shift, header: 30, footer: 40)
            XCTAssertEqual(align(reference, current)?.shift, shift)
        }
    }

    func testFramesWithoutOverlapDoNotAlign() throws {
        XCTAssertNil(align(try page(0), try page(5000)), "unrelated content must not be forced into an offset")
        XCTAssertNil(align(try page(0), try page(200)), "a full screen apart leaves nothing to compare")
    }

    func testABlankPageCannotBeAligned() throws {
        let blank = try frame { _, _ in (255, 255, 255) }
        let a = signature(blank)
        XCTAssertNil(ScrollFrameAnalyzer.alignment(reference: a, current: a,
                                                   unchanged: [Bool](repeating: false, count: a.rows)))
    }

    func testRepeatingContentPrefersTheExpectedOffset() throws {
        // Identical blocks every 50 rows: offsets 20 and 70 look the same.
        func stripes(_ position: Int) throws -> ScrollFrameAnalyzer.Frame {
            try frame { y, x in self.textured(row: (position + y) % 50, x: x) }
        }
        let reference = try stripes(0)
        let current = try stripes(20)
        XCTAssertEqual(align(reference, current, preferred: 20)?.shift, 20)
        XCTAssertEqual(align(reference, current, preferred: 70)?.shift, 70)
        XCTAssertEqual(align(reference, current)?.shift, 20, "without an expectation, the smaller move")
    }

    func testVerificationSettlesAnOffByOneEstimate() throws {
        let reference = try page(0)
        let current = try page(37)
        let a = signature(reference), b = signature(current)
        let unchanged = ScrollFrameAnalyzer.compare(a, b).unchanged
        let rough = ScrollFrameAnalyzer.Alignment(shift: 38, agreement: 0.8, comparedRows: 100)
        let verified = try XCTUnwrap(ScrollFrameAnalyzer.verify(rough, reference: reference, current: current,
                                                                unchanged: unchanged, columns: 0..<reference.width))
        XCTAssertEqual(verified.shift, 37)
    }

    func testVerificationRejectsAWrongOffset() throws {
        let reference = try page(0)
        let current = try page(37)
        let a = signature(reference), b = signature(current)
        let unchanged = ScrollFrameAnalyzer.compare(a, b).unchanged
        let wrong = ScrollFrameAnalyzer.Alignment(shift: 90, agreement: 0.8, comparedRows: 100)
        XCTAssertNil(ScrollFrameAnalyzer.verify(wrong, reference: reference, current: current,
                                                unchanged: unchanged, columns: 0..<reference.width))
    }

    // MARK: - Real screens

    /// Retina content: every line is two identical pixel rows, so an offset and
    /// its neighbour agree on half the rows. Found on a real capture, where a
    /// check that sampled every other row picked the wrong one.
    private func doubledPage(_ position: Int) throws -> ScrollFrameAnalyzer.Frame {
        try frame { y, x in self.textured(row: (position + y) / 2, x: x) }
    }

    func testRetinaLinesAlignToTheExactPixelRow() throws {
        let reference = try doubledPage(400)
        for shift in [56, 57, 1, 2, -3, -84, 131] {
            XCTAssertEqual(align(reference, try doubledPage(400 + shift))?.shift, shift, "shift \(shift)")
        }
    }

    func testVerificationKeepsAnExactEstimateOnRetinaLines() throws {
        let reference = try doubledPage(0)
        let current = try doubledPage(56)
        let a = signature(reference), b = signature(current)
        let unchanged = ScrollFrameAnalyzer.compare(a, b).unchanged
        for estimate in [55, 56, 57] {
            let rough = ScrollFrameAnalyzer.Alignment(shift: estimate, agreement: 0.8, comparedRows: 100)
            XCTAssertEqual(ScrollFrameAnalyzer.verify(rough, reference: reference, current: current,
                                                      unchanged: unchanged, columns: 0..<reference.width)?.shift,
                           56, "estimate \(estimate)")
        }
    }

    func testAStaticSidebarDoesNotDragTheOffset() throws {
        // The left quarter is a sidebar that doesn't scroll.
        func withSidebar(_ position: Int) throws -> ScrollFrameAnalyzer.Frame {
            try frame { y, x in x < 100 ? self.textured(row: 9000 + y, x: x) : self.textured(row: position + y, x: x) }
        }
        let a = signature(try withSidebar(0)), b = signature(try withSidebar(37))
        let comparison = ScrollFrameAnalyzer.compare(a, b)
        XCTAssertFalse(comparison.movingBins[0], "the sidebar's bands stay put")
        XCTAssertTrue(comparison.movingBins[a.bins - 1])
        XCTAssertEqual(align(try withSidebar(0), try withSidebar(37))?.shift, 37)
    }

    func testATranslucentRegionThatDoesNotFollowThePageIsIgnored() throws {
        // The right fifth changes from frame to frame without moving with the
        // page — a translucent window over the selection, blurring what's below.
        func overlaid(_ position: Int) throws -> ScrollFrameAnalyzer.Frame {
            try frame { y, x in x >= 320 ? self.textured(row: 70_000 + position * 7 + y, x: x) : self.textured(row: position + y, x: x) }
        }
        for shift in [12, 90, 150] {
            XCTAssertEqual(align(try overlaid(0), try overlaid(shift))?.shift, shift, "shift \(shift)")
        }
    }

    func testDisagreementBunchedAtTheTopDoesNotHideTheOffset() throws {
        // Found on a real capture: another window's big title sat over the top
        // right of the selection, changing from frame to frame. A search that
        // sampled the top rows first gave the real offset up before reaching
        // the rest of the frame.
        func covered(_ position: Int, phase: Int) throws -> ScrollFrameAnalyzer.Frame {
            try frame { y, x in
                if y < 90 && x >= 340 { return self.textured(row: 50_000 + phase * 97 + y, x: x) }
                return self.textured(row: position + y, x: x)
            }
        }
        XCTAssertEqual(align(try covered(0, phase: 0), try covered(28, phase: 1))?.shift, 28)
        XCTAssertEqual(align(try covered(0, phase: 0), try covered(120, phase: 2))?.shift, 120)
    }

    func testSubtleNoiseDoesNotBreakAlignment() throws {
        let reference = try page(0)
        // Antialiasing-style noise: a channel off by one or two here and there.
        let current = try frame { y, x in
            var c = self.textured(row: 60 + y, x: x)
            if (x + y) % 7 == 0 { c.1 = c.1 &+ 2 }
            return c
        }
        XCTAssertEqual(align(reference, current)?.shift, 60)
    }
}
