import Cocoa
import ScreenCaptureKit

// MARK: - ScrollCaptureController

/// Runs a scroll capture session: gives the window under the selection the
/// focus a click would have given it, follows the user's scrolling (or scrolls
/// by itself), and builds one tall image.
///
/// Frames are grabbed and stitched on background queues (`ScrollFrameGrabber`,
/// `ScrollCaptureEngine`). This class only reacts to input and updates the UI,
/// so the main thread — and with it the user's scrolling — never waits on
/// capture work. Nothing here intercepts the user's mouse: the app being
/// captured sees exactly the events it would without macshot.
@MainActor
final class ScrollCaptureController {

    private enum Phase { case idle, starting, active, finishing, finished, cancelled }

    // MARK: - Public state

    private(set) var stripCount: Int = 0
    private(set) var stitchedPixelSize: CGSize = .zero
    var isActive: Bool { phase == .active }
    private(set) var autoScrollActive: Bool = false
    /// A short note for the HUD while the user has to do something.
    private(set) var statusMessage: String?

    // MARK: - Callbacks

    /// Size, auto-scroll state or status changed.
    var onProgressChanged: (() -> Void)?
    var onPreviewUpdated: ((NSImage) -> Void)?
    var onSessionDone: ((NSImage?) -> Void)?

    // MARK: - Config

    /// macshot's own windows: never taken for the window being captured.
    var excludedWindowIDs: [CGWindowID] = []
    /// Frames are composited from the windows below this one (the HUD), which
    /// keeps it — and anything else macshot shows above it — out of the image.
    var captureBelowWindowID: CGWindowID = kCGNullWindowID

    // MARK: - Settings

    private var autoScrollEnabled: Bool = false
    private var autoScrollSpeed: Int = 3
    private var maxScrollHeight: Int = 30000
    private var frozenDetectionEnabled: Bool = true

    // MARK: - Private

    private let captureRect: NSRect
    private let screen: NSScreen
    private let backingScale: CGFloat
    private var captureRectCG: CGRect = .zero  // global, top-left origin
    private var phase = Phase.idle

    private var grabber: ScrollFrameGrabber?
    private var engine: ScrollCaptureEngine?
    /// The one task that grabs and stitches; manual and auto mode share it so
    /// grabs never overlap.
    private var loopTask: Task<Void, Never>?

    // Manual scrolling
    private var scrollMonitorGlobal: Any?
    private var scrollMonitorLocal: Any?
    private var lastScrollActivity: TimeInterval = 0
    private var lastGrabWasSettled = true
    /// Pause between grabs while the content moves.
    private let manualInterval: TimeInterval = 0.07
    /// How long after the last scroll event the content is still watched.
    private let quietInterval: TimeInterval = 0.25
    /// Longest wait for the page to come to rest after the last scroll event.
    private let settleTimeout: TimeInterval = 1.0

    // Auto-scroll
    private var planner: AutoScrollPlanner?
    private var needsPointerPlacement = false
    private var viewportPixels = 0
    private var autoScrollNote: String?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Init

    init(captureRect: NSRect, screen: NSScreen) {
        self.captureRect = captureRect
        self.screen      = screen
        self.backingScale = screen.backingScaleFactor
    }

    // MARK: - Session

