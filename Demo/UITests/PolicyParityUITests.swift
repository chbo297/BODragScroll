import XCTest

final class PolicyParityUITests: DemoUITestCase {
    private enum HandoffMode: CaseIterable {
        case coordinated
        case innerFirst
        case innerFirstAtBoundary

        var label: String {
            switch self {
            case .coordinated: return "协调"
            case .innerFirst: return "列表优先"
            case .innerFirstAtBoundary: return "到边界"
            }
        }
    }

    private enum BounceMode: CaseIterable {
        case panel
        case inner
        case disabled

        var label: String {
            switch self {
            case .panel: return "面板顶"
            case .inner: return "列表"
            case .disabled: return "关闭"
            }
        }
    }

    private enum VerticalGesture {
        case upward
        case downwardAtTopBoundary
    }

    private struct BounceObservation {
        let settledHeight: CGFloat
        let minimumHeightDuringPull: CGFloat
        let minimumInnerOffsetDuringPull: CGFloat
        let trace: String
    }

    private struct MotionObservation {
        let settledHeight: CGFloat
        let minimumHeight: CGFloat
        let maximumHeight: CGFloat
        let minimumInnerOffset: CGFloat
        let maximumInnerOffset: CGFloat
        let trace: String
    }

    /// Every public PolicyLab combination must be selectable without changing geometry or
    /// starting a capture. Semantic motion is tested separately so this matrix does not turn
    /// harmless UIKit frame-count differences into parity failures.
    func testAllThirtySixPolicyConfigurationsAreReachableAndStable() {
        for implementation in [DemoImplementationUnderTest.objectiveC, .swift] {
            _ = launch(scenario: .policyLab, implementation: implementation)
            let maximumHeight = dragPanel(deltaY: -app.frame.height * 0.62)
            XCTAssertGreaterThan(maximumHeight, 700)
            let firstMotionSequence = latestTraceSequence
            var visited = 0

            for handoff in HandoffMode.allCases {
                for bounce in BounceMode.allCases {
                    for resistance in [false, true] {
                        // Starting with false guarantees that at least one control changes for
                        // the first combination as the Demo defaults its indicator to on.
                        for indicator in [false, true] {
                            XCTContext.runActivity(
                                named: "\(implementation.rawValue)-\(handoff.label)-\(bounce.label)-r\(resistance)-i\(indicator)"
                            ) { _ in
                                configurePolicies(
                                    handoff: handoff,
                                    bounce: bounce,
                                    resistance: resistance,
                                    indicator: indicator
                                )
                                XCTAssertEqual(
                                    readHUDSnapshot().displayHeight ?? .nan,
                                    maximumHeight,
                                    accuracy: 1,
                                    "Changing a value-type policy unexpectedly changed panel geometry"
                                )
                                visited += 1
                            }
                        }
                    }
                }
            }

            XCTAssertEqual(visited, 36)
            XCTAssertTrue(requireElement("policyTable").exists)
            XCTAssertGreaterThanOrEqual(
                traceCount(callback: "sceneEvent", after: firstMotionSequence),
                36,
                "Each matrix configuration must publish at least one policy-update event"
            )
            XCTAssertEqual(
                traceCount(callback: "didScroll", after: firstMotionSequence),
                0,
                "Tapping policy controls must not synthesize scroll callbacks"
            )
            attachHUDTrace("policy-36-configurations-\(implementation.rawValue)", keepAlways: true)
            attachScreenshot("policy-36-configurations-\(implementation.rawValue)", keepAlways: true)
        }
    }

