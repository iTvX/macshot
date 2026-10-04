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
        func x(_ desired: CGFloat, _ width: CGFloat) -> CGFloat {
            max(safe.minX, min(desired, safe.maxX - width))
        }
        func y(_ desired: CGFloat, _ height: CGFloat) -> CGFloat {
            max(safe.minY, min(desired, safe.maxY - height))
        }
        let below = anchor.minY - 12 - groupHeight
        let above = anchor.maxY + 12
        var groupY = below >= safe.minY ? below : (above + groupHeight <= safe.maxY ? above : y(anchor.minY + 12, groupHeight))
        let groupX = x(anchor.midX - max(tools.width, options.width) / 2, max(tools.width, options.width))
        for obstacle in obstacles {
            let group = NSRect(x: groupX, y: groupY, width: max(tools.width, options.width), height: groupHeight)
            if group.intersects(obstacle) { groupY = y(obstacle.minY - groupHeight - 8, groupHeight) }
        }
        let toolFrame = NSRect(x: x(anchor.midX - tools.width / 2, tools.width),
                              y: groupY + options.height + optionsGap, width: tools.width, height: tools.height)
        let optionFrame = options.height > 0
            ? NSRect(x: x(toolFrame.midX - options.width / 2, options.width), y: groupY, width: options.width, height: options.height)
            : .zero
        let group = toolFrame.union(optionFrame.isEmpty ? toolFrame : optionFrame).insetBy(dx: -8, dy: -8)
        let actionX = x(anchor.maxX - actions.width, actions.width)
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
