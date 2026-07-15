import XCTest

final class WebControlsParityUITests: DemoUITestCase {
    private struct WebObservation {
        let displayHeightAfterWebDrag: CGFloat
        let maximumWebOffset: CGFloat
        let trace: String
    }

    private struct CarouselObservation {
        let visibleItems: [Int]
        let displayHeight: CGFloat
    }

    private struct ControlsObservation {
        let sliderValue: Int
        let carousel: CarouselObservation
    }

    private struct AccessibilityObservation {
        let mode: String
        let collapsedHeight: CGFloat
        let expandedHeight: CGFloat
        let collapseResult: String
        let expandResult: String
    }

    func testWebLinkedAndExclusiveCaptureMatchObjectiveC() {
        let ocLinked = observeWebDrag(.objectiveC, mode: "面板联动")
        let swiftLinked = observeWebDrag(.swift, mode: "面板联动")
        let ocExclusive = observeWebDrag(.objectiveC, mode: "Web 独占")
        let swiftExclusive = observeWebDrag(.swift, mode: "Web 独占")

        XCTAssertEqual(
            swiftLinked.displayHeightAfterWebDrag,
            ocLinked.displayHeightAfterWebDrag,
            accuracy: 3,
            "Linked Web panel result differs.\nOC:\n\(ocLinked.trace)\nSwift:\n\(swiftLinked.trace)"
        )
        XCTAssertEqual(
            swiftExclusive.displayHeightAfterWebDrag,
            ocExclusive.displayHeightAfterWebDrag,
            accuracy: 3,
            "Exclusive Web panel result differs.\nOC:\n\(ocExclusive.trace)\nSwift:\n\(swiftExclusive.trace)"
        )
        XCTAssertGreaterThan(
            ocLinked.displayHeightAfterWebDrag,
            ocExclusive.displayHeightAfterWebDrag + 100
        )
        XCTAssertGreaterThan(
            swiftLinked.displayHeightAfterWebDrag,
            swiftExclusive.displayHeightAfterWebDrag + 100
        )
        XCTAssertGreaterThan(
            ocExclusive.maximumWebOffset,
            ocLinked.maximumWebOffset + 40,
            "OC reference did not distinguish linked/exclusive Web ownership"
        )
        XCTAssertGreaterThan(
            swiftExclusive.maximumWebOffset,
            swiftLinked.maximumWebOffset + 40,
            "Swift Web-exclusive mode did not give the gesture to WebKit"
        )
        XCTAssertEqual(
            swiftExclusive.maximumWebOffset,
            ocExclusive.maximumWebOffset,
            accuracy: 35
        )
    }

    func testOfflineWebButtonRemainsInteractiveInBothImplementations() {
        for implementation in [DemoImplementationUnderTest.objectiveC, .swift] {
            _ = launch(scenario: .webContent, implementation: implementation)
            _ = expandPanelToMaximum()
            _ = selectSegment(control: "web.mode", label: "Web 独占")

            let webView = requireElement("web.ready")
            var button = app.webViews.buttons["点击网页按钮"].firstMatch
            for _ in 0..<10 where !button.isHittable {
                webView.swipeUp()
                button = app.webViews.buttons["点击网页按钮"].firstMatch
            }
            XCTAssertTrue(
                button.isHittable,
                "Offline HTML button did not become reachable for \(implementation.rawValue)"
            )
            button.tap()
            XCTAssertTrue(
                app.webViews.buttons["网页按钮已触发 ✓"].firstMatch.waitForExistence(timeout: 3),
                "Web button click was swallowed for \(implementation.rawValue)"
            )
            attachScreenshot("web-button-\(implementation.rawValue)", keepAlways: true)
        }
    }

    func testNativeControlsAndDefaultHorizontalCarouselMatchObjectiveC() {
        let oc = observeControlsAndCarousel(.objectiveC)
        let swift = observeControlsAndCarousel(.swift)

        // XCUI's normalized slider position describes the full accessibility frame while UIKit
        // lays the thumb out inside track insets. On this runtime a requested 0.8 reports 84, so
        // verify that valueChanged fired and compare the two implementations instead of requiring
        // the geometrically incorrect literal 80.
        XCTAssertLessThanOrEqual(abs(swift.sliderValue - oc.sliderValue), 1)
        XCTAssertTrue((70...90).contains(oc.sliderValue))

        XCTAssertEqual(swift.carousel.displayHeight, oc.carousel.displayHeight, accuracy: 2)
        XCTAssertEqual(
            swift.carousel.visibleItems,
            oc.carousel.visibleItems,
            "Default carousel result differs"
        )
        XCTAssertFalse(
            swift.carousel.visibleItems.isEmpty,
            "Carousel accessibility state was unreadable"
        )
    }

    func testAccessibilityOwnershipModesMatchObjectiveC() {
        let modes = ["自动", "Panel", "接管"]
        for mode in modes {
            let objectiveC = observeAccessibilityMode(.objectiveC, mode: mode)
            let swift = observeAccessibilityMode(.swift, mode: mode)

            XCTAssertEqual(swift.collapsedHeight, objectiveC.collapsedHeight, accuracy: 2)
            XCTAssertEqual(swift.expandedHeight, objectiveC.expandedHeight, accuracy: 2)
            XCTAssertEqual(
                swift.collapseResult.contains("handled"),
                objectiveC.collapseResult.contains("handled"),
                "Collapse handling differs in \(mode) mode"
            )
            XCTAssertEqual(
                swift.expandResult.contains("handled"),
                objectiveC.expandResult.contains("handled"),
                "Expand handling differs in \(mode) mode"
            )
            XCTAssertTrue(swift.collapseResult.contains("accessibilityScroll"))
            XCTAssertTrue(swift.expandResult.contains("accessibilityScroll"))
        }
    }

