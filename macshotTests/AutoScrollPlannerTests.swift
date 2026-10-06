import XCTest

/// Auto-scroll has to move the page far enough to make progress but never
/// further than the visible area, in apps that scroll by very different
/// distances per event — and know when to stop.
final class AutoScrollPlannerTests: XCTestCase {

    private func planner(viewport: Int = 1000, scale: CGFloat = 2, speed: Int = 3) -> AutoScrollPlanner {
        AutoScrollPlanner(viewportPixels: viewport, scale: scale, speed: speed)
    }

    func testTheFirstStepIsCautious() {
        var p = planner()
        let step = p.nextStep()
        XCTAssertEqual(step.unit, .pixel)
        // 30 % of 1000 px at 2 px per point.
        XCTAssertEqual(step.amount, 150)
    }

    func testStepsGrowTowardsTheSpeedOnceTheAppsScrollIsKnown() {
        var p = planner(speed: 3)
        _ = p.nextStep()                                            // 150 pt
        XCTAssertEqual(p.record(.scrolled(shift: 300, appendedRows: 300)), .keepGoing)
        let second = p.nextStep()
        XCTAssertEqual(second.amount, 225, "45 % of the viewport, at the measured 2 px per point")
        XCTAssertEqual(p.record(.scrolled(shift: 450, appendedRows: 450)), .keepGoing)
        XCTAssertEqual(p.nextStep().amount, 300, "60 %: the medium-fast default")
        XCTAssertEqual(p.record(.scrolled(shift: 600, appendedRows: 600)), .keepGoing)
        XCTAssertEqual(p.nextStep().amount, 300, "and no further")
    }

    func testAnAppThatScrollsFurtherPerEventGetsSmallerSteps() {
        var p = planner()
        _ = p.nextStep()                                            // 150 pt
        _ = p.record(.scrolled(shift: 600, appendedRows: 600))      // 4 px per point
        XCTAssertEqual(Double(p.nextStep().amount), 112.5, accuracy: 0.5, "450 px wanted at 4 px per point")
    }

    func testEverySpeedStaysWithinTheViewport() {
        for speed in 1...4 {
            XCTAssertLessThan(AutoScrollPlanner.stepFraction(speed: speed), 0.8, "speed \(speed)")
            XCTAssertGreaterThan(AutoScrollPlanner.stepFraction(speed: speed), 0.2, "speed \(speed)")
        }
        XCTAssertEqual(AutoScrollPlanner.stepFraction(speed: 99), AutoScrollPlanner.stepFraction(speed: 3))
    }

    func testThreeStillStepsAfterMovingMeanTheEnd() {
        var p = planner()
        _ = p.nextStep()
        _ = p.record(.scrolled(shift: 300, appendedRows: 300))
        _ = p.nextStep()
        XCTAssertEqual(p.record(.unchanged), .keepGoing)
        _ = p.nextStep()
        XCTAssertEqual(p.record(.unchanged), .keepGoing)
        _ = p.nextStep()
        XCTAssertEqual(p.record(.unchanged), .reachedEnd)
    }

    func testAnAppIgnoringPixelEventsGetsWheelLinesThenGivesUp() {
        var p = planner()
        _ = p.nextStep()
        XCTAssertEqual(p.record(.unchanged), .keepGoing)
        _ = p.nextStep()
        XCTAssertEqual(p.record(.unchanged), .keepGoing)
        let probe = p.nextStep()
        XCTAssertEqual(probe, AutoScrollPlanner.Step(unit: .line, amount: 1), "probe the line height first")
        XCTAssertEqual(p.record(.scrolled(shift: 80, appendedRows: 80)), .keepGoing)
        XCTAssertEqual(p.nextStep(), AutoScrollPlanner.Step(unit: .line, amount: 6),
                       "45 % of 1000 px at 80 px per line")

        var stubborn = planner()
        for _ in 0..<2 { _ = stubborn.nextStep(); _ = stubborn.record(.unchanged) }
        _ = stubborn.nextStep()
        XCTAssertEqual(stubborn.record(.unchanged), .keepGoing)
        _ = stubborn.nextStep()
        XCTAssertEqual(stubborn.record(.unchanged), .cannotScroll)
    }

    func testAnOvershootIsUndoneAndTheStepShrinks() {
        var p = planner()
        _ = p.nextStep()
        _ = p.record(.scrolled(shift: 300, appendedRows: 300))
        let big = p.nextStep()
        XCTAssertEqual(p.record(.lost), .keepGoing)
        let back = p.nextStep()
        XCTAssertEqual(back, AutoScrollPlanner.Step(unit: big.unit, amount: -big.amount), "scroll straight back")
        XCTAssertEqual(p.record(.unchanged), .keepGoing, "being back where we were isn't the end of the page")
        let next = p.nextStep()
        XCTAssertGreaterThan(next.amount, 0)
        XCTAssertLessThan(next.amount, big.amount)
    }

    func testRepeatedlyLosingThePageGivesUp() {
        var p = planner()
        var decision = AutoScrollPlanner.Decision.keepGoing
        for _ in 0..<8 where decision == .keepGoing {
            _ = p.nextStep()
            decision = p.record(.lost)
        }
        XCTAssertEqual(decision, .cannotScroll)
    }

    func testScrollingTheWrongWayFlipsDirection() {
        var p = planner()
        let first = p.nextStep()
        XCTAssertGreaterThan(first.amount, 0)
        XCTAssertEqual(p.record(.scrolled(shift: -300, appendedRows: 0)), .keepGoing)
        XCTAssertLessThan(p.nextStep().amount, 0)
    }

    func testStepsStayInsideTheScrollingPartOnceItIsKnown() {
        var p = planner(viewport: 1000, speed: 4)
        _ = p.nextStep()
        _ = p.record(.scrolled(shift: 300, appendedRows: 300))
        // Pinned bars turn out to take 600 of the 1000 rows.
        p.limitViewport(to: 400)
        for _ in 0..<3 {
            let step = p.nextStep()
            XCTAssertLessThanOrEqual(Int(step.amount) * 2, 400 * 3 / 4, "never more than three quarters of what scrolls")
            _ = p.record(.scrolled(shift: Int(step.amount) * 2, appendedRows: Int(step.amount) * 2))
        }
        p.limitViewport(to: 0)
        XCTAssertLessThanOrEqual(Int(p.nextStep().amount) * 2, 300, "an unknown height changes nothing")
    }

    func testTheHeightLimitEndsTheRun() {
        var p = planner()
        _ = p.nextStep()
        XCTAssertEqual(p.record(.limitReached), .reachedEnd)
    }
}
