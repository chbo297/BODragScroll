import XCTest

final class BODragScrollDemoSmokeUITests: DemoUITestCase {
    func testFreePanelSwiftSmoke() { runSmoke(.freePanel, .swift) }
    func testFreePanelObjectiveCSmoke() { runSmoke(.freePanel, .objectiveC) }

    func testMovementSwiftSmoke() { runSmoke(.movement, .swift) }
    func testMovementObjectiveCSmoke() { runSmoke(.movement, .objectiveC) }

    func testTableHandoffSwiftSmoke() { runSmoke(.tableHandoff, .swift) }
    func testTableHandoffObjectiveCSmoke() { runSmoke(.tableHandoff, .objectiveC) }

    func testAutomaticSmartHandoffSwiftSmoke() { runSmoke(.automaticSmartHandoff, .swift) }
    func testAutomaticSmartHandoffObjectiveCSmoke() { runSmoke(.automaticSmartHandoff, .objectiveC) }

    func testNestedScrollChainSwiftSmoke() { runSmoke(.nestedScrollChain, .swift) }
    func testNestedScrollChainObjectiveCSmoke() { runSmoke(.nestedScrollChain, .objectiveC) }

    func testExplicitSegmentsSwiftSmoke() { runSmoke(.explicitSegments, .swift) }
    func testExplicitSegmentsObjectiveCSmoke() { runSmoke(.explicitSegments, .objectiveC) }

    func testPolicyLabSwiftSmoke() { runSmoke(.policyLab, .swift) }
    func testPolicyLabObjectiveCSmoke() { runSmoke(.policyLab, .objectiveC) }

    func testWebContentSwiftSmoke() { runSmoke(.webContent, .swift) }
    func testWebContentObjectiveCSmoke() { runSmoke(.webContent, .objectiveC) }

    func testControlsAndGesturesSwiftSmoke() { runSmoke(.controlsAndGestures, .swift) }
    func testControlsAndGesturesObjectiveCSmoke() { runSmoke(.controlsAndGestures, .objectiveC) }

    private func runSmoke(
        _ scenario: DemoScenarioUnderTest,
        _ implementation: DemoImplementationUnderTest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let initial = launch(
            scenario: scenario,
            implementation: implementation,
            file: file,
            line: line
        )
        assertDragHostFillsScreen(file: file, line: line)

        let dragDistance = min(320, app.frame.height * 0.38)
        let up = dragPanel(deltaY: -dragDistance, file: file, line: line)
        let traceAfterUp = readHUDSnapshot()
        XCTAssertGreaterThan(
            up,
            initial + 8,
            "Upward header drag did not expand \(scenario.name)/\(implementation.rawValue). Trace: \(traceAfterUp.rawText)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            traceAfterUp.traceLines.contains(where: { $0.contains("willBeginDragging") }),
            "Header drag did not reach willBeginDragging. Trace: \(traceAfterUp.rawText)",
            file: file,
            line: line
        )

        let down = dragPanel(deltaY: dragDistance, file: file, line: line)
        XCTAssertLessThan(
            down,
            up - 8,
            "Downward header drag did not collapse \(scenario.name)/\(implementation.rawValue)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(down, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(up, app.frame.height, file: file, line: line)

        let trace = readHUDSnapshot()
        XCTAssertFalse(trace.rawText.isEmpty, "HUD trace is empty", file: file, line: line)
        attachHUDTrace("\(scenario.name)-\(implementation.rawValue)-trace")
        attachScreenshot("\(scenario.name)-\(implementation.rawValue)-smoke")
    }

    private func assertDragHostFillsScreen(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let host = requireElement(DemoAccessibilityID.dragHost, file: file, line: line)
        let screen = app.frame
        XCTAssertEqual(host.frame.minX, screen.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(host.frame.maxX, screen.maxX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(host.frame.minY, screen.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(host.frame.maxY, screen.maxY, accuracy: 1, file: file, line: line)
    }
}
