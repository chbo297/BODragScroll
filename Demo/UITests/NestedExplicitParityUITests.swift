import Foundation
import XCTest

final class NestedExplicitParityUITests: DemoUITestCase {
    private struct NestedOrigin {
        let name: String
        let panelOffset: CGFloat
        let expectedPrimary: String
        let expectedChain: [String]
    }

    private struct NestedObservation {
        let implementation: DemoImplementationUnderTest
        let origin: NestedOrigin
        let expandedHeight: CGFloat
        let maximumObservedHeight: CGFloat
        let captureChain: [String]
        let largestOffsetJump: CGFloat
        let totalParticipantMovement: CGFloat
        let finalParticipantOffsets: [String: CGFloat]
        let trace: String
    }

    private struct ExplicitObservation {
        let implementation: DemoImplementationUnderTest
        let maximumHeight: CGFloat
        let upwardFinalOffset: CGFloat
        let downwardFinalHeight: CGFloat
        let downwardFinalOffset: CGFloat
        let upwardBoundaryOffset: CGFloat
        let downwardBoundaryOffset: CGFloat
        let largestOffsetJump: CGFloat
        let trace: String
    }

    /// Each origin is run in a new process so its responder-chain geometry and all offsets start
    /// from the same state. The expected chains exercise one, two and three nested scroll views.
    func testNestedResponderChainCaptureAndOffsetContinuityMatchesObjectiveC() {
        let origins = [
            NestedOrigin(
                name: "outer",
                panelOffset: 330,
                expectedPrimary: "outerScroll",
                expectedChain: ["outerScroll"]
            ),
            NestedOrigin(
                name: "middle",
                panelOffset: 610,
                expectedPrimary: "middleScroll",
                expectedChain: ["middleScroll", "outerScroll"]
            ),
            NestedOrigin(
                name: "deep",
                panelOffset: 720,
                expectedPrimary: "deepTable",
                expectedChain: ["deepTable", "middleScroll", "outerScroll"]
            )
        ]

        for origin in origins {
            let objectiveC = observeNestedOrigin(origin, implementation: .objectiveC)
            let swift = observeNestedOrigin(origin, implementation: .swift)

            XCTAssertEqual(
                swift.captureChain,
                objectiveC.captureChain,
                "Responder-chain candidates differ for the \(origin.name) origin.\nOC:\n\(objectiveC.trace)\nSwift:\n\(swift.trace)"
            )
            XCTAssertEqual(swift.expandedHeight, objectiveC.expandedHeight, accuracy: 1)
            XCTAssertEqual(
                swift.maximumObservedHeight,
                objectiveC.maximumObservedHeight,
                accuracy: 1,
                "Nested panel envelope differs for \(origin.name).\nOC:\n\(objectiveC.trace)\nSwift:\n\(swift.trace)"
            )
            XCTAssertLessThanOrEqual(
                swift.maximumObservedHeight,
                swift.expandedHeight + 1,
                "Nested participant drag exceeded the panel's configured maximum. Trace:\n\(swift.trace)"
            )
            XCTAssertGreaterThan(
                swift.totalParticipantMovement,
                5,
                "Swift captured the expected chain but did not move a participant. Trace:\n\(swift.trace)"
            )
            XCTAssertGreaterThan(
                objectiveC.totalParticipantMovement,
                5,
                "OC reference gesture did not move a participant. Trace:\n\(objectiveC.trace)"
            )
            XCTAssertLessThan(
                swift.largestOffsetJump,
                220,
                "Swift participant offset jumped during a single slow gesture. Trace:\n\(swift.trace)"
            )
            XCTAssertLessThan(
                objectiveC.largestOffsetJump,
                220,
                "OC reference offset jumped during a single slow gesture. Trace:\n\(objectiveC.trace)"
            )
            for identifier in origin.expectedChain {
                XCTAssertEqual(
                    swift.finalParticipantOffsets[identifier] ?? .nan,
                    objectiveC.finalParticipantOffsets[identifier] ?? .nan,
                    accuracy: 5,
                    "Final offset for \(identifier) differs at the \(origin.name) origin"
                )
            }
        }
    }

