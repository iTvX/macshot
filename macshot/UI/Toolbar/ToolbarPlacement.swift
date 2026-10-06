import Cocoa

/// Geometry shared by the live overlay, the editor and the layout regression tests.
enum ToolbarPlacement {
    /// Space beyond image edges in the editor window: room for the bar below the image.
    static let editorContentInsets = NSEdgeInsets(top: 16, left: 16, bottom: 76, right: 16)

    enum Side { case below, above, inside }

    struct Frames {
        let bar: NSRect
        /// The options panel; `.zero` when no panel is shown.
        let panel: NSRect
        let side: Side
    }

    static let margin: CGFloat = 10
    /// Clear of the selection handles' hit areas, which reach 7pt past its edges.
    static let barGap: CGFloat = 10
    static let panelGap: CGFloat = 6

    /// The bar sits right-aligned with the selection's right edge — where the pointer
    /// ends after dragging a selection — below it, else above it, else inside its
    /// bottom edge (selections that fill the screen). An open options panel hangs on the
    /// bar's outer side, centred on `panelAnchorX` (bar coordinates).
    static func place(in bounds: NSRect, around anchor: NSRect, bar: NSSize,
                      panel: NSSize? = nil, panelAnchorX: CGFloat? = nil,
                      obstacles: [NSRect] = []) -> Frames {
        let safe = bounds.insetBy(dx: margin, dy: margin)
        let x = max(safe.minX, min(anchor.maxX - bar.width, safe.maxX - bar.width))
        let panelBlock = panel.map { $0.height + panelGap } ?? 0
        func isClear(_ rect: NSRect) -> Bool { rect.isEmpty || !obstacles.contains { $0.intersects(rect) } }
        func panelFrame(for barRect: NSRect, below: Bool) -> NSRect {
            guard let panel else { return .zero }
            let centre = barRect.minX + (panelAnchorX ?? barRect.width / 2)
            let px = max(safe.minX, min(centre - panel.width / 2, safe.maxX - panel.width))
            let py = below ? barRect.minY - panelGap - panel.height : barRect.maxY + panelGap
            return NSRect(x: px, y: py, width: panel.width, height: panel.height)
        }

        let belowY = anchor.minY - barGap - bar.height
        if belowY - panelBlock >= safe.minY {
            let barRect = NSRect(x: x, y: belowY, width: bar.width, height: bar.height)
            let panelRect = panelFrame(for: barRect, below: true)
            if isClear(barRect) && isClear(panelRect) { return Frames(bar: barRect, panel: panelRect, side: .below) }
        }
        let aboveY = anchor.maxY + barGap
        if aboveY + bar.height + panelBlock <= safe.maxY {
            let barRect = NSRect(x: x, y: aboveY, width: bar.width, height: bar.height)
            let panelRect = panelFrame(for: barRect, below: false)
            if isClear(barRect) && isClear(panelRect) { return Frames(bar: barRect, panel: panelRect, side: .above) }
        }
        let insideY = max(safe.minY, min(anchor.minY + barGap, safe.maxY - bar.height - panelBlock))
        let barRect = NSRect(x: x, y: insideY, width: bar.width, height: bar.height)
        return Frames(bar: barRect, panel: panelFrame(for: barRect, below: false), side: .inside)
    }

    /// Editor window: the bar is centred at the bottom; the panel opens above it.
    static func placeInEditor(in bounds: NSRect, bar: NSSize, panel: NSSize? = nil,
                              panelAnchorX: CGFloat? = nil) -> Frames {
        let barRect = NSRect(x: round(bounds.midX - bar.width / 2), y: 16, width: bar.width, height: bar.height)
        guard let panel else { return Frames(bar: barRect, panel: .zero, side: .inside) }
        let safe = bounds.insetBy(dx: margin, dy: margin)
        let centre = barRect.minX + (panelAnchorX ?? bar.width / 2)
        let px = max(safe.minX, min(centre - panel.width / 2, safe.maxX - panel.width))
        let panelRect = NSRect(x: round(px), y: barRect.maxY + panelGap, width: panel.width, height: panel.height)
        return Frames(bar: barRect, panel: panelRect, side: .inside)
    }

    /// The size pill: above the selection's top-left corner (where screenshot tools
    /// show dimensions); inside that corner when there is no room or the bar, panel or
    /// notch is in the way; below-left as a last resort. Never covers a resize handle.
    static func placeBadge(size: NSSize, selection: NSRect, in bounds: NSRect,
                           avoiding avoid: [NSRect] = []) -> NSRect {
        let gap = barGap
        let limits = bounds.insetBy(dx: 4, dy: 4)
        func clampX(_ x: CGFloat) -> CGFloat { max(limits.minX, min(x, limits.maxX - size.width)) }
        let fitsInside = selection.width >= size.width + gap * 2 && selection.height >= size.height + gap * 2
        var candidates = [NSRect(x: clampX(selection.minX), y: selection.maxY + gap, width: size.width, height: size.height)]
        if fitsInside {
            candidates.append(NSRect(x: clampX(selection.minX + gap), y: selection.maxY - gap - size.height,
                                     width: size.width, height: size.height))
        }
        candidates.append(NSRect(x: clampX(selection.minX), y: selection.minY - gap - size.height,
                                 width: size.width, height: size.height))
        func overlap(_ rect: NSRect) -> CGFloat {
            avoid.reduce(0) { total, other in
                let hit = rect.intersection(other)
                return hit.isNull ? total : total + hit.width * hit.height
            }
        }
        let onScreen = candidates.filter { limits.contains($0) }
        if let clear = onScreen.first(where: { overlap($0) == 0 }) { return clear }
        if let least = onScreen.min(by: { overlap($0) < overlap($1) }) { return least }
        let fallback = candidates[0]
        return NSRect(x: fallback.minX, y: max(limits.minY, min(fallback.minY, limits.maxY - size.height)),
                      width: size.width, height: size.height)
    }
}
