import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Grabs the capture rectangle, off the main thread.
nonisolated final class ScrollFrameGrabber: @unchecked Sendable {
    private let rect: CGRect
    private let belowWindowID: CGWindowID
    private let filter: SCContentFilter?
    private let configuration: SCStreamConfiguration?
    private let queue = DispatchQueue(label: "macshot.scrollcapture.grab", qos: .userInitiated)

    /// - Parameters:
    ///   - rect: Global display coordinates, top-left origin.
    ///   - belowWindowID: Only windows below this one are composited, which
    ///     keeps macshot's own panels above it out of every frame.
    ///     `kCGNullWindowID` composites everything on screen.
    ///   - filter: When set (application exclusions), frames come from
    ///     ScreenCaptureKit with this filter instead.
    init(rect: CGRect, belowWindowID: CGWindowID,
         filter: SCContentFilter? = nil, configuration: SCStreamConfiguration? = nil) {
        self.rect = rect
        self.belowWindowID = belowWindowID
        self.filter = filter
        self.configuration = configuration
    }

    func grab() async -> CGImage? {
        if let filter, let configuration {
            guard #available(macOS 14.0, *) else { return nil }
            return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
        let rect = rect, below = belowWindowID
        return await withCheckedContinuation { continuation in
            queue.async {
                let options: CGWindowListOption = below == kCGNullWindowID ? .optionOnScreenOnly : .optionOnScreenBelowWindow
                continuation.resume(returning: CGWindowListCreateImage(rect, options, below, [.boundsIgnoreFraming]))
            }
        }
    }
}

/// Runs a `ScrollStitcher` on its own serial queue so normalising, matching
/// and copying frames never competes with input handling on the main thread.
nonisolated final class ScrollCaptureEngine: @unchecked Sendable {

    struct Report: @unchecked Sendable {
        /// What stitching the frame did; nil when it was only inspected.
        var outcome: ScrollStitcher.Outcome?
        /// The grab matched the one before it: whatever was moving has stopped.
        var isSettled = false
        var outputPixelSize: CGSize = .zero
        var strips = 0
        var isLost = false
        /// Rows of the frame that scroll (pinned edges left out).
        var scrollingHeight = 0
        /// A new live preview, when one is due.
        var preview: CGImage?
    }

    /// Hard ceilings on the output, whatever the preference says: a page can't
    /// grow past 100,000 rows or 1 GiB of pixels.
    static let maximumRows = 100_000
    static let maximumBytes = 1 << 30

    static func heightLimit(preference: Int, width: Int) -> Int {
        let byMemory = maximumBytes / max(1, width * 4)
        let ceiling = min(maximumRows, byMemory)
        return preference > 0 ? min(preference, ceiling) : ceiling
    }

    private let queue = DispatchQueue(label: "macshot.scrollcapture.stitch", qos: .userInitiated)
    private let heightPreference: Int
    private let separatesPinnedFooter: Bool
    private let scrollbarAllowance: Int
    private let previewWidth: Int

    // Queue-confined state.
    private var colorSpace: CGColorSpace?
    private var stitcher: ScrollStitcher?
    private var latest: (frame: ScrollFrameAnalyzer.Frame, signature: ScrollFrameAnalyzer.RowSignature)?
    private var latestIsStitched = false
    private var previousSignature: ScrollFrameAnalyzer.RowSignature?
    private var previewIsDue = false
    private var lastPreviewTime: TimeInterval = 0
    private var isDiscarded = false

    init(heightPreference: Int, separatesPinnedFooter: Bool, scrollbarAllowance: Int, previewWidth: Int) {
        self.heightPreference = heightPreference
        self.separatesPinnedFooter = separatesPinnedFooter
        self.scrollbarAllowance = scrollbarAllowance
        self.previewWidth = previewWidth
    }

    private func onQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Takes in a grab: compares it with the previous one and, when `stitch`
    /// is set and a session has begun, places it in the page.
    func ingest(_ image: CGImage, stitch: Bool) async -> Report {
        await onQueue { [self] in
            guard !isDiscarded else { return Report() }
            let space = colorSpace ?? ScrollFrameAnalyzer.workingColorSpace(for: image)
            guard let frame = ScrollFrameAnalyzer.frame(from: image, colorSpace: space) else {
                return report(outcome: nil, settled: false)
            }
            colorSpace = space
            let columns = ScrollFrameAnalyzer.matchingColumns(width: frame.width,
                                                              scrollbarAllowance: scrollbarAllowance)
            let signature = ScrollFrameAnalyzer.signature(of: frame, columns: columns)
            var settled = false
            if let previous = previousSignature, previous.rows == signature.rows, previous.bins == signature.bins {
                settled = ScrollFrameAnalyzer.compare(previous, signature).isAtRest
            }
            previousSignature = signature
            latest = (frame, signature)
            latestIsStitched = false
            let outcome = stitch ? stitchLatestOnQueue() : nil
            return report(outcome: outcome, settled: settled)
        }
    }

    /// Starts the page with the most recent grab.
    func beginWithLatest() async -> Report? {
        await onQueue { [self] in
            guard !isDiscarded, stitcher == nil, let latest else { return nil }
            let configuration = ScrollStitcher.Configuration(
                maximumHeight: Self.heightLimit(preference: heightPreference, width: latest.frame.width),
                separatesPinnedFooter: separatesPinnedFooter,
                scrollbarAllowance: scrollbarAllowance,
                previewWidth: previewWidth)
            guard let created = ScrollStitcher(firstFrame: latest.frame, configuration: configuration) else { return nil }
            stitcher = created
            latestIsStitched = true
            previewIsDue = true
            return report(outcome: nil, settled: true, forcePreview: true)
        }
    }

    /// Places the most recent grab, if it hasn't been already.
    func stitchLatest() async -> Report {
        await onQueue { [self] in
            guard !isDiscarded else { return Report() }
            let outcome = stitchLatestOnQueue()
            return report(outcome: outcome, settled: true)
        }
    }

    /// The finished image. The engine is spent afterwards.
    func finish() async -> CGImage? {
        await onQueue { [self] in
            guard !isDiscarded, let stitcher else { return nil }
            let image = stitcher.makeImage()
            discardOnQueue()
            return image
        }
    }

    /// Frees everything; later calls do nothing.
    func discard() {
        queue.async { [self] in discardOnQueue() }
    }

    private func discardOnQueue() {
        isDiscarded = true
        stitcher = nil
        latest = nil
        previousSignature = nil
    }

    private func stitchLatestOnQueue() -> ScrollStitcher.Outcome? {
        guard let stitcher, let latest, !latestIsStitched else { return nil }
        latestIsStitched = true
        let outcome = stitcher.process(latest.frame, signature: latest.signature)
        if case .scrolled = outcome { previewIsDue = true }
        return outcome
    }

    private func report(outcome: ScrollStitcher.Outcome?, settled: Bool, forcePreview: Bool = false) -> Report {
        var report = Report(outcome: outcome, isSettled: settled)
        guard let stitcher else { return report }
        report.outputPixelSize = CGSize(width: stitcher.width, height: stitcher.outputHeight)
        report.strips = stitcher.appendedStrips + 1
        report.isLost = stitcher.isLost
        report.scrollingHeight = stitcher.scrollingHeight
        let now = ProcessInfo.processInfo.systemUptime
        // Throttled while the page is moving; always refreshed once it rests.
        if previewIsDue && (forcePreview || settled || now - lastPreviewTime >= 0.25) {
            report.preview = stitcher.makePreviewImage()
            previewIsDue = false
            lastPreviewTime = now
        }
        return report
    }
}