    /// Verifies the authored composite-axis ordering in both directions:
    /// panel -> table [0, 620] -> panel -> table [620, end], then the symmetric reverse path.
    func testExplicitSegmentBoundaryAndBidirectionalHandoffMatchesObjectiveC() {
        let objectiveC = observeExplicitSegments(.objectiveC)
        let swift = observeExplicitSegments(.swift)

        XCTAssertEqual(swift.maximumHeight, objectiveC.maximumHeight, accuracy: 1)
        XCTAssertEqual(swift.upwardBoundaryOffset, 620, accuracy: 3)
        XCTAssertEqual(objectiveC.upwardBoundaryOffset, 620, accuracy: 3)
        XCTAssertEqual(swift.downwardBoundaryOffset, 620, accuracy: 3)
        XCTAssertEqual(objectiveC.downwardBoundaryOffset, 620, accuracy: 3)
        XCTAssertGreaterThan(swift.upwardFinalOffset, 650)
        XCTAssertGreaterThan(objectiveC.upwardFinalOffset, 650)
        XCTAssertEqual(swift.downwardFinalHeight, objectiveC.downwardFinalHeight, accuracy: 2)
        XCTAssertLessThan(swift.downwardFinalHeight, 390)
        XCTAssertLessThanOrEqual(abs(swift.downwardFinalOffset), 3)
        XCTAssertLessThanOrEqual(abs(objectiveC.downwardFinalOffset), 3)
        XCTAssertLessThan(
            swift.largestOffsetJump,
            260,
            "Swift table offset jumped across an explicit segment handoff. Trace:\n\(swift.trace)"
        )
    }

    private func observeNestedOrigin(
        _ origin: NestedOrigin,
        implementation: DemoImplementationUnderTest
    ) -> NestedObservation {
        _ = launch(scenario: .nestedScrollChain, implementation: implementation)
        let expandedHeight = expandPanelToMaximum()
        let baseline = latestTraceSequence

        dragVisiblePanelContent(
            deltaY: -130,
            visibleOffsetFromPanelTop: origin.panelOffset,
            velocity: .slow
        )
        waitForGestureToFinish(after: baseline)

        let lines = traceLines(after: baseline)
        let trace = lines.joined(separator: "\n")
        // The OC delegate only exposes its capture-info callback for some candidate counts, while
        // Swift intentionally calls the proposal hook for zero/one/many candidates. The ordered
        // can-capture requests are the common observable contract and reflect the same responder
        // chain without asserting this deliberate callback-frequency improvement.
        let chain = orderedUnique(
            lines
                .filter { $0.contains(" canCaptureScrollView h=") }
                .map { detailValue(named: "scrollView", in: $0) }
                .filter { !$0.isEmpty }
        )
        let primary = chain.first ?? ""
        XCTAssertEqual(
            primary,
            origin.expectedPrimary,
            "Wrong primary candidate for \(origin.name)/\(implementation.rawValue). Trace:\n\(trace)"
        )
        XCTAssertEqual(
            chain,
            origin.expectedChain,
            "Wrong responder-chain capture for \(origin.name)/\(implementation.rawValue). Trace:\n\(trace)"
        )

        if let proposal = lines.first(where: { $0.contains(" adjustCaptureProposal h=") }) {
            let proposedChain = detailValue(named: "candidatesBefore", in: proposal)
                .split(separator: ",")
                .map(String.init)
                .filter { !$0.isEmpty }
            XCTAssertEqual(
                proposedChain,
                origin.expectedChain,
                "Capture proposal disagrees with responder-chain evaluation. Proposal:\n\(proposal)"
            )
        }

        var largestJump: CGFloat = 0
        var totalMovement: CGFloat = 0
        var finalParticipantOffsets: [String: CGFloat] = [:]
        for identifier in origin.expectedChain {
            let samples = traceSamples(for: identifier, after: baseline)
            XCTAssertFalse(
                samples.isEmpty,
                "No snapshots for \(identifier) in \(implementation.rawValue). Trace:\n\(trace)"
            )
            let offsets = samples.map(\.offsetY)
            if let minimum = offsets.min(), let maximum = offsets.max() {
                let movement = maximum - minimum
                totalMovement += movement
            }
            finalParticipantOffsets[identifier] = offsets.last
            largestJump = max(largestJump, largestConsecutiveJump(in: offsets))
        }

        attachHUDTrace("nested-\(origin.name)-\(implementation.rawValue)", keepAlways: true)
        attachScreenshot("nested-\(origin.name)-\(implementation.rawValue)", keepAlways: true)
        return NestedObservation(
            implementation: implementation,
            origin: origin,
            expandedHeight: expandedHeight,
            maximumObservedHeight: lines.compactMap { traceHeight(in: $0) }.max() ?? expandedHeight,
            captureChain: chain,
            largestOffsetJump: largestJump,
            totalParticipantMovement: totalMovement,
            finalParticipantOffsets: finalParticipantOffsets,
            trace: trace
        )
    }