    private func observeWebDrag(
        _ implementation: DemoImplementationUnderTest,
        mode: String
    ) -> WebObservation {
        _ = launch(scenario: .webContent, implementation: implementation)
        _ = expandPanelToMaximum()
        _ = selectSegment(control: "web.mode", label: mode)
        let middle = dragPanel(deltaY: app.frame.height * 0.48, velocity: .slow)
        XCTAssertEqual(middle, 390, accuracy: 1)

        let baseline = latestTraceSequence
        dragVisiblePanelContent(
            deltaY: -340,
            visibleOffsetFromPanelTop: 330,
            velocity: .slow
        )
        let heightAfterWebDrag = waitForStableDisplayHeight()

        // Web-exclusive scrolling does not call the panel delegate. A small header gesture records
        // one passive participant snapshot without changing the ownership result just measured.
        _ = dragPanel(deltaY: -35, velocity: .slow)
        let samples = traceSamples(for: "webScroll", after: baseline)
        let trace = traceLines(after: baseline).joined(separator: "\n")
        XCTAssertFalse(samples.isEmpty, "No Web snapshots for \(mode)/\(implementation.rawValue)")
        attachHUDTrace("web-\(mode)-\(implementation.rawValue)", keepAlways: true)
        attachScreenshot("web-\(mode)-\(implementation.rawValue)", keepAlways: true)
        return WebObservation(
            displayHeightAfterWebDrag: heightAfterWebDrag,
            maximumWebOffset: samples.map(\.offsetY).max() ?? 0,
            trace: trace
        )
    }

    private func observeControlsAndCarousel(
        _ implementation: DemoImplementationUnderTest
    ) -> ControlsObservation {
        _ = launch(scenario: .controlsAndGestures, implementation: implementation)
        let maximum = expandPanelToMaximum()

        let button = requireElement("controls.button")
        button.tap()
        XCTAssertTrue(elementText("controls.result").contains("count 1"))

        let toggle = requireElement("controls.switch")
        toggle.tap()
        XCTAssertTrue(elementText("controls.result").contains("Switch · ON"))

        let slider = requireElement("controls.slider")
        slider.adjust(toNormalizedSliderPosition: 0.8)
        XCTAssertTrue(
            waitUntil(timeout: 2) { self.elementText("controls.result").contains("Slider ·") },
            "Slider valueChanged was swallowed for \(implementation.rawValue)"
        )
        let sliderResult = elementText("controls.result")
        let sliderValue = sliderValue(in: sliderResult)
        XCTAssertNotNil(
            sliderValue,
            "Could not parse slider result for \(implementation.rawValue): \(sliderResult)"
        )

        let carousel = scrollToElement("controls.carousel", in: "controlsPageScroll")
        swipe(
            carousel,
            from: CGVector(dx: 0.84, dy: 0.5),
            to: CGVector(dx: 0.16, dy: 0.5),
            velocity: .slow
        )
        Thread.sleep(forTimeInterval: 0.35)
        let height = waitForStableDisplayHeight()
        XCTAssertEqual(height, maximum, accuracy: 2)
        let observation = CarouselObservation(
            visibleItems: visibleCarouselItems(in: carousel),
            displayHeight: height
        )
        attachScreenshot("controls-carousel-\(implementation.rawValue)", keepAlways: true)
        return ControlsObservation(sliderValue: sliderValue ?? -1, carousel: observation)
    }

    private func observeAccessibilityMode(
        _ implementation: DemoImplementationUnderTest,
        mode: String
    ) -> AccessibilityObservation {
        _ = launch(scenario: .controlsAndGestures, implementation: implementation)
        _ = expandPanelToMaximum()
        _ = scrollToElement("controls.accessibility", in: "controlsPageScroll")
        _ = selectSegment(control: "controls.accessibility", label: mode)

        let collapse = scrollToElement(
            "controls.accessibility.collapse",
            in: "controlsPageScroll"
        )
        collapse.tap()
        let collapsedHeight = waitForStableDisplayHeight()
        let collapseResult = elementText("controls.result")

        let expand = scrollToElement(
            "controls.accessibility.expand",
            in: "controlsPageScroll"
        )
        expand.tap()
        let expandedHeight = waitForStableDisplayHeight()
        let expandResult = elementText("controls.result")
        attachHUDTrace(
            "controls-accessibility-\(mode)-\(implementation.rawValue)",
            keepAlways: true
        )
        return AccessibilityObservation(
            mode: mode,
            collapsedHeight: collapsedHeight,
            expandedHeight: expandedHeight,
            collapseResult: collapseResult,
            expandResult: expandResult
        )
    }

    private func expandPanelToMaximum() -> CGFloat {
        var height = waitForStableDisplayHeight()
        for _ in 0..<3 where height < app.frame.height * 0.75 {
            height = dragPanel(deltaY: -app.frame.height * 0.62, velocity: .slow)
        }
        XCTAssertGreaterThan(height, app.frame.height * 0.75)
        return height
    }

    private func visibleCarouselItems(in carousel: XCUIElement) -> [Int] {
        let visibleFrame = carousel.frame.insetBy(dx: 1, dy: 1)
        return carousel.descendants(matching: .staticText).allElementsBoundByIndex
            .compactMap { element -> Int? in
                guard element.exists,
                      visibleFrame.intersects(element.frame) else { return nil }
                return Int(element.label)
            }
            .sorted()
    }

    private func sliderValue(in text: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: #"Slider ·\s*([0-9]+)"#),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}
