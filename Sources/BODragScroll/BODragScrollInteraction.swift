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
    fileprivate var controlTouchObserver: ControlTouchObserverGestureRecognizer?
    fileprivate var deferredControlInteraction: DeferredControlInteraction?
    fileprivate var nextDeferredControlInteractionID: UInt64 = 1
    fileprivate var needsTouchCompletionSettlement = false
    fileprivate var didTouchWebView = false

    init() {}
}

/// Monotonic identity for one physical touch while it is live in the dedicated control observer.
///
/// `ObjectIdentifier(UITouch)` is used only as the observer's short-lived lookup key. It is never
/// persisted as control ownership, so UIKit reusing a `UITouch` object cannot complete an older
/// synthetic sequence.
struct DeferredControlTouchToken: Hashable {
    let rawValue: UInt64
}

/// One synthetic UIControl sequence started while a participant scroll view is decelerating.
///
/// The identifier prevents a stale terminal callback from completing a newer physical touch. The
/// control stays weak because removing it from the hierarchy must never extend its lifetime merely
/// to deliver a synthetic terminal event.
@MainActor
fileprivate final class DeferredControlInteraction {
    let id: UInt64
    let touchToken: DeferredControlTouchToken
    let initialLocationInWindow: CGPoint
    weak var control: UIControl?
    weak var initialWindow: UIWindow?
    weak var initialSuperview: UIView?

    init(
        id: UInt64,
        touchToken: DeferredControlTouchToken,
        initialLocationInWindow: CGPoint,
        control: UIControl
    ) {
        self.id = id
        self.touchToken = touchToken
        self.initialLocationInWindow = initialLocationInWindow
        self.control = control
        initialWindow = control.window
        initialSuperview = control.superview
    }
}

// MARK: - Passive control touch observer

/// Observes physical touches for synthetic UIControl delivery without ever recognizing or
/// participating in gesture arbitration.
///
/// Interrupted-motion attach correction is intentionally owned by a separate recognizer. Every
/// registered control token leaves this observer through ended, cancelled, or observation-lost
/// exactly once, without participating in gesture arbitration.
@MainActor
final class ControlTouchObserverGestureRecognizer: UIGestureRecognizer {
    struct TouchSample {
        let token: DeferredControlTouchToken
        let identifier: ObjectIdentifier
        let locationInHost: CGPoint
        let locationInWindow: CGPoint
    }

    struct TouchTerminal {
        let sample: TouchSample
        let cancelled: Bool
    }

    private var tokensByTouchIdentifier: [ObjectIdentifier: DeferredControlTouchToken] = [:]
    private var nextTokenValue: UInt64 = 1

