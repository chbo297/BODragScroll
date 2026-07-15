//
//  BODragScrollView.swift
//  BODragScroll
//
//  Public surface, panel layout, and shared runtime state.
//

#if canImport(UIKit)
import UIKit

// MARK: - Runtime state groups

@MainActor
final class BODragScrollPanelState {
    var lastLayoutBounds = CGRect.zero
    var hasCompletedLayout = false
    var needsPanelLayout = false
    var pendingInitialDisplayHeight: CGFloat?
    var preservedDisplayHeightForNextLayout: CGFloat?
    var replacementGeneration: UInt64 = 0
}

@MainActor
final class BODragScrollDragState {
    var lastMotionSource: BODragScrollMotionSource = .panel
}

@MainActor
final class BODragScrollScrollingState {
    var mismatchDirection = 0
    var isForcingMismatchRecovery = false
    var lastPublishedParticipantScrolling = false
    var callbackEpoch: UInt64 = 0
}

@MainActor
final class BODragScrollRuntimeState {
    let panel = BODragScrollPanelState()
    let capture = BODragScrollCaptureState()
    let drag = BODragScrollDragState()
    let scrolling = BODragScrollScrollingState()
    let transition = BODragScrollTransitionState()
    let interaction = BODragScrollInteractionState()

    /// Nesting-safe replacement for the OC implementation's single `innerSetting` Boolean.
    var mutationDepth = 0
    var deferredMovementActions: [() -> Void] = []
    var isDrainingDeferredMovementActions = false
    /// Invalidates release/movement calculations when synchronous client callbacks mutate any
    /// public geometry or policy input without necessarily starting a new movement transaction.
    var decisionGeometryRevision: UInt64 = 0
}

struct BODragScrollParticipantDecisionState: Equatable {
    let id: ObjectIdentifier
    let superviewID: ObjectIdentifier?
    let isDescendantOfPanel: Bool
    let frame: CGRect
    let bounds: CGRect
    let contentSize: CGSize
    let contentOffset: CGPoint
    let contentInset: UIEdgeInsets
    let isScrollEnabled: Bool
    let bounces: Bool
    let alwaysBounceVertical: Bool
}

struct BODragScrollDecisionStateToken: Equatable {
    let revision: UInt64
    let captureOperationEpoch: UInt64
    let captureSessionID: UInt64?
    let captureHierarchyIsValid: Bool
    let expectedParticipantCount: Int
    let panelID: ObjectIdentifier?
    let panelFrame: CGRect?
    let bounds: CGRect
    let contentSize: CGSize
    let contentOffset: CGPoint
    let contentInset: UIEdgeInsets
    let participants: [BODragScrollParticipantDecisionState]
}

// MARK: - Main view

/// A draggable panel whose vertical axis can incorporate one primary and multiple ancestor scroll views.
///
/// `BODragScrollView` owns its inherited `UIScrollView.delegate`. Use `behaviorProvider` for synchronous
/// decisions and `eventDelegate` for notifications.
@MainActor
public final class BODragScrollView: UIScrollView {

    // MARK: Public API

    /// The fixed-size content panel. Movement changes how much of this view is visible; it does not resize it.
    public var panelView: UIView? {
        get { panelViewStorage }
        set {
            if isInternallyMutating {
                // Structural replacement is as unsafe as movement while UIKit is observing a
                // partial host geometry. Reuse the ordered post-mutation queue.
                runtime.deferredMovementActions.append { [weak self] in
                    self?.replacePanelView(with: newValue)
                }
            } else {
                replacePanelView(with: newValue)
            }
        }
    }

    /// The panel's displayed height: `bounds.height - (panel.frame.minY - contentOffset.y)`.
    public private(set) var displayHeight: CGFloat = 0

    /// Whether a UIView-driven display-height transition is active. Event delegates can use this
    /// to distinguish animation-driven height publication from direct drag/scroll publication.
    public var isAnimatingDisplayHeight: Bool {
        runtime.transition.isViewAnimating
    }

    /// Sorted panel display heights at which release may settle. Values use the OC API's Float32 input semantics.
    public var detentHeights: [CGFloat] {
        get { detentHeightsStorage }
        set { setDetentHeights(newValue) }
    }

