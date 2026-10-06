import CoreGraphics
import Foundation

/// Pixel arithmetic for scroll capture: normalising frames, summarising rows,
/// finding how far the content moved between two frames, and telling pinned
/// rows (sticky headers and footers) apart from the ones that scroll.
///
/// Kept free of capture state so it can be reasoned about — and tested — on
/// plain images. `ScrollStitcher` owns the decisions; this owns the arithmetic.
///
/// Rows are always addressed through a frame's own `bytesPerRow`. Deriving the
/// stride as `width * 4` is wrong whenever the window server pads rows for
/// alignment, and the error compounds row by row.
nonisolated enum ScrollFrameAnalyzer {

    // MARK: - Frames

    /// The one layout every comparison and row copy assumes: 32-bit BGRA with
    /// premultiplied alpha first, little endian — what the window server returns.
    static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                         | CGBitmapInfo.byteOrder32Little.rawValue)

    /// An immutable frame in `bitmapInfo` layout.
    struct Frame: @unchecked Sendable {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let colorSpace: CGColorSpace
        let pixels: Data

        func withPixels<R>(_ body: (UnsafePointer<UInt8>) throws -> R) rethrows -> R {
            try pixels.withUnsafeBytes { buffer in
                try body(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self))
            }
        }
    }

    /// The colour space frames are normalised into: the image's own when it is
    /// RGB, sRGB otherwise.
    static func workingColorSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb { return space }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Converts `image` into the shared layout and `colorSpace`. Images already
    /// in that layout share their bytes instead of being redrawn.
    static func frame(from image: CGImage, colorSpace: CGColorSpace? = nil) -> Frame? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !sizeOverflow else { return nil }
        let space = colorSpace ?? workingColorSpace(for: image)

        if image.bitsPerComponent == 8, image.bitsPerPixel == 32,
           image.alphaInfo == .premultipliedFirst,
           image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little,
           let source = image.colorSpace, CFEqual(source, space),
           image.bytesPerRow >= rowBytes,
           let data = image.dataProvider?.data,
           CFDataGetLength(data) >= image.bytesPerRow * (height - 1) + rowBytes {
            return Frame(width: width, height: height, bytesPerRow: image.bytesPerRow,
                         colorSpace: space, pixels: data as Data)
        }

        var pixels = Data(count: byteCount)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: rowBytes, space: space, bitmapInfo: bitmapInfo.rawValue) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return Frame(width: width, height: height, bytesPerRow: rowBytes, colorSpace: space, pixels: pixels)
    }

    /// Columns that take part in matching: everything except a strip down the
    /// right edge, where a scrollbar thumb moves at its own pace.
    static func matchingColumns(width: Int, scrollbarAllowance: Int) -> Range<Int> {
        let margin = max(0, min(scrollbarAllowance, width / 8))
        return 0..<max(1, width - margin)
    }

    // MARK: - Row signatures

    /// A compact summary of every row: the mean brightness of narrow vertical
    /// bands. Enough to tell rows apart without comparing every pixel again for
    /// each candidate offset.
    struct RowSignature: Sendable {
        let rows: Int
        let bins: Int
        /// Column where each band starts, plus the end of the last one.
        let binEdges: [Int]
        /// `rows × bins` band means, 0…255.
        let values: [UInt8]
        /// Rows with visible structure: varied across the row, or different from
        /// a neighbour. A blank row matches anything, so it can't vouch for an
        /// alignment.
        let informative: [Bool]
    }

    /// Mean per-band difference (0…255) below which two rows count as the same.
    static let rowTolerance = 2
    /// Per-band difference allowed when deciding a row is unchanged.
    static let bandTolerance = 3

    static func signature(of frame: Frame, columns: Range<Int>) -> RowSignature {
        let lower = max(0, min(columns.lowerBound, frame.width - 1))
        let upper = max(lower + 1, min(columns.upperBound, frame.width))
        let span = upper - lower
        let bins = max(1, min(64, span / 32))
        var edges = [Int](repeating: 0, count: bins + 1)
        for bin in 0...bins { edges[bin] = lower + span * bin / bins }

        var values = [UInt8](repeating: 0, count: frame.height * bins)
        frame.withPixels { base in
            values.withUnsafeMutableBufferPointer { output in
                for y in 0..<frame.height {
                    let row = base + y * frame.bytesPerRow
                    for bin in 0..<bins {
                        let start = edges[bin], end = edges[bin + 1]
                        let step = max(1, (end - start) / 20)
                        var sum = 0, samples = 0
                        var x = start
                        while x < end {
                            let pixel = row + x * 4
                            sum += Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])
                            samples += 1
                            x += step
                        }
                        output[y * bins + bin] = UInt8(min(255, (sum + samples * 3 / 2) / max(1, samples * 3)))
                    }
                }
            }
        }

        var informative = [Bool](repeating: false, count: frame.height)
        values.withUnsafeBufferPointer { v in
            for y in 0..<frame.height {
                let row = y * bins
                var low = 255, high = 0
                for bin in 0..<bins {
                    let value = Int(v[row + bin])
                    low = min(low, value); high = max(high, value)
                }
                if high - low > bandTolerance { informative[y] = true; continue }
                // A uniform row still marks a position when it differs from the
                // row beside it (a rule, a border, the edge of a block).
                if y > 0, rowDistance(v, row, v, row - bins, bins) > rowTolerance * bins {
                    informative[y] = true
                } else if y + 1 < frame.height, rowDistance(v, row, v, row + bins, bins) > rowTolerance * bins {
                    informative[y] = true
                }
            }
        }
        return RowSignature(rows: frame.height, bins: bins, binEdges: edges, values: values, informative: informative)
    }

    /// Band difference that rejects a row on its own, so a single strong local
    /// feature (a caret over a blank line) can't pass as a match.
    static let bandOutlier = 16

    @inline(__always)
    private static func rowsAgree(_ a: UnsafeBufferPointer<UInt8>, _ aStart: Int,
                                  _ b: UnsafeBufferPointer<UInt8>, _ bStart: Int, _ bins: [Int],
                                  tolerance: Int) -> Bool {
        var total = 0
        for bin in bins {
            let difference = abs(Int(a[aStart + bin]) - Int(b[bStart + bin]))
            if difference > bandOutlier { return false }
            total += difference
        }
        return total <= tolerance
    }

    /// Sum of per-band differences between two rows.
    @inline(__always)
    private static func rowDistance(_ a: UnsafeBufferPointer<UInt8>, _ aStart: Int,
                                    _ b: UnsafeBufferPointer<UInt8>, _ bStart: Int, _ bins: Int) -> Int {
        var total = 0
        for bin in 0..<bins { total += abs(Int(a[aStart + bin]) - Int(b[bStart + bin])) }
        return total
    }

    // MARK: - Unchanged rows

    /// Rows that show the same thing at the same place in both frames: pinned
    /// headers and footers, and blank rows. None of them can say how far the
    /// content moved. A few differing bands (a blinking caret, a spinner) still
    /// count as unchanged.
    static func unchangedRows(_ a: RowSignature, _ b: RowSignature) -> [Bool] {
        guard a.rows == b.rows, a.bins == b.bins else { return [Bool](repeating: false, count: b.rows) }
        let required = (a.bins * 9 + 9) / 10
        var result = [Bool](repeating: false, count: a.rows)
        a.values.withUnsafeBufferPointer { av in
            b.values.withUnsafeBufferPointer { bv in
                for y in 0..<a.rows {
                    let start = y * a.bins
                    var same = 0
                    for bin in 0..<a.bins where abs(Int(av[start + bin]) - Int(bv[start + bin])) <= bandTolerance {
                        same += 1
                    }
                    result[y] = same >= required
                }
            }
        }
        return result
    }

    /// How two grabs of the same rectangle relate.
    struct Comparison: Sendable {
        /// Per row: the same in both grabs (see `unchangedRows`).
        let unchanged: [Bool]
        /// Rows with structure in either grab.
        let informativeRows: Int
        /// Of those, the rows that changed.
        let changedInformativeRows: Int
        /// Share of all rows that changed, 0…1.
        let changedFraction: Double
        /// Per band: it changes along with the scrolling content. Bands that
        /// stay put while rows around them change — a sidebar, another window
        /// overlapping the selection, a blank margin — can't follow an offset
        /// and are left out of matching.
        let movingBins: [Bool]

        /// Nothing scrolled — at most a small local change such as a caret, a
        /// spinner or a hover highlight. Scrolling changes nearly every row
        /// that has content, however sparse the page.
        var isAtRest: Bool { changedInformativeRows <= max(2, informativeRows * 15 / 100) }

        /// Practically pixel-identical: one grab can stand in for the other.
        var isIdentical: Bool { changedFraction <= 0.02 }
    }

    static func compare(_ a: RowSignature, _ b: RowSignature) -> Comparison {
        let unchanged = unchangedRows(a, b)
        var informative = 0, changedInformative = 0, changed = 0
        for y in 0..<unchanged.count {
            if !unchanged[y] { changed += 1 }
            let hasContent = (y < a.informative.count && a.informative[y])
                || (y < b.informative.count && b.informative[y])
            guard hasContent else { continue }
            informative += 1
            if !unchanged[y] { changedInformative += 1 }
        }
        let fraction = unchanged.isEmpty ? 0 : Double(changed) / Double(unchanged.count)
        return Comparison(unchanged: unchanged, informativeRows: informative,
                          changedInformativeRows: changedInformative, changedFraction: fraction,
                          movingBins: movingBins(a, b, unchanged: unchanged))
    }

    /// Bands that differ in more than a tenth of the rows that changed. With
    /// fewer than two such bands, every band counts.
    static func movingBins(_ a: RowSignature, _ b: RowSignature, unchanged: [Bool]) -> [Bool] {
        let bins = b.bins
        guard a.rows == b.rows, a.bins == bins, unchanged.count == a.rows else {
            return [Bool](repeating: true, count: bins)
        }
        var differing = [Int](repeating: 0, count: bins)
        var changedRows = 0
        a.values.withUnsafeBufferPointer { av in
            b.values.withUnsafeBufferPointer { bv in
                for y in 0..<a.rows where !unchanged[y] {
                    changedRows += 1
                    let start = y * bins
                    for bin in 0..<bins where abs(Int(av[start + bin]) - Int(bv[start + bin])) > bandTolerance {
                        differing[bin] += 1
                    }
                }
            }
        }
        let moving = differing.map { $0 * 10 > changedRows }
        return moving.filter { $0 }.count >= 2 ? moving : [Bool](repeating: true, count: bins)
    }

    /// Rows left out of matching: the unchanged runs at the top and bottom
    /// edges (pinned bars, blank margins). Unchanged rows in between are
    /// content that merely looks the same in place — on Retina every line is
    /// two identical pixel rows, so after an odd-pixel scroll half the rows
    /// match where they are — and still take part.
    static func pinnedRows(_ unchanged: [Bool]) -> [Bool] {
        let bands = pinnedBands(unchanged)
        var result = [Bool](repeating: false, count: unchanged.count)
        for y in 0..<bands.top { result[y] = true }
        for y in (unchanged.count - bands.bottom)..<unchanged.count { result[y] = true }
        return result
    }

    /// Unchanged rows pinned to the top and bottom edges.
    static func pinnedBands(_ unchanged: [Bool]) -> (top: Int, bottom: Int) {
        let top = unchanged.firstIndex(of: false) ?? unchanged.count
        guard top < unchanged.count else { return (unchanged.count, 0) }
        let bottom = unchanged.count - 1 - (unchanged.lastIndex(of: false) ?? unchanged.count - 1)
        return (top, bottom)
    }

    // MARK: - Alignment

    struct Alignment: Equatable, Sendable {
        /// Rows the content moved up: `current[y]` shows what `reference[y + shift]`
        /// showed. Positive when the page scrolled down.
        let shift: Int
        /// Share of compared rows that agreed.
        let agreement: Double
        let comparedRows: Int
        /// Bands that followed the offset (nil: all of them). A translucent bar
        /// over the content changes as the page moves without moving with it;
        /// its bands are left out once the offset is known.
        var bins: [Bool]? = nil
    }

    /// Rows needed before an alignment can be trusted.
    static let minimumComparedRows = 8
    /// Share of compared rows that must agree. A spinner or hover highlight
    /// pinned to the screen disagrees in both frames; the rest has to carry it.
    static let minimumAgreement = 0.7

    /// The vertical offset that best maps `current` onto `reference`, or nil
    /// when no offset is convincing (the content moved further than a frame,
    /// changed, or is blank).
    ///
    /// Rows pinned to the top and bottom edges (see `pinnedRows`) don't take
    /// part, so headers and footers can neither vote for nor against an offset.
    static func alignment(reference a: RowSignature, current b: RowSignature,
                          unchanged: [Bool], movingBins: [Bool]? = nil,
                          preferredShift: Int? = nil) -> Alignment? {
        guard a.rows == b.rows, a.bins == b.bins, unchanged.count == a.rows, a.rows > minimumComparedRows else {
            return nil
        }
        let rows = a.rows, bins = a.bins
        let moving = movingBins.flatMap { $0.count == bins ? $0 : nil } ?? [Bool](repeating: true, count: bins)
        let movingIndices = (0..<bins).filter { moving[$0] }
        guard !movingIndices.isEmpty else { return nil }

        // Rows between the pinned edges, in a low-discrepancy order: any
        // prefix of the list samples the whole frame evenly, so a cluster of
        // odd rows (a translucent bar, a block of another window) can't make
        // the real offset look hopeless early on.
        let pinned = pinnedRows(unchanged)
        let scrollingRows = (0..<rows).filter { !pinned[$0] }
        guard scrollingRows.count >= minimumComparedRows else { return nil }
        var probes: [Int] = []
        probes.reserveCapacity(scrollingRows.count)
        let count = scrollingRows.count
        var step = max(1, Int(Double(count) * 0.6180339887))
        while gcd(step, count) != 1 { step += 1 }
        for k in 0..<count { probes.append(scrollingRows[(k * step) % count]) }

        return a.values.withUnsafeBufferPointer { av -> Alignment? in
            b.values.withUnsafeBufferPointer { bv -> Alignment? in
                func score(_ shift: Int, limit: Int, bins binList: [Int], giveUpEarly: Bool,
                           informativeA: [Bool], informativeB: [Bool]) -> (agree: Int, compared: Int) {
                    let tolerance = rowTolerance * binList.count
                    var agree = 0, compared = 0, disagree = 0
                    for y in probes {
                        let source = y + shift
                        guard source >= 0, source < rows, !pinned[source] else { continue }
                        guard informativeB[y] || informativeA[source] else { continue }
                        compared += 1
                        if rowsAgree(av, source * bins, bv, y * bins, binList, tolerance: tolerance) {
                            agree += 1
                        } else {
                            disagree += 1
                            // Hopeless candidates are dropped early; a real match
                            // keeps most rows in agreement.
                            if giveUpEarly && disagree >= 16 && disagree > agree * 2 { return (agree, compared) }
                        }
                        if compared >= limit { break }
                    }
                    return (agree, compared)
                }

                /// Offsets worth a closer look, judged on a sample of rows.
                func coarseCandidates(bins binList: [Int], informativeA: [Bool], informativeB: [Bool],
                                      minimumRatio: Double, keep: Int) -> [Int] {
                    let maxShift = rows - minimumComparedRows
                    var found: [(shift: Int, ratio: Double, compared: Int)] = []
                    for shift in -maxShift...maxShift where shift != 0 {
                        let result = score(shift, limit: 64, bins: binList, giveUpEarly: true,
                                           informativeA: informativeA, informativeB: informativeB)
                        guard result.compared >= minimumComparedRows else { continue }
                        let ratio = Double(result.agree) / Double(result.compared)
                        if ratio >= minimumRatio { found.append((shift, ratio, result.compared)) }
                    }
                    found.sort { $0.ratio != $1.ratio ? $0.ratio > $1.ratio : $0.compared > $1.compared }
                    return found.prefix(keep).map(\.shift)
                }

                /// Bands that keep failing at `shift` while the rest agree.
                func inconsistentBins(at shift: Int) -> Set<Int> {
                    var misses = [Int](repeating: 0, count: bins)
                    var compared = 0
                    for y in probes {
                        let source = y + shift
                        guard source >= 0, source < rows, !pinned[source],
                              b.informative[y] || a.informative[source] else { continue }
                        compared += 1
                        for bin in movingIndices
                        where abs(Int(av[source * bins + bin]) - Int(bv[y * bins + bin])) > bandOutlier {
                            misses[bin] += 1
                        }
                    }
                    // At the real offset a band that follows the page practically
                    // never misses; one that misses in 5 % of rows doesn't follow it.
                    let failing = Set(movingIndices.filter { misses[$0] * 20 > compared })
                    // Only a minority of bands can be set aside; beyond that
                    // the offset itself is wrong.
                    return failing.count * 4 <= movingIndices.count && movingIndices.count - failing.count >= 2
                        ? failing : []
                }

                /// Every moving row for each candidate, without the bands that
                /// don't follow it.
                func bestOf(_ candidates: [Int]) -> Alignment? {
                    var best: Alignment?
                    for shift in candidates {
                        let skipped = inconsistentBins(at: shift)
                        let usable = movingIndices.filter { !skipped.contains($0) }
                        let result = score(shift, limit: Int.max, bins: usable, giveUpEarly: false,
                                           informativeA: a.informative, informativeB: b.informative)
                        guard result.compared >= minimumComparedRows else { continue }
                        var mask = [Bool](repeating: false, count: bins)
                        for bin in usable { mask[bin] = true }
                        let found = Alignment(shift: shift,
                                              agreement: Double(result.agree) / Double(result.compared),
                                              comparedRows: result.compared, bins: mask)
                        guard let current = best else { best = found; continue }
                        if isBetter(found, than: current, preferredShift: preferredShift) { best = found }
                    }
                    return best
                }

                let primary = coarseCandidates(bins: movingIndices, informativeA: a.informative,
                                               informativeB: b.informative, minimumRatio: 0.4, keep: 8)
                if let best = bestOf(primary), best.agreement >= minimumAgreement { return best }

                // A region that changes without following the page (a
                // translucent window over part of the selection, a band that is
                // half sidebar) can spoil every row. Look for the offset in
                // each quarter of the width on its own, then judge the
                // candidates on all bands again.
                guard movingIndices.count >= 2 else { return nil }
                var candidates = primary
                let groups = min(4, movingIndices.count)
                for group in 0..<groups {
                    let slice = Array(movingIndices[(movingIndices.count * group / groups)..<(movingIndices.count * (group + 1) / groups)])
                    guard !slice.isEmpty else { continue }
                    let localA = informativeRows(a, av, bins: slice)
                    let localB = informativeRows(b, bv, bins: slice)
                    for shift in coarseCandidates(bins: slice, informativeA: localA, informativeB: localB,
                                                  minimumRatio: 0.6, keep: 4) where !candidates.contains(shift) {
                        candidates.append(shift)
                    }
                }
                guard let best = bestOf(candidates), best.agreement >= minimumAgreement else { return nil }
                return best
            }
        }
    }

    /// Rows with structure within `bins` alone.
    private static func informativeRows(_ signature: RowSignature, _ values: UnsafeBufferPointer<UInt8>,
                                        bins binList: [Int]) -> [Bool] {
        let bins = signature.bins
        var result = [Bool](repeating: false, count: signature.rows)
        for y in 0..<signature.rows {
            let row = y * bins
            var low = 255, high = 0
            for bin in binList {
                let value = Int(values[row + bin])
                low = min(low, value); high = max(high, value)
            }
            if high - low > bandTolerance { result[y] = true; continue }
            func differs(from neighbour: Int) -> Bool {
                guard neighbour >= 0, neighbour < signature.rows else { return false }
                var total = 0
                for bin in binList { total += abs(Int(values[row + bin]) - Int(values[neighbour * bins + bin])) }
                return total > rowTolerance * binList.count
            }
            result[y] = differs(from: y - 1) || differs(from: y + 1)
        }
        return result
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (a, b)
        while y != 0 { (x, y) = (y, x % y) }
        return abs(x)
    }

    /// Rows pinned to the bottom edge: counted up from the bottom while a row
    /// either didn't change or didn't move with the content — an opaque bar,
    /// or a translucent one showing the page blurred beneath it. Blank rows
    /// count too; that's harmless, see `ScrollStitcher`.
    static func pinnedBottomRows(reference a: RowSignature, current b: RowSignature,
                                 unchanged: [Bool], alignment: Alignment) -> Int {
        guard a.rows == b.rows, a.bins == b.bins, unchanged.count == a.rows else { return 0 }
        let bins = a.bins
        let mask = alignment.bins.flatMap { $0.count == bins ? $0 : nil } ?? [Bool](repeating: true, count: bins)
        let binList = (0..<bins).filter { mask[$0] }
        guard !binList.isEmpty else { return 0 }
        let tolerance = rowTolerance * binList.count
        var count = 0
        a.values.withUnsafeBufferPointer { av in
            b.values.withUnsafeBufferPointer { bv in
                for y in stride(from: a.rows - 1, through: 0, by: -1) {
                    if unchanged[y] { count += 1; continue }
                    // Where this row of the reference shows up in the current frame.
                    let target = y - alignment.shift
                    guard target >= 0, target < b.rows else { break }
                    if rowsAgree(av, y * bins, bv, target * bins, binList, tolerance: tolerance) { break }
                    count += 1
                }
            }
        }
        return count
    }

    /// Ranks alignments: clearly better agreement wins. Near ties — repeating
    /// content, where several offsets fit — go to the one closest to the
    /// expected offset, then to the one backed by more rows (the smaller move).
    private static func isBetter(_ candidate: Alignment, than current: Alignment, preferredShift: Int?) -> Bool {
        if abs(candidate.agreement - current.agreement) > 0.02 { return candidate.agreement > current.agreement }
        if let preferredShift {
            let candidateDistance = abs(candidate.shift - preferredShift)
            let currentDistance = abs(current.shift - preferredShift)
            if candidateDistance != currentDistance { return candidateDistance < currentDistance }
        }
        if candidate.comparedRows != current.comparedRows { return candidate.comparedRows > current.comparedRows }
        return abs(candidate.shift) < abs(current.shift)
    }

    // MARK: - Pixel verification

    /// Mean colour difference (0…255) at which two pixel rows still count as
    /// the same row rendered twice.
    static let pixelRowTolerance = 6

    /// Re-checks an alignment against the pixels themselves, and settles a
    /// one-row ambiguity between neighbouring offsets. Returns nil when the
    /// pixels disagree with the row summaries.
    ///
    /// Every row is compared: on a Retina display each line of content is
    /// usually two identical pixel rows, so every other row can't tell an
    /// offset from its neighbour. Only `columns` are compared (the moving
    /// bands). A neighbour replaces the estimate only when it is clearly better.
    static func verify(_ alignment: Alignment, reference a: Frame, current b: Frame,
                       unchanged: [Bool], columns: [Range<Int>]) -> Alignment? {
        guard a.width == b.width, a.height == b.height, unchanged.count == a.height else { return nil }
        let ranges = columns.map { max(0, $0.lowerBound)..<max(0, min(a.width, $0.upperBound)) }.filter { !$0.isEmpty }
        let span = ranges.reduce(0) { $0 + $1.count }
        guard span > 0 else { return nil }
        let step = max(1, span / 384)
        var offsets: [Int] = []
        for range in ranges {
            var x = range.lowerBound
            while x < range.upperBound { offsets.append(x * 4); x += step }
        }

        let pinned = pinnedRows(unchanged)
        func measure(_ shift: Int) -> (agree: Int, compared: Int, error: Int)? {
            guard shift != 0 else { return nil }
            var agree = 0, compared = 0, totalError = 0
            a.withPixels { ap in
                b.withPixels { bp in
                    offsets.withUnsafeBufferPointer { xs in
                        for y in 0..<b.height {
                            let source = y + shift
                            guard source >= 0, source < a.height, !pinned[y], !pinned[source] else { continue }
                            let rowA = ap + source * a.bytesPerRow, rowB = bp + y * b.bytesPerRow
                            var sum = 0
                            for offset in xs {
                                sum += abs(Int(rowA[offset]) - Int(rowB[offset]))
                                    + abs(Int(rowA[offset + 1]) - Int(rowB[offset + 1]))
                                    + abs(Int(rowA[offset + 2]) - Int(rowB[offset + 2]))
                            }
                            let error = sum / max(1, xs.count * 3)
                            compared += 1
                            totalError += error
                            if error <= pixelRowTolerance { agree += 1 }
                        }
                    }
                }
            }
            return compared > 0 ? (agree, compared, totalError) : nil
        }

        guard var best = measure(alignment.shift).map({ (shift: alignment.shift, result: $0) }) else { return nil }
        for neighbour in [alignment.shift - 1, alignment.shift + 1] {
            guard let result = measure(neighbour) else { continue }
            let mean = Double(result.error) / Double(result.compared)
            let bestMean = Double(best.result.error) / Double(best.result.compared)
            let agreement = Double(result.agree) / Double(result.compared)
            let bestAgreement = Double(best.result.agree) / Double(best.result.compared)
            if mean + 0.25 < bestMean && agreement >= bestAgreement { best = (neighbour, result) }
        }
        guard best.result.compared >= minimumComparedRows else { return nil }
        let agreement = Double(best.result.agree) / Double(best.result.compared)
        guard agreement >= 0.7 else { return nil }
        return Alignment(shift: best.shift, agreement: agreement, comparedRows: best.result.compared)
    }

    static func verify(_ alignment: Alignment, reference a: Frame, current b: Frame,
                       unchanged: [Bool], columns: Range<Int>) -> Alignment? {
        verify(alignment, reference: a, current: b, unchanged: unchanged, columns: [columns])
    }

    /// Pixel columns of the moving bands, as contiguous runs.
    static func columns(of signature: RowSignature, movingBins: [Bool]) -> [Range<Int>] {
        guard movingBins.count == signature.bins, signature.binEdges.count == signature.bins + 1 else {
            return [(signature.binEdges.first ?? 0)..<(signature.binEdges.last ?? 0)]
        }
        var runs: [Range<Int>] = []
        var start: Int?
        for bin in 0...signature.bins {
            let moving = bin < signature.bins && movingBins[bin]
            if moving, start == nil { start = signature.binEdges[bin] }
            if !moving, let first = start {
                runs.append(first..<signature.binEdges[bin])
                start = nil
            }
        }
        return runs
    }
}