    /// Upward movement from the table's top distinguishes coordinated composition from both
    /// inner-first modes. Pulling down at that same boundary distinguishes unconditional
    /// inner-first from the boundary-aware mode.
    func testAllHandoffModesMatchObjectiveCInBothDirections() {
        for gesture in [VerticalGesture.upward, .downwardAtTopBoundary] {
            var objectiveC: [HandoffMode: MotionObservation] = [:]
            var swift: [HandoffMode: MotionObservation] = [:]

            for mode in HandoffMode.allCases {
                objectiveC[mode] = observeHandoff(
                    implementation: .objectiveC,
                    mode: mode,
                    gesture: gesture
                )
                swift[mode] = observeHandoff(
                    implementation: .swift,
                    mode: mode,
                    gesture: gesture
                )
            }

            for mode in HandoffMode.allCases {
                guard let reference = objectiveC[mode], let candidate = swift[mode] else {
                    XCTFail("Missing handoff observation for \(mode.label)")
                    continue
                }
                let containerParticipates = mode == .coordinated
                    || (mode == .innerFirstAtBoundary && gesture == .downwardAtTopBoundary)
                if containerParticipates {
                    assertLifecycle(in: reference.trace, context: "OC \(mode.label)")
                    assertLifecycle(in: candidate.trace, context: "Swift \(mode.label)")
                } else {
                    assertNoContainerLifecycle(in: reference.trace, context: "OC \(mode.label)")
                    assertNoContainerLifecycle(in: candidate.trace, context: "Swift \(mode.label)")
                }
                XCTAssertEqual(
                    candidate.settledHeight,
                    reference.settledHeight,
                    accuracy: 2,
                    "Settled panel height diverged for \(mode.label)/\(gesture)\nOC:\n\(reference.trace)\nSwift:\n\(candidate.trace)"
                )
            }

            guard let coordinatedOC = objectiveC[.coordinated],
                  let innerOC = objectiveC[.innerFirst],
                  let boundaryOC = objectiveC[.innerFirstAtBoundary],
                  let coordinatedSwift = swift[.coordinated],
                  let innerSwift = swift[.innerFirst],
                  let boundarySwift = swift[.innerFirstAtBoundary] else { continue }

            switch gesture {
            case .upward:
                for observation in [coordinatedOC, coordinatedSwift] {
                    XCTAssertGreaterThan(observation.maximumHeight, 400)
                    XCTAssertLessThan(observation.maximumInnerOffset, 30)
                }
                for observation in [innerOC, boundaryOC, innerSwift, boundarySwift] {
                    XCTAssertLessThanOrEqual(observation.maximumHeight, 392)
                    XCTAssertGreaterThan(observation.maximumInnerOffset, 40)
                }
            case .downwardAtTopBoundary:
                for observation in [coordinatedOC, boundaryOC, coordinatedSwift, boundarySwift] {
                    XCTAssertLessThan(observation.minimumHeight, 385)
                }
                for observation in [innerOC, innerSwift] {
                    XCTAssertGreaterThanOrEqual(observation.minimumHeight, 389)
                    XCTAssertGreaterThanOrEqual(observation.minimumInnerOffset, -1)
                }
            }
        }
    }

    /// Panel-owned and disabled top bounce are exercised at the lowest detent. Inner-owned top
    /// bounce needs visible list content, so its middle-detent regression remains the dedicated
    /// test below.
    func testPanelTopAndDisabledBounceMatchObjectiveCAtLowestDetent() {
        let objectiveCPanel = observeLowestDetentBounce(.objectiveC, mode: .panel)
        let swiftPanel = observeLowestDetentBounce(.swift, mode: .panel)
        let objectiveCDisabled = observeLowestDetentBounce(.objectiveC, mode: .disabled)
        let swiftDisabled = observeLowestDetentBounce(.swift, mode: .disabled)

        for observation in [objectiveCPanel, swiftPanel] {
            XCTAssertLessThan(
                observation.minimumHeight,
                148,
                "Panel-owned bounce was not exercised. Trace:\n\(observation.trace)"
            )
            assertLifecycle(in: observation.trace, context: "panel-owned bounce")
        }
        for observation in [objectiveCDisabled, swiftDisabled] {
            XCTAssertGreaterThanOrEqual(
                observation.minimumHeight,
                149,
                "Disabled bounce crossed the lowest detent. Trace:\n\(observation.trace)"
            )
            assertLifecycle(in: observation.trace, context: "disabled bounce")
        }
        XCTAssertEqual(swiftPanel.settledHeight, objectiveCPanel.settledHeight, accuracy: 1)
        XCTAssertEqual(swiftDisabled.settledHeight, objectiveCDisabled.settledHeight, accuracy: 1)
    }

