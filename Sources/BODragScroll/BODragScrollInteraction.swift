//
//  BODragScrollInteraction.swift
//  BODragScroll
//
//  UIKit interaction adaptation: hit testing, gesture arbitration, accessibility,
//  and completion of system touch/deceleration edge cases.
//

#if canImport(UIKit)
import UIKit
import UIKit.UIGestureRecognizerSubclass

// MARK: - Interaction-owned state

/// Reference state owned by `BODragScrollView.RuntimeState`.
///
/// Keeping the recognizer and the deferred control here lets the interaction layer own its UIKit
/// details without adding unrelated fields to the scroll/layout state.
@MainActor
final class BODragScrollInteractionState {
    fileprivate var touchCompletionGesture: TouchCompletionGestureRecognizer?
    fileprivate weak var decelerationInterruptedControl: UIControl?
    fileprivate var needsTouchCompletionSettlement = false
    fileprivate var didTouchWebView = false

    init() {}
}

// MARK: - Touch completion recognizer

/// Completes a touch sequence that interrupted a native scroll animation but did not start a drag.
/// The host uses the completion to settle the panel again after the finger is lifted.
@MainActor
final class TouchCompletionGestureRecognizer: UIGestureRecognizer {
    private var currentTouches: [UITouch] = []
    private var hasSeenMultipleTouches = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func reset() {
        super.reset()
        currentTouches.removeAll(keepingCapacity: true)
        hasSeenMultipleTouches = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)

        let beginsSequence = currentTouches.isEmpty
        currentTouches.append(contentsOf: touches)

        if beginsSequence, !currentTouches.isEmpty {
            state = .began
        }
        if currentTouches.count > 1 {
            hasSeenMultipleTouches = true
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finishTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finishTouches(touches)
    }

    /// Ends a multi-touch sequence only after every touch is gone, matching the OC recognizer.
    private func finishTouches(_ touches: Set<UITouch>) {
        if hasSeenMultipleTouches {
            currentTouches.removeAll { touches.contains($0) }
            if currentTouches.isEmpty {
                state = .ended
                hasSeenMultipleTouches = false
            }
        } else {
            state = .ended
        }
    }

    /// Stops the completion callback when a real panel drag has taken over settlement.
    func finishRecognition() {
        state = state == .possible ? .failed : .cancelled
    }
}

// MARK: - UIKit override forwarding targets

extension BODragScrollView {
    var didTouchWebView: Bool {
        get { runtime.interaction.didTouchWebView }
        set { runtime.interaction.didTouchWebView = newValue }
    }

    /// Installs interaction support once. Called from the view's common initializer.
    func installInteractionSupport() {
        guard runtime.interaction.touchCompletionGesture == nil else { return }

        let gesture = TouchCompletionGestureRecognizer(
            target: self,
            action: #selector(interaction_handleTouchCompletion(_:))
        )
        gesture.name = "BODragScrollView-TouchCompletion"
        gesture.delegate = self
        runtime.interaction.touchCompletionGesture = gesture
        addGestureRecognizer(gesture)
    }

    /// Forward target for `point(inside:with:)` in the main class.
    func interaction_point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let panelView else { return false }

