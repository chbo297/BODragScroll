import XCTest

final class FreePanelBoundaryUITests: DemoUITestCase {
    private struct ContentGeometry {
        let mode: String
        let contentHeight: CGFloat
        let boundsHeight: CGFloat
        let insetTop: CGFloat
        let insetBottom: CGFloat
        let effectiveHeight: CGFloat
        let scrollableDistance: CGFloat
        let offsetY: CGFloat
        let minimumOffsetY: CGFloat
        let maximumOffsetY: CGFloat
        let relation: String
    }

    func testFreePanelBoundariesAndImplementationSwitch() {
        _ = launch(scenario: .freePanel, implementation: .swift)

        let swiftMinimum = dragPanel(toNormalizedScreenY: 0.995)
        XCTAssertEqual(swiftMinimum, 104, accuracy: 0.75)

        let swiftMaximum = dragPanel(toNormalizedScreenY: 0.005)
        XCTAssertGreaterThan(swiftMaximum, 190)
        XCTAssertLessThanOrEqual(swiftMaximum, app.frame.height - 1)
        attachHUDTrace("free-panel-Swift-maximum")
        attachScreenshot("free-panel-Swift-maximum")

        switchImplementation(to: .objectiveC)
        XCTAssertEqual(waitForStableDisplayHeight(), 190, accuracy: 0.75)

        let objectiveCMinimum = dragPanel(toNormalizedScreenY: 0.995)
        XCTAssertEqual(objectiveCMinimum, 104, accuracy: 0.75)

        let objectiveCMaximum = dragPanel(toNormalizedScreenY: 0.005)
        XCTAssertGreaterThan(objectiveCMaximum, 190)
        XCTAssertLessThanOrEqual(objectiveCMaximum, app.frame.height - 1)
        XCTAssertEqual(objectiveCMaximum, swiftMaximum, accuracy: 0.75)
        attachHUDTrace("free-panel-OC-maximum")
        attachScreenshot("free-panel-OC-maximum")

        switchImplementation(to: .swift)
        XCTAssertEqual(waitForStableDisplayHeight(), 190, accuracy: 0.75)
    }

    func testFreePanelContentAmountModesRespectInsetsForSwiftAndObjectiveC() {
        _ = launch(scenario: .freePanel, implementation: .swift)
        assertContentAmountModes(verifiesSwipeBehavior: true)

        // The last checked mode is C. It must be copied to the rebuilt OC page rather than reset.
        switchImplementation(to: .objectiveC)
        _ = dragPanel(toNormalizedScreenY: 0.005)
        let control = requireElement("free.contentAmount")
        XCTAssertTrue(control.buttons["C 大于"].isSelected)
        assertContentGeometry(readContentGeometry(expectedMode: "C"), mode: "C")
        // The repaired OC no-detent coordinator must now match Swift for A/B/C ownership and handoff.
        assertContentAmountModes(panelIsExpanded: true, verifiesSwipeBehavior: true)
    }

    private func assertContentAmountModes(
        panelIsExpanded: Bool = false,
        verifiesSwipeBehavior: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if !panelIsExpanded {
            _ = dragPanel(toNormalizedScreenY: 0.005, file: file, line: line)
        }

        for (segment, mode) in [("A 少于", "A"), ("B 等于", "B"), ("C 大于", "C")] {
            _ = selectSegment(control: "free.contentAmount", label: segment, file: file, line: line)
            let geometry = readContentGeometry(expectedMode: mode, file: file, line: line)
            assertContentGeometry(
                geometry,
                mode: mode,
                file: file,
                line: line
            )
            if verifiesSwipeBehavior {
                assertContentSwipeBehavior(
                    mode: mode,
                    initialGeometry: geometry,
                    file: file,
                    line: line
                )
            }
        }
    }