    /// Display-height ranges in which release preserves the system-predicted target instead of snapping.
    public var nonSnappingRanges: [ClosedRange<CGFloat>] {
        get { nonSnappingRangesStorage }
        set {
            nonSnappingRangesStorage = normalizedRanges(newValue)
            advanceDecisionGeometryRevision()
        }
    }

    /// Used only when `detentHeights` is empty. The default effective value is 66 points.
    public var minimumDisplayHeight: CGFloat? {
        get { minimumDisplayHeightStorage }
        set {
            minimumDisplayHeightStorage = newValue.flatMap(normalizedObjectiveCNumber)
            outerGeometryConfigurationDidChange()
        }
    }

    /// Typed behavior configuration. Invalid tuning values are normalized before becoming active.
    public var configuration: BODragScrollConfiguration {
        get { configurationStorage }
        set {
            configurationStorage = Self.normalized(newValue)
            behaviorConfigurationDidChange()
        }
    }

    /// Synchronous layout, capture, gesture, target, and accessibility decisions.
    public weak var behaviorProvider: BODragScrollBehaviorProvider? {
        didSet {
            advanceDecisionGeometryRevision()
            runtime.panel.needsPanelLayout = true
            setNeedsLayout()
            reloadScrollMetrics()
        }
    }

    /// Event-only notifications. The inherited `UIScrollView.delegate` remains private to the engine.
    public weak var eventDelegate: BODragScrollEventDelegate?

    /// Re-evaluate the panel size supplied by `behaviorProvider` without replacing the panel view.
    ///
    /// Use this after an external sizing input changes while this view's own bounds stay the same.
    /// The currently visible height is preserved when possible, and any in-flight movement is
    /// reconciled through the same layout-interruption path used for a viewport-size change.
    public func invalidatePanelLayout() {
        if isInternallyMutating {
            runtime.deferredMovementActions.append { [weak self] in
                self?.invalidatePanelLayout()
            }
            return
        }

        advanceDecisionGeometryRevision()
        runtime.panel.needsPanelLayout = true

        if runtime.panel.hasCompletedLayout,
           runtime.panel.lastLayoutBounds.size == bounds.size,
           let panelView = panelViewStorage {
            let visibleBounds = layer.presentation()?.bounds ?? bounds
            let visiblePanelOrigin = panelView.layer.presentation()?.frame.minY
                ?? panelView.frame.minY
            let preservedDisplayHeight = normalizeFinite(
                visibleBounds.height - (visiblePanelOrigin - visibleBounds.minY),
                fallback: displayHeight
            )
            transitionPanelLayoutDidInvalidate()
            runtime.panel.preservedDisplayHeightForNextLayout = preservedDisplayHeight
            interruptMovementForLayoutChange(finalDisplayHeight: preservedDisplayHeight)
            if nativeScrollState.isDecelerating {
                withInternalMutation {
                    setContentOffset(contentOffset, animated: false)
                }
            }
        }

        setNeedsLayout()
    }

    // MARK: Shared internal storage

    let runtime = BODragScrollRuntimeState()

    private var panelViewStorage: UIView?
    private var detentHeightsStorage: [CGFloat] = []
    private var nonSnappingRangesStorage: [ClosedRange<CGFloat>] = []
    private var minimumDisplayHeightStorage: CGFloat?
    private var configurationStorage = BODragScrollConfiguration()

    /// The panel's own rate. During participant-owned portions the inherited scroll view temporarily mirrors
    /// the primary participant's rate without changing this stored preference.
    var panelDecelerationRate: UIScrollView.DecelerationRate = .fast

    // MARK: Initialization

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        BODragScrollUIScrollViewBridge.installIfNeeded()

        contentInsetAdjustmentBehavior = .never
        panGestureRecognizer.name = "BODragScrollView-Pan"
        super.decelerationRate = .fast
        super.delegate = self
        super.showsHorizontalScrollIndicator = false
        super.showsVerticalScrollIndicator = false
        super.delaysContentTouches = false
        super.canCancelContentTouches = true
        super.scrollsToTop = false
        autoresizesSubviews = false
        automaticallyAdjustsScrollIndicatorInsets = false