    private func observeExplicitSegments(
        _ implementation: DemoImplementationUnderTest
    ) -> ExplicitObservation {
        _ = launch(scenario: .explicitSegments, implementation: implementation)
        let upwardBaseline = latestTraceSequence

        var upwardFinalOffset: CGFloat = 0
        var upwardFinalHeight = waitForStableDisplayHeight()
        for _ in 0..<8 {
            let height = waitForStableDisplayHeight()
            let startOffset = max(180, min(height - 28, 650))
            let gestureBaseline = latestTraceSequence
            dragVisiblePanelContent(
                deltaY: -480,
                visibleOffsetFromPanelTop: startOffset,
                velocity: .slow
            )
            waitForGestureToFinish(after: gestureBaseline)
            upwardFinalHeight = waitForStableDisplayHeight()
            upwardFinalOffset = traceSamples(for: "segmentedTable", after: upwardBaseline).last?.offsetY ?? 0
            if upwardFinalHeight > app.frame.height * 0.75, upwardFinalOffset > 680 { break }
        }

        let upwardSamples = traceSamples(for: "segmentedTable", after: upwardBaseline)
        let upwardTrace = traceLines(after: upwardBaseline).joined(separator: "\n")
        XCTAssertFalse(upwardSamples.isEmpty, "No explicit-segment samples. Trace:\n\(upwardTrace)")
        let maximumHeight = upwardSamples.map(\.displayHeight).max() ?? upwardFinalHeight
        let upwardPhases = assertUpwardExplicitOrdering(
            samples: upwardSamples,
            maximumHeight: maximumHeight,
            implementation: implementation,
            trace: upwardTrace
        )

        let downwardBaseline = latestTraceSequence
        var downwardFinalHeight = upwardFinalHeight
        var downwardFinalOffset = upwardFinalOffset
        for _ in 0..<14 {
            let height = waitForStableDisplayHeight()
            let startOffset = max(170, min(height - 28, 230))
            let gestureBaseline = latestTraceSequence
            dragVisiblePanelContent(
                deltaY: 480,
                visibleOffsetFromPanelTop: startOffset,
                velocity: .slow
            )
            waitForGestureToFinish(after: gestureBaseline)
            downwardFinalHeight = waitForStableDisplayHeight()
            downwardFinalOffset = traceSamples(for: "segmentedTable", after: downwardBaseline).last?.offsetY
                ?? downwardFinalOffset
            if downwardFinalHeight < 380, abs(downwardFinalOffset) <= 3 { break }
        }

        let downwardSamples = traceSamples(for: "segmentedTable", after: downwardBaseline)
        let downwardTrace = traceLines(after: downwardBaseline).joined(separator: "\n")
        let downwardPhases = assertDownwardExplicitOrdering(
            samples: downwardSamples,
            maximumHeight: maximumHeight,
            implementation: implementation,
            trace: downwardTrace
        )

        let allSamples = upwardSamples + downwardSamples
        let trace = "UPWARD\n\(upwardTrace)\nDOWNWARD\n\(downwardTrace)"
        attachHUDTrace("explicit-segments-\(implementation.rawValue)", keepAlways: true)
        attachScreenshot("explicit-segments-\(implementation.rawValue)", keepAlways: true)
        return ExplicitObservation(
            implementation: implementation,
            maximumHeight: maximumHeight,
            upwardFinalOffset: upwardFinalOffset,
            downwardFinalHeight: downwardFinalHeight,
            downwardFinalOffset: downwardFinalOffset,
            upwardBoundaryOffset: upwardPhases.boundaryOffset,
            downwardBoundaryOffset: downwardPhases.boundaryOffset,
            largestOffsetJump: largestConsecutiveJump(in: allSamples.map(\.offsetY)),
            trace: trace
        )
    }