        let visiblePanelLayer = panelView.layer.presentation() ?? panelView.layer
        let panelPoint = layer.convert(point, to: visiblePanelLayer)
        return panelView.point(inside: panelPoint, with: event)
    }

    /// Forward target for `hitTest(_:with:)` in the main class.
    func interaction_hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden,
              isUserInteractionEnabled,
              alpha > 0.01,
              let panelView else {
            return nil
        }

        let visiblePanelLayer = panelView.layer.presentation() ?? panelView.layer
        let panelPoint = layer.convert(point, to: visiblePanelLayer)
        guard panelView.point(inside: panelPoint, with: event),
              let hitView = panelView.hitTest(panelPoint, with: event) else {
            return nil
        }

        let nativeState = nativeScrollState
        let isInterruptingHostMotion = isPerformingViewTransition
            || isPerformingSystemScrollTransition
            || nativeState.isDecelerating
        if event != nil, isInterruptingHostMotion {
            if let primary = primaryParticipantScrollView, lastMotionWasParticipant {
                guard hierarchy(of: hitView) > 2 else {
                    return hitView
                }

                // During participant inertia, consume the interruption at the nearest nested scroll
                // view instead of allowing a control or Web view below it to receive a spurious tap.
                return capturedScrollViews(
                    from: hitView,
                    until: primary,
                    includeStart: true,
                    participatingOnly: false
                ).first ?? primary
            }

            // During panel inertia, the touch should only stop the selected scroll driver.
            return preferredParticipantScrollView(from: hitView) ?? self
        }

        // UIKit can leave a nested scroll view decelerating independently. Stop that scroll view
        // before dispatching a new touch to content below it.
        var responder: UIResponder? = hitView
        while let current = responder, current !== self {
            if let scrollView = current as? UIScrollView, scrollView.isDecelerating {
                return scrollView
            }
            responder = current.next
        }
        return hitView
    }

    /// Forward target invoked before the main class calls `super.touchesShouldBegin`.
    func interaction_touchesShouldBegin(
        _ touches: Set<UITouch>,
        with event: UIEvent?,
        in view: UIView
    ) {
#if DEBUG
        debugBeginTouch(from: view)
#endif
        let nativeState = nativeScrollState
        if lastMotionWasParticipant,
           primaryParticipantScrollView != nil,
           nativeState.isDecelerating,
           let control = view as? UIControl,
           hierarchy(of: view) == 1 {
            // UIScrollView suppresses this control sequence when the touch stops participant inertia.
            // Begin it manually; `finishDeferredControlInteraction()` delivers the matching end.
            runtime.interaction.decelerationInterruptedControl = control
            control.sendActions(for: .touchDown)
        }

        let touchedWebView = beginCapture(from: view)
        didTouchWebView = touchedWebView != nil
#if DEBUG
        debugCaptureDidFinish(from: view)
#endif
    }

    /// Forward target for `touchesShouldCancel(in:)` in the main class.
    func interaction_touchesShouldCancel(in view: UIView) -> Bool {
        true
    }

    /// Completes the UIControl sequence begun while participant inertia was being interrupted.
    /// Transition calls this from the outer scroll view's did-end-dragging callback.
    func finishDeferredControlInteraction() {
        guard let control = runtime.interaction.decelerationInterruptedControl else { return }
        defer { runtime.interaction.decelerationInterruptedControl = nil }

        let point = panGestureRecognizer.location(in: window)
        let controlRect = control.convert(control.bounds, to: window)
        control.sendActions(for: controlRect.contains(point) ? .touchUpInside : .touchUpOutside)
    }

    /// Cancels the touch-completion fallback when an actual drag has taken responsibility for settling.
    /// Transition calls this from the outer scroll view's will-begin-dragging callback.
    func cancelPendingTouchCompletionSettlement() {
        guard runtime.interaction.needsTouchCompletionSettlement else { return }
        runtime.interaction.needsTouchCompletionSettlement = false
        runtime.interaction.touchCompletionGesture?.finishRecognition()
    }

    /// Forward target for `accessibilityScroll(_:)` in the main class.
    func interaction_accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard panelView != nil else { return false }

        let providerState = decisionStateToken()
        let transactionEpoch = runtime.transition.nextTransactionID
        let disposition = behaviorProvider?.dragScrollView(
            self,
            accessibilityDispositionFor: direction
        ) ?? .automatic

        let inspectsParticipant: Bool
        switch disposition {
        case .handled:
            // `.handled` explicitly transfers the operation to the provider, including any state
            // change it performs synchronously.
            return true
        case .automatic:
            inspectsParticipant = true
        case .panelOnly:
            inspectsParticipant = false
        }
        guard runtime.transition.nextTransactionID == transactionEpoch,
              decisionStateToken() == providerState,
              panelView != nil else { return false }

        switch direction {
        case .down:
            if let targetHeight = nextHigherDetent() {
                moveForAccessibility(toDisplayHeight: targetHeight)
                return true
            }

            guard runtimeDetentHeights.isEmpty,
                  !inspectsParticipant || primaryParticipantScrollView == nil else {
                return false
            }

            return moveToAccessibilityPanelBoundary(maximum: true)

        case .up:
            if !runtimeDetentHeights.isEmpty {
                if let largestDetent = runtimeDetentHeights.last,
                   comparisonPolicy.isWithinBoundaryBand(displayHeight, largestDetent),
                   inspectsParticipant {
                    if primaryParticipantScrollView == nil, window != nil {
                        let captureTransactionEpoch = runtime.transition.nextTransactionID
                        let panelBeforeCapture = panelView
                        let center = CGPoint(x: bounds.midX, y: bounds.midY)
                        if let targetView = interaction_hitTest(center, with: nil) {
                            _ = beginCapture(from: targetView)
                        }
                        guard runtime.transition.nextTransactionID == captureTransactionEpoch,
                              panelView === panelBeforeCapture else {
                            // Capture policy callbacks installed a newer movement/structure. Treat
                            // the accessibility request as consumed without overriding that intent.
                            return true
                        }
                    }

                    if let primary = primaryParticipantScrollView,
                       primary.contentOffset.y > -primary.effectiveContentInset.top {
                        // The inner scroll view still has accessible content above the current item.
                        return false
                    }
                }

                guard let targetHeight = nextLowerDetent() else { return false }
                moveForAccessibility(toDisplayHeight: targetHeight)
                return true
            }

            guard !inspectsParticipant || primaryParticipantScrollView == nil else {
                return false
            }

            return moveToAccessibilityPanelBoundary(maximum: false)

        default:
            return false
        }
    }

    /// Forward target for `gestureRecognizerShouldBegin(_:)` in the main class.
    func interaction_gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if isTouchCompletionGesture(gestureRecognizer) {
            let interval = Date().timeIntervalSince1970 - lastSystemAnimationEndTimestamp
            runtime.interaction.needsTouchCompletionSettlement =
                lastSystemAnimationEndTimestamp > 0 && interval < 0.1
            lastSystemAnimationEndTimestamp = 0
            return runtime.interaction.needsTouchCompletionSettlement
        }

        if gestureRecognizer.view === self, let primary = primaryParticipantScrollView {
            switch configuration.handoff.mode {
            case .innerFirst:
                return false
            case .innerFirstAtBoundary:
                let velocityY = panGestureRecognizer.velocity(in: window).y
                return !innerScrollCanConsume(primary, gestureVelocityY: velocityY)
            case .coordinated:
                break
            }
        }

        if gestureRecognizer.view === self,
           configuration.capture.disablesPanelInteractionInWebView,
           didTouchWebView {
            return false
        }
        return true
    }

    /// Correctly accepts the recognizer's base type; this is not a `UITapGestureRecognizer`.
    @objc func interaction_handleTouchCompletion(_ gestureRecognizer: UIGestureRecognizer) {
        let nativeState = nativeScrollState
        guard runtime.interaction.needsTouchCompletionSettlement,
              gestureRecognizer.state == .ended,
              !nativeState.isDecelerating else {
            return
        }

        settleToNearestDetent(
            animated: true,
            options: BODragScrollMovementOptions(),
            completion: nil
        )
    }
}

