import XCTest

final class ViewportLayoutParityUITests: DemoUITestCase {
    private struct Observation {
        let portraitMaximum: CGFloat
        let landscapeMaximum: CGFloat
        let restoredPortraitMaximum: CGFloat
    }

    func testFreePanelMaximumTracksFullViewportAcrossRotation() {
        assertRotationParity(scenario: .freePanel)
    }

    func testNestedPanelMaximumTracksFullViewportAcrossRotation() {
        assertRotationParity(scenario: .nestedScrollChain)
    }

    func testLowestStateLeavesOrdinaryInnerScrollRegionReachable() {
        for implementation in [DemoImplementationUnderTest.swift, .objectiveC] {
            _ = launch(scenario: .tableHandoff, implementation: implementation)
            let height = dragPanel(toNormalizedScreenY: 0.995)
            let bottomInset = demoBottomSafeAreaInset()
            XCTAssertGreaterThan(
                height - bottomInset,
                100,
                "The Demo's lowest state must extend more than 100pt above the bottom safe area"
            )
            XCTAssertGreaterThanOrEqual(
                height - bottomInset - 152,
                50 - 0.5,
                "At least 50pt of ordinary inner-scroll space must remain interactable"
            )
        }
    }

    func testRotationDuringActiveMovementDoesNotDuplicateTerminalCallbacks() {
        var settledLandscapeHeights: [CGFloat] = []
        for implementation in [DemoImplementationUnderTest.swift, .objectiveC] {
            XCUIDevice.shared.orientation = .portrait
            _ = launch(
                scenario: .movement,
                implementation: implementation,
                launchEnvironment: [
                    "BODRAGSCROLL_AUTO_ROTATE_DURING_INTERRUPTION": "1"
                ]
            )
            let interrupt = requireElement("movement.interrupt")
            XCTAssertTrue(interrupt.isHittable, "The sticky interruption action is not hittable")
            XCTAssertEqual(waitForStableDisplayHeight(), 390, accuracy: 1)
            let portraitCeiling = viewportHeight()

            let baseline = latestTraceSequence
            interrupt.tap()
            XCTAssertTrue(
                waitUntil(timeout: 5) { self.app.frame.width > self.app.frame.height },
                "Application did not rotate while movement was active"
            )
            XCTAssertTrue(
                waitUntil(timeout: 3) { [weak self] in
                    self?.traceLines(after: baseline).contains {
                        $0.contains(" viewportInvalidation h=") && $0.contains(" anim=true ")
                    } == true
                },
                "Viewport reconciliation did not observe the active View animation"
            )
            let activePresentationHeights = traceLines(after: baseline).compactMap { line -> CGFloat? in
                guard line.contains(" viewportInvalidation h="),
                      line.contains(" anim=true ") else { return nil }
                return traceDetailValue(named: "visiblePanelHeight", in: line)
            }
            XCTAssertTrue(
                activePresentationHeights.contains {
                    $0 > 392 && $0 < portraitCeiling - 2
                },
                "Relayout did not sample a presentation frame between the middle and top detents: \(activePresentationHeights)"
            )
            XCTAssertTrue(
                waitUntil(timeout: 8) { [weak self] in
                    self?.traceCount(callback: "movementCompletion", after: baseline) == 2
                },
                "Both overlapping View-animation transactions must terminate during relayout"
            )
            let settledLandscapeHeight = waitForStableDisplayHeight()
            assertHeightInsideViewport(settledLandscapeHeight)
            settledLandscapeHeights.append(settledLandscapeHeight)
            let completions = traceLines(after: baseline).filter {
                $0.contains(" movementCompletion h=")
            }
            let firstCompletions = completions.filter { $0.contains("label=第一段") }
            let secondCompletions = completions.filter { $0.contains("label=第二段") }
            XCTAssertEqual(
                firstCompletions.count,
                1,
                "The first movement must publish exactly one public completion"
            )
            XCTAssertEqual(
                secondCompletions.count,
                1,
                "The replacement movement must publish exactly one public completion"
            )
            let terminalCountsAtCompletion = [
                traceCount(callback: "didEndScrollingAnimation", after: baseline),
                traceCount(callback: "didEndDecelerating", after: baseline),
                traceCount(callback: "didFinishMovement", after: baseline)
            ]
            XCTAssertEqual(
                terminalCountsAtCompletion[0],
                0,
                "A View-animation transaction must not manufacture a system-scroll terminal"
            )
            XCTAssertEqual(
                terminalCountsAtCompletion[1],
                0,
                "A programmatic View animation must not manufacture a deceleration terminal"
            )
            if implementation == .swift {
                XCTAssertEqual(
                    terminalCountsAtCompletion[2],
                    2,
                    "Each Swift transaction must publish exactly one typed terminal"
                )
                XCTAssertTrue(
                    firstCompletions.first?.contains("outcome=interrupted") == true,
                    "The replacement transaction did not interrupt the first Swift movement"
                )
                XCTAssertTrue(
                    secondCompletions.first?.contains("outcome=interrupted") == true,
                    "Viewport relayout did not interrupt the active second Swift movement"
                )
            } else {
                XCTAssertLessThanOrEqual(
                    terminalCountsAtCompletion[2],
                    2,
                    "The untagged OC target terminal duplicated before public completion"
                )
            }

            // Give UIKit a full extra turn to deliver any terminal callback deferred by the
            // forced animation/deceleration stop. The adapter must discard stale old terminals.
            waitForLateTerminalGrace()

            XCTAssertEqual(
                traceCount(callback: "movementCompletion", after: baseline),
                2,
                "Public movement completion duplicated after rotation"
            )
            XCTAssertEqual(
                [
                    traceCount(callback: "didEndScrollingAnimation", after: baseline),
                    traceCount(callback: "didEndDecelerating", after: baseline),
                    traceCount(callback: "didFinishMovement", after: baseline)
                ],
                terminalCountsAtCompletion,
                "A stale terminal callback arrived after both public completions"
            )
            attachHUDTrace(
                "viewport-active-movement-\(implementation.rawValue)",
                keepAlways: true
            )
            attachScreenshot(
                "viewport-active-movement-\(implementation.rawValue)",
                keepAlways: true
            )
        }
        XCTAssertEqual(settledLandscapeHeights.count, 2)
        if settledLandscapeHeights.count == 2 {
            XCTAssertEqual(
                settledLandscapeHeights[0],
                settledLandscapeHeights[1],
                accuracy: 1,
                "Swift and OC must preserve the same visible height through active rotation"
            )
        }
    }

