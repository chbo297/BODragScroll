import XCTest

/// Deep, black-box parity coverage for the two scenarios whose behavior is easiest to regress
/// while still looking superficially correct: programmatic movement transactions and the
/// continuous panel/UITableView handoff. Every implementation run starts in a new application
/// process; assertions compare semantic terminal state rather than frame-by-frame callback counts.
final class MovementHandoffParityUITests: DemoUITestCase {
    func testMovementAutomaticSwiftObjectiveCParity() {
        assertMovementStyleParity(.automatic)
    }

    func testMovementSystemScrollSwiftObjectiveCParity() {
        assertMovementStyleParity(.systemScroll)
    }

    func testMovementViewAnimationSwiftObjectiveCParity() {
        assertMovementStyleParity(.viewAnimation)
    }

    func testMovementNonSnappingRangeSwiftObjectiveCParity() {
        let swift = runNonSnappingRange(implementation: .swift)
        let objectiveC = runNonSnappingRange(implementation: .objectiveC)

        XCTAssertLessThanOrEqual(
            abs(swift.retainedHeight - objectiveC.retainedHeight),
            80,
            "The same slow release should remain in the same non-snapping region"
        )
    }

    func testMovementNearestFromBothSidesOfMidpointMatchesObjectiveC() {
        for (desiredHeight, expectsMiddle) in [(300.0, false), (335.0, true)] as [(CGFloat, Bool)] {
            let swift = runMeaningfulNearest(
                implementation: .swift,
                desiredHeight: desiredHeight
            )
            let objectiveC = runMeaningfulNearest(
                implementation: .objectiveC,
                desiredHeight: desiredHeight
            )
            let expectedDetent = expectsMiddle ? 390 : demoMinimumInteractiveDisplayHeight()

            XCTAssertEqual(swift, expectedDetent, accuracy: 2)
            XCTAssertEqual(objectiveC, expectedDetent, accuracy: 2)
            XCTAssertEqual(swift, objectiveC, accuracy: 1)
        }
    }

    func testMovementInterruptionSwiftObjectiveCParity() {
        let swift = runInterruption(implementation: .swift)
        let objectiveC = runInterruption(implementation: .objectiveC)

        XCTAssertEqual(swift.finalHeight, objectiveC.finalHeight, accuracy: 1)
        XCTAssertEqual(swift.completionCount, objectiveC.completionCount)
        XCTAssertEqual(swift.firstCompletionCount, objectiveC.firstCompletionCount)
        XCTAssertEqual(swift.secondCompletionCount, objectiveC.secondCompletionCount)
    }

    func testHandoffPlacementsSwiftObjectiveCParity() {
        for placement in HandoffPlacement.allCases {
            let swift = runHandoff(placement: placement, implementation: .swift)
            let objectiveC = runHandoff(placement: placement, implementation: .objectiveC)

            XCTAssertEqual(
                swift.displayHeight,
                objectiveC.displayHeight,
                accuracy: placement == .afterFullyDisplayed ? 90 : 3,
                "Final panel height diverged for \(placement.rawValue)"
            )

            if placement == .afterFullyDisplayed {
                XCTAssertLessThanOrEqual(abs(swift.innerOffsetY), 8)
                XCTAssertLessThanOrEqual(abs(objectiveC.innerOffsetY), 8)
            } else {
                // Deceleration distance is intentionally not compared exactly: UIKit samples
                // velocity independently for each process. Both kernels must hand movement to the
                // table at the same boundary and leave the panel at the middle detent.
                XCTAssertGreaterThan(swift.innerOffsetY, 20)
                XCTAssertGreaterThan(objectiveC.innerOffsetY, 20)
            }
        }
    }

    func testAutomaticSmartHandoffBoundarySwiftObjectiveCParity() {
        let swift = runAutomaticSmartHandoff(implementation: .swift)
        let objectiveC = runAutomaticSmartHandoff(implementation: .objectiveC)

        let expectedLow = demoMinimumInteractiveDisplayHeight()
        XCTAssertEqual(swift.initialHeight, expectedLow, accuracy: swift.onePhysicalPixel)
        XCTAssertEqual(objectiveC.initialHeight, expectedLow, accuracy: objectiveC.onePhysicalPixel)
        XCTAssertEqual(
            swift.activationHeight,
            objectiveC.activationHeight,
            accuracy: max(swift.onePhysicalPixel, objectiveC.onePhysicalPixel),
            "Swift and OC activated the inner scroll at different detents"
        )
        XCTAssertEqual(
            swift.firstInnerHeight,
            objectiveC.firstInnerHeight,
            accuracy: max(swift.onePhysicalPixel, objectiveC.onePhysicalPixel),
            "Swift and OC first moved inner content at different panel heights"
        )
    }

    func testHandoffDynamicRowsSwiftAndObjectiveC() {
        for implementation in [DemoImplementationUnderTest.swift, .objectiveC] {
            runDynamicRows(implementation: implementation)
        }
    }

