import Cocoa
import XCTest

/// What macshot puts on screen during a scroll capture must stay out of the
/// captured rectangle, and its Escape handling must only take plain Escape.
final class ScrollCaptureChromeTests: XCTestCase {

    func testTheFrameSurroundsTheSelectionWithoutCoveringIt() {
        let selection = NSRect(x: 100, y: 200, width: 300, height: 400)
        let strips = ScrollCaptureFrameWindows.stripFrames(around: selection, thickness: 2)
        XCTAssertEqual(strips.count, 4)
        for strip in strips {
            XCTAssertFalse(strip.intersects(selection), "\(strip) would show up in the capture")
            XCTAssertGreaterThan(strip.width * strip.height, 0)
        }
        // Together they close the ring: every edge of the selection is lined.
        let outer = selection.insetBy(dx: -2, dy: -2)
        let union = strips.dropFirst().reduce(strips[0]) { $0.union($1) }
        XCTAssertEqual(union, outer)
        XCTAssertTrue(strips.contains { $0.minY == selection.maxY && $0.width == outer.width })
        XCTAssertTrue(strips.contains { $0.maxY == selection.minY && $0.width == outer.width })
        XCTAssertTrue(strips.contains { $0.maxX == selection.minX && $0.height == selection.height })
        XCTAssertTrue(strips.contains { $0.minX == selection.maxX && $0.height == selection.height })
    }

    func testOnlyPlainEscapeCancels() {
        XCTAssertTrue(ScrollCaptureEscapeInterceptor.isCancelKey(keyCode: 53, flags: []))
        XCTAssertTrue(ScrollCaptureEscapeInterceptor.isCancelKey(keyCode: 53, flags: .maskShift))
        XCTAssertTrue(ScrollCaptureEscapeInterceptor.isCancelKey(keyCode: 53, flags: .maskNonCoalesced),
                      "bookkeeping flags don't make it a chord")
        XCTAssertFalse(ScrollCaptureEscapeInterceptor.isCancelKey(keyCode: 53, flags: .maskCommand),
                       "⌘⎋ belongs to the app that has focus")
        XCTAssertFalse(ScrollCaptureEscapeInterceptor.isCancelKey(keyCode: 53, flags: .maskAlternate))
        XCTAssertFalse(ScrollCaptureEscapeInterceptor.isCancelKey(keyCode: 53, flags: .maskControl))
        XCTAssertFalse(ScrollCaptureEscapeInterceptor.isCancelKey(keyCode: 36, flags: []), "Return is not Escape")
    }
}