    private func assertRotationParity(scenario: DemoScenarioUnderTest) {
        let swift = observeRotation(scenario: scenario, implementation: .swift)
        let objectiveC = observeRotation(scenario: scenario, implementation: .objectiveC)

        XCTAssertEqual(swift.portraitMaximum, objectiveC.portraitMaximum, accuracy: 1)
        XCTAssertEqual(swift.landscapeMaximum, objectiveC.landscapeMaximum, accuracy: 1)
        XCTAssertEqual(
            swift.restoredPortraitMaximum,
            objectiveC.restoredPortraitMaximum,
            accuracy: 1
        )
    }

    private func observeRotation(
        scenario: DemoScenarioUnderTest,
        implementation: DemoImplementationUnderTest
    ) -> Observation {
        XCUIDevice.shared.orientation = .portrait
        _ = launch(scenario: scenario, implementation: implementation)

        let portraitMaximum = expandToViewportMaximum()
        assertHeightInsideViewport(portraitMaximum)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            waitUntil(timeout: 5) { self.app.frame.width > self.app.frame.height },
            "Application did not rotate to landscape"
        )
        _ = waitForStableDisplayHeight()
        attachGeometry("landscape-before-expand-\(scenario.name)-\(implementation.rawValue)")
        let landscapeMaximum = expandToViewportMaximum()
        assertHeightInsideViewport(landscapeMaximum)

        // Pull upward once more at the ceiling. Bounce may temporarily overshoot, but settling must
        // return to the Demo-authored full-viewport detent.
        dragVisiblePanelContent(deltaY: -90, visibleOffsetFromPanelTop: 180, velocity: .slow)
        assertHeightInsideViewport(waitForStableDisplayHeight())

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(
            waitUntil(timeout: 5) { self.app.frame.height > self.app.frame.width },
            "Application did not rotate back to portrait"
        )
        _ = waitForStableDisplayHeight()
        let restoredPortraitMaximum = expandToViewportMaximum()
        assertHeightInsideViewport(restoredPortraitMaximum)

        attachHUDTrace(
            "viewport-\(scenario.name)-\(implementation.rawValue)",
            keepAlways: true
        )
        attachScreenshot(
            "viewport-\(scenario.name)-\(implementation.rawValue)",
            keepAlways: true
        )
        return Observation(
            portraitMaximum: portraitMaximum,
            landscapeMaximum: landscapeMaximum,
            restoredPortraitMaximum: restoredPortraitMaximum
        )
    }

    private func attachGeometry(_ name: String) {
        let hud = readHUDSnapshot()
        let values = [
            "app=\(app.frame)",
            "host=\(requireElement(DemoAccessibilityID.dragHost).frame)",
            "panel=\(requireElement(DemoAccessibilityID.panel).frame)",
            "ready=\(requireElement(DemoAccessibilityID.ready).frame)",
            "hudHeight=\(hud.displayHeight.map(String.init(describing:)) ?? "nil")"
        ]
        let attachment = XCTAttachment(string: values.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForLateTerminalGrace() {
        let grace = expectation(description: "late terminal grace")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { grace.fulfill() }
        wait(for: [grace], timeout: 1.5)
    }

    private func traceDetailValue(named name: String, in line: String) -> CGFloat? {
        let marker = "\(name)="
        guard let markerRange = line.range(of: marker) else { return nil }
        let suffix = line[markerRange.upperBound...]
        let token = suffix.prefix { character in
            character == "+" || character == "-" || character == "." || character.isNumber
        }
        return Double(token).map { CGFloat($0) }
    }

    private func expandToViewportMaximum() -> CGFloat {
        var height = waitForStableDisplayHeight()
        for _ in 0..<4 {
            let ceiling = viewportHeight()
            if abs(height - ceiling) <= 1 { break }
            height = dragPanel(deltaY: -app.frame.height * 0.72, velocity: .slow)
        }
        let ceiling = viewportHeight()
        XCTAssertEqual(
            height,
            ceiling,
            accuracy: 1,
            "Highest detent must equal the complete drag-host viewport"
        )
        return height
    }

    private func assertHeightInsideViewport(
        _ height: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ceiling = viewportHeight()
        XCTAssertLessThanOrEqual(
            height,
            ceiling + 0.5,
            "Panel exceeded the Demo viewport: height=\(height), ceiling=\(ceiling)",
            file: file,
            line: line
        )
    }

    private func viewportHeight() -> CGFloat {
        requireElement(DemoAccessibilityID.dragHost).frame.height
    }
}