    /// A short collapse gesture from the maximum detent is the OC tuning point for
    /// `shrinkResistance`: enabled stays at the current detent while disabled advances downward.
    func testCollapseResistanceMatchesObjectiveC() {
        let objectiveCWithout = observeCollapseResistance(.objectiveC, enabled: false)
        let objectiveCWith = observeCollapseResistance(.objectiveC, enabled: true)
        let swiftWithout = observeCollapseResistance(.swift, enabled: false)
        let swiftWith = observeCollapseResistance(.swift, enabled: true)

        XCTAssertNotEqual(
            objectiveCWithout.settledHeight,
            objectiveCWith.settledHeight,
            accuracy: 2,
            "Reference gesture did not reach the OC shrink-resistance decision boundary"
        )
        XCTAssertEqual(swiftWithout.settledHeight, objectiveCWithout.settledHeight, accuracy: 2)
        XCTAssertEqual(swiftWith.settledHeight, objectiveCWith.settledHeight, accuracy: 2)
        for observation in [objectiveCWithout, objectiveCWith, swiftWithout, swiftWith] {
            assertLifecycle(in: observation.trace, context: "collapse resistance")
        }
    }

    /// Indicator policy is presentation-only. Both implementations must preserve the same
    /// capture owner and geometry with it on or off. Screenshots are retained for visual review;
    /// exact indicator fade timing is deliberately not asserted because Swift uses UIKit's public
    /// `flashScrollIndicators()` while OC mutates private indicator subviews.
    func testIndicatorTogglePreservesMotionParity() {
        var observations: [String: MotionObservation] = [:]
        for implementation in [DemoImplementationUnderTest.objectiveC, .swift] {
            for enabled in [false, true] {
                let key = "\(implementation.rawValue)-\(enabled)"
                observations[key] = observeIndicator(implementation, enabled: enabled)
            }
        }

        guard let objectiveCOff = observations["OC-false"],
              let objectiveCOn = observations["OC-true"],
              let swiftOff = observations["Swift-false"],
              let swiftOn = observations["Swift-true"] else {
            XCTFail("Missing indicator observations")
            return
        }

        for observation in [objectiveCOff, objectiveCOn, swiftOff, swiftOn] {
            XCTAssertEqual(observation.settledHeight, 390, accuracy: 2)
            XCTAssertGreaterThan(observation.maximumInnerOffset, 40)
            XCTAssertLessThanOrEqual(observation.maximumHeight, 392)
            assertNoContainerLifecycle(in: observation.trace, context: "inner-first indicator policy")
        }
        XCTAssertEqual(swiftOff.settledHeight, objectiveCOff.settledHeight, accuracy: 2)
        XCTAssertEqual(swiftOn.settledHeight, objectiveCOn.settledHeight, accuracy: 2)
    }

    /// The original engine trims detents below the current detent for one capture when
    /// `forceBouncesInnerTop` is enabled. Pulling down from the middle detent must therefore
    /// bounce the table immediately instead of collapsing the panel toward the low detent.
    func testForcedInnerTopBounceAtMiddleDetentMatchesObjectiveC() {
        let objectiveC = observeForcedInnerTopBounce(.objectiveC)
        let swift = observeForcedInnerTopBounce(.swift)

        XCTAssertEqual(objectiveC.settledHeight, 390, accuracy: 1)
        XCTAssertEqual(swift.settledHeight, objectiveC.settledHeight, accuracy: 1)
        XCTAssertLessThan(
            objectiveC.minimumInnerOffsetDuringPull,
            -1,
            "OC reference gesture did not exercise inner top bounce. Trace:\n\(objectiveC.trace)"
        )
        XCTAssertLessThan(
            swift.minimumInnerOffsetDuringPull,
            -1,
            "Swift did not hand the pull-down to the inner table. Trace:\n\(swift.trace)"
        )
        XCTAssertEqual(
            swift.minimumHeightDuringPull,
            objectiveC.minimumHeightDuringPull,
            accuracy: 2,
            "Swift changed panel height while OC kept the middle detent.\nOC:\n\(objectiveC.trace)\nSwift:\n\(swift.trace)"
        )
        XCTAssertGreaterThanOrEqual(
            swift.minimumHeightDuringPull,
            swift.settledHeight - 2,
            "Forced inner bounce must not consume a lower panel detent. Trace:\n\(swift.trace)"
        )
    }

