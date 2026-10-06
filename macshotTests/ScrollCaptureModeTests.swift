import Cocoa
import XCTest

/// While a scroll capture runs, the app being captured has to see exactly what
/// it would without macshot: no window above it. Only the HUD and a frame drawn
/// outside the selection may be on screen, and nothing may outlive the session.
@MainActor
final class ScrollCaptureModeTests: XCTestCase {

    private var controller: OverlayWindowController?

    override func tearDown() {
        controller?.tearDown()
        controller = nil
        super.tearDown()
    }

    /// macshot's window with this number, if it's still around.
    private func window(_ id: CGWindowID) -> NSWindow? {
        NSApp.window(withWindowNumber: Int(id))
    }

    private func isShowing(_ id: CGWindowID) -> Bool {
        window(id)?.isVisible ?? false
    }

    /// Returns the overlay in scroll capture mode and its selection in screen coordinates.
    private func startScrollCapture() throws -> (OverlayWindowController, NSRect) {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let overlay = OverlayWindowController(screen: screen)
        controller = overlay
        let selection = NSRect(x: 200, y: 150, width: 420, height: 320)
        overlay.showOverlay()
        overlay.applySelection(selection)
        XCTAssertTrue(isShowing(overlay.windowNumber), "the overlay is up while the selection is made")
        overlay.setScrollCaptureState(isActive: true, maxHeight: 30000)
        return (overlay, selection.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY))
    }

    func testTheOverlayStepsAsideForTheLiveApp() throws {
        let (overlay, selection) = try startScrollCapture()
        XCTAssertFalse(isShowing(overlay.windowNumber), "nothing of macshot may cover the app being captured")

        let chrome = overlay.scrollCaptureChromeWindowIDs
        XCTAssertEqual(chrome.count, 5, "the HUD and four frame strips")
        let hud = try XCTUnwrap(overlay.scrollCaptureHUDWindowID)
        XCTAssertTrue(chrome.contains(hud))
        for id in chrome {
            XCTAssertTrue(isShowing(id), "window \(id) should be on screen")
            let panel = try XCTUnwrap(window(id))
            XCTAssertTrue(panel.level.rawValue >= 257, "above ordinary windows")
            if id != hud {
                XCTAssertTrue(panel.ignoresMouseEvents, "the frame must not catch clicks or scrolls")
                XCTAssertFalse(panel.frame.intersects(selection), "frame strip \(panel.frame) would end up in the capture")
            } else {
                XCTAssertFalse(panel.canBecomeKey, "clicking the HUD must not take focus from the captured app")
            }
        }
    }

    func testEndingTheSessionRemovesEverything() throws {
        let (overlay, _) = try startScrollCapture()
        let chrome = overlay.scrollCaptureChromeWindowIDs
        XCTAssertFalse(chrome.isEmpty)
        overlay.setScrollCaptureState(isActive: false)
        XCTAssertTrue(overlay.scrollCaptureChromeWindowIDs.isEmpty)
        for id in chrome { XCTAssertFalse(isShowing(id), "window \(id) outlived the session") }
    }

    func testDismissingMidSessionLeavesNothingBehind() throws {
        // A Space change used to dismiss the overlay without ending scroll
        // capture, stranding the HUD (and an input tap) until relaunch.
        let (overlay, _) = try startScrollCapture()
        let chrome = overlay.scrollCaptureChromeWindowIDs
        overlay.dismiss()
        XCTAssertTrue(overlay.scrollCaptureChromeWindowIDs.isEmpty)
        for id in chrome { XCTAssertFalse(isShowing(id), "window \(id) outlived the overlay") }
    }

    func testTheHUDShowsAStatusInPlaceOfTheSize() throws {
        let (overlay, _) = try startScrollCapture()
        let hud = try XCTUnwrap(window(try XCTUnwrap(overlay.scrollCaptureHUDWindowID)))
        overlay.updateScrollCaptureProgress(stripCount: 3, pixelSize: CGSize(width: 840, height: 2400))
        let plain = hud.frame.width
        overlay.updateScrollCaptureProgress(stripCount: 3, pixelSize: CGSize(width: 840, height: 2400),
                                            status: "Scrolled too fast — scroll back a little")
        let withStatus = hud.frame.width
        XCTAssertGreaterThan(withStatus, plain, "the longer status line widens the HUD")
        overlay.updateScrollCaptureProgress(stripCount: 3, pixelSize: CGSize(width: 840, height: 2400))
        XCTAssertEqual(hud.frame.width, plain, "and it goes back once the status clears")
    }
}