        installInteractionSupport()
    }

    // MARK: UIScrollView invariants

    public override var delegate: UIScrollViewDelegate? {
        get { super.delegate }
        set {
            guard let newValue else {
                // Generic view teardown code often clears delegates. This component's delegate is
                // an engine invariant, so an external nil assignment is intentionally ignored.
                // Do not write `self` back here: UIKit also clears its weak delegate while the
                // scroll view is deallocating, when re-registering the dying object would abort.
                return
            }
            guard newValue === self else {
                assertionFailure(
                    "BODragScrollView owns UIScrollView.delegate; use behaviorProvider/eventDelegate instead"
                )
                return
            }
            super.delegate = self
        }
    }

    public override var decelerationRate: UIScrollView.DecelerationRate {
        get { super.decelerationRate }
        set {
            if isInternallyMutating {
                super.decelerationRate = newValue
            } else {
                panelDecelerationRate = newValue
                if primaryParticipantScrollView == nil {
                    super.decelerationRate = newValue
                }
            }
        }
    }

    // UIKit requires overrides to be declared in the class body. Interaction owns their implementation.
    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        interaction_point(inside: point, with: event)
    }

    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        interaction_hitTest(point, with: event)
    }

    public override func touchesShouldBegin(
        _ touches: Set<UITouch>,
        with event: UIEvent?,
        in view: UIView
    ) -> Bool {
        interaction_touchesShouldBegin(touches, with: event, in: view)
        return super.touchesShouldBegin(touches, with: event, in: view)
    }

    public override func touchesShouldCancel(in view: UIView) -> Bool {
        interaction_touchesShouldCancel(in: view)
    }

    public override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        interaction_accessibilityScroll(direction)
    }

    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        interaction_gestureRecognizerShouldBegin(gestureRecognizer)
    }

    public override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            // Set the persistent suspension before UIKit invokes any subclass/view callbacks.
            runtime.capture.isSuspendedForWindowTransition = true
            super.willMove(toWindow: nil)
            endCapture()
            interruptMovementForRemovalFromWindow()
            abortUserDragLifecycleForRemoval()
        } else {
            super.willMove(toWindow: newWindow)
            runtime.capture.isSuspendedForWindowTransition = false
        }
    }

    // MARK: Panel layout

    public override func layoutSubviews() {
        let previousBounds = runtime.panel.lastLayoutBounds
        let sizeChanged = previousBounds.size != bounds.size
        runtime.panel.lastLayoutBounds = bounds

        if sizeChanged,
           runtime.panel.hasCompletedLayout,
           let panelView = panelViewStorage {
            let visibleOuterOffset = layer.presentation()?.bounds.origin.y ?? contentOffset.y
            let visiblePanelOrigin = panelView.layer.presentation()?.frame.minY
                ?? panelView.frame.minY
            let preservedDisplayHeight = normalizeFinite(
                previousBounds.height - (visiblePanelOrigin - visibleOuterOffset),
                fallback: displayHeight
            )
            transitionPanelLayoutDidInvalidate()
            runtime.panel.preservedDisplayHeightForNextLayout = preservedDisplayHeight
            interruptMovementForLayoutChange(finalDisplayHeight: preservedDisplayHeight)
            if nativeScrollState.isDecelerating {
                withInternalMutation {
                    setContentOffset(contentOffset, animated: false)
                }
            }
        }

        if sizeChanged || !runtime.panel.hasCompletedLayout || runtime.panel.needsPanelLayout {
            layoutPanel(previousBounds: previousBounds)
        }

        super.layoutSubviews()
    }

    private func layoutPanel(previousBounds: CGRect) {
        runtime.panel.needsPanelLayout = false
        transitionPanelLayoutDidInvalidate()
        guard let panelView = panelViewStorage else {
            runtime.panel.hasCompletedLayout = false
            withInternalMutation {
                setContentInsetIfNeeded(.zero)
                setContentSizeIfNeeded(.zero)
                setContentOffsetIfNeeded(.zero)
            }
            setDisplayHeight(0, source: .panel)
            return
        }
        let layoutPanelGeneration = runtime.panel.replacementGeneration

        let firstLayout = !runtime.panel.hasCompletedLayout
        let pendingMovementIDBeforeProvider = runtime.transition.pendingLayoutMovement?
            .transaction.id

        var proposedDisplayHeight: CGFloat
        if let pending = runtime.panel.pendingInitialDisplayHeight {
            proposedDisplayHeight = pending
            runtime.panel.pendingInitialDisplayHeight = nil
        } else if let preserved = runtime.panel.preservedDisplayHeightForNextLayout {
            proposedDisplayHeight = preserved
        } else if firstLayout {
            proposedDisplayHeight = effectiveMinimumDisplayHeight
        } else {
            proposedDisplayHeight = previousBounds.height - (panelView.frame.minY - contentOffset.y)
        }

        var panelSize = panelView.frame.size
        let layoutProvider = behaviorProvider
        let providerWasCalled = layoutProvider != nil
        if let providedSize = layoutProvider?.dragScrollView(
            self,
            sizeFor: panelView,
            firstLayout: firstLayout,
            proposedDisplayHeight: &proposedDisplayHeight
        ) {
            panelSize = providedSize
        }

        // The provider may mutate detents/minimum height even when it returns nil for size.
        if providerWasCalled {
            proposedDisplayHeight = normalizeFinite(proposedDisplayHeight, fallback: effectiveMinimumDisplayHeight)
        }

        let viewportWidth = bounds.width
        let viewportHeight = bounds.height
        if panelSize.width <= 0 || panelSize.height <= 0 {
            panelSize = panelView.sizeThatFits(
                CGSize(width: viewportWidth, height: .greatestFiniteMagnitude)
            )
        }
        if panelSize.width <= 0 || !panelSize.width.isFinite {
            panelSize.width = viewportWidth
        }
        if panelSize.height <= 0 || !panelSize.height.isFinite {
            panelSize.height = viewportHeight
        }

        guard panelViewStorage === panelView,
              runtime.panel.replacementGeneration == layoutPanelGeneration,
              behaviorProvider === layoutProvider,
              runtime.transition.pendingLayoutMovement?.transaction.id
                == pendingMovementIDBeforeProvider else {
            // A synchronous sizing callback replaced the panel or started a newer pre-layout
            // movement. Restart with that new intention instead of applying stale geometry.
            runtime.panel.needsPanelLayout = true
            setNeedsLayout()
            return
        }

        let insets = calculatedOuterInsets(panelHeight: panelSize.height)
        if let pending = runtime.transition.pendingLayoutMovement,
           pending.isAppliedByInitialLayout,
           pending.transaction.id == pendingMovementIDBeforeProvider,
           runtime.transition.activeTransaction === pending.transaction {
            // A non-animated request accepted before first layout must resolve through the same
            // panel-axis limits as an already-laid-out request. Otherwise it could bypass disabled
            // top/bottom bounce merely because geometry was not ready at call time.
            let minimumOffset = -insets.top
            let maximumOffset = max(
                panelSize.height + insets.bottom - viewportHeight,
                minimumOffset
            )
            var requestedOffset = proposedDisplayHeight - viewportHeight
            if !requestedOffset.isFinite {
                requestedOffset = minimumOffset
            } else if requestedOffset < minimumOffset,
                      !configuration.bounce.allowsPanelTopBounce {
                requestedOffset = minimumOffset
            } else if requestedOffset > maximumOffset,
                      !configuration.bounce.allowsPanelBottomBounce {
                requestedOffset = maximumOffset
            }
            proposedDisplayHeight = normalizeFinite(
                viewportHeight + requestedOffset,
                fallback: effectiveMinimumDisplayHeight
            )
        }

        guard preparePendingInitialLayoutMovement(
            resolvedDisplayHeight: proposedDisplayHeight
        ) else {
            // `willMove` is synchronous and may start a newer pre-layout intention. Defer geometry
            // to a fresh pass so the superseded height is never applied after that callback.
            runtime.panel.hasCompletedLayout = !firstLayout
            runtime.panel.needsPanelLayout = true
            setNeedsLayout()
            return
        }

        runtime.panel.hasCompletedLayout = true

        let panelFrame = CGRect(
            x: (viewportWidth - panelSize.width) * 0.5,
            y: 0,
            width: panelSize.width,
            height: panelSize.height
        )
        let requestedOffset = CGPoint(x: contentOffset.x, y: proposedDisplayHeight - viewportHeight)

        withInternalMutation {
            setContentInsetIfNeeded(insets)
            setContentSizeIfNeeded(CGSize(width: viewportWidth, height: panelSize.height))
            setPanelFrame(panelFrame)
            setContentOffsetIfNeeded(requestedOffset)
        }
        guard panelViewStorage === panelView,
              runtime.panel.replacementGeneration == layoutPanelGeneration else {
            // Callback-bearing UIKit setters above drain deferred structural changes before this
            // method resumes. A replacement panel owns any movement created by those callbacks;
            // leave that pending intention attached for the replacement's fresh layout pass.
            runtime.panel.needsPanelLayout = true
            setNeedsLayout()
            return
        }
        runtime.panel.preservedDisplayHeightForNextLayout = nil
        advanceDecisionGeometryRevision()

        // Mark base panel geometry ready before capture rebuild publishes display changes. A
        // callback from rebuild can then execute directly instead of creating a stranded pending
        // request.
        let preparedMovement = takePendingMovementForCompletedLayout(
            expectedTransactionID: pendingMovementIDBeforeProvider
        )
        rebuildCaptureSessionIfNeeded(reason: .layout)
        guard panelViewStorage === panelView,
              runtime.panel.replacementGeneration == layoutPanelGeneration else {
            runtime.panel.needsPanelLayout = true
            setNeedsLayout()
            return
        }
        setDisplayHeight(displayHeightForCurrentGeometry, source: .panel)
        guard panelViewStorage === panelView,
              runtime.panel.replacementGeneration == layoutPanelGeneration else {
            // didChangeDisplayHeight is client code. A replacement triggered there owns the
            // pending size-change interruption and must finish it after its own coherent layout.
            runtime.panel.needsPanelLayout = true
            setNeedsLayout()
            return
        }
        completePendingLayoutInterruptionIfNeeded()
        performPreparedMovementAfterLayoutIfNeeded(preparedMovement)
    }

    // MARK: Shared geometry/state façade

    var runtimeDetentHeights: [CGFloat] { detentHeightsStorage }

    var effectiveMinimumDisplayHeight: CGFloat {
        detentHeightsStorage.first ?? minimumDisplayHeightStorage ?? 66
    }

    var maximumConfiguredDisplayHeight: CGFloat {
        if let last = detentHeightsStorage.last {
            return max(effectiveMinimumDisplayHeight, last)
        }
        return max(effectiveMinimumDisplayHeight, panelViewStorage?.bounds.height ?? 0)
    }

    var displayScale: CGFloat {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        return scale.isFinite && scale > 0 ? scale : 1
    }

    var comparisonPolicy: ScrollComparisonPolicy {
        ScrollComparisonPolicy(displayScale: displayScale)
    }

    var displayHeightForCurrentGeometry: CGFloat {
        guard let panelView = panelViewStorage else { return 0 }
        return normalizeFinite(
            bounds.height - (panelView.frame.minY - contentOffset.y),
            fallback: displayHeight
        )
    }

    var minimumOuterOffset: CGFloat {
        normalizeFinite(
            -contentInset.top,
            fallback: normalizeFinite(displayHeight - bounds.height, fallback: 0)
        )
    }

    var maximumOuterOffset: CGFloat {
        let minimum = minimumOuterOffset
        return max(
            normalizeFinite(
                contentSize.height + contentInset.bottom - bounds.height,
                fallback: minimum
            ),
            minimum
        )
    }

    var isInternallyMutating: Bool { runtime.mutationDepth > 0 }

    var nativeScrollState: BODragScrollNativeScrollState {
        BODragScrollUIScrollViewBridge.nativeState(of: self)
    }

    func withInternalMutation(_ body: () -> Void) {
        runtime.mutationDepth += 1
        body()
        runtime.mutationDepth -= 1
        guard runtime.mutationDepth == 0,
              !runtime.isDrainingDeferredMovementActions else { return }

        // UIKit property setters are callback-bearing. A public movement requested while host
        // geometry is only partially updated must start after the atomic mutation, never inside it.
        runtime.isDrainingDeferredMovementActions = true
        defer { runtime.isDrainingDeferredMovementActions = false }
        while !runtime.deferredMovementActions.isEmpty {
            let action = runtime.deferredMovementActions.removeFirst()
            action()
        }
    }

    func advanceDecisionGeometryRevision() {
        runtime.decisionGeometryRevision &+= 1
    }

    func decisionStateToken() -> BODragScrollDecisionStateToken {
        let session = runtime.capture.session
        let participantStates = session?.participantChain.compactMap { participant in
            participant.scrollView.map { scrollView in
                BODragScrollParticipantDecisionState(
                    id: ObjectIdentifier(scrollView),
                    superviewID: scrollView.superview.map(ObjectIdentifier.init),
                    isDescendantOfPanel: panelViewStorage.map {
                        scrollView === $0 || scrollView.isDescendant(of: $0)
                    } ?? false,
                    frame: scrollView.frame,
                    bounds: scrollView.bounds,
                    contentSize: scrollView.contentSize,
                    contentOffset: scrollView.contentOffset,
                    contentInset: scrollView.effectiveContentInset,
                    isScrollEnabled: scrollView.isScrollEnabled,
                    bounces: scrollView.bounces,
                    alwaysBounceVertical: scrollView.alwaysBounceVertical
                )
            }
        } ?? []
        return BODragScrollDecisionStateToken(
            revision: runtime.decisionGeometryRevision,
            captureOperationEpoch: runtime.capture.operationEpoch,
            captureSessionID: session?.id,
            captureHierarchyIsValid: session?.hierarchy.isValid() ?? true,
            expectedParticipantCount: session?.participantChain.count ?? 0,
            panelID: panelViewStorage.map(ObjectIdentifier.init),
            panelFrame: panelViewStorage?.frame,
            bounds: bounds,
            contentSize: contentSize,
            contentOffset: contentOffset,
            contentInset: contentInset,
            participants: participantStates
        )
    }

    func setPanelFrame(_ frame: CGRect) {
        guard let panelView = panelViewStorage, panelView.frame != frame else { return }
        if panelView.bounds.size != frame.size {
            panelView.frame = frame
            return
        }

        let center = CGPoint(
            x: frame.minX + frame.width * panelView.layer.anchorPoint.x,
            y: frame.minY + frame.height * panelView.layer.anchorPoint.y
        )
        if panelView.center != center {
            panelView.center = center
        }
    }

    func setDisplayHeight(_ value: CGFloat, source: BODragScrollMotionSource) {
        let finiteValue = normalizeFinite(value, fallback: displayHeight)
        runtime.drag.lastMotionSource = source
        guard !comparisonPolicy.isJitterEqual(displayHeight, finiteValue) else { return }

        displayHeight = finiteValue
        transitionDidChangeDisplayHeightDuringDrag()
        eventDelegate?.dragScrollView(self, didChangeDisplayHeight: finiteValue)
    }

    func publishScrollUpdate(displayHeight: CGFloat, source: BODragScrollMotionSource) {
        runtime.drag.lastMotionSource = source
        let publishedDisplayHeight = normalizeFinite(displayHeight, fallback: self.displayHeight)
        eventDelegate?.dragScrollView(
            self,
            didScroll: BODragScrollUpdate(displayHeight: publishedDisplayHeight, source: source)
        )
    }

    func updateOuterInsetsPreservingOffset() {
        guard runtime.panel.hasCompletedLayout, let panelView = panelViewStorage else { return }
        let previousOffset = contentOffset
        withInternalMutation {
            setContentInsetIfNeeded(calculatedOuterInsets(panelHeight: panelView.bounds.height))
            setContentOffsetIfNeeded(previousOffset)
        }
    }

    func calculatedOuterInsets(panelHeight: CGFloat) -> UIEdgeInsets {
        let maximumDisplayHeight = detentHeightsStorage.last.map {
            max(effectiveMinimumDisplayHeight, $0)
        } ?? max(effectiveMinimumDisplayHeight, panelHeight)
        return UIEdgeInsets(
            top: bounds.height - effectiveMinimumDisplayHeight,
            left: 0,
            bottom: maximumDisplayHeight - panelHeight,
            right: 0
        )
    }

    // MARK: Public-value normalization and invalidation

    private func replacePanelView(with newValue: UIView?) {
        guard newValue !== panelViewStorage else { return }
        guard newValue !== self else {
            assertionFailure("panelView cannot be the BODragScrollView itself")
            return
        }

        suspendCaptureAcquisition()
        defer { resumeCaptureAcquisition() }

        runtime.panel.replacementGeneration &+= 1
        let replacementGeneration = runtime.panel.replacementGeneration
        runtime.panel.preservedDisplayHeightForNextLayout = nil
        advanceDecisionGeometryRevision()
        // Invalidate the old panel before interruption callbacks run. A movement started by an old
        // completion is thereby queued for the incoming panel instead of executing on stale geometry.
        runtime.panel.hasCompletedLayout = false
        transitionPanelLayoutDidInvalidate()
        interruptActiveMovement(outcome: .interrupted)
        guard runtime.panel.replacementGeneration == replacementGeneration else { return }
        endCapture()
        guard runtime.panel.replacementGeneration == replacementGeneration else { return }
        if nativeScrollState.isDecelerating {
            setContentOffset(contentOffset, animated: false)
            guard runtime.panel.replacementGeneration == replacementGeneration else { return }
        }

        panelViewStorage?.removeFromSuperview()
        guard runtime.panel.replacementGeneration == replacementGeneration else { return }
        panelViewStorage = newValue
        if let newValue {
            addSubview(newValue)
            guard runtime.panel.replacementGeneration == replacementGeneration else { return }
        }

        runtime.panel.hasCompletedLayout = false
        runtime.panel.needsPanelLayout = false
        runtime.panel.lastLayoutBounds = .zero
        transitionPanelLayoutDidInvalidate()
        if newValue == nil {
            setDisplayHeight(0, source: .panel)
            completePendingLayoutInterruptionIfNeeded()
            guard runtime.panel.replacementGeneration == replacementGeneration else { return }
        }
        setNeedsLayout()
    }

    private func setDetentHeights(_ values: [CGFloat]) {
        let sorted = values.compactMap(normalizedObjectiveCNumber).sorted()
        detentHeightsStorage = sorted.reduce(into: []) { result, value in
            if result.last != value {
                result.append(value)
            }
        }
        outerGeometryConfigurationDidChange()
    }

    private func outerGeometryConfigurationDidChange() {
        advanceDecisionGeometryRevision()
        updateOuterInsetsPreservingOffset()
        reloadScrollMetrics()
        setNeedsLayout()
    }

    private func behaviorConfigurationDidChange() {
        advanceDecisionGeometryRevision()
        reloadScrollMetrics()
        setNeedsLayout()
    }

    private func normalizedRanges(_ ranges: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        ranges.compactMap { range in
            guard range.lowerBound.isFinite, range.upperBound.isFinite else { return nil }
            return min(range.lowerBound, range.upperBound)...max(range.lowerBound, range.upperBound)
        }
    }

    private func normalizedObjectiveCNumber(_ value: CGFloat) -> CGFloat? {
        let normalized = CGFloat(Float(value))
        return normalized.isFinite ? normalized : nil
    }

    private func normalizeFinite(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        value.isFinite ? value : fallback
    }

    private static func normalized(_ input: BODragScrollConfiguration) -> BODragScrollConfiguration {
        var result = input

        let ratio = result.handoff.minimumInnerVisibilityRatio
        result.handoff.minimumInnerVisibilityRatio = ratio.isFinite ? min(1, max(0, ratio)) : 0.7

        var movement = result.movement
        movement.lowVelocityThreshold = finiteNonnegative(movement.lowVelocityThreshold, fallback: 0.2)
        movement.highVelocityThreshold = finiteNonnegative(movement.highVelocityThreshold, fallback: 2.2)
        movement.nearBoundaryDistance = finiteNonnegative(movement.nearBoundaryDistance, fallback: 86)
        movement.outerToInnerSnapDistance = finiteNonnegative(
            movement.outerToInnerSnapDistance,
            fallback: 140
        )
        movement.speed = min(100_000, max(100, finiteNonnegative(movement.speed, fallback: 1_000)))
        movement.baseDuration = finiteNonnegative(movement.baseDuration, fallback: 0.12)
        movement.maximumDuration = max(
            movement.baseDuration,
            finiteNonnegative(movement.maximumDuration, fallback: 0.32)
        )
        result.movement = movement
        return result
    }

    private static func finiteNonnegative<T: BinaryFloatingPoint>(_ value: T, fallback: T) -> T {
        value.isFinite ? max(0, value) : fallback
    }
}

#endif