    func testForcedInnerBounceOnlyTrimsSmartPlacementInBothImplementations() {
        let automaticOC = runForcedBouncePlacement(.automatic, implementation: .objectiveC)
        let automaticSwift = runForcedBouncePlacement(.automatic, implementation: .swift)
        let fixedOC = runForcedBouncePlacement(.fixed, implementation: .objectiveC)
        let fixedSwift = runForcedBouncePlacement(.fixed, implementation: .swift)

        for observation in [automaticOC, automaticSwift] {
            XCTAssertEqual(observation.settledHeight, 390, accuracy: 2)
            XCTAssertGreaterThanOrEqual(observation.minimumHeight, 388)
            XCTAssertLessThan(observation.minimumInnerOffset, -1)
        }
        XCTAssertEqual(automaticSwift.settledHeight, automaticOC.settledHeight, accuracy: 1)
        XCTAssertEqual(automaticSwift.minimumHeight, automaticOC.minimumHeight, accuracy: 2)

        for observation in [fixedOC, fixedSwift] {
            XCTAssertLessThan(
                observation.minimumHeight,
                300,
                "Fixed authored placement must retain the lower panel region. Trace:\n\(observation.trace)"
            )
            XCTAssertLessThan(observation.settledHeight, 300)
            XCTAssertGreaterThanOrEqual(observation.minimumInnerOffset, -2)
        }
        XCTAssertEqual(fixedSwift.settledHeight, fixedOC.settledHeight, accuracy: 2)
        XCTAssertEqual(fixedSwift.minimumHeight, fixedOC.minimumHeight, accuracy: 3)
    }
}

private extension MovementHandoffParityUITests {
    enum MovementStyle: String {
        case automatic = "自动"
        case systemScroll = "系统"
        case viewAnimation = "View"
    }

    struct MovementStyleObservation {
        let high: CGFloat
        let middle: CGFloat
        let nearest: CGFloat
        let low: CGFloat
    }

    struct RangeObservation {
        let retainedHeight: CGFloat
    }

    struct InterruptionObservation {
        let finalHeight: CGFloat
        let completionCount: Int
        let firstCompletionCount: Int
        let secondCompletionCount: Int
    }

    enum HandoffPlacement: String, CaseIterable {
        case afterFullyDisplayed = "全展开"
        case fixed = "固定"
        case touchedPosition = "触点"
    }

    struct HandoffObservation {
        let displayHeight: CGFloat
        let innerOffsetY: CGFloat
    }

    struct AutomaticSmartHandoffObservation {
        let initialHeight: CGFloat
        let activationHeight: CGFloat
        let firstInnerHeight: CGFloat
        let onePhysicalPixel: CGFloat
    }

    enum ForcedBouncePlacement: String {
        case automatic = "自动"
        case fixed = "固定"
    }

    struct ForcedBounceObservation {
        let settledHeight: CGFloat
        let minimumHeight: CGFloat
        let minimumInnerOffset: CGFloat
        let trace: String
    }

    func movementControl(
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let control = requireElement(identifier, file: file, line: line)
        XCTAssertTrue(
            waitUntil(timeout: 2) { control.isHittable },
            "Fixed movement control \(identifier) is not hittable",
            file: file,
            line: line
        )
        return control
    }

    func assertMovementStyleParity(
        _ style: MovementStyle,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let swift = runMovementStyle(style, implementation: .swift, file: file, line: line)
        let objectiveC = runMovementStyle(style, implementation: .objectiveC, file: file, line: line)

        XCTAssertEqual(swift.high, objectiveC.high, accuracy: 1, file: file, line: line)
        XCTAssertEqual(swift.middle, objectiveC.middle, accuracy: 1, file: file, line: line)
        XCTAssertEqual(swift.nearest, objectiveC.nearest, accuracy: 1, file: file, line: line)
        XCTAssertEqual(swift.low, objectiveC.low, accuracy: 1, file: file, line: line)
    }

