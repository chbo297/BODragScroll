import XCTest

/// UI automation verifies the lab's hierarchy, instrumentation and ordinary control delivery.
/// Exact "fling, then press before deceleration ends" timing remains a physical/manual lab case:
/// XCUITest intentionally waits for scroll quiescence between two synthesized gestures.
final class DecelerationControlLabUITests: DemoUITestCase {
    private struct Counts: Equatable {
        var down = 0
        var upInside = 0
        var upOutside = 0
        var cancel = 0
        var movingDown = 0
    }

    private let controlIDs = [
        "deceleration.fixed.button",
        "deceleration.fixed.control",
        "deceleration.inner.button",
        "deceleration.inner.control",
        "deceleration.overlay.button",
        "deceleration.overlay.control"
    ]

    func testAllControlVariantsAreVisibleAndInstrumented() {
        _ = launch(scenario: .decelerationControlLab, implementation: .swift)

        let innerScroll = requireElement("deceleration.inner.scroll")
        let fixedRegion = requireElement("deceleration.fixed.region")
        let overlayRegion = requireElement("deceleration.overlay.region")
        XCTAssertTrue(innerScroll.isHittable)
        XCTAssertTrue(fixedRegion.exists)
        XCTAssertTrue(overlayRegion.exists)
        XCTAssertFalse(
            fixedRegion.frame.intersects(innerScroll.frame),
            "The fixed controls must remain outside the participant scroll view."
        )
        XCTAssertTrue(
            overlayRegion.frame.intersects(innerScroll.frame),
            "The overlay controls must visually cover the participant while remaining siblings."
        )
        for identifier in controlIDs {
            let control = requireElement(identifier)
            XCTAssertTrue(
                control.frame.intersects(app.frame),
                "Control is not visible in the lab: \(identifier) · \(control.frame)"
            )
            XCTAssertEqual(counts(for: identifier), Counts())
        }
    }

    func testControlInstrumentationReportsOrdinaryTapsInBothImplementations() {
        for implementation in [DemoImplementationUnderTest.objectiveC, .swift] {
            _ = launch(scenario: .decelerationControlLab, implementation: implementation)

            for identifier in controlIDs {
                let control = requireElement(identifier)
                let before = counts(for: identifier)
                // A custom UIControl hosted by UITableView's sticky section header is exposed by
                // AX but can report `isHittable == false` on some simulator runtimes. A physical
                // coordinate tap still exercises the real UIKit hit-test path.
                if control.isHittable {
                    control.tap()
                } else {
                    control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                }
                XCTAssertTrue(
                    waitUntil(timeout: 2) {
                        self.counts(for: identifier).upInside == before.upInside + 1
                    },
                    "Tap instrumentation did not finish for \(identifier)/\(implementation.rawValue)"
                )
                let after = counts(for: identifier)
                XCTAssertEqual(after.down, before.down + 1)
                XCTAssertEqual(after.upInside, before.upInside + 1)
                XCTAssertEqual(after.upOutside, before.upOutside)
                XCTAssertEqual(after.cancel, before.cancel)
                XCTAssertEqual(after.movingDown, before.movingDown)
            }
        }
    }

    private func counts(for identifier: String) -> Counts {
        let value = elementText(identifier)
        return Counts(
            down: integer(named: "down", in: value),
            upInside: integer(named: "upInside", in: value),
            upOutside: integer(named: "upOutside", in: value),
            cancel: integer(named: "cancel", in: value),
            movingDown: integer(named: "movingDown", in: value)
        )
    }

    private func integer(named key: String, in text: String) -> Int {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        guard let expression = try? NSRegularExpression(pattern: escapedKey + #"=([0-9]+)"#),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              let range = Range(match.range(at: 1), in: text),
              let value = Int(text[range]) else {
            XCTFail("Missing \(key) counter in accessibility value: \(text)")
            return -1
        }
        return value
    }
}