    private func assertContentSwipeBehavior(
        mode: String,
        initialGeometry: ContentGeometry,
        file: StaticString,
        line: UInt
    ) {
        dragVisiblePanelContent(
            deltaY: -180,
            visibleOffsetFromPanelTop: 500,
            velocity: .slow
        )
        Thread.sleep(forTimeInterval: 0.35)
        let result = readContentGeometry(expectedMode: mode, file: file, line: line)

        if mode == "C" {
            XCTAssertGreaterThan(
                result.offsetY,
                initialGeometry.minimumOffsetY + 10,
                "C mode should hand off to a genuinely scrollable inner content range",
                file: file,
                line: line
            )
            XCTAssertLessThanOrEqual(
                result.offsetY,
                result.maximumOffsetY,
                file: file,
                line: line
            )
        } else {
            XCTAssertEqual(
                result.offsetY,
                initialGeometry.minimumOffsetY,
                accuracy: 0.001,
                "A/B must not acquire a positive inner scrolling distance",
                file: file,
                line: line
            )
        }
    }

    private func readContentGeometry(
        expectedMode: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ContentGeometry {
        let marker = requireElement("free.contentGeometry", file: file, line: line)
        var rawValue = ""
        XCTAssertTrue(
            waitUntil(timeout: 3) {
                guard let value = marker.value as? String,
                      value.contains("mode=\(expectedMode);") else { return false }
                rawValue = value
                return true
            },
            "Content geometry did not update to mode \(expectedMode). Value: \(String(describing: marker.value))",
            file: file,
            line: line
        )

        let fields = Dictionary(uniqueKeysWithValues: rawValue.split(separator: ";").compactMap { field in
            let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
            return pair.count == 2 ? (pair[0], pair[1]) : nil
        })
        func number(_ key: String) -> CGFloat {
            guard let raw = fields[key], let value = Double(raw) else {
                XCTFail("Missing numeric field \(key) in \(rawValue)", file: file, line: line)
                return .nan
            }
            return CGFloat(value)
        }

        return ContentGeometry(
            mode: fields["mode"] ?? "",
            contentHeight: number("content"),
            boundsHeight: number("bounds"),
            insetTop: number("insetTop"),
            insetBottom: number("insetBottom"),
            effectiveHeight: number("effective"),
            scrollableDistance: number("scrollable"),
            offsetY: number("offsetY"),
            minimumOffsetY: number("minimumOffsetY"),
            maximumOffsetY: number("maximumOffsetY"),
            relation: fields["relation"] ?? ""
        )
    }

    private func assertContentGeometry(
        _ geometry: ContentGeometry,
        mode: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(geometry.mode, mode, file: file, line: line)
        XCTAssertGreaterThan(geometry.insetTop, 0, file: file, line: line)
        XCTAssertGreaterThan(geometry.insetBottom, 0, file: file, line: line)
        XCTAssertEqual(
            geometry.contentHeight + geometry.insetTop + geometry.insetBottom,
            geometry.effectiveHeight,
            accuracy: 0.001,
            file: file,
            line: line
        )
        XCTAssertEqual(
            geometry.maximumOffsetY - geometry.minimumOffsetY,
            geometry.scrollableDistance,
            accuracy: 0.001,
            file: file,
            line: line
        )
        XCTAssertEqual(
            geometry.offsetY,
            geometry.minimumOffsetY,
            accuracy: 0.001,
            "Changing mode or implementation must normalize the inner offset to its inset-aware top",
            file: file,
            line: line
        )

        switch mode {
        case "A":
            XCTAssertEqual(geometry.relation, "less", file: file, line: line)
            XCTAssertLessThan(geometry.effectiveHeight, geometry.boundsHeight - 1, file: file, line: line)
            XCTAssertEqual(geometry.scrollableDistance, 0, accuracy: 0.001, file: file, line: line)
        case "B":
            XCTAssertEqual(geometry.relation, "equal", file: file, line: line)
            XCTAssertEqual(
                geometry.effectiveHeight,
                geometry.boundsHeight,
                accuracy: 0.001,
                file: file,
                line: line
            )
            XCTAssertEqual(geometry.scrollableDistance, 0, accuracy: 0.001, file: file, line: line)
        case "C":
            XCTAssertEqual(geometry.relation, "greater", file: file, line: line)
            XCTAssertGreaterThan(geometry.effectiveHeight, geometry.boundsHeight + 500, file: file, line: line)
            XCTAssertEqual(
                geometry.scrollableDistance,
                geometry.effectiveHeight - geometry.boundsHeight,
                accuracy: 0.001,
                file: file,
                line: line
            )
        default:
            XCTFail("Unexpected content amount mode \(mode)", file: file, line: line)
        }
    }
}