    func startSession() async {
        guard phase == .idle else { return }
        phase = .starting

        let ud = UserDefaults.standard
        autoScrollEnabled = ud.object(forKey: "scrollAutoScrollEnabled") as? Bool ?? false
        autoScrollSpeed = ud.object(forKey: "scrollAutoScrollSpeed") as? Int ?? 3
        maxScrollHeight = ud.object(forKey: "scrollMaxHeight") as? Int ?? 30000
        frozenDetectionEnabled = ud.object(forKey: "scrollFrozenDetection") as? Bool ?? true

        // AppKit coordinates → global CG coordinates (top-left origin).
        let primaryScreenH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        captureRectCG = CGRect(x: captureRect.minX, y: primaryScreenH - captureRect.maxY,
                               width: captureRect.width, height: captureRect.height)

        let target = ScrollCaptureTarget.window(
            at: CGPoint(x: captureRectCG.midX, y: captureRectCG.midY), excluding: Set(excludedWindowIDs))
        if let target {
            let bundleIdentifier = NSRunningApplication(processIdentifier: target.processID)?.bundleIdentifier
            guard !CaptureExclusionStore.contains(bundleIdentifier: bundleIdentifier) else {
                endStartup()
                return
            }
        }

        var filter: SCContentFilter?
        var configuration: SCStreamConfiguration?
        if CaptureExclusionStore.hasConfiguredApplications {
            guard let prepared = await prepareExclusionCapture() else {
                if phase == .starting { endStartup() }
                return
            }
            (filter, configuration) = prepared
        }
        guard phase == .starting else { return }

        let grabber = ScrollFrameGrabber(rect: captureRectCG, belowWindowID: captureBelowWindowID,
                                         filter: filter, configuration: configuration)
        let engine = ScrollCaptureEngine(
            heightPreference: maxScrollHeight,
            separatesPinnedFooter: frozenDetectionEnabled,
            scrollbarAllowance: Int((18 * backingScale).rounded(.up)),
            previewWidth: Int((200 * backingScale).rounded()))
        self.grabber = grabber
        self.engine = engine

        // Without focus some apps ignore scrolling until the user clicks into
        // them; hand it over the way that click would.
        if let target { await focus(target) }
        guard phase == .starting else { return }
        ScrollCaptureInput.refreshPointer()
        // Let the window redraw in its focused appearance before the first frame.
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard phase == .starting else { return }

        guard let first = await captureFirstFrame(grabber: grabber, engine: engine) else {
            if phase == .starting { endStartup() }
            return
        }
        guard phase == .starting else { return }
        phase = .active
        viewportPixels = Int(first.outputPixelSize.height)
        lastScrollActivity = now
        apply(first)

        if autoScrollEnabled {
            startAutoScroll()
        } else {
            startManualScrollMonitors()
        }
    }

    /// Ends a session that never got going: nothing to deliver.
    private func endStartup() {
        phase = .finished
        tearDownInput()
        engine?.discard()
        onSessionDone?(nil)
    }