    private func assertUpwardExplicitOrdering(
        samples: [DemoTraceSample],
        maximumHeight: CGFloat,
        implementation: DemoImplementationUnderTest,
        trace: String
    ) -> (boundaryOffset: CGFloat, sequences: [Int]) {
        let middleScroll = samples.first {
            abs($0.displayHeight - 390) <= 3 && $0.offsetY > 20 && $0.offsetY < 590
        }
        let panelAboveMiddle = samples.first {
            $0.displayHeight > 420 && $0.displayHeight < maximumHeight - 12 && abs($0.offsetY - 620) <= 5
        }
        let postBoundaryScroll = samples.first {
            $0.displayHeight >= maximumHeight - 3 && $0.offsetY > 650
        }

        XCTAssertNotNil(middleScroll, "Missing h=390/table<620 phase for \(implementation.rawValue). Trace:\n\(trace)")
        XCTAssertNotNil(panelAboveMiddle, "Panel did not expand while table was held at 620 for \(implementation.rawValue). Trace:\n\(trace)")
        XCTAssertNotNil(postBoundaryScroll, "Table did not continue above 620 at maximum panel height for \(implementation.rawValue). Trace:\n\(trace)")

        let sequences = [middleScroll?.sequence, panelAboveMiddle?.sequence, postBoundaryScroll?.sequence].compactMap { $0 }
        if sequences.count == 3 {
            XCTAssertEqual(sequences, sequences.sorted(), "Upward explicit phases are out of order. Trace:\n\(trace)")
        }
        return (panelAboveMiddle?.offsetY ?? .nan, sequences)
    }

    private func assertDownwardExplicitOrdering(
        samples: [DemoTraceSample],
        maximumHeight: CGFloat,
        implementation: DemoImplementationUnderTest,
        trace: String
    ) -> (boundaryOffset: CGFloat, sequences: [Int]) {
        let panelBelowMaximum = samples.first {
            $0.displayHeight < maximumHeight - 12 && $0.displayHeight > 420 && abs($0.offsetY - 620) <= 5
        }
        let middleScroll = samples.first {
            abs($0.displayHeight - 390) <= 3 && $0.offsetY > 20 && $0.offsetY < 590
        }
        let panelBelowMiddle = samples.first {
            $0.displayHeight < 370 && abs($0.offsetY) <= 5
        }

        XCTAssertNotNil(panelBelowMaximum, "Panel did not collapse while table was held at 620 for \(implementation.rawValue). Trace:\n\(trace)")
        XCTAssertNotNil(middleScroll, "Missing reverse h=390/table<620 phase for \(implementation.rawValue). Trace:\n\(trace)")
        XCTAssertNotNil(panelBelowMiddle, "Panel did not resume collapse after table returned to zero for \(implementation.rawValue). Trace:\n\(trace)")

        let sequences = [panelBelowMaximum?.sequence, middleScroll?.sequence, panelBelowMiddle?.sequence].compactMap { $0 }
        if sequences.count == 3 {
            XCTAssertEqual(sequences, sequences.sorted(), "Downward explicit phases are out of order. Trace:\n\(trace)")
        }
        return (panelBelowMaximum?.offsetY ?? .nan, sequences)
    }

    private func expandPanelToMaximum() -> CGFloat {
        var height = waitForStableDisplayHeight()
        for _ in 0..<3 where height < app.frame.height * 0.75 {
            height = dragPanel(deltaY: -app.frame.height * 0.62, velocity: .slow)
        }
        XCTAssertGreaterThan(height, app.frame.height * 0.75)
        return height
    }

    private func waitForGestureToFinish(after sequence: Int) {
        XCTAssertTrue(
            waitUntil(timeout: 5, pollInterval: 0.12) {
                let lines = self.traceLines(after: sequence)
                if lines.contains(where: { $0.contains(" didEndDecelerating h=") }) {
                    return true
                }
                return lines.contains {
                    $0.contains(" didEndDragging h=") && $0.contains("willDecelerate=false")
                }
            },
            "Gesture did not publish a terminal callback. Trace:\n\(traceLines(after: sequence).joined(separator: "\n"))"
        )
        Thread.sleep(forTimeInterval: 0.12)
    }

    private func detailValue(named name: String, in line: String) -> String {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let expression = try? NSRegularExpression(
            pattern: escapedName + #"=(.*?)(?:,[A-Za-z][A-Za-z0-9]*=|\})"#
        ) else { return "" }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: range),
              let valueRange = Range(match.range(at: 1), in: line) else { return "" }
        return String(line[valueRange])
    }

    private func largestConsecutiveJump(in values: [CGFloat]) -> CGFloat {
        zip(values, values.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }

    private func traceHeight(in line: String) -> CGFloat? {
        guard let expression = try? NSRegularExpression(pattern: #" h=([+-]?\d+(?:\.\d+)?)"#) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: range),
              let valueRange = Range(match.range(at: 1), in: line),
              let value = Double(line[valueRange]) else { return nil }
        return CGFloat(value)
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