    var onTouchesBegan: (([TouchSample]) -> Void)?
    var onTouchesMoved: (([TouchSample]) -> Void)?
    var onTouchesFinished: (([TouchTerminal]) -> Void)?
    var onObservationLost: (([TouchSample]) -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func reset() {
        super.reset()
        invalidateObservation()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        let samples = touches.compactMap { touch -> TouchSample? in
            guard let token = registerIfNeeded(touchIdentifier: ObjectIdentifier(touch)) else {
                return nil
            }
            return TouchSample(
                token: token,
                identifier: ObjectIdentifier(touch),
                locationInHost: touch.location(in: view),
                locationInWindow: touch.location(in: view?.window)
            )
        }
        if !samples.isEmpty {
            onTouchesBegan?(samples)
        }
        // Deliberately remain `.possible`. This object is an observer, not a competing gesture.
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        let samples = samples(for: touches)
        if !samples.isEmpty {
            onTouchesMoved?(samples)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finishTouches(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finishTouches(touches, cancelled: true)
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    func token(for touch: UITouch) -> DeferredControlTouchToken? {
        guard isEnabled,
              state == .possible,
              touch.phase != .ended,
              touch.phase != .cancelled else { return nil }
        return registerIfNeeded(touchIdentifier: ObjectIdentifier(touch))
    }

    func isLive(_ token: DeferredControlTouchToken) -> Bool {
        tokensByTouchIdentifier.values.contains(token)
    }

    func token(for identifier: ObjectIdentifier) -> DeferredControlTouchToken? {
        tokensByTouchIdentifier[identifier]
    }

    func identifier(for token: DeferredControlTouchToken) -> ObjectIdentifier? {
        tokensByTouchIdentifier.first { $0.value == token }?.key
    }

    var liveTouchCount: Int {
        tokensByTouchIdentifier.count
    }

    /// Internal deterministic seam for UIKit integration tests that cannot construct `UITouch`.
    func registerTouchForTesting(identifier: ObjectIdentifier) -> DeferredControlTouchToken {
        registerIfNeeded(touchIdentifier: identifier)!
    }

    func finishTouchForTesting(
        token: DeferredControlTouchToken,
        identifier: ObjectIdentifier,
        locationInHost: CGPoint,
        cancelled: Bool
    ) {
        guard tokensByTouchIdentifier[identifier] == token else { return }
        tokensByTouchIdentifier.removeValue(forKey: identifier)
        onTouchesFinished?([
            TouchTerminal(
                sample: TouchSample(
                    token: token,
                    identifier: identifier,
                    locationInHost: locationInHost,
                    locationInWindow: locationInHost
                ),
                cancelled: cancelled
            )
        ])
    }

    func loseAllTouchesForTesting() {
        invalidateObservation()
    }

    /// Drops every locally observed touch before reporting loss. This is also used when the host is
    /// removed from a window, where UIKit is not required to send a terminal recognizer callback.
    func invalidateObservation() {
        let lost = liveSamples(locationInHost: .zero)
        tokensByTouchIdentifier.removeAll(keepingCapacity: true)
        if !lost.isEmpty {
            onObservationLost?(lost)
        }
    }

    private func registerIfNeeded(
        touchIdentifier: ObjectIdentifier
    ) -> DeferredControlTouchToken? {
        if let token = tokensByTouchIdentifier[touchIdentifier] {
            return token
        }
        let token = DeferredControlTouchToken(rawValue: nextTokenValue)
        nextTokenValue &+= 1
        tokensByTouchIdentifier[touchIdentifier] = token
        return token
    }

    private func samples(for touches: Set<UITouch>) -> [TouchSample] {
        touches.compactMap { touch in
            let identifier = ObjectIdentifier(touch)
            guard let token = tokensByTouchIdentifier[identifier] else { return nil }
            return TouchSample(
                token: token,
                identifier: identifier,
                locationInHost: touch.location(in: view),
                locationInWindow: touch.location(in: view?.window)
            )
        }
    }

    private func finishTouches(_ touches: Set<UITouch>, cancelled: Bool) {
        let terminals = samples(for: touches).map {
            TouchTerminal(sample: $0, cancelled: cancelled)
        }
        for touch in touches {
            tokensByTouchIdentifier.removeValue(forKey: ObjectIdentifier(touch))
        }
        if !terminals.isEmpty {
            onTouchesFinished?(terminals)
        }
        if tokensByTouchIdentifier.isEmpty, state == .possible {
            state = .failed
        }
    }

    private func liveSamples(locationInHost: CGPoint) -> [TouchSample] {
        tokensByTouchIdentifier.map { identifier, token in
            TouchSample(
                token: token,
                identifier: identifier,
                locationInHost: locationInHost,
                locationInWindow: locationInHost
            )
        }
    }
}

// MARK: - Touch completion recognizer

/// Completes a touch sequence that interrupted panel motion but did not start a new drag.
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
        // Keep the OC recognizer's terminal mapping exactly: both ended and cancelled touches
        // leave through the same finish routine and publish recognizer state `.ended`.
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
    /// Whether a tracking-only touch still intends to settle interrupted panel motion.
    var isAwaitingTouchCompletionSettlement: Bool {
        runtime.interaction.needsTouchCompletionSettlement
    }

    var didTouchWebView: Bool {
        get { runtime.interaction.didTouchWebView }
        set { runtime.interaction.didTouchWebView = newValue }
    }

    /// Installs interaction support once. Called from the view's common initializer.
    func installInteractionSupport() {
        guard runtime.interaction.touchCompletionGesture == nil,
              runtime.interaction.controlTouchObserver == nil else { return }

        let controlObserver = ControlTouchObserverGestureRecognizer(target: nil, action: nil)
        controlObserver.name = "BODragScrollView-ControlTouchObserver"
        controlObserver.onTouchesBegan = { [weak self, weak controlObserver] samples in
            guard let self, let controlObserver else { return }
            for sample in samples {
                self.cancelStaleDeferredControlBeforeNewTouch(
                    newToken: sample.token,
                    observer: controlObserver
                )
            }
        }
        controlObserver.onTouchesMoved = { [weak self] samples in
            guard let self else { return }
            for sample in samples {
                self.cancelDeferredControlIfOwnerBecameDrag(
                    touchToken: sample.token,
                    locationInWindow: sample.locationInWindow
                )
            }
        }
        controlObserver.onTouchesFinished = { [weak self] terminals in
            guard let self else { return }
            for terminal in terminals {
                self.finishDeferredControlFromTouchObserver(
                    touchToken: terminal.sample.token,
                    terminalLocationInHost: terminal.sample.locationInHost,
                    cancelled: terminal.cancelled
                )
            }
        }
        controlObserver.onObservationLost = { [weak self] samples in
            guard let self else { return }
            let lostTokens = Set(samples.map(\.token))
            guard let interaction = self.runtime.interaction.deferredControlInteraction,
                  lostTokens.contains(interaction.touchToken) else { return }
            self.cancelDeferredControlInteractionIfNeeded(expectedID: interaction.id)
        }
        runtime.interaction.controlTouchObserver = controlObserver
        addGestureRecognizer(controlObserver)

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
                let hierarchyDepth = hierarchy(of: hitView)
                guard hierarchyDepth > 2 else {
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
           hierarchy(of: view) == 1,
           let control = view as? UIControl,
           touches.count == 1,
           let touch = touches.first,
           let observer = runtime.interaction.controlTouchObserver,
           let touchToken = observer.token(for: touch) {
            // Match the OC compatibility boundary: only a control outside the decelerating
            // participant gets a synthetic sequence. Controls inside the participant remain under
            // UIKit's ordinary "stop inertia without activating content" behavior.
            beginDeferredControlInteraction(
                with: control,
                touchToken: touchToken,
                initialLocationInHost: touch.location(in: self),
                initialLocationInWindow: touch.location(in: window)
            )
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

    /// Identifier of the synthetic sequence owned by the current physical touch, if any.
    var pendingDeferredControlInteractionID: UInt64? {
        runtime.interaction.deferredControlInteraction?.id
    }

    var pendingDeferredControlTouchToken: DeferredControlTouchToken? {
        runtime.interaction.deferredControlInteraction?.touchToken
    }

    /// Compatibility seam for the existing deterministic UIKit tests. Production ownership remains
    /// token-based; the physical object identifier never leaves the observer's live lookup table.
    var pendingDeferredControlTouchIdentifier: ObjectIdentifier? {
        guard let token = pendingDeferredControlTouchToken else { return nil }
        return runtime.interaction.controlTouchObserver?.identifier(for: token)
    }

    private func cancelStaleDeferredControlBeforeNewTouch(
        newToken: DeferredControlTouchToken,
        observer: ControlTouchObserverGestureRecognizer
    ) {
        guard let interaction = runtime.interaction.deferredControlInteraction,
              interaction.touchToken != newToken,
              !observer.isLive(interaction.touchToken) else { return }
        cancelDeferredControlInteractionIfNeeded(expectedID: interaction.id)
    }

    // Internal deterministic seams for UIKit tests, which cannot construct `UITouch` instances.
    func registerControlTouchForTesting(
        identifier: ObjectIdentifier
    ) -> DeferredControlTouchToken {
        runtime.interaction.controlTouchObserver!.registerTouchForTesting(identifier: identifier)
    }

    func finishControlTouchForTesting(
        token: DeferredControlTouchToken,
        identifier: ObjectIdentifier,
        locationInHost: CGPoint,
        cancelled: Bool
    ) {
        runtime.interaction.controlTouchObserver?.finishTouchForTesting(
            token: token,
            identifier: identifier,
            locationInHost: locationInHost,
            cancelled: cancelled
        )
    }

    func loseControlTouchObservationForTesting() {
        runtime.interaction.controlTouchObserver?.loseAllTouchesForTesting()
    }

    func beginDeferredControlInteraction(
        with control: UIControl,
        touchIdentifier: ObjectIdentifier,
        initialLocationInHost: CGPoint
    ) {
        let token = registerControlTouchForTesting(identifier: touchIdentifier)
        beginDeferredControlInteraction(
            with: control,
            touchToken: token,
            initialLocationInHost: initialLocationInHost
        )
    }

    func finishDeferredControlFromTouchObserver(
        touchIdentifier: ObjectIdentifier,
        terminalLocationInHost: CGPoint,
        cancelled: Bool
    ) {
        guard let observer = runtime.interaction.controlTouchObserver,
              let token = observer.token(for: touchIdentifier) else { return }
        observer.finishTouchForTesting(
            token: token,
            identifier: touchIdentifier,
            locationInHost: terminalLocationInHost,
            cancelled: cancelled
        )
    }

    func cancelDeferredControlIfOwnerBecameDrag(
        touchIdentifier: ObjectIdentifier,
        locationInHost: CGPoint
    ) {
        guard let token = runtime.interaction.controlTouchObserver?.token(for: touchIdentifier) else {
            return
        }
        cancelDeferredControlIfOwnerBecameDrag(
            touchToken: token,
            locationInWindow: locationInHost
        )
    }

    /// Starts the UIControl sequence that UIKit suppresses when this touch first stops participant
    /// inertia. Any older unfinished sequence is cancelled before the new touch becomes owner.
    func beginDeferredControlInteraction(
        with control: UIControl,
        touchToken: DeferredControlTouchToken,
        initialLocationInHost: CGPoint,
        initialLocationInWindow: CGPoint? = nil
    ) {
        if runtime.interaction.deferredControlInteraction?.control == nil {
            runtime.interaction.deferredControlInteraction = nil
        }
        guard let observer = runtime.interaction.controlTouchObserver,
              observer.isLive(touchToken) else { return }
        if let existing = runtime.interaction.deferredControlInteraction {
            // A genuinely simultaneous second finger cannot steal the first control sequence.
            if observer.isLive(existing.touchToken) {
                return
            }
            // Observation of the old physical sequence has already ended. Never let that orphan
            // block a later tap: cancel it exactly once before the new touch becomes owner.
            cancelDeferredControlInteractionIfNeeded(expectedID: existing.id)
        }
        guard runtime.interaction.deferredControlInteraction == nil,
              observer.isLive(touchToken) else { return }

        // Generic motion repair and synthetic control delivery are independent. Keep the repair
        // armed until touch-up: a control that starts scroll(to:) supersedes it by transaction
        // generation, while a control with no panel movement still leaves the interrupted panel
        // responsible for returning to a legal detent.

        let id = runtime.interaction.nextDeferredControlInteractionID
        runtime.interaction.nextDeferredControlInteractionID &+= 1
        runtime.interaction.deferredControlInteraction = DeferredControlInteraction(
            id: id,
            touchToken: touchToken,
            initialLocationInWindow: initialLocationInWindow ?? initialLocationInHost,
            control: control
        )
        control.sendActions(for: .touchDown)
    }

    /// Completes only from the terminal callback of the same physical touch that began the
    /// synthetic sequence. Clearing ownership before target-action delivery makes re-entrant
    /// programmatic scrolling safe.
    func completeDeferredControlInteractionIfNeeded(
        expectedID: UInt64? = nil,
        terminalLocationInHost: CGPoint
    ) {
        guard let interaction = takeDeferredControlInteraction(expectedID: expectedID),
              let control = interaction.control else { return }
        guard let initialWindow = interaction.initialWindow,
              control.window === initialWindow,
              control.superview === interaction.initialSuperview,
              control.isEnabled,
              control.isUserInteractionEnabled,
              !control.isHidden,
              control.alpha > 0.01 else {
            control.sendActions(for: .touchCancel)
            return
        }

        let pointInControl = control.convert(terminalLocationInHost, from: self)
        control.sendActions(
            for: control.point(inside: pointInControl, with: nil) ? .touchUpInside : .touchUpOutside
        )
    }

    /// Cancels the synthetic control sequence as soon as the touch becomes a real drag. A drag must
    /// never be converted back into `.touchUpInside`, even if it finishes inside the control bounds.
    func cancelDeferredControlInteractionIfNeeded(expectedID: UInt64? = nil) {
        guard let interaction = takeDeferredControlInteraction(expectedID: expectedID) else { return }
        interaction.control?.sendActions(for: .touchCancel)
    }

    /// UIControl compatibility owns its own touch-slop decision. UIScrollView delegate callbacks do
    /// not expose which finger began the pan, so they cannot safely cancel a sequence owned by a
    /// different stationary finger.
    func cancelDeferredControlIfOwnerBecameDrag(
        touchToken: DeferredControlTouchToken,
        locationInWindow: CGPoint
    ) {
        guard let interaction = runtime.interaction.deferredControlInteraction,
              interaction.touchToken == touchToken else { return }
        let dx = locationInWindow.x - interaction.initialLocationInWindow.x
        let dy = locationInWindow.y - interaction.initialLocationInWindow.y
        let dragCancellationDistance: CGFloat = 10
        guard hypot(dx, dy) >= dragCancellationDistance else { return }
        cancelDeferredControlInteractionIfNeeded(expectedID: interaction.id)
    }

    /// UIScrollView does not identify the finger that crossed its pan threshold. When exactly one
    /// physical touch is live and it owns the control sequence, the ownership is unambiguous and the
    /// drag must cancel immediately rather than waiting for a hard-coded movement distance.
    func cancelDeferredControlIfOnlyLiveTouchBecameDrag() {
        guard let interaction = runtime.interaction.deferredControlInteraction,
              let observer = runtime.interaction.controlTouchObserver,
              observer.liveTouchCount == 1,
              observer.isLive(interaction.touchToken) else { return }
        cancelDeferredControlInteractionIfNeeded(expectedID: interaction.id)
    }

    /// Detaches all control-touch ownership before UIKit begins removing the host from its window.
    /// The returned callback delivers the sole terminal event only after transition cleanup has
    /// detached its old owners, so target-action re-entry cannot be overwritten by removal state.
    func prepareDeferredControlCancellationForRemoval() -> (() -> Void)? {
        let interaction = takeDeferredControlInteraction(expectedID: nil)
        if let observer = runtime.interaction.controlTouchObserver {
            observer.invalidateObservation()
            observer.isEnabled = false
        }
        guard let control = interaction?.control else { return nil }
        return { [weak control] in
            control?.sendActions(for: .touchCancel)
        }
    }

    func resumeControlTouchObservationAfterWindowAttachment() {
        runtime.interaction.controlTouchObserver?.isEnabled = true
    }

    private func takeDeferredControlInteraction(
        expectedID: UInt64?
    ) -> DeferredControlInteraction? {
        guard let interaction = runtime.interaction.deferredControlInteraction else { return nil }
        if let expectedID, interaction.id != expectedID {
            return nil
        }
        runtime.interaction.deferredControlInteraction = nil
        return interaction
    }

    /// Cancels the narrow touch-completion fallback when a real drag takes responsibility for the
    /// panel, matching OC `scrollViewWillBeginDragging`.
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
        guard runtime.interaction.needsTouchCompletionSettlement,
              gestureRecognizer.state == .ended else { return }
        guard !nativeScrollState.isDecelerating else { return }

        // This is the OC `onTapGes:` settlement boundary. `.began` must not consume the flag: only
        // the terminal `.ended` action repairs interrupted panel motion that did not become
        // a real drag. `scrollViewWillBeginDragging` owns the mutually exclusive drag path.
        settleInterruptedSystemAnimationToNearestDetentIfNeeded()
    }

    /// Terminal path for the passive observer. Only the UITouch that began this synthetic sequence
    /// may finish it; unrelated fingers cannot supply its outcome or endpoint.
    func finishDeferredControlFromTouchObserver(
        touchToken: DeferredControlTouchToken,
        terminalLocationInHost: CGPoint,
        cancelled: Bool
    ) {
        guard let interaction = runtime.interaction.deferredControlInteraction,
              interaction.touchToken == touchToken else { return }
        if cancelled {
            cancelDeferredControlInteractionIfNeeded(expectedID: interaction.id)
        } else {
            completeDeferredControlInteractionIfNeeded(
                expectedID: interaction.id,
                terminalLocationInHost: terminalLocationInHost
            )
        }
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
        // 临时排查用日志（不要提交）。
        if gestureRecognizer.view === self,
           let primary = primaryParticipantScrollView,
           otherGestureRecognizer.view === primary {
            bodragJitterLog(
                "arbitration.requireFailureOfInner",
                "result=\(result) mode=\(configuration.handoff.mode) inner=[\(BODragScrollJitterLog.describe(primary))]"
            )
        }
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
        // 临时排查用日志（不要提交）。result=true 表示内部 pan 必须等外层 pan 先失败，
        // 也就是「内部手势被 fail 掉、全部由 dragScroll 驱动」的预期形态。
        if gestureRecognizer.view === self,
           let primary = primaryParticipantScrollView,
           otherGestureRecognizer.view === primary {
            bodragJitterLog(
                "arbitration.innerMustWaitForPanel",
                "result=\(result) mode=\(configuration.handoff.mode) innerPanState=\(primary.panGestureRecognizer.state.rawValue)"
            )
        }
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
        // 临时排查用日志（不要提交）。simultaneous=true + inner 未被 fail 掉 = 双驱动，会抖。
        if gestureRecognizer.view === self,
           let primary = primaryParticipantScrollView,
           otherGestureRecognizer.view === primary {
            bodragJitterLog("arbitration.simultaneousWithInner", "result=\(result)")
        }
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
        requestMovement(
            toDisplayHeight: targetHeight,
            animated: true,
            options: BODragScrollMovementOptions(),
            reason: .accessibility,
            completion: nil
        )
    }
}

#endif
