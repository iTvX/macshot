import CoreGraphics
import Foundation

/// Builds one tall image from successive frames of a scrolling region.
///
/// Every frame is aligned against the last frame that was placed, so the
/// stitcher always knows which part of the page is on screen. Scrolling back up
/// and down again re-appends nothing, and a frame that can't be placed (the page
/// moved more than a screen between two grabs) is set aside rather than glued on
/// with a gap — the next frame that overlaps the last placed one carries on.
///
/// New content always enters at the bottom edge, so a pinned header only ever
/// comes from the first frame. A pinned footer is kept out of every appended
/// strip and added once, from the furthest frame, at the end.
///
/// Not thread-safe: confine an instance to one queue.
nonisolated final class ScrollStitcher {

    typealias Frame = ScrollFrameAnalyzer.Frame
    typealias RowSignature = ScrollFrameAnalyzer.RowSignature

    enum Outcome: Equatable, Sendable {
        /// Nothing moved since the previous frame.
        case unchanged
        /// The content moved by `shift` rows, `appendedRows` of which were new.
        case scrolled(shift: Int, appendedRows: Int)
        /// The frame couldn't be placed against the previous one.
        case lost
        /// The frame didn't have the session's size.
        case rejected
        /// The next strip would pass the height limit; the image is complete.
        case limitReached
    }

    struct Configuration: Sendable {
        /// Output rows allowed. The first frame is always kept whole.
        var maximumHeight: Int
        /// Keep a pinned footer out of the appended strips.
        var separatesPinnedFooter: Bool
        /// Columns at the right edge left out of matching (scrollbar).
        var scrollbarAllowance: Int
        /// Width of the live preview in pixels; 0 for none.
        var previewWidth: Int
    }

    let width: Int
    let frameHeight: Int
    let colorSpace: CGColorSpace
    let columns: Range<Int>
    private let configuration: Configuration

    private var reference: Frame
    private var referenceSignature: RowSignature
    /// The first frame's rows, kept until the pinned edges are decided.
    private var firstSignature: RowSignature?
    /// Page row shown in the first row of `reference`.
    private var position = 0
    private var lastShift: Int?
    /// Rows pinned to the bottom edge; decided at the first movement.
    private(set) var footerHeight: Int?
    /// Rows that stayed put at the top edge at the first movement.
    private(set) var headerHeight: Int?
    private var footerPixels = Data()
    private let content: ScrollRowBuffer
    private let preview: ScrollPreviewBuffer?

    private(set) var appendedStrips = 0
    private(set) var isLost = false
    private(set) var isComplete = false

    var outputHeight: Int { content.rows + (footerHeight ?? 0) }

    /// Height of the part of the frame that scrolls, once the pinned edges are known.
    var scrollingHeight: Int { frameHeight - (headerHeight ?? 0) - (footerHeight ?? 0) }

    init?(firstFrame: Frame, configuration: Configuration) {
        guard firstFrame.width > 0, firstFrame.height > 0 else { return nil }
        width = firstFrame.width
        frameHeight = firstFrame.height
        colorSpace = firstFrame.colorSpace
        self.configuration = configuration
        columns = ScrollFrameAnalyzer.matchingColumns(width: firstFrame.width,
                                                      scrollbarAllowance: configuration.scrollbarAllowance)
        reference = firstFrame
        referenceSignature = ScrollFrameAnalyzer.signature(of: firstFrame, columns: columns)
        firstSignature = referenceSignature
        content = ScrollRowBuffer(bytesPerRow: firstFrame.width * 4)
        preview = configuration.previewWidth > 0
            ? ScrollPreviewBuffer(sourceWidth: firstFrame.width, width: configuration.previewWidth,
                                  colorSpace: firstFrame.colorSpace)
            : nil
        guard append(rows: 0..<firstFrame.height, of: firstFrame) else { return nil }
        preview?.append(rows: 0..<firstFrame.height, of: firstFrame, contentRows: 0..<firstFrame.height)
    }

    /// The row summary this stitcher compares frames by.
    func signature(for frame: Frame) -> RowSignature {
        ScrollFrameAnalyzer.signature(of: frame, columns: columns)
    }

    /// Places `frame` and appends whatever part of it is new.
    func process(_ frame: Frame, signature: RowSignature) -> Outcome {
        guard !isComplete else { return .limitReached }
        guard frame.width == width, frame.height == frameHeight, frame.bytesPerRow >= width * 4,
              signature.rows == frameHeight, signature.bins == referenceSignature.bins else { return .rejected }

        let comparison = ScrollFrameAnalyzer.compare(referenceSignature, signature)
        if comparison.isAtRest {
            // Same view, perhaps with a caret or spinner in another state. A
            // practically identical frame becomes the reference so slow
            // animations don't drift away from it.
            if comparison.isIdentical {
                reference = frame
                referenceSignature = signature
            }
            isLost = false
            return .unchanged
        }
        let unchanged = comparison.unchanged

        guard let estimate = ScrollFrameAnalyzer.alignment(
                reference: referenceSignature, current: signature, unchanged: unchanged,
                movingBins: comparison.movingBins, preferredShift: lastShift),
              let verified = ScrollFrameAnalyzer.verify(
                estimate, reference: reference, current: frame, unchanged: unchanged,
                columns: ScrollFrameAnalyzer.columns(of: signature,
                                                     movingBins: estimate.bins ?? comparison.movingBins)) else {
            isLost = true
            return .lost
        }

        let shift = verified.shift
        let newPosition = position + shift
        if footerHeight == nil {
            // Pinned rows are judged against the first frame once the page has
            // moved down far enough for a translucent bar to show that it
            // doesn't follow. Until then nothing new is appended (new rows
            // only come from below the first frame).
            guard newPosition >= Self.pinnedDecisionDistance(frameHeight: frameHeight),
                  let first = firstSignature else {
                position = newPosition
                reference = frame
                referenceSignature = signature
                lastShift = shift
                isLost = false
                return .scrolled(shift: shift, appendedRows: 0)
            }
            let sinceFirst = ScrollFrameAnalyzer.Alignment(shift: newPosition, agreement: verified.agreement,
                                                           comparedRows: verified.comparedRows, bins: estimate.bins)
            decideFooter(first: first, current: signature, alignment: sinceFirst)
            firstSignature = nil
        }
        let footer = footerHeight ?? 0
        // Page row just below the part of this frame that scrolls.
        let visibleEnd = newPosition + frameHeight - footer
        var appended = 0
        if visibleEnd > content.rows {
            let newRows = visibleEnd - content.rows
            let firstRow = frameHeight - footer - newRows
            // Overlapping frames always leave the new rows inside this one.
            guard firstRow >= 0 else {
                isLost = true
                return .lost
            }
            guard content.rows + newRows + footer <= configuration.maximumHeight else {
                isComplete = true
                return .limitReached
            }
            guard append(rows: firstRow..<(firstRow + newRows), of: frame) else {
                isComplete = true
                return .limitReached
            }
            preview?.append(rows: firstRow..<(firstRow + newRows), of: frame,
                            contentRows: (content.rows - newRows)..<content.rows)
            footerPixels = Self.copyRows((frameHeight - footer)..<frameHeight, of: frame)
            appended = newRows
            appendedStrips += 1
        }
        position = newPosition
        reference = frame
        referenceSignature = signature
        lastShift = shift
        isLost = false
        return .scrolled(shift: shift, appendedRows: appended)
    }

    /// How far the page has to move down from the first frame before its
    /// pinned rows are judged. A translucent bar shows the page moving behind
    /// it, so it only gives itself away once the page has moved further than
    /// the bar is tall: a quarter of the frame covers tab bars and toolbars.
    static func pinnedDecisionDistance(frameHeight: Int) -> Int {
        max(16, frameHeight / 4)
    }

    /// Settles the pinned footer against the first frame: bottom rows that
    /// stayed put or didn't move with the page (a translucent bar). Blank rows
    /// at the bottom look pinned too; treating them as footer is harmless
    /// because the footer always comes from the furthest frame, which
    /// continues the page exactly where the strips stop.
    private func decideFooter(first: RowSignature, current signature: RowSignature,
                              alignment: ScrollFrameAnalyzer.Alignment) {
        let unchanged = ScrollFrameAnalyzer.unchangedRows(first, signature)
        let top = ScrollFrameAnalyzer.pinnedBands(unchanged).top
        headerHeight = min(top, frameHeight - 1)
        guard configuration.separatesPinnedFooter else {
            footerHeight = 0
            return
        }
        let bottom = ScrollFrameAnalyzer.pinnedBottomRows(
            reference: first, current: signature, unchanged: unchanged, alignment: alignment)
        // The scrolling part has to stay taller than the movement, or strips
        // would reach into pinned rows.
        let limit = frameHeight - top - abs(alignment.shift) - 1
        let footer = max(0, min(bottom, limit))
        footerHeight = footer
        guard footer > 0 else { return }
        // Nothing has been appended yet: the page so far is the first frame,
        // whose bottom rows are the footer.
        footerPixels = content.copyRows((frameHeight - footer)..<frameHeight)
        content.truncate(to: frameHeight - footer)
        preview?.truncate(contentRows: frameHeight - footer)
    }

    private func append(rows: Range<Int>, of frame: Frame) -> Bool {
        frame.withPixels { base in
            content.append(from: base, sourceBytesPerRow: frame.bytesPerRow, rows: rows)
        }
    }

    private static func copyRows(_ rows: Range<Int>, of frame: Frame) -> Data {
        guard !rows.isEmpty else { return Data() }
        let rowBytes = frame.width * 4
        var data = Data(count: rows.count * rowBytes)
        data.withUnsafeMutableBytes { destination in
            frame.withPixels { source in
                for (index, row) in rows.enumerated() {
                    memcpy(destination.baseAddress! + index * rowBytes, source + row * frame.bytesPerRow, rowBytes)
                }
            }
        }
        return data
    }

    // MARK: - Output

    /// A reduced copy of the image so far, for the live preview.
    func makePreviewImage() -> CGImage? {
        guard let preview else { return nil }
        return footerPixels.withUnsafeBytes { footer in
            preview.makeImage(footer: footer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                              footerRows: footerHeight ?? 0, sourceBytesPerRow: width * 4)
        }
    }

    /// The finished image. Hands the pixels over without copying them, so the
    /// stitcher can't be used afterwards.
    func makeImage() -> CGImage? {
        isComplete = true
        let footer = footerHeight ?? 0
        if footer > 0 {
            let appended = footerPixels.withUnsafeBytes { bytes -> Bool in
                guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                return content.append(from: base, sourceBytesPerRow: width * 4, rows: 0..<footer)
            }
            guard appended else { return nil }
        }
        return content.detachImage(width: width, colorSpace: colorSpace)
    }
}