    private func observeForcedInnerTopBounce(
        _ implementation: DemoImplementationUnderTest
    ) -> BounceObservation {
        _ = launch(scenario: .policyLab, implementation: implementation)

        // Fully expose the table-header policy controls without scrolling that header.
        let expanded = dragPanel(deltaY: -app.frame.height * 0.62)
        XCTAssertGreaterThan(expanded, 700)
        _ = selectSegment(control: "policy.bounce", label: "列表")

        // Re-enter an exact detent while keeping the table at its top boundary.
        let middle = dragPanel(deltaY: app.frame.height * 0.46)
        XCTAssertEqual(middle, 390, accuracy: 1)
        let baseline = latestTraceSequence

        dragVisiblePanelContent(
            deltaY: 120,
            visibleOffsetFromPanelTop: 300,
            velocity: .slow
        )
        let settledHeight = waitForStableDisplayHeight()

        let samples = traceSamples(for: "policyTable", after: baseline)
        let trace = traceLines(after: baseline).joined(separator: "\n")
        XCTAssertFalse(
            samples.isEmpty,
            "No policy table snapshots were recorded for \(implementation.rawValue). Trace:\n\(trace)"
        )
        attachHUDTrace("policy-forced-inner-bounce-\(implementation.rawValue)", keepAlways: true)
        attachScreenshot("policy-forced-inner-bounce-\(implementation.rawValue)", keepAlways: true)

        return BounceObservation(
            settledHeight: settledHeight,
            minimumHeightDuringPull: samples.map(\.displayHeight).min() ?? middle,
            minimumInnerOffsetDuringPull: samples.map(\.offsetY).min() ?? 0,
            trace: trace
        )
    }

    private func observeHandoff(
        implementation: DemoImplementationUnderTest,
        mode: HandoffMode,
        gesture: VerticalGesture
    ) -> MotionObservation {
        preparePolicyScene(
            implementation,
            handoff: mode,
            bounce: .disabled,
            resistance: false,
            indicator: false,
            targetHeight: 390
        )
        let baseline = latestTraceSequence
        let markerBefore = requireElement("policy.handoff").frame.minY
        dragVisiblePanelContent(
            deltaY: gesture == .upward ? -180 : 120,
            // Keep the touch well above the home-affordance gate. In inner-first mode the host
            // intentionally yields, so a lower start can be interpreted as a system Home swipe.
            visibleOffsetFromPanelTop: 220,
            normalizedX: 0.12,
            velocity: .slow
        )
        let settledHeight = waitForStableDisplayHeight()
        let markerAfter = requireElement("policy.handoff").frame.minY
        let directInnerOffsetDelta = markerBefore - markerAfter
        let result = motionObservation(
            settledHeight: settledHeight,
            after: baseline,
            directInnerOffsetDelta: directInnerOffsetDelta
        )
        attachText(
            "policy-handoff-frame-\(implementation.rawValue)-\(mode.label)-\(gesture)",
            "markerBefore=\(markerBefore) markerAfter=\(markerAfter) delta=\(directInnerOffsetDelta)"
        )
        attachHUDTrace(
            "policy-handoff-\(implementation.rawValue)-\(mode.label)-\(gesture)",
            keepAlways: true
        )
        return result
    }

    private func observeLowestDetentBounce(
        _ implementation: DemoImplementationUnderTest,
        mode: BounceMode
    ) -> MotionObservation {
        preparePolicyScene(
            implementation,
            handoff: .coordinated,
            bounce: mode,
            resistance: false,
            indicator: false,
            targetHeight: 150
        )
        let baseline = latestTraceSequence
        _ = dragPanel(deltaY: 100, velocity: .slow)
        let settledHeight = waitForStableDisplayHeight()
        let result = motionObservation(settledHeight: settledHeight, after: baseline)
        attachHUDTrace(
            "policy-lowest-bounce-\(implementation.rawValue)-\(mode.label)",
            keepAlways: true
        )
        attachScreenshot(
            "policy-lowest-bounce-\(implementation.rawValue)-\(mode.label)",
            keepAlways: true
        )
        return result
    }

