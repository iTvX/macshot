import CoreGraphics
import Foundation

/// Decides how far each auto-scroll step goes, learning from how far the page
/// really moved. Apps scroll by very different distances per event, and a step
/// taller than the visible area leaves no overlap to stitch against.
nonisolated struct AutoScrollPlanner: Equatable {

    enum Unit: Equatable, Sendable { case pixel, line }

    struct Step: Equatable, Sendable {
        let unit: Unit
        /// Positive scrolls the content towards its end.
        let amount: Int32
    }

    enum Decision: Equatable, Sendable {
        case keepGoing
        /// The page stopped moving: its end was reached.
        case reachedEnd
        /// The window doesn't respond to synthetic scrolling.
        case cannotScroll
    }

    /// Share of the visible height that one step moves, per speed setting (1…4).
    static func stepFraction(speed: Int) -> Double {
        switch speed {
        case 1: return 0.3
        case 2: return 0.45
        case 4: return 0.75
        default: return 0.6
        }
    }

    private(set) var unit: Unit = .pixel
    private var viewportPixels: Double
    private let scale: Double
    private let preferredFraction: Double
    private var fraction: Double
    private var direction: Int32 = 1
    private var pixelsPerUnit: [Unit: Double] = [:]
    private var hasMoved = false
    private var stillSteps = 0
    private var lostSteps = 0
    private var lastStep: Step?
    private var reverseNext = false
    private var lastStepWasReverse = false

    /// - Parameters:
    ///   - viewportPixels: Height of the part of the frame that scrolls.
    ///   - scale: Pixels per point of the display.
    init(viewportPixels: Int, scale: CGFloat, speed: Int) {
        self.viewportPixels = Double(max(1, viewportPixels))
        self.scale = Double(max(1, scale))
        preferredFraction = Self.stepFraction(speed: speed)
        // Cautious until the first step shows how this app scrolls.
        fraction = min(preferredFraction, 0.3)
    }

    /// Narrows the visible height to the part that scrolls once pinned bars
    /// are known: a step must stay inside it.
    mutating func limitViewport(to pixels: Int) {
        guard pixels > 0 else { return }
        viewportPixels = min(viewportPixels, Double(pixels))
    }

    mutating func nextStep() -> Step {
        if reverseNext, let last = lastStep {
            // The previous step overshot; going back restores the overlap.
            reverseNext = false
            lastStepWasReverse = true
            let step = Step(unit: last.unit, amount: -last.amount)
            lastStep = step
            return step
        }
        lastStepWasReverse = false
        let target = max(1, fraction * viewportPixels)
        let amount: Double
        switch unit {
        case .pixel:
            // Pixel events are in points; until measured, assume one point
            // moves the page one point.
            let perUnit = pixelsPerUnit[.pixel] ?? scale
            amount = min(max((target / max(0.05, perUnit)).rounded(), 1), 4000)
        case .line:
            // Line height varies from app to app: probe with one line first.
            if let perUnit = pixelsPerUnit[.line], perUnit > 0 {
                amount = min(max((target / perUnit).rounded(), 1), 40)
            } else {
                amount = 1
            }
        }
        let step = Step(unit: unit, amount: direction * Int32(amount))
        lastStep = step
        return step
    }

    mutating func record(_ outcome: ScrollStitcher.Outcome) -> Decision {
        let wasReverse = lastStepWasReverse
        lastStepWasReverse = false
        switch outcome {
        case .scrolled(let shift, _):
            if wasReverse { return .keepGoing }
            if shift < 0 && !hasMoved {
                // Synthetic events scrolled the other way; follow suit.
                direction = -direction
                return .keepGoing
            }
            guard shift > 0 else { return stillStep() }
            if let step = lastStep, step.amount != 0 {
                let measured = Double(shift) / Double(abs(step.amount))
                let previous = pixelsPerUnit[step.unit]
                pixelsPerUnit[step.unit] = previous.map { ($0 + measured) / 2 } ?? measured
            }
            hasMoved = true
            stillSteps = 0
            lostSteps = 0
            fraction = min(preferredFraction, fraction * 1.5)
            return .keepGoing
        case .unchanged:
            if wasReverse { return .keepGoing }
            return stillStep()
        case .lost:
            lostSteps += 1
            if lostSteps >= 4 { return .cannotScroll }
            fraction = max(0.12, fraction / 2)
            if !wasReverse { reverseNext = true }
            return .keepGoing
        case .rejected:
            return .keepGoing
        case .limitReached:
            return .reachedEnd
        }
    }

    private mutating func stillStep() -> Decision {
        stillSteps += 1
        if hasMoved { return stillSteps >= 3 ? .reachedEnd : .keepGoing }
        guard stillSteps >= 2 else { return .keepGoing }
        if unit == .pixel {
            // Some apps ignore pixel-precise events; try classic wheel lines.
            unit = .line
            stillSteps = 0
            return .keepGoing
        }
        return .cannotScroll
    }
}