// MARK: - Gesture arbitration

extension BODragScrollView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        let result = interaction_shouldRequireFailureOf(
            gestureRecognizer,
            otherGestureRecognizer: otherGestureRecognizer
        )
#if DEBUG
        debugGestureArbitration(
            callback: "shouldRequireFailureOf",
            gestureRecognizer: gestureRecognizer,
            otherGestureRecognizer: otherGestureRecognizer,
            result: result
        )
#endif
        return result
    }

    private func interaction_shouldRequireFailureOf(
        _ gestureRecognizer: UIGestureRecognizer,
        otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard !isTouchCompletionGesture(gestureRecognizer),
              gestureRecognizer.view === self else {
            return false
        }

        if let primary = primaryParticipantScrollView,
           otherGestureRecognizer.view === primary {
            switch configuration.handoff.mode {
            case .innerFirst:
                return true
            case .innerFirstAtBoundary:
                let velocityY = panGestureRecognizer.velocity(in: window).y
                return innerScrollCanConsume(primary, gestureVelocityY: velocityY)
            case .coordinated:
                return false
            }
        }

        let providerState = decisionStateToken()
        let transactionEpoch = runtime.transition.nextTransactionID
        if let strategy = behaviorProvider?.dragScrollView(
            self,
            strategyFor: gestureRecognizer,
            otherGesture: otherGestureRecognizer
        ) {
            guard runtime.transition.nextTransactionID == transactionEpoch,
                  decisionStateToken() == providerState else { return false }
            switch strategy {
            case .simultaneous, .panelFirst, .systemDefault:
                return false
            case .otherFirst:
                return true
            }
        }

        guard let otherScrollView = otherGestureRecognizer.view as? UIScrollView else {
            return false
        }
        switch capturePriority(for: otherScrollView) {
        case .otherFirst:
            return true
        case .panelFirst, .simultaneous, .systemDefault, .participant, nil:
            return false
        }
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        let result = interaction_shouldBeRequiredToFailBy(
            gestureRecognizer,
            otherGestureRecognizer: otherGestureRecognizer
        )
#if DEBUG
        debugGestureArbitration(
            callback: "shouldBeRequiredToFailBy",
            gestureRecognizer: gestureRecognizer,
            otherGestureRecognizer: otherGestureRecognizer,
            result: result
        )
#endif
        return result
    }

    private func interaction_shouldBeRequiredToFailBy(
        _ gestureRecognizer: UIGestureRecognizer,
        otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard !isTouchCompletionGesture(gestureRecognizer),
              gestureRecognizer.view === self else {
            return false
        }

        if let primary = primaryParticipantScrollView,
           otherGestureRecognizer.view === primary {
            switch configuration.handoff.mode {
            case .innerFirst:
                return false
            case .innerFirstAtBoundary:
                let velocityY = panGestureRecognizer.velocity(in: window).y
                return !innerScrollCanConsume(primary, gestureVelocityY: velocityY)
            case .coordinated:
                return true
            }
        }

        let providerState = decisionStateToken()
        let transactionEpoch = runtime.transition.nextTransactionID
        if let strategy = behaviorProvider?.dragScrollView(
            self,
            strategyFor: gestureRecognizer,
            otherGesture: otherGestureRecognizer
        ) {
            guard runtime.transition.nextTransactionID == transactionEpoch,
                  decisionStateToken() == providerState else { return false }
            switch strategy {
            case .panelFirst:
                return true
            case .simultaneous, .otherFirst, .systemDefault:
                return false
            }
        }

        let nativeState = nativeScrollState
        if nativeState.isDecelerating, otherGestureRecognizer is UITapGestureRecognizer {
            return configuration.gesture.failsOtherTapDuringDeceleration
        }

        guard let otherScrollView = otherGestureRecognizer.view as? UIScrollView else {
            return false
        }
        switch capturePriority(for: otherScrollView) {
        case .panelFirst, .participant:
            return true
        case .simultaneous, .otherFirst, .systemDefault, nil:
            return false
        }
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        let result = interaction_shouldRecognizeSimultaneouslyWith(
            gestureRecognizer,
            otherGestureRecognizer: otherGestureRecognizer
        )
#if DEBUG
        debugGestureArbitration(
            callback: "shouldRecognizeSimultaneouslyWith",
            gestureRecognizer: gestureRecognizer,
            otherGestureRecognizer: otherGestureRecognizer,
            result: result
        )
#endif
        return result
    }

    private func interaction_shouldRecognizeSimultaneouslyWith(
        _ gestureRecognizer: UIGestureRecognizer,
        otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if isTouchCompletionGesture(gestureRecognizer) {
            return true
        }
        guard gestureRecognizer.view === self else { return false }
        guard otherGestureRecognizer.view !== self else { return false }

        if let primary = primaryParticipantScrollView,
           otherGestureRecognizer.view === primary {
            // The outer driver coordinates the participant offset in code.
            return false
        }

        let providerState = decisionStateToken()
        let transactionEpoch = runtime.transition.nextTransactionID
        if let strategy = behaviorProvider?.dragScrollView(
            self,
            strategyFor: gestureRecognizer,
            otherGesture: otherGestureRecognizer
        ) {
            guard runtime.transition.nextTransactionID == transactionEpoch,
                  decisionStateToken() == providerState else { return false }
            switch strategy {
            case .simultaneous:
                return true
            case .panelFirst, .otherFirst, .systemDefault:
                return false
            }
        }

        guard configuration.gesture.recognizesSimultaneouslyWithOtherGestures else {
            return false
        }

        let nativeState = nativeScrollState
        if nativeState.isDecelerating, otherGestureRecognizer is UITapGestureRecognizer {
            let hierarchyDepth = otherGestureRecognizer.view.map { hierarchy(of: $0) } ?? -1
            let tapIsOutsideParticipant = primaryParticipantScrollView != nil
                && isWithinParticipantSegment
                && hierarchyDepth < 2
            if tapIsOutsideParticipant {
                return true
            }
            return !configuration.gesture.failsOtherTapDuringDeceleration
        }

        let hierarchyDepth = otherGestureRecognizer.view.map { hierarchy(of: $0) } ?? -1
        if let otherScrollView = otherGestureRecognizer.view as? UIScrollView {
            guard hierarchyDepth >= 1 else { return false }
            return capturePriority(for: otherScrollView) == .simultaneous
        }

        // Do not coexist with a recognizer below the primary participant: in Web content this can
        // otherwise scroll two nested layers at the same time.
        return !(primaryParticipantScrollView != nil && hierarchyDepth >= 2)
    }
}

// MARK: - Private interaction helpers

private extension BODragScrollView {
    var lastMotionWasParticipant: Bool {
        if case .participant = lastMotionSource {
            return true
        }
        return false
    }

    func isTouchCompletionGesture(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === runtime.interaction.touchCompletionGesture
    }

    func nextHigherDetent() -> CGFloat? {
        guard let largestDetent = runtimeDetentHeights.last else { return nil }
        let target = runtimeDetentHeights.first { $0 >= displayHeight + 1 }
            ?? largestDetent
        guard target != displayHeight else { return nil }
        return target
    }

    func nextLowerDetent() -> CGFloat? {
        guard let smallestDetent = runtimeDetentHeights.first else { return nil }
        let target = runtimeDetentHeights.last { $0 <= displayHeight - 1 }
            ?? smallestDetent
        guard target != displayHeight else { return nil }
        return target
    }

    func moveForAccessibility(toDisplayHeight targetHeight: CGFloat) {
        move(
            toDisplayHeight: targetHeight,
            animated: true,
            options: BODragScrollMovementOptions(),
            reason: .accessibility,
            completion: nil
        )
    }
}

#endif