    private func observeCollapseResistance(
        _ implementation: DemoImplementationUnderTest,
        enabled: Bool
    ) -> MotionObservation {
        preparePolicyScene(
            implementation,
            handoff: .coordinated,
            bounce: .disabled,
            resistance: enabled,
            indicator: false,
            targetHeight: nil
        )
        let baseline = latestTraceSequence
        flickPanelDown(deltaY: 64)
        let settledHeight = waitForStableDisplayHeight()
        let result = motionObservation(settledHeight: settledHeight, after: baseline)
        attachHUDTrace(
            "policy-resistance-\(implementation.rawValue)-\(enabled)",
            keepAlways: true
        )
        return result
    }

    /// `shrinkResistance` is consulted only for a release with meaningful velocity. The common
    /// slow-drag helper deliberately settles its velocity to zero, so use a short real flick and
    /// no terminal hold for this policy's decision boundary.
    private func flickPanelDown(deltaY: CGFloat) {
        let displayHeight = waitForStableDisplayHeight()
        let frame = app.frame
        let startPoint = CGPoint(
            x: frame.midX,
            y: min(frame.maxY - 2, max(frame.minY + 2, frame.maxY - displayHeight + 22))
        )
        let targetY = min(frame.maxY - 2, max(frame.minY + 2, startPoint.y + deltaY))
        let start = app.coordinate(
            withNormalizedOffset: CGVector(
                dx: (startPoint.x - frame.minX) / max(frame.width, 1),
                dy: (startPoint.y - frame.minY) / max(frame.height, 1)
            )
        )
        let destination = app.coordinate(
            withNormalizedOffset: CGVector(
                dx: (startPoint.x - frame.minX) / max(frame.width, 1),
                dy: (targetY - frame.minY) / max(frame.height, 1)
            )
        )
        start.press(
            forDuration: 0.05,
            thenDragTo: destination,
            withVelocity: .fast,
            thenHoldForDuration: 0
        )
    }

    private func observeIndicator(
        _ implementation: DemoImplementationUnderTest,
        enabled: Bool
    ) -> MotionObservation {
        preparePolicyScene(
            implementation,
            handoff: .innerFirst,
            bounce: .disabled,
            resistance: false,
            indicator: enabled,
            targetHeight: 390
        )
        let baseline = latestTraceSequence
        let markerBefore = requireElement("policy.handoff").frame.minY
        dragVisiblePanelContent(
            deltaY: -180,
            visibleOffsetFromPanelTop: 220,
            normalizedX: 0.12,
            velocity: .slow
        )
        attachScreenshot(
            "policy-indicator-\(implementation.rawValue)-\(enabled)",
            keepAlways: true
        )
        let settledHeight = waitForStableDisplayHeight()
        let markerAfter = requireElement("policy.handoff").frame.minY
        let directInnerOffsetDelta = markerBefore - markerAfter
        let result = motionObservation(
            settledHeight: settledHeight,
            after: baseline,
            directInnerOffsetDelta: directInnerOffsetDelta
        )
        attachText(
            "policy-indicator-frame-\(implementation.rawValue)-\(enabled)",
            "markerBefore=\(markerBefore) markerAfter=\(markerAfter) delta=\(directInnerOffsetDelta)"
        )
        attachHUDTrace(
            "policy-indicator-\(implementation.rawValue)-\(enabled)",
            keepAlways: true
        )
        return result
    }

    private func preparePolicyScene(
        _ implementation: DemoImplementationUnderTest,
        handoff: HandoffMode,
        bounce: BounceMode,
        resistance: Bool,
        indicator: Bool,
        targetHeight: CGFloat?
    ) {
        _ = launch(scenario: .policyLab, implementation: implementation)
        let maximum = dragPanel(deltaY: -app.frame.height * 0.62)
        XCTAssertGreaterThan(maximum, 700)
        configurePolicies(
            handoff: handoff,
            bounce: bounce,
            resistance: resistance,
            indicator: indicator
        )
        guard let targetHeight else { return }
        let delta: CGFloat
        if targetHeight <= 151 {
            delta = app.frame.height * 0.72
        } else {
            delta = app.frame.height * 0.46
        }
        let resolved = dragPanel(deltaY: delta)
        XCTAssertEqual(resolved, targetHeight, accuracy: 1)
    }

