import Cocoa

/// Geometry shared by the live overlay and the layout regression tests.
enum ToolbarPlacement {
    // Space beyond image edges for the top actions and two bottom rows.
    static let editorContentInsets = NSEdgeInsets(top: 82, left: 16, bottom: 134, right: 16)

    struct Frames {
        let tools: NSRect
        let actions: NSRect
        let options: NSRect
    }

    static func place(in bounds: NSRect, around anchor: NSRect,
                      tools: NSSize, actions: NSSize, options: NSSize,
                      obstacles: [NSRect] = []) -> Frames {
        let safe = bounds.insetBy(dx: 12, dy: 12)
        let optionsGap: CGFloat = options.height > 0 ? 6 : 0
        let groupHeight = tools.height + optionsGap + options.height
        let groupWidth = max(tools.width, options.width)
        // Resize handles straddle the selection edges; chrome placed outside must leave them reachable.
        let selection = anchor.insetBy(dx: -6, dy: -6)
        func x(_ desired: CGFloat, _ width: CGFloat) -> CGFloat {
            max(safe.minX, min(desired, safe.maxX - width))
        }
        func y(_ desired: CGFloat, _ height: CGFloat) -> CGFloat {
            max(safe.minY, min(desired, safe.maxY - height))
        }
        func isClear(_ rect: NSRect) -> Bool {
            safe.contains(rect) && !obstacles.contains { $0.intersects(rect) }
        }
        let below = anchor.minY - 12 - groupHeight
        let above = anchor.maxY + 12
        var groupY = below >= safe.minY ? below : (above + groupHeight <= safe.maxY ? above : y(anchor.minY + 12, groupHeight))
        let groupX = x(anchor.midX - groupWidth / 2, groupWidth)
        for obstacle in obstacles {
            let group = NSRect(x: groupX, y: groupY, width: groupWidth, height: groupHeight)
            guard group.intersects(obstacle) else { continue }
            // Step past the obstacle away from the selection; stepping toward it
            // would cover the content, so that is only the last resort.
            let outward = groupY >= anchor.maxY ? obstacle.maxY + 8 : obstacle.minY - groupHeight - 8
            let moved = NSRect(x: groupX, y: outward, width: groupWidth, height: groupHeight)
            groupY = isClear(moved) ? outward : y(obstacle.minY - groupHeight - 8, groupHeight)
        }
        let toolFrame = NSRect(x: x(anchor.midX - tools.width / 2, tools.width),
                              y: groupY + options.height + optionsGap, width: tools.width, height: tools.height)
        let optionFrame = options.height > 0
            ? NSRect(x: x(toolFrame.midX - options.width / 2, options.width), y: groupY, width: options.width, height: options.height)
            : .zero
        let group = toolFrame.union(optionFrame.isEmpty ? toolFrame : optionFrame).insetBy(dx: -8, dy: -8)
        let actionX = x(anchor.maxX - actions.width, actions.width)
        let topY = y(anchor.maxY - actions.height, actions.height)
        // Beside the top corner, dropped under anything (the notch) in the way.
        func besideTop(_ originX: CGFloat) -> [NSPoint] {
            let rect = NSRect(x: originX, y: topY, width: actions.width, height: actions.height)
            let lowered = obstacles.filter { $0.intersects(rect) }.map { $0.minY - actions.height - 8 }.min()
            return [NSPoint(x: originX, y: topY)] + (lowered.map { [NSPoint(x: originX, y: $0)] } ?? [])
        }
        // Outside the selection first: above its trailing edge, beside its top
        // corners, then past the tools. Float inside only when nothing is left.
        let outside = ([NSPoint(x: actionX, y: anchor.maxY + 12)]
            + besideTop(anchor.maxX + 12) + besideTop(anchor.minX - actions.width - 12)
            + [NSPoint(x: actionX, y: group.maxY + 8),
               NSPoint(x: actionX, y: group.minY - actions.height - 8),
               NSPoint(x: actionX, y: anchor.minY - actions.height - 12)])
            .map { NSRect(origin: $0, size: actions) }
        if let clear = outside.first(where: { isClear($0) && !$0.intersects(group) && !$0.intersects(selection) }) {
            return Frames(tools: toolFrame, actions: clear, options: optionFrame)
        }
        let candidates = [anchor.maxY + 12, group.maxY + 8, anchor.minY - actions.height - 12,
                          anchor.maxY - actions.height - 12, safe.maxY - actions.height, safe.minY]
        var actionFrame = NSRect(origin: NSPoint(x: actionX, y: y(candidates[0], actions.height)), size: actions)
        for candidate in candidates {
            var rect = NSRect(origin: NSPoint(x: actionX, y: y(candidate, actions.height)), size: actions)
            for obstacle in obstacles where rect.intersects(obstacle) {
                rect.origin.y = y(obstacle.minY - actions.height - 8, actions.height)
            }
            if !rect.intersects(group) && !obstacles.contains(where: { $0.intersects(rect) }) {
                actionFrame = rect; break
            }
        }
        return Frames(tools: toolFrame, actions: actionFrame, options: optionFrame)
    }
}