    func stopSession() {
        switch phase {
        case .idle, .starting:
            // The HUD and its Stop button are on screen before the first frame
            // lands; a stop then ends the session with nothing to show.
            endStartup()
        case .active:
            phase = .finishing
            let pendingLoop = loopTask
            // The page may still be moving under a running manual loop: take
            // one last look so what's on screen at Stop makes it in.
            let wasWatchingScroll = loopTask != nil && !autoScrollActive
            tearDownInput()
            Task { [weak self] in
                await pendingLoop?.value
                guard let self, self.phase == .finishing, let engine = self.engine else { return }
                if wasWatchingScroll, let image = await self.grabber?.grab() {
                    guard self.phase == .finishing else { return }
                    _ = await engine.ingest(image, stitch: true)
                }
                guard self.phase == .finishing else { return }
                let finalImage = await engine.finish()
                guard self.phase == .finishing else { return }
                self.phase = .finished
                let result = finalImage.map { cg in
                    NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / self.backingScale,
                                                      height: CGFloat(cg.height) / self.backingScale))
                }
                self.onSessionDone?(result)
            }
        case .finishing, .finished, .cancelled:
            return
        }
    }

    func cancelSession() {
        // Valid in every phase, including while the first frame is still being
        // captured: the phase check keeps that startup from going on.
        guard phase != .finished, phase != .cancelled else { return }
        phase = .cancelled
        tearDownInput()
        loopTask?.cancel()
        engine?.discard()
    }

    private func tearDownInput() {
        removeManualScrollMonitors()
        autoScrollActive = false
        planner = nil
    }

    // MARK: - Focus

    /// Raises the target window and activates its app, unless it already has
    /// the focus.
    private func focus(_ target: ScrollCaptureTarget) async {
        guard target.processID != getpid(),
              let application = NSRunningApplication(processIdentifier: target.processID) else { return }
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID
        let alreadyFocused = await offMain { isFrontmost && target.isFocusedWindow() }
        guard !alreadyFocused, phase == .starting else { return }
        await offMain { target.raiseWindow() }
        guard phase == .starting else { return }
        AppDelegate.activateApp(application)
    }

    /// Runs blocking Accessibility calls away from the main thread.
    private func offMain<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Frame capture

    private func prepareExclusionCapture() async -> (SCContentFilter, SCStreamConfiguration)? {
        guard #available(macOS 14.0, *) else { return nil }
        // macshot's panels were just ordered in; give the shareable-content
        // list a moment to include them, or they'd show up in every frame.
        let onScreen = Set((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } })
        let wanted = Set(excludedWindowIDs).intersection(onScreen)
        var content: SCShareableContent?
        for attempt in 0..<3 {
            guard let fetched = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true) else { return nil }
            content = fetched
            let listed = Set(fetched.windows.map { CGWindowID($0.windowID) })
            if wanted.isSubset(of: listed) || attempt == 2 { break }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        guard let content else { return nil }
        let screenID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: {
            screenID != nil && $0.displayID == screenID!
        }) ?? content.displays.first else { return nil }

        let excludedWindows = excludedWindowIDs.compactMap { windowID in
            content.windows.first { CGWindowID($0.windowID) == windowID }
        }
        let filter = CaptureExclusionStore.contentFilter(
            display: display,
            content: content,
            excludingWindows: excludedWindows)

        let localRect = CGRect(
            x: captureRect.minX - screen.frame.minX,
            y: screen.frame.maxY - captureRect.maxY,
            width: captureRect.width,
            height: captureRect.height)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = localRect
        configuration.width = Int(localRect.width * backingScale)
        configuration.height = Int(localRect.height * backingScale)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = false
        return (filter, configuration)
    }

    /// The first frame, once two grabs in a row agree (or after a short wait,
    /// for pages that never stop animating).
    private func captureFirstFrame(grabber: ScrollFrameGrabber,
                                   engine: ScrollCaptureEngine) async -> ScrollCaptureEngine.Report? {
        let deadline = now + 0.8
        var grabs = 0
        while phase == .starting {
            if let image = await grabber.grab() {
                guard phase == .starting else { return nil }
                let report = await engine.ingest(image, stitch: false)
                grabs += 1
                if (grabs >= 2 && report.isSettled) || now >= deadline {
                    return await engine.beginWithLatest()
                }
            } else if now >= deadline {
                return nil
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return nil
    }

    private func apply(_ report: ScrollCaptureEngine.Report) {
        guard phase == .active else { return }
        if let preview = report.preview {
            let size = NSSize(width: report.outputPixelSize.width / backingScale,
                              height: report.outputPixelSize.height / backingScale)
            onPreviewUpdated?(NSImage(cgImage: preview, size: size))
        }
        var changed = false
        if report.outputPixelSize != .zero, report.outputPixelSize != stitchedPixelSize {
            stitchedPixelSize = report.outputPixelSize
            changed = true
        }
        if report.strips > 0, report.strips != stripCount {
            stripCount = report.strips
            changed = true
        }
        if case .scrolled = report.outcome { autoScrollNote = nil }
        let message = report.isLost ? L("Scrolled too fast — scroll back a little") : autoScrollNote
        if message != statusMessage {
            statusMessage = message
            changed = true
        }
        if changed { onProgressChanged?() }
        if report.outcome == .limitReached { stopSession() }
    }

    // MARK: - Capture loop

    private func ensureLoop() {
        guard loopTask == nil, phase == .active else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        defer { loopTask = nil }
        while phase == .active {
            if autoScrollActive {
                await autoScrollStep()
            } else {
                // Idle once the user has stopped scrolling and the page has
                // come to rest — or after a second regardless, for content that
                // never rests (video). The next scroll event starts it again.
                let quietFor = now - lastScrollActivity
                if quietFor > quietInterval && (lastGrabWasSettled || quietFor > settleTimeout) { return }
                await manualStep()
            }
        }
    }

    // MARK: - Manual scroll

    private func startManualScrollMonitors() {
        guard scrollMonitorGlobal == nil, scrollMonitorLocal == nil else { return }
        scrollMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.noteScrollActivity()
        }
        scrollMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.noteScrollActivity()
            return event
        }
    }

    private func removeManualScrollMonitors() {
        if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
        if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
    }

    private func noteScrollActivity() {
        guard phase == .active, !autoScrollActive else { return }
        lastScrollActivity = now
        lastGrabWasSettled = false
        ensureLoop()
    }

    /// One grab while the user scrolls, stitched straight away: during a fast
    /// fling the page can pass a whole screen between two pauses.
    private func manualStep() async {
        guard let grabber, let engine else { return }
        let started = now
        guard let image = await grabber.grab() else {
            lastGrabWasSettled = true
            try? await Task.sleep(nanoseconds: 100_000_000)
            return
        }
        guard phase == .active else { return }
        let report = await engine.ingest(image, stitch: true)
        guard phase == .active else { return }
        lastGrabWasSettled = report.isSettled
        apply(report)
        let remaining = manualInterval - (now - started)
        if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
    }

    // MARK: - Auto-scroll

    func toggleAutoScroll() {
        guard phase == .active else { return }
        if autoScrollActive {
            stopAutoScroll(note: nil)
        } else {
            startAutoScroll()
        }
    }

    private func startAutoScroll() {
        removeManualScrollMonitors()
        autoScrollActive = true
        autoScrollNote = nil
        planner = AutoScrollPlanner(viewportPixels: viewportPixels, scale: backingScale, speed: autoScrollSpeed)
        needsPointerPlacement = true
        statusMessage = nil
        onProgressChanged?()
        ensureLoop()
    }

    private func stopAutoScroll(note: String?) {
        autoScrollActive = false
        planner = nil
        autoScrollNote = note
        statusMessage = note
        startManualScrollMonitors()
        onProgressChanged?()
    }

    /// Scroll events go to the window under the pointer, so it's parked inside
    /// the selection — in the upper part, away from where new rows come in,
    /// so hover highlights stay out of them.
    private var autoScrollPointerLocation: CGPoint {
        CGPoint(x: captureRectCG.midX, y: captureRectCG.minY + captureRectCG.height * 0.35)
    }

    private func autoScrollStep() async {
        guard let grabber, let engine, var stepPlanner = planner else { return }
        if needsPointerPlacement {
            needsPointerPlacement = false
            ScrollCaptureInput.movePointer(to: autoScrollPointerLocation)
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard phase == .active, autoScrollActive else { return }
        }
        let step = stepPlanner.nextStep()
        planner = stepPlanner
        ScrollCaptureInput.postScroll(step)
        await waitForSettledContent(grabber: grabber, engine: engine)
        guard phase == .active, autoScrollActive else { return }
        let report = await engine.stitchLatest()
        guard phase == .active, autoScrollActive else { return }
        apply(report)
        guard phase == .active, autoScrollActive, var current = planner else { return }
        let decision = current.record(report.outcome ?? .unchanged)
        current.limitViewport(to: report.scrollingHeight)
        planner = current
        switch decision {
        case .keepGoing:
            break
        case .reachedEnd:
            stopSession()
        case .cannotScroll:
            stopAutoScroll(note: L("Auto Scroll can't scroll this window — scroll manually"))
        }
    }

    /// Waits for the page to stop moving after a step: two grabs in a row
    /// agree, once motion was seen (or long enough that none is coming).
    private func waitForSettledContent(grabber: ScrollFrameGrabber, engine: ScrollCaptureEngine) async {
        let started = now
        var sawMotion = false
        try? await Task.sleep(nanoseconds: 40_000_000)
        while phase == .active && autoScrollActive {
            if let image = await grabber.grab() {
                guard phase == .active, autoScrollActive else { return }
                let report = await engine.ingest(image, stitch: false)
                if !report.isSettled {
                    sawMotion = true
                } else if sawMotion || now - started >= 0.35 {
                    return
                }
            }
            if now - started >= 1.5 { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}