    private func configurePolicies(
        handoff: HandoffMode,
        bounce: BounceMode,
        resistance: Bool,
        indicator: Bool
    ) {
        setSegment(control: "policy.handoff", label: handoff.label)
        setSegment(control: "policy.bounce", label: bounce.label)
        setSwitch("policy.resistance", on: resistance)
        setSwitch("policy.indicator", on: indicator)
    }

    private func setSegment(control identifier: String, label: String) {
        let control = requireElement(identifier)
        let button = control.buttons[label]
        if !button.exists {
            XCTAssertTrue(button.waitForExistence(timeout: 3), "Missing segment \(label) in \(identifier)")
        }
        if !button.isSelected {
            XCTAssertTrue(button.isHittable, "Segment \(label) is not hittable")
            button.tap()
        }
        XCTAssertTrue(button.isSelected, "Segment \(label) did not become selected")
    }

    private func setSwitch(_ identifier: String, on desiredValue: Bool) {
        let control = requireElement(identifier)
        if switchValue(control) != desiredValue {
            XCTAssertTrue(control.isHittable, "Switch \(identifier) is not hittable")
            control.tap()
        }
        XCTAssertEqual(switchValue(control), desiredValue)
    }

    private func switchValue(_ identifier: String) -> Bool {
        switchValue(requireElement(identifier))
    }

    private func switchValue(_ element: XCUIElement) -> Bool {
        if let number = element.value as? NSNumber {
            return number.boolValue
        }
        let value = String(describing: element.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["1", "true", "on", "yes", "开", "已打开"].contains(value)
    }

    private func motionObservation(
        settledHeight: CGFloat,
        after sequence: Int,
        directInnerOffsetDelta: CGFloat = 0
    ) -> MotionObservation {
        let samples = traceSamples(for: "policyTable", after: sequence)
        let callbackTrace = traceLines(after: sequence).joined(separator: "\n")
        let trace = callbackTrace.isEmpty
            ? "DIRECT_INNER markerOffsetDelta=\(directInnerOffsetDelta)"
            : callbackTrace
        if samples.isEmpty {
            // In both kernels `.innerFirst` deliberately prevents the container recognizer from
            // beginning. The panel delegate therefore has no callbacks to snapshot, so measure
            // the table's real movement from an accessibility element embedded in its header.
            return MotionObservation(
                settledHeight: settledHeight,
                minimumHeight: settledHeight,
                maximumHeight: settledHeight,
                minimumInnerOffset: min(0, directInnerOffsetDelta),
                maximumInnerOffset: max(0, directInnerOffsetDelta),
                trace: trace
            )
        }
        return MotionObservation(
            settledHeight: settledHeight,
            minimumHeight: samples.map(\.displayHeight).min() ?? settledHeight,
            maximumHeight: samples.map(\.displayHeight).max() ?? settledHeight,
            minimumInnerOffset: samples.map(\.offsetY).min() ?? 0,
            maximumInnerOffset: samples.map(\.offsetY).max() ?? 0,
            trace: trace
        )
    }

    private func assertLifecycle(in trace: String, context: String) {
        for callback in ["willBeginDragging", "didScroll", "willEndDragging", "didEndDragging"] {
            XCTAssertTrue(
                trace.contains(" \(callback) h="),
                "Missing \(callback) for \(context). Trace:\n\(trace)"
            )
        }
    }

    private func assertNoContainerLifecycle(in trace: String, context: String) {
        for callback in ["willBeginDragging", "didScroll", "willEndDragging", "didEndDragging"] {
            XCTAssertFalse(
                trace.contains(" \(callback) h="),
                "Container unexpectedly participated in \(context). Trace:\n\(trace)"
            )
        }
    }

    private func attachText(_ name: String, _ contents: String) {
        let attachment = XCTAttachment(string: contents)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