// MARK: - Row storage

/// Rows of 32-bit pixels in one growable block, handed to the final CGImage
/// without a copy.
nonisolated final class ScrollRowBuffer {
    let bytesPerRow: Int
    private(set) var rows = 0
    private var capacity = 0
    private var storage: UnsafeMutableRawPointer?

    init(bytesPerRow: Int) {
        self.bytesPerRow = bytesPerRow
    }

    deinit { free(storage) }

    /// Makes room for `count` more rows; false when the memory isn't available.
    private func reserve(additionalRows count: Int) -> Bool {
        let needed = rows + count
        guard needed > capacity else { return true }
        let grown = max(needed, capacity + capacity / 2, 256)
        let (bytes, overflow) = grown.multipliedReportingOverflow(by: bytesPerRow)
        guard !overflow, let block = realloc(storage, bytes) else { return false }
        storage = block
        capacity = grown
        return true
    }

    /// Copies `rows` from a source image laid out `sourceBytesPerRow` apart.
    func append(from source: UnsafePointer<UInt8>, sourceBytesPerRow: Int, rows range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return true }
        guard reserve(additionalRows: range.count), let storage else { return false }
        let rowBytes = min(bytesPerRow, sourceBytesPerRow)
        for (index, row) in range.enumerated() {
            memcpy(storage + (rows + index) * bytesPerRow, source + row * sourceBytesPerRow, rowBytes)
        }
        rows += range.count
        return true
    }

    func truncate(to count: Int) {
        rows = max(0, min(rows, count))
    }

    /// A tightly packed copy of `range`.
    func copyRows(_ range: Range<Int>) -> Data {
        let rowBytes = bytesPerRow
        guard let storage, !range.isEmpty, range.lowerBound >= 0, range.upperBound <= rows else { return Data() }
        return Data(bytes: storage + range.lowerBound * rowBytes, count: range.count * rowBytes)
    }

    /// The rows as an image that borrows the buffer; only valid inside `body`.
    func withImage<R>(width: Int, colorSpace: CGColorSpace, _ body: (CGImage) -> R) -> R? {
        guard rows > 0, let storage,
              let data = CFDataCreateWithBytesNoCopy(
                nil, storage.assumingMemoryBound(to: UInt8.self), rows * bytesPerRow, kCFAllocatorNull),
              let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: colorSpace,
                                  bitmapInfo: ScrollFrameAnalyzer.bitmapInfo, provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return body(image)
    }

    /// Moves the rows into a CGImage that frees them when it goes away.
    func detachImage(width: Int, colorSpace: CGColorSpace) -> CGImage? {
        guard rows > 0, let block = storage else { return nil }
        let byteCount = rows * bytesPerRow
        let owned = realloc(block, byteCount) ?? block
        storage = nil
        capacity = 0
        let height = rows
        rows = 0
        guard let provider = CGDataProvider(dataInfo: nil, data: owned, size: byteCount, releaseData: { _, data, _ in
            free(UnsafeMutableRawPointer(mutating: data))
        }) else {
            free(owned)
            return nil
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: colorSpace,
                       bitmapInfo: ScrollFrameAnalyzer.bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - Preview

/// A narrow copy of the stitched page, grown strip by strip so the live
/// preview never has to rescale the full image.
nonisolated final class ScrollPreviewBuffer {
    private let sourceWidth: Int
    private let width: Int
    private let scale: Double
    private let colorSpace: CGColorSpace
    private let rows: ScrollRowBuffer

    init(sourceWidth: Int, width: Int, colorSpace: CGColorSpace) {
        self.sourceWidth = sourceWidth
        self.width = max(1, min(width, sourceWidth))
        scale = Double(self.width) / Double(max(1, sourceWidth))
        self.colorSpace = colorSpace
        rows = ScrollRowBuffer(bytesPerRow: self.width * 4)
    }

    private func previewRow(_ contentRow: Int) -> Int {
        Int((Double(contentRow) * scale).rounded())
    }

    /// Adds `sourceRows` of `frame`, which hold page rows `contentRows`.
    func append(rows sourceRows: Range<Int>, of frame: ScrollFrameAnalyzer.Frame, contentRows: Range<Int>) {
        let start = max(rows.rows, previewRow(contentRows.lowerBound))
        let end = previewRow(contentRows.upperBound)
        let count = end - start
        guard count > 0, !sourceRows.isEmpty else { return }
        let strip = Self.scaledStrip(of: frame, rows: sourceRows, width: width, height: count, colorSpace: colorSpace)
        guard let strip else { return }
        strip.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            _ = rows.append(from: base, sourceBytesPerRow: width * 4, rows: 0..<count)
        }
    }

    func truncate(contentRows: Int) {
        rows.truncate(to: previewRow(contentRows))
    }

    /// The preview so far, with the footer (if any) scaled onto the bottom.
    func makeImage(footer: UnsafePointer<UInt8>?, footerRows: Int, sourceBytesPerRow: Int) -> CGImage? {
        let footerHeight = footerRows > 0 && footer != nil ? max(1, previewRow(footerRows)) : 0
        let height = rows.rows + footerHeight
        guard height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: ScrollFrameAnalyzer.bitmapInfo.rawValue) else { return nil }
        context.interpolationQuality = .medium
        _ = rows.withImage(width: width, colorSpace: colorSpace) { image in
            context.draw(image, in: CGRect(x: 0, y: footerHeight, width: width, height: rows.rows))
        }
        if footerHeight > 0, let footer,
           let data = CFDataCreateWithBytesNoCopy(nil, footer, footerRows * sourceBytesPerRow, kCFAllocatorNull),
           let provider = CGDataProvider(data: data),
           let image = CGImage(width: sourceWidth, height: footerRows, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: sourceBytesPerRow, space: colorSpace,
                               bitmapInfo: ScrollFrameAnalyzer.bitmapInfo, provider: provider,
                               decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: footerHeight))
        }
        return context.makeImage()
    }

    /// `rows` of `frame` scaled to `width × height`, as tightly packed rows.
    private static func scaledStrip(of frame: ScrollFrameAnalyzer.Frame, rows: Range<Int>,
                                    width: Int, height: Int, colorSpace: CGColorSpace) -> Data? {
        var output = Data(count: width * height * 4)
        let drawn = output.withUnsafeMutableBytes { destination -> Bool in
            guard let context = CGContext(data: destination.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                          bitmapInfo: ScrollFrameAnalyzer.bitmapInfo.rawValue) else { return false }
            context.interpolationQuality = .medium
            return frame.withPixels { base -> Bool in
                let start = base + rows.lowerBound * frame.bytesPerRow
                let length = (rows.count - 1) * frame.bytesPerRow + frame.width * 4
                guard let data = CFDataCreateWithBytesNoCopy(nil, start, length, kCFAllocatorNull),
                      let provider = CGDataProvider(data: data),
                      let image = CGImage(width: frame.width, height: rows.count, bitsPerComponent: 8,
                                          bitsPerPixel: 32, bytesPerRow: frame.bytesPerRow, space: colorSpace,
                                          bitmapInfo: ScrollFrameAnalyzer.bitmapInfo, provider: provider,
                                          decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
        }
        return drawn ? output : nil
    }
}