    func runMovementStyle(
        _ style: MovementStyle,
        implementation: DemoImplementationUnderTest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> MovementStyleObservation {
        _ = launch(scenario: .movement, implementation: implementation, file: file, line: line)

        _ = selectSegment(control: "movement.style", label: style.rawValue, file: file, line: line)

        let high = performMovement(
            control: "movement.high",
            expectedHeight: nil,
            implementation: implementation,
            file: file,
            line: line
        )
        XCTAssertGreaterThan(high, app.frame.height * 0.72, file: file, line: line)
        XCTAssertLessThanOrEqual(high, app.frame.height, file: file, line: line)

        // The fixed operation surface keeps nearest available without scrolling the captured
        // documentation view and accidentally changing the panel position first. The range test
        // below separately verifies a meaningful between-detents nearest calculation.
        let nearest = performMovement(
            control: "movement.nearest",
            expectedHeight: high,
            implementation: implementation,
            requiresWillMove: false,
            requiresDelegateTerminal: false,
            file: file,
            line: line
        )
        let middle = performMovement(
            control: "movement.middle",
            expectedHeight: 390,
            implementation: implementation,
            file: file,
            line: line
        )
        let low = performMovement(
            control: "movement.low",
            expectedHeight: demoMinimumInteractiveDisplayHeight(),
            implementation: implementation,
            file: file,
            line: line
        )

        attachHUDTrace("movement-\(style.rawValue)-\(implementation.rawValue)-trace")
        attachScreenshot("movement-\(style.rawValue)-\(implementation.rawValue)")
        return MovementStyleObservation(high: high, middle: middle, nearest: nearest, low: low)
    }

    func performMovement(
        control identifier: String,
        expectedHeight: CGFloat?,
        implementation: DemoImplementationUnderTest,
        requiresWillMove: Bool = true,
        requiresDelegateTerminal: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGFloat {
        let button = movementControl(identifier, file: file, line: line)
        let baseline = latestTraceSequence
        button.tap()

        XCTAssertTrue(
            waitUntil(timeout: 8) { [weak self] in
                self?.traceCount(callback: "movementCompletion", after: baseline) == 1
            },
            "Missing completion for \(identifier)/\(implementation.rawValue)",
            file: file,
            line: line
        )
        let finalHeight = waitForStableDisplayHeight(file: file, line: line)
        if let expectedHeight {
            XCTAssertEqual(finalHeight, expectedHeight, accuracy: 1, file: file, line: line)
        }

        XCTAssertEqual(
            traceCount(callback: "movementCompletion", after: baseline),
            1,
            "Public completion must terminate once",
            file: file,
            line: line
        )
        if requiresDelegateTerminal, implementation == .swift {
            XCTAssertTrue(
                waitUntil(timeout: 3) { [weak self] in
                    self?.traceCount(callback: "didFinishMovement", after: baseline) == 1
                },
                "Swift's typed delegate terminal callback did not arrive",
                file: file,
                line: line
            )
            XCTAssertEqual(
                traceCount(callback: "didFinishMovement", after: baseline),
                1,
                "Swift delegate terminal callback must terminate once",
                file: file,
                line: line
            )
        } else if requiresDelegateTerminal {
            // The original OC system-scroll path can resolve its public completion without
            // forwarding didTargetToH. The migration intentionally fills that lifecycle gap; for
            // strict OC observation, reject duplicates without pretending the callback exists.
            XCTAssertLessThanOrEqual(
                traceCount(callback: "didFinishMovement", after: baseline),
                1,
                "The untagged OC delegate terminal callback must not duplicate",
                file: file,
                line: line
            )
        }
        if requiresWillMove {
            let willMoveCount = traceCount(callback: "willMoveToDisplayHeight", after: baseline)
            if implementation == .swift {
                XCTAssertEqual(
                    willMoveCount,
                    1,
                    "A real Swift target change must publish one typed willMove callback",
                    file: file,
                    line: line
                )
            } else {
                // Some original animation paths complete without forwarding the optional legacy
                // willTargetToH delegate. Preserve that observation, but reject duplicate events.
                XCTAssertLessThanOrEqual(
                    willMoveCount,
                    1,
                    "The optional OC will-move callback must not duplicate",
                    file: file,
                    line: line
                )
            }
        }

        let completionLines = traceLines(after: baseline).filter {
            $0.contains(" movementCompletion h=")
        }
        let expectedOutcome = implementation == .swift ? "outcome=completed" : "outcome=legacyCompletion"
        XCTAssertTrue(
            completionLines.contains { $0.contains(expectedOutcome) },
            "Unexpected completion semantics for \(identifier): \(completionLines)",
            file: file,
            line: line
        )
        return finalHeight
    }

    func runNonSnappingRange(
        implementation: DemoImplementationUnderTest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> RangeObservation {
        _ = launch(scenario: .movement, implementation: implementation, file: file, line: line)
        _ = dragPanel(deltaY: -app.frame.height * 0.72, file: file, line: line)

        let rangeSwitch = movementControl("movement.range", file: file, line: line)
        rangeSwitch.tap()
        XCTAssertTrue(
            waitUntil(timeout: 3) {
                self.traceLines().contains {
                    $0.contains("sceneEvent") && $0.contains("非吸附区已开启")
                }
            },
            "The non-snapping range switch did not apply",
            file: file,
            line: line
        )

        var retainedHeight = CGFloat.nan
        var releaseBaseline = latestTraceSequence
        for desiredHeight in [300.0, 275.0, 325.0] as [CGFloat] {
            let current = waitForStableDisplayHeight(file: file, line: line)
            if current < app.frame.height * 0.72 {
                _ = dragPanel(deltaY: -app.frame.height * 0.72, file: file, line: line)
            }
            releaseBaseline = latestTraceSequence
            let destinationY = (app.frame.maxY - desiredHeight + 22 - app.frame.minY)
                / max(app.frame.height, 1)
            retainedHeight = dragPanel(
                toNormalizedScreenY: destinationY,
                velocity: .slow,
                file: file,
                line: line
            )
            let lowerBound = demoMinimumInteractiveDisplayHeight() + 35
            if (lowerBound...360).contains(retainedHeight) { break }
        }

        XCTAssertTrue(
            (demoMinimumInteractiveDisplayHeight() + 35...360).contains(retainedHeight),
            "Release did not remain inside the configured non-snapping range",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            traceCount(callback: "willBeginDragging", after: releaseBaseline),
            1,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            traceCount(callback: "willEndDragging", after: releaseBaseline),
            1,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            traceCount(callback: "didEndDragging", after: releaseBaseline),
            1,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            traceCount(callback: "shouldBypassDetents", after: releaseBaseline),
            1,
            file: file,
            line: line
        )

        // This case remains focused on the non-snapping release contract. A separate test disables
        // bypass while the panel is still between detents, then invokes nearest from both sides of
        // the midpoint so the operation cannot pass as a no-op at an existing detent.
        attachHUDTrace("movement-range-\(implementation.rawValue)-trace")
        attachScreenshot("movement-range-\(implementation.rawValue)")
        return RangeObservation(retainedHeight: retainedHeight)
    }

    func runMeaningfulNearest(
        implementation: DemoImplementationUnderTest,
        desiredHeight: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGFloat {
        _ = launch(scenario: .movement, implementation: implementation, file: file, line: line)
        let rangeSwitch = movementControl("movement.range", file: file, line: line)
        rangeSwitch.tap()
        XCTAssertTrue(
            waitUntil(timeout: 3) { [weak self] in
                self?.traceLines().contains {
                    $0.contains("sceneEvent") && $0.contains("非吸附区已开启")
                } == true
            },
            file: file,
            line: line
        )

        let destinationY = (app.frame.maxY - desiredHeight + 22 - app.frame.minY)
            / max(app.frame.height, 1)
        let retainedHeight = dragPanel(
            toNormalizedScreenY: destinationY,
            velocity: .slow,
            file: file,
            line: line
        )
        XCTAssertEqual(retainedHeight, desiredHeight, accuracy: 20, file: file, line: line)
        XCTAssertTrue(
            (demoMinimumInteractiveDisplayHeight() + 35...360).contains(retainedHeight),
            file: file,
            line: line
        )

        let visibleRangeSwitch = movementControl("movement.range", file: file, line: line)
        visibleRangeSwitch.tap()
        XCTAssertTrue(
            waitUntil(timeout: 3) { [weak self] in
                self?.traceLines().contains {
                    $0.contains("sceneEvent") && $0.contains("非吸附区已关闭")
                } == true
            },
            file: file,
            line: line
        )

        let nearest = movementControl("movement.nearest", file: file, line: line)
        let baseline = latestTraceSequence
        nearest.tap()
        XCTAssertTrue(
            waitUntil(timeout: 8) { [weak self] in
                self?.traceCount(callback: "movementCompletion", after: baseline) == 1
            },
            "Nearest movement did not complete exactly once",
            file: file,
            line: line
        )
        let finalHeight = waitForStableDisplayHeight(file: file, line: line)
        XCTAssertGreaterThan(
            abs(finalHeight - retainedHeight),
            20,
            "Nearest unexpectedly passed as a no-op",
            file: file,
            line: line
        )
        attachHUDTrace("movement-nearest-\(Int(desiredHeight))-\(implementation.rawValue)-trace")
        attachScreenshot("movement-nearest-\(Int(desiredHeight))-\(implementation.rawValue)")
        return finalHeight
    }

    func runInterruption(
        implementation: DemoImplementationUnderTest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> InterruptionObservation {
        _ = launch(scenario: .movement, implementation: implementation, file: file, line: line)
        let button = movementControl("movement.interrupt", file: file, line: line)
        let baseline = latestTraceSequence
        button.tap()

        XCTAssertTrue(
            waitUntil(timeout: 10) { [weak self] in
                self?.traceCount(callback: "movementCompletion", after: baseline) == 2
            },
            "Both overlapping movement transactions must complete exactly once",
            file: file,
            line: line
        )
        let finalHeight = waitForStableDisplayHeight(file: file, line: line)
        XCTAssertEqual(finalHeight, 390, accuracy: 1, file: file, line: line)

        let completions = traceLines(after: baseline).filter {
            $0.contains(" movementCompletion h=")
        }
        let first = completions.filter { $0.contains("label=第一段") }
        let second = completions.filter { $0.contains("label=第二段") }
        XCTAssertEqual(first.count, 1, file: file, line: line)
        XCTAssertEqual(second.count, 1, file: file, line: line)
        let delegateTerminalCount = traceCount(callback: "didFinishMovement", after: baseline)
        if implementation == .swift {
            XCTAssertEqual(
                delegateTerminalCount,
                2,
                "Each Swift transaction must also have one typed delegate terminal event",
                file: file,
                line: line
            )
        } else {
            XCTAssertLessThanOrEqual(
                delegateTerminalCount,
                2,
                "Untagged OC delegate terminal callbacks must not duplicate",
                file: file,
                line: line
            )
        }
        let willMoveCount = traceCount(callback: "willMoveToDisplayHeight", after: baseline)
        if implementation == .swift {
            XCTAssertEqual(willMoveCount, 2, file: file, line: line)
        } else {
            XCTAssertLessThanOrEqual(willMoveCount, 2, file: file, line: line)
        }

        if implementation == .swift {
            XCTAssertTrue(
                first[0].contains("outcome=interrupted"),
                "Unexpected first Swift terminal: \(first)",
                file: file,
                line: line
            )
            XCTAssertTrue(
                second[0].contains("outcome=completed"),
                "Second Swift completion was not completed: \(second)",
                file: file,
                line: line
            )
        } else {
            XCTAssertTrue(
                first[0].contains("outcome=legacyCompletion"),
                "Unexpected first OC completion: \(first)",
                file: file,
                line: line
            )
            XCTAssertTrue(
                second[0].contains("outcome=legacyCompletion"),
                "Unexpected second OC completion: \(second)",
                file: file,
                line: line
            )
        }

        attachHUDTrace("movement-interruption-\(implementation.rawValue)-trace")
        attachScreenshot("movement-interruption-\(implementation.rawValue)")
        return InterruptionObservation(
            finalHeight: finalHeight,
            completionCount: completions.count,
            firstCompletionCount: first.count,
            secondCompletionCount: second.count
        )
    }

    func runHandoff(
        placement: HandoffPlacement,
        implementation: DemoImplementationUnderTest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> HandoffObservation {
        _ = launch(scenario: .tableHandoff, implementation: implementation, file: file, line: line)
        _ = dragPanel(deltaY: -app.frame.height * 0.72, file: file, line: line)

        _ = scrollToElement(
            "handoff.placement",
            in: "innerTable",
            maximumSwipes: 6,
            file: file,
            line: line
        )
        _ = selectSegment(
            control: "handoff.placement",
            label: placement.rawValue,
            file: file,
            line: line
        )

        // All three modes are exercised from the same meaningful boundary: the fixed mode's
        // activation detent. Full-display must keep consuming panel distance; fixed and touch
        // placement must immediately hand the same upward gesture to the table.
        let middleHeaderY = (app.frame.maxY - 390 + 22 - app.frame.minY) / max(app.frame.height, 1)
        let middle = dragPanel(
            toNormalizedScreenY: middleHeaderY,
            velocity: .slow,
            file: file,
            line: line
        )
        XCTAssertEqual(middle, 390, accuracy: 2, file: file, line: line)

        let baseline = latestTraceSequence
        dragVisiblePanelContent(
            // From the 390pt detent the fully-displayed placement still has roughly 500pt of
            // panel distance to consume on the largest supported simulator. Cross the midpoint
            // so UIKit settles at the upper detent; a shorter drag correctly springs back to 390
            // and therefore cannot distinguish "panel consumed" from "nothing moved".
            deltaY: -520,
            visibleOffsetFromPanelTop: 210,
            normalizedX: 0.5,
            velocity: .slow
        )
        XCTAssertTrue(
            waitUntil(timeout: 8) { [weak self] in
                guard let self else { return false }
                return self.traceCount(callback: "didEndDragging", after: baseline) > 0
                    && !self.traceSamples(for: "innerTable", after: baseline).isEmpty
            },
            "The table gesture did not complete",
            file: file,
            line: line
        )
        _ = waitUntil(timeout: 5) { [weak self] in
            guard let sample = self?.traceSamples(for: "innerTable", after: baseline).last else {
                return false
            }
            return sample.line.contains("decelerating=false")
        }
        let displayHeight = waitForStableDisplayHeight(file: file, line: line)
        let samples = traceSamples(for: "innerTable", after: baseline)
        guard let finalSample = samples.last else {
            XCTFail("No innerTable snapshots were recorded", file: file, line: line)
            return HandoffObservation(displayHeight: displayHeight, innerOffsetY: .nan)
        }

        attachHUDTrace("handoff-\(placement.rawValue)-\(implementation.rawValue)-trace")
        attachScreenshot("handoff-\(placement.rawValue)-\(implementation.rawValue)")

        XCTAssertGreaterThanOrEqual(
            traceCount(callback: "canCaptureScrollView", after: baseline),
            1,
            "Missing canCaptureScrollView for \(placement.rawValue)/\(implementation.rawValue)",
            file: file,
            line: line
        )
        if implementation == .swift {
            XCTAssertGreaterThanOrEqual(
                traceCount(callback: "adjustCaptureProposal", after: baseline),
                1,
                "Missing adjustCaptureProposal for \(placement.rawValue)/Swift",
                file: file,
                line: line
            )
        } else {
            // The original OC delegate has can-capture and segment hooks, but no equivalent of
            // Swift's typed proposal-mutation callback. Its absence is an API improvement in the
            // rewrite, not a handoff mismatch; the surrounding capture semantics remain strict.
            XCTAssertEqual(
                traceCount(callback: "adjustCaptureProposal", after: baseline),
                0,
                "The legacy adapter unexpectedly synthesized a proposal-mutation callback",
                file: file,
                line: line
            )
        }
        XCTAssertGreaterThanOrEqual(
            traceCount(callback: "segmentsForScrollView", after: baseline),
            1,
            "Missing segmentsForScrollView for \(placement.rawValue)/\(implementation.rawValue)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            traceCount(callback: "willBeginDragging", after: baseline),
            1,
            "Missing willBeginDragging for \(placement.rawValue)/\(implementation.rawValue)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            traceCount(callback: "willEndDragging", after: baseline),
            1,
            "Missing willEndDragging for \(placement.rawValue)/\(implementation.rawValue)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            traceCount(callback: "didEndDragging", after: baseline),
            1,
            "Missing didEndDragging for \(placement.rawValue)/\(implementation.rawValue)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            traceCount(callback: "didScroll", after: baseline),
            1,
            "Missing didScroll for \(placement.rawValue)/\(implementation.rawValue)",
            file: file,
            line: line
        )

        switch placement {
        case .afterFullyDisplayed:
            XCTAssertGreaterThan(displayHeight, 450, file: file, line: line)
            XCTAssertLessThanOrEqual(abs(finalSample.offsetY), 8, file: file, line: line)
        case .fixed, .touchedPosition:
            XCTAssertEqual(displayHeight, 390, accuracy: 3, file: file, line: line)
            XCTAssertGreaterThan(finalSample.offsetY, 20, file: file, line: line)
        }

        return HandoffObservation(
            displayHeight: displayHeight,
            innerOffsetY: finalSample.offsetY
        )
    }

    func runAutomaticSmartHandoff(
        implementation: DemoImplementationUnderTest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AutomaticSmartHandoffObservation {
        let initialHeight = launch(
            scenario: .automaticSmartHandoff,
            implementation: implementation,
            file: file,
            line: line
        )

        let geometry = elementText("smartHandoff.geometry")
        guard let frameY = markerNumber("frameY", in: geometry),
              let frameMaxY = markerNumber("frameMaxY", in: geometry),
              let panelBottomY = markerNumber("panelBottomY", in: geometry),
              let contentHeight = markerNumber("contentHeight", in: geometry),
              let boundsHeight = markerNumber("boundsHeight", in: geometry),
              let scrollableDistance = markerNumber("scrollableDistance", in: geometry),
              let displayScale = markerNumber("displayScale", in: geometry),
              let minimumInnerVisibilityRatio = markerNumber(
                  "minimumInnerVisibilityRatio",
                  in: geometry
              ),
              let detents = markerNumbers("detents", in: geometry),
              detents.count == 3 else {
            XCTFail("Could not parse smart-handoff geometry: \(geometry)", file: file, line: line)
            return AutomaticSmartHandoffObservation(
                initialHeight: initialHeight,
                activationHeight: .nan,
                firstInnerHeight: .nan,
                onePhysicalPixel: 1
            )
        }

        let onePhysicalPixel = 1 / max(displayScale, 1)
        XCTAssertEqual(frameY, 40, accuracy: onePhysicalPixel, file: file, line: line)
        XCTAssertEqual(frameMaxY - frameY, boundsHeight, accuracy: onePhysicalPixel, file: file, line: line)
        XCTAssertEqual(
            frameMaxY,
            panelBottomY,
            accuracy: onePhysicalPixel,
            "The participant does not extend to the panel bottom",
            file: file,
            line: line
        )
        XCTAssertEqual(panelBottomY, detents[2], accuracy: onePhysicalPixel, file: file, line: line)
        XCTAssertEqual(
            contentHeight - boundsHeight,
            scrollableDistance,
            accuracy: onePhysicalPixel,
            file: file,
            line: line
        )
        XCTAssertEqual(scrollableDistance, 2_000, accuracy: onePhysicalPixel, file: file, line: line)
        XCTAssertEqual(initialHeight, detents[0], accuracy: onePhysicalPixel, file: file, line: line)
        XCTAssertTrue(
            geometry.contains("handoffMode=coordinated"),
            "The case no longer uses the default coordinated handoff mode: \(geometry)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            geometry.contains("innerPlacement=automatic"),
            "The case no longer uses default automatic placement: \(geometry)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            minimumInnerVisibilityRatio,
            0.7,
            accuracy: 0.000_001,
            "The default automatic visibility ratio changed",
            file: file,
            line: line
        )

        guard let activationHeight = detents.first(where: {
            ($0 - frameY) / max(boundsHeight, 1) >= minimumInnerVisibilityRatio
        }) else {
            XCTFail("No automatic activation detent for geometry: \(geometry)", file: file, line: line)
            return AutomaticSmartHandoffObservation(
                initialHeight: initialHeight,
                activationHeight: .nan,
                firstInnerHeight: .nan,
                onePhysicalPixel: onePhysicalPixel
            )
        }

        let baseline = latestTraceSequence
        // Start 90pt below the panel top: inside the participant's y=40...low visible slice, never
        // on the panel-only grabber. Derive the distance from the
        // selected activation detent so the test remains valid on taller future viewports.
        let upwardDistance = max(120, activationHeight - initialHeight + 80)
        dragVisiblePanelContent(
            deltaY: -upwardDistance,
            visibleOffsetFromPanelTop: 90,
            normalizedX: 0.5,
            velocity: .slow
        )

        XCTAssertTrue(
            waitUntil(timeout: 10) { [weak self] in
                guard let self else { return false }
                return self.traceCount(callback: "didEndDragging", after: baseline) > 0
                    && self.traceSamples(for: "smartHandoffScroll", after: baseline)
                        .contains(where: { $0.offsetY > onePhysicalPixel })
            },
            "The lowest-detent gesture never handed movement to the inner scroll",
            file: file,
            line: line
        )
        _ = waitUntil(timeout: 6) { [weak self] in
            guard let self else { return false }
            let lines = self.traceLines(after: baseline)
            return lines.contains(where: { $0.contains(" didEndDecelerating h=") })
                || lines.last?.contains("decelerating=false") == true
        }
        _ = waitForStableDisplayHeight(file: file, line: line)

        let trace = traceLines(after: baseline)
        let motionSamples = traceSamples(for: "smartHandoffScroll", after: baseline)
            .filter { $0.line.contains(" didScroll h=") }
        guard let firstPanelMotion = motionSamples.first(where: {
            $0.displayHeight > initialHeight + onePhysicalPixel
        }), let firstInnerMotion = motionSamples.first(where: {
            $0.offsetY > onePhysicalPixel
        }) else {
            XCTFail("Missing panel→inner motion samples. Trace:\n\(trace.joined(separator: "\n"))", file: file, line: line)
            return AutomaticSmartHandoffObservation(
                initialHeight: initialHeight,
                activationHeight: activationHeight,
                firstInnerHeight: .nan,
                onePhysicalPixel: onePhysicalPixel
            )
        }

        XCTAssertLessThanOrEqual(
            abs(firstPanelMotion.offsetY),
            onePhysicalPixel,
            "The participant moved before the panel began expanding",
            file: file,
            line: line
        )
        let samplesBeforeActivation = motionSamples.filter {
            $0.sequence < firstInnerMotion.sequence
                && $0.displayHeight < activationHeight - onePhysicalPixel
        }
        XCTAssertFalse(samplesBeforeActivation.isEmpty, "No panel-only movement was observed", file: file, line: line)
        XCTAssertTrue(
            samplesBeforeActivation.allSatisfy { abs($0.offsetY) <= onePhysicalPixel },
            "Inner content moved before the automatic activation detent",
            file: file,
            line: line
        )
        XCTAssertEqual(
            firstInnerMotion.displayHeight,
            activationHeight,
            accuracy: onePhysicalPixel,
            "Inner content did not start at the mathematically selected detent",
            file: file,
            line: line
        )
        let innerOwnedSamples = motionSamples.filter {
            $0.sequence >= firstInnerMotion.sequence && $0.offsetY > onePhysicalPixel
        }
        XCTAssertTrue(
            innerOwnedSamples.allSatisfy {
                abs($0.displayHeight - activationHeight) <= onePhysicalPixel
            },
            "Panel height continued changing after the inner segment took ownership",
            file: file,
            line: line
        )
        XCTAssertTrue(
            trace.contains(where: {
                $0.contains(" canCaptureScrollView h=")
                    && $0.contains("scrollView=smartHandoffScroll")
                    && $0.contains("result=true")
            }),
            "The participant was not captured through the public capture path",
            file: file,
            line: line
        )
        XCTAssertTrue(
            trace.contains(where: {
                $0.contains(" segmentsForScrollView h=")
                    && $0.contains("scrollView=smartHandoffScroll")
                    && $0.contains("segments=nil")
            }),
            "The case did not exercise default automatic placement",
            file: file,
            line: line
        )

        attachHUDTrace("automatic-smart-handoff-\(implementation.rawValue)-trace", keepAlways: true)
        attachScreenshot("automatic-smart-handoff-\(implementation.rawValue)", keepAlways: true)
        return AutomaticSmartHandoffObservation(
            initialHeight: initialHeight,
            activationHeight: activationHeight,
            firstInnerHeight: firstInnerMotion.displayHeight,
            onePhysicalPixel: onePhysicalPixel
        )
    }

    func markerNumber(_ key: String, in text: String) -> CGFloat? {
        guard let keyRange = text.range(of: key + "=") else { return nil }
        let suffix = text[keyRange.upperBound...]
        let value = suffix.prefix { $0 != "," && $0 != " " && $0 != "|" }
        return Double(value).map { CGFloat($0) }
    }

    func markerNumbers(_ key: String, in text: String) -> [CGFloat]? {
        guard let keyRange = text.range(of: key + "=") else { return nil }
        let suffix = text[keyRange.upperBound...]
        let value = suffix.prefix { $0 != " " && $0 != "|" }
        let numbers = value.split(separator: ",").compactMap { component in
            Double(component).map { CGFloat($0) }
        }
        return numbers.isEmpty ? nil : numbers
    }

    func runDynamicRows(
        implementation: DemoImplementationUnderTest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        _ = launch(scenario: .tableHandoff, implementation: implementation, file: file, line: line)
        _ = dragPanel(deltaY: -app.frame.height * 0.72, file: file, line: line)

        let addButton = scrollToElement(
            "handoff.add",
            in: "innerTable",
            maximumSwipes: 6,
            file: file,
            line: line
        )
        let addBaseline = latestTraceSequence
        addButton.tap()
        XCTAssertTrue(
            waitUntil(timeout: 4) { [weak self] in
                self?.traceLines(after: addBaseline).contains {
                    $0.contains("sceneEvent") && $0.contains("内容已刷新 · 64 行")
                } == true
            },
            "Adding rows did not reload the table",
            file: file,
            line: line
        )
        XCTAssertEqual(
            traceLines(after: addBaseline).filter {
                $0.contains("sceneEvent") && $0.contains("内容已刷新 · 64 行")
            }.count,
            1,
            file: file,
            line: line
        )
        let expandedRangeMaximum = driveInnerTableToBottom(file: file, line: line)
        XCTAssertGreaterThan(
            expandedRangeMaximum,
            1_000,
            "The expanded table did not expose a meaningful scroll range",
            file: file,
            line: line
        )

        let removeButton = scrollToElement(
            "handoff.remove",
            in: "innerTable",
            direction: .down,
            maximumSwipes: 12,
            file: file,
            line: line
        )
        let removeBaseline = latestTraceSequence
        removeButton.tap()
        XCTAssertTrue(
            waitUntil(timeout: 4) { [weak self] in
                self?.traceLines(after: removeBaseline).contains {
                    $0.contains("sceneEvent") && $0.contains("内容已刷新 · 54 行")
                } == true
            },
            "Removing rows did not reload the table",
            file: file,
            line: line
        )
        XCTAssertEqual(
            traceLines(after: removeBaseline).filter {
                $0.contains("sceneEvent") && $0.contains("内容已刷新 · 54 行")
            }.count,
            1,
            file: file,
            line: line
        )
        let reducedRangeMaximum = driveInnerTableToBottom(file: file, line: line)
        XCTAssertGreaterThan(
            expandedRangeMaximum - reducedRangeMaximum,
            450,
            "reloadScrollMetrics did not reflect the ten-row content-range reduction",
            file: file,
            line: line
        )

        attachHUDTrace("handoff-rows-\(implementation.rawValue)-trace")
        attachScreenshot("handoff-rows-\(implementation.rawValue)")
    }

    func driveInnerTableToBottom(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGFloat {
        var maximumOffset: CGFloat = 0
        var stablePasses = 0
        for _ in 0..<12 {
            let previousMaximum = maximumOffset
            let baseline = latestTraceSequence
            dragVisiblePanelContent(
                deltaY: -520,
                visibleOffsetFromPanelTop: 500,
                normalizedX: 0.75,
                velocity: .slow
            )
            XCTAssertTrue(
                waitUntil(timeout: 6) { [weak self] in
                    (self?.traceCount(callback: "didEndDragging", after: baseline) ?? 0) > 0
                },
                "The dynamic-range table gesture did not finish",
                file: file,
                line: line
            )
            _ = waitForStableDisplayHeight(file: file, line: line)
            maximumOffset = max(
                maximumOffset,
                traceSamples(for: "innerTable", after: baseline).map(\.offsetY).max() ?? 0
            )
            stablePasses = maximumOffset <= previousMaximum + 2 ? stablePasses + 1 : 0
            if stablePasses >= 2 { break }
        }
        return maximumOffset
    }

    func runForcedBouncePlacement(
        _ placement: ForcedBouncePlacement,
        implementation: DemoImplementationUnderTest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ForcedBounceObservation {
        _ = launch(scenario: .tableHandoff, implementation: implementation, file: file, line: line)
        _ = dragPanel(deltaY: -app.frame.height * 0.72, file: file, line: line)
        _ = scrollToElement(
            "handoff.placement",
            in: "innerTable",
            maximumSwipes: 6,
            file: file,
            line: line
        )
        _ = selectSegment(
            control: "handoff.placement",
            label: placement.rawValue,
            file: file,
            line: line
        )
        let forceSwitch = scrollToElement(
            "handoff.forceInnerTopBounce",
            in: "innerTable",
            maximumSwipes: 4,
            file: file,
            line: line
        )
        forceSwitch.tap()

        let middleHeaderY = (app.frame.maxY - 390 + 22 - app.frame.minY)
            / max(app.frame.height, 1)
        let middle = dragPanel(
            toNormalizedScreenY: middleHeaderY,
            velocity: .slow,
            file: file,
            line: line
        )
        XCTAssertEqual(middle, 390, accuracy: 2, file: file, line: line)

        let baseline = latestTraceSequence
        dragVisiblePanelContent(
            deltaY: 200,
            visibleOffsetFromPanelTop: 245,
            normalizedX: 0.1,
            velocity: .slow
        )
        let settledHeight = waitForStableDisplayHeight(file: file, line: line)
        let samples = traceSamples(for: "innerTable", after: baseline)
        let trace = traceLines(after: baseline).joined(separator: "\n")
        XCTAssertFalse(
            samples.isEmpty,
            "No table samples for forced-bounce \(placement.rawValue)/\(implementation.rawValue). Trace:\n\(trace)",
            file: file,
            line: line
        )
        attachHUDTrace(
            "handoff-force-bounce-\(placement.rawValue)-\(implementation.rawValue)",
            keepAlways: true
        )
        attachScreenshot(
            "handoff-force-bounce-\(placement.rawValue)-\(implementation.rawValue)",
            keepAlways: true
        )
        return ForcedBounceObservation(
            settledHeight: settledHeight,
            minimumHeight: samples.map(\.displayHeight).min() ?? middle,
            minimumInnerOffset: samples.map(\.offsetY).min() ?? 0,
            trace: trace
        )
    }

}
