//
//  BODragScrollTransition.swift
//  BODragScroll
//
//  Programmatic movement, release targeting, animation, and scroll lifecycle settlement.
//  `scrollViewDidScroll` intentionally belongs to BODragScrollScrolling.swift.
//

#if canImport(UIKit)
import UIKit

// MARK: - Transition runtime

@MainActor
final class BODragScrollMovementTransaction {
    let id: UInt64
    private(set) var requestedDisplayHeight: CGFloat
    let reason: BODragScrollMovementReason

    private let completion: ((BODragScrollMovementResult) -> Void)?
    private(set) var resolvedDisplayHeight: CGFloat?
    private(set) var outcome: BODragScrollMovementOutcome?
    private(set) var isFinished = false

    init(
        id: UInt64,
        requestedDisplayHeight: CGFloat,
        reason: BODragScrollMovementReason,
        completion: ((BODragScrollMovementResult) -> Void)?
    ) {
        self.id = id
        self.requestedDisplayHeight = requestedDisplayHeight
        self.reason = reason
        self.completion = completion
    }

    func announceResolvedTarget(_ displayHeight: CGFloat, on dragScrollView: BODragScrollView) {
        guard resolvedDisplayHeight == nil, !isFinished else { return }
        resolvedDisplayHeight = displayHeight
        dragScrollView.eventDelegate?.dragScrollView(
            dragScrollView,
            willMoveToDisplayHeight: displayHeight,
            reason: reason
        )
    }

    func retargetRequest(to displayHeight: CGFloat) {
        guard resolvedDisplayHeight == nil, !isFinished else { return }
        requestedDisplayHeight = displayHeight
    }

    func finish(
        outcome: BODragScrollMovementOutcome,
        finalDisplayHeight: CGFloat,
        on dragScrollView: BODragScrollView
    ) {
        guard !isFinished else { return }
        isFinished = true
        self.outcome = outcome

        let result = BODragScrollMovementResult(
            requestedDisplayHeight: requestedDisplayHeight,
            finalDisplayHeight: finalDisplayHeight,
            reason: reason,
            outcome: outcome
        )
        dragScrollView.eventDelegate?.dragScrollView(dragScrollView, didFinishMovement: result)
        completion?(result)
        dragScrollView.scheduleMovementIdlePublicationIfNeeded()
    }
}

@MainActor
struct BODragScrollPendingLayoutMovement {
    let transaction: BODragScrollMovementTransaction
    let animated: Bool
    let options: BODragScrollMovementOptions
    let isAppliedByInitialLayout: Bool
}

/// Identifies the exact capture-session generation whose lease/lifetime belongs to a movement lifecycle.
/// A non-nil ownership whose `sessionID` is nil means the lifecycle began without a capture;
/// it must not tear down a capture created re-entrantly by a later callback.
@MainActor
struct BODragScrollCaptureCleanupOwnership: Equatable {
    let sessionID: UInt64?
    let sessionOwnershipGeneration: UInt64?
}

@MainActor
struct BODragScrollPendingLayoutInterruption {
    let transaction: BODragScrollMovementTransaction?
    let captureCleanupOwnership: BODragScrollCaptureCleanupOwnership?
    let shouldFinishCancelledDecelerationLifecycle: Bool
    let forwardedParticipant: UIScrollView?
}

@MainActor
final class BODragScrollTransitionState {
    enum Driver: Equatable {
        case dragWithoutDeceleration
        case dragDeceleration
        case systemAnimation
        case viewAnimation
        case scrollToTop
    }

    var nextTransactionID: UInt64 = 1
    var activeTransaction: BODragScrollMovementTransaction?
    var pendingLayoutMovement: BODragScrollPendingLayoutMovement?
    var pendingLayoutInterruptions: [BODragScrollPendingLayoutInterruption] = []
    var isCompletingLayoutInterruptions = false
    var movementsDeferredUntilLayoutInterruptionEnds: [() -> Void] = []
    var isDrainingLayoutDeferredMovements = false
    var driver: Driver?

    var isPanelLayoutReady = false
    var isViewAnimating = false
    var captureCleanupOwnership: BODragScrollCaptureCleanupOwnership?
    var systemAnimationTransactionID: UInt64?
    var systemAnimationTargetOffsetY: CGFloat?
    var systemAnimationSettlementMonitorTransactionID: UInt64?
    var systemAnimationStartOffsetY: CGFloat?
    var systemAnimationHasObservedProgress = false
    var scrollToTopTargetOffsetY: CGFloat?
    var scrollToTopSettlementMonitorTransactionID: UInt64?
    var scrollToTopStartOffsetY: CGFloat?
    var scrollToTopHasObservedProgress = false

    var forwardedDragLifecycleToParticipant = false
    weak var forwardedParticipant: UIScrollView?
    var forwardedDragBeginToEventDelegate = false
    var lastSystemAnimationEndTimestamp: TimeInterval = 0
    var isUserDragLifecycleActive = false
    var isEmittingTerminalDragLifecycleCallback = false
    var movementsDeferredUntilDragEnds: [() -> Void] = []
    var isDrainingDragDeferredMovements = false
    var isAwaitingDidEndDecelerating = false

    /// A movement or drag began after the most recently published idle event.
    var hasUnpublishedMovementActivity = false

    /// Coalesces all UIKit and transaction terminal callbacks onto one next-turn idle check.
    var isIdlePublicationScheduled = false
}

// MARK: - Unified movement activity

@MainActor
extension BODragScrollView {
    /// One authoritative activity predicate shared by the public API and final idle publication.
    var hasActiveMovementOwner: Bool {
        let transition = runtime.transition
        let nativeState = nativeScrollState
        // `isTracking` alone is only a touch-down. The OC touch-completion candidate is deliberately
        // not a movement owner: it remains true after `.ended` until the next should-begin/drag.
        return transition.activeTransaction != nil
            || transition.pendingLayoutMovement != nil
            || !transition.pendingLayoutInterruptions.isEmpty
            || transition.isCompletingLayoutInterruptions
            || transition.driver != nil
            || transition.isUserDragLifecycleActive
            || transition.isAwaitingDidEndDecelerating
            || transition.isEmittingTerminalDragLifecycleCallback
            || transition.isDrainingDragDeferredMovements
            || transition.isDrainingLayoutDeferredMovements
            || runtime.isDrainingDeferredMovementActions
            || isInternallyMutating
            || !transition.movementsDeferredUntilDragEnds.isEmpty
            || !transition.movementsDeferredUntilLayoutInterruptionEnds.isEmpty
            || !runtime.deferredMovementActions.isEmpty
            || nativeState.isDragging
            || nativeState.isDecelerating
    }

    /// Marks that the next true transition to idle must be published even when the height is unchanged.
    func markMovementActivityBegan() {
        runtime.transition.hasUnpublishedMovementActivity = true
    }

    /// Coalesces transaction and UIKit terminal callbacks, then publishes only after all owners stop.
    func scheduleMovementIdlePublicationIfNeeded() {
        let transition = runtime.transition
        guard transition.hasUnpublishedMovementActivity,
              !transition.isIdlePublicationScheduled else { return }
        transition.isIdlePublicationScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.runtime.transition.isIdlePublicationScheduled = false
            self.publishMovementIdleIfPossible()
        }
    }

    private func publishMovementIdleIfPossible() {
        let transition = runtime.transition
        guard transition.hasUnpublishedMovementActivity,
              !hasActiveMovementOwner else { return }

        // Clear before entering client code so a re-entrant movement owns a fresh idle event.
        transition.hasUnpublishedMovementActivity = false
        eventDelegate?.dragScrollView(
            self,
            didBecomeIdleAtDisplayHeight: displayHeight
        )
    }
}

// MARK: - Programmatic movement

@MainActor
extension BODragScrollView {
    /// Scroll the panel to a display height. Every accepted request owns one completion-once transaction.
    /// The return value is the synchronously resolved height when execution starts immediately. If
    /// UIKit is inside an atomic layout/drag mutation, it is the accepted requested height; use the
    /// completion result for the eventual resolved/final height.
    @discardableResult
    public func scroll(
        toDisplayHeight requestedDisplayHeight: CGFloat,
        animated: Bool,
        options: BODragScrollMovementOptions = .init(),
        completion: ((BODragScrollMovementResult) -> Void)? = nil
    ) -> CGFloat {
        return requestMovement(
            toDisplayHeight: requestedDisplayHeight,
            animated: animated,
            options: options,
            reason: .programmatic,
            completion: completion
        )
    }

    /// Internal entry used by accessibility and other typed movement sources.
    @discardableResult
    func requestMovement(
        toDisplayHeight requestedDisplayHeight: CGFloat,
        animated: Bool,
        options: BODragScrollMovementOptions = .init(),
        reason: BODragScrollMovementReason,
        completion: ((BODragScrollMovementResult) -> Void)? = nil
    ) -> CGFloat {
        if !runtime.transition.pendingLayoutInterruptions.isEmpty
            || runtime.transition.isCompletingLayoutInterruptions {
            runtime.transition.movementsDeferredUntilLayoutInterruptionEnds.append { [weak self] in
                _ = self?.requestMovement(
                    toDisplayHeight: requestedDisplayHeight,
                    animated: animated,
                    options: options,
                    reason: reason,
                    completion: completion
                )
            }
            return requestedDisplayHeight.isFinite ? requestedDisplayHeight : displayHeight
        }
        if runtime.transition.isUserDragLifecycleActive {
            runtime.transition.movementsDeferredUntilDragEnds.append { [weak self] in
                _ = self?.requestMovement(
                    toDisplayHeight: requestedDisplayHeight,
                    animated: animated,
                    options: options,
                    reason: reason,
                    completion: completion
                )
            }
            return requestedDisplayHeight.isFinite ? requestedDisplayHeight : displayHeight
        }
        if isInternallyMutating {
            runtime.deferredMovementActions.append { [weak self] in
                _ = self?.requestMovement(
                    toDisplayHeight: requestedDisplayHeight,
                    animated: animated,
                    options: options,
                    reason: reason,
                    completion: completion
                )
            }
            return requestedDisplayHeight.isFinite ? requestedDisplayHeight : displayHeight
        }
        let transaction = beginMovementTransaction(
            requestedDisplayHeight: requestedDisplayHeight,
            reason: reason,
            completion: completion
        )
        // An interrupted transaction's callback may synchronously start a newer movement. The newer
        // intention owns the view; this older call must not continue after re-entrant replacement.
        guard runtime.transition.activeTransaction === transaction else {
            return displayHeight
        }

        guard requestedDisplayHeight.isFinite else {
            transaction.announceResolvedTarget(displayHeight, on: self)
            finishActiveMovement(
                transactionID: transaction.id,
                outcome: .cancelled,
                finalDisplayHeight: displayHeight
            )
            return displayHeight
        }

        guard panelView != nil else {
            transaction.announceResolvedTarget(0, on: self)
            finishActiveMovement(transactionID: transaction.id, outcome: .cancelled, finalDisplayHeight: 0)
            return 0
        }

        guard runtime.panel.hasCompletedLayout,
              runtime.transition.isPanelLayoutReady else {
            if !animated {
                // Let first layout start at the requested value instead of publishing the minimum
                // height and immediately jumping to the pending non-animated destination.
                runtime.panel.pendingInitialDisplayHeight = requestedDisplayHeight
            }
            runtime.transition.pendingLayoutMovement = BODragScrollPendingLayoutMovement(
                transaction: transaction,
                animated: animated,
                options: options,
                isAppliedByInitialLayout: !animated
            )
            return requestedDisplayHeight
        }

        return executeMovement(transaction: transaction, animated: animated, options: options)
    }

    /// Accessibility's no-detent up/down action is semantic (panel minimum/maximum), not a fixed
    /// height captured before callbacks. Take movement/capture ownership first, then resolve the
    /// boundary from the final panel-only geometry so synchronous lifecycle callbacks cannot stale it.
    @discardableResult
    func moveToAccessibilityPanelBoundary(maximum: Bool) -> Bool {
        if !runtime.transition.pendingLayoutInterruptions.isEmpty
            || runtime.transition.isCompletingLayoutInterruptions {
            runtime.transition.movementsDeferredUntilLayoutInterruptionEnds.append { [weak self] in
                _ = self?.moveToAccessibilityPanelBoundary(maximum: maximum)
            }
            return true
        }
        if runtime.transition.isUserDragLifecycleActive {
            runtime.transition.movementsDeferredUntilDragEnds.append { [weak self] in
                _ = self?.moveToAccessibilityPanelBoundary(maximum: maximum)
            }
            return true
        }
        if isInternallyMutating {
            runtime.deferredMovementActions.append { [weak self] in
                _ = self?.moveToAccessibilityPanelBoundary(maximum: maximum)
            }
            return true
        }

        let transaction = beginMovementTransaction(
            requestedDisplayHeight: displayHeight,
            reason: .accessibility,
            completion: nil
        )
        guard runtime.transition.activeTransaction === transaction else { return true }
        guard panelView != nil else {
            transaction.announceResolvedTarget(0, on: self)
            finishActiveMovement(
                transactionID: transaction.id,
                outcome: .cancelled,
                finalDisplayHeight: 0
            )
            return false
        }
        guard runtime.panel.hasCompletedLayout,
              runtime.transition.isPanelLayoutReady else {
            transaction.announceResolvedTarget(displayHeight, on: self)
            finishActiveMovement(
                transactionID: transaction.id,
                outcome: .cancelled,
                finalDisplayHeight: displayHeightForCurrentGeometry
            )
            return false
        }

        suspendCaptureAcquisition()
        defer { resumeCaptureAcquisition() }
        endCapture()
        guard runtime.transition.activeTransaction === transaction else { return true }
        reloadScrollMetrics()
        guard runtime.transition.activeTransaction === transaction else { return true }

        let targetDisplayHeight = maximum
            ? maximumConfiguredDisplayHeight
            : effectiveMinimumDisplayHeight
        guard targetDisplayHeight.isFinite else {
            transaction.announceResolvedTarget(displayHeight, on: self)
            finishActiveMovement(
                transactionID: transaction.id,
                outcome: .cancelled,
                finalDisplayHeight: displayHeightForCurrentGeometry
            )
            return false
        }
        transaction.retargetRequest(to: targetDisplayHeight)
        let targetOffset = CGPoint(
            x: contentOffset.x,
            y: targetDisplayHeight - bounds.height
        )
        let alreadyAtBoundary = CGPointEqualToPoint(contentOffset, targetOffset)
        _ = executeMovement(
            transaction: transaction,
            animated: true,
            options: BODragScrollMovementOptions()
        )
        return !alreadyAtBoundary
    }

    /// Resolve the current composite-axis position to its nearest legal detent.
    @discardableResult
    public func settleToNearestDetent(
        animated: Bool = true,
        options: BODragScrollMovementOptions = .init(),
        completion: ((BODragScrollMovementResult) -> Void)? = nil
    ) -> CGFloat {
        // Like OC `takeAttach`, an empty detent list has no legal attach target and is a no-op.
        guard !runtimeDetentHeights.isEmpty else { return displayHeight }
        if !runtime.transition.pendingLayoutInterruptions.isEmpty
            || runtime.transition.isCompletingLayoutInterruptions {
            runtime.transition.movementsDeferredUntilLayoutInterruptionEnds.append { [weak self] in
                _ = self?.settleToNearestDetent(
                    animated: animated,
                    options: options,
                    completion: completion
                )
            }
            return displayHeight
        }
        if runtime.transition.isUserDragLifecycleActive {
            runtime.transition.movementsDeferredUntilDragEnds.append { [weak self] in
                _ = self?.settleToNearestDetent(
                    animated: animated,
                    options: options,
                    completion: completion
                )
            }
            return displayHeight
        }
        if isInternallyMutating {
            runtime.deferredMovementActions.append { [weak self] in
                _ = self?.settleToNearestDetent(
                    animated: animated,
                    options: options,
                    completion: completion
                )
            }
            return displayHeight
        }
        let transaction = beginMovementTransaction(
            requestedDisplayHeight: displayHeight,
            reason: .nearestDetent,
            completion: completion
        )
        guard runtime.transition.activeTransaction === transaction else {
            return displayHeight
        }

        reloadScrollMetrics()
        // Rebuilding geometry may synchronously emit a callback which starts a newer movement.
        guard runtime.transition.activeTransaction === transaction else {
            return displayHeight
        }

        let targetDisplayHeight: CGFloat
        if let model = releaseTargetModel(), !model.segments.isEmpty,
           runtime.panel.hasCompletedLayout,
           runtime.transition.isPanelLayoutReady {
            let decisionState = decisionStateToken()
            targetDisplayHeight = solveTarget(
                model: model,
                proposedOuterOffset: contentOffset.y,
                velocity: 0,
                forceSnapping: true
            ).targetDisplayHeight
            guard runtime.transition.activeTransaction === transaction,
                  decisionStateToken() == decisionState else {
                if runtime.transition.activeTransaction === transaction {
                    finishActiveMovement(
                        transactionID: transaction.id,
                        outcome: .cancelled,
                        finalDisplayHeight: displayHeightForCurrentGeometry
                    )
                }
                return displayHeight
            }
        } else {
            let referenceHeight = runtime.panel.pendingInitialDisplayHeight ?? displayHeight
            let index = ScrollMath.sortedIndex(
                in: runtimeDetentHeights.map(ScrollSourceScalar.native),
                value: referenceHeight,
                nearby: true,
                ceil: false
            )
            targetDisplayHeight = runtimeDetentHeights[index]
        }
        transaction.retargetRequest(to: targetDisplayHeight)

        guard runtime.panel.hasCompletedLayout,
              runtime.transition.isPanelLayoutReady else {
            if !animated {
                runtime.panel.pendingInitialDisplayHeight = targetDisplayHeight
            }
            runtime.transition.pendingLayoutMovement = BODragScrollPendingLayoutMovement(
                transaction: transaction,
                animated: animated,
                options: options,
                isAppliedByInitialLayout: !animated
            )
            return targetDisplayHeight
        }

        return executeMovement(transaction: transaction, animated: animated, options: options)
    }

    /// OC `onTapGes:` calls `takeAttach:` only when the zero-velocity target differs from the
    /// current outer offset by at least its value-equality tolerance. Its target solver also keeps
    /// `shouldMisAttach` / non-snapping ranges authoritative. Keep both decisions outside movement
    /// transactions, then issue the already-resolved height just like OC `scrollToDisplayH:`.
    func settleInterruptedSystemAnimationToNearestDetentIfNeeded() {
        guard !runtimeDetentHeights.isEmpty,
              runtime.panel.hasCompletedLayout,
              runtime.transition.isPanelLayoutReady,
              let model = releaseTargetModel(),
              !model.segments.isEmpty else { return }

        let transactionEpoch = runtime.transition.nextTransactionID
        let activeTransactionAtEntry = runtime.transition.activeTransaction
        let driverAtEntry = runtime.transition.driver
        let decisionState = decisionStateToken()
        let decision = solveTarget(
            model: model,
            proposedOuterOffset: contentOffset.y,
            velocity: 0,
            forceSnapping: false
        )
        guard runtime.transition.nextTransactionID == transactionEpoch,
              runtime.transition.activeTransaction === activeTransactionAtEntry,
              runtime.transition.driver == driverAtEntry,
              decisionStateToken() == decisionState,
              decision.targetOuterOffset.isFinite,
              decision.targetDisplayHeight.isFinite,
              !comparisonPolicy.isValueEqual(
                  decision.targetOuterOffset,
                  contentOffset.y
              ) else { return }

        _ = requestMovement(
            toDisplayHeight: decision.targetDisplayHeight,
            animated: true,
            options: BODragScrollMovementOptions(),
            // OC `takeAttach:` calls the ordinary `scrollToDisplayH:` path (`outset-ani`), not its
            // public manual-nearest-detent API. Keep the same movement-style/callback reason here.
            reason: .programmatic,
            completion: nil
        )
    }

    // MARK: Layout deferral and invalidation

    /// Called by the layout phase once panel geometry, insets, and content size are valid.
    /// Announces a non-animated pre-layout target after the sizing provider has resolved its final
    /// value but before geometry changes. False means the callback synchronously superseded it.
    func preparePendingInitialLayoutMovement(resolvedDisplayHeight: CGFloat) -> Bool {
        guard let pending = runtime.transition.pendingLayoutMovement,
              pending.isAppliedByInitialLayout,
              runtime.transition.activeTransaction === pending.transaction else {
            return true
        }
        let announcementState = decisionStateToken()
        pending.transaction.announceResolvedTarget(resolvedDisplayHeight, on: self)
        guard runtime.transition.activeTransaction === pending.transaction,
              decisionStateToken() == announcementState else {
            if runtime.transition.activeTransaction === pending.transaction {
                finishActiveMovement(
                    transactionID: pending.transaction.id,
                    outcome: .cancelled,
                    finalDisplayHeight: displayHeightForCurrentGeometry
                )
            }
            return false
        }
        return true
    }

    /// Mark panel geometry ready and detach only the pending intention that entered this layout
    /// pass. Notifications emitted afterward are allowed to create a newer movement, which must not
    /// be consumed as if it had already been applied by this pass.
    func takePendingMovementForCompletedLayout(
        expectedTransactionID: UInt64?
    ) -> BODragScrollPendingLayoutMovement? {
        runtime.transition.isPanelLayoutReady = true
        guard let pending = runtime.transition.pendingLayoutMovement else { return nil }
        runtime.transition.pendingLayoutMovement = nil
        guard pending.transaction.id == expectedTransactionID else {
            // This intention was created by a callback after the pass chose its geometry. Execute
            // it normally against the now-valid layout; it was not applied by this pass.
            runtime.panel.pendingInitialDisplayHeight = nil
            return BODragScrollPendingLayoutMovement(
                transaction: pending.transaction,
                animated: pending.animated,
                options: pending.options,
                isAppliedByInitialLayout: false
            )
        }
        return pending
    }

    /// Complete or execute the exact intention detached by
    /// `takePendingMovementForCompletedLayout(expectedTransactionID:)`.
    func performPreparedMovementAfterLayoutIfNeeded(
        _ pending: BODragScrollPendingLayoutMovement?
    ) {
        guard let pending else { return }
        guard runtime.transition.activeTransaction === pending.transaction else { return }
        if pending.isAppliedByInitialLayout {
            let resolvedDisplayHeight = displayHeightForCurrentGeometry
            pending.transaction.announceResolvedTarget(resolvedDisplayHeight, on: self)
            guard runtime.transition.activeTransaction === pending.transaction else { return }
            finishActiveMovement(
                transactionID: pending.transaction.id,
                outcome: .completed,
                finalDisplayHeight: resolvedDisplayHeight
            )
            return
        }

        _ = executeMovement(
            transaction: pending.transaction,
            animated: pending.animated,
            options: pending.options
        )
    }

    /// Called when replacing/removing the panel so subsequent moves wait for the next valid layout.
    func transitionPanelLayoutDidInvalidate() {
        runtime.transition.isPanelLayoutReady = false
    }

    /// Cancel an active transition without changing whether the current panel layout is valid.
    /// Panel replacement owns layout invalidation through `runtime.panel.hasCompletedLayout`.
    func interruptActiveMovement(outcome: BODragScrollMovementOutcome) {
        interruptRunningMovement(outcome: outcome)
    }

    /// `willMove(toWindow: nil)` cannot rely on UIKit to deliver an animation-end callback.
    func interruptMovementForRemovalFromWindow() {
        interruptRunningMovement(outcome: .interrupted)
        completePendingLayoutInterruptionIfNeeded()
    }

    func abortUserDragLifecycleForRemoval(
        preparedDeferredControlCancellation: (() -> Void)? = nil
    ) {
        let deferredControlCancellation = preparedDeferredControlCancellation
            ?? prepareDeferredControlCancellationForRemoval()
        let wasTrackingLifecycle = runtime.transition.isUserDragLifecycleActive
        let wasAwaitingDeceleration = runtime.transition.isAwaitingDidEndDecelerating
        let wasEmittingTerminalCallback = runtime.transition
            .isEmittingTerminalDragLifecycleCallback
        let participant = runtime.transition.forwardedDragLifecycleToParticipant
            ? runtime.transition.forwardedParticipant
            : nil
        let shouldForwardHostDragEnd = runtime.transition.forwardedDragBeginToEventDelegate
        let captureOwnership = takeCaptureCleanupOwnership()

        // Detach every old lifecycle owner before entering UIControl/delegate callbacks. Keep the
        // top-level drag gate active until the end so re-entrant scroll(to:) requests queue behind
        // this teardown instead of mutating half-removed geometry synchronously.
        runtime.transition.isAwaitingDidEndDecelerating = false
        runtime.transition.isEmittingTerminalDragLifecycleCallback = false
        runtime.transition.forwardedDragLifecycleToParticipant = false
        runtime.transition.forwardedParticipant = nil
        runtime.transition.forwardedDragBeginToEventDelegate = false
        deferredControlCancellation?()

        // UIKit is not required to deliver the terminal delegate callbacks after removal. Close the
        // exact lifecycle we forwarded so delegates never remain logically dragging. If removal
        // happens inside a terminal callback, that callback's local stack still owns delivery and
        // must not be duplicated here.
        if wasTrackingLifecycle, !wasEmittingTerminalCallback {
            if let participant {
                participant.delegate?.scrollViewDidEndDragging?(
                    participant,
                    willDecelerate: false
                )
            }
            if shouldForwardHostDragEnd {
                eventDelegate?.dragScrollViewDidEndDragging(self, willDecelerate: false)
            }
        } else if wasAwaitingDeceleration, !wasEmittingTerminalCallback {
            if let participant {
                participant.delegate?.scrollViewDidEndDecelerating?(participant)
            }
            eventDelegate?.dragScrollViewDidEndDecelerating(self)
        }
        finishCapture(ifOwnedBy: captureOwnership)
        finishUserDragLifecycleAndRunDeferredMovements()
    }

    func finishDecelerationLifecycleCancelledByLayout(participant: UIScrollView?) {
        if let participant {
            participant.delegate?.scrollViewDidEndDecelerating?(participant)
        }
        eventDelegate?.dragScrollViewDidEndDecelerating(self)
        finishUserDragLifecycleAndRunDeferredMovements()
    }

    /// Freeze an in-flight movement before bounds-dependent layout is rebuilt. Layout immediately
    /// reconciles geometry, so the interrupted transaction reports the height visible in the old
    /// viewport rather than a transient value calculated with the new bounds.
    func interruptMovementForLayoutChange(finalDisplayHeight _: CGFloat) {
        freezeRunningMovementForLayoutChange()
    }

    /// Finish a size-change interruption only after layout has installed one coherent geometry.
    /// Completion callbacks can then safely read the same display height carried by the result.
    func completePendingLayoutInterruptionIfNeeded() {
        let pending = runtime.transition.pendingLayoutInterruptions
        guard !pending.isEmpty else { return }
        runtime.transition.pendingLayoutInterruptions.removeAll()
        runtime.transition.isCompletingLayoutInterruptions = true
        withInternalMutation {
            for ownership in pending.compactMap(\.captureCleanupOwnership) {
                finishCapture(ifOwnedBy: ownership)
            }
            for interruption in pending where interruption.shouldFinishCancelledDecelerationLifecycle {
                finishDecelerationLifecycleCancelledByLayout(
                    participant: interruption.forwardedParticipant
                )
            }
            let finalDisplayHeight = displayHeightForCurrentGeometry
            for interruption in pending {
                interruption.transaction?.finish(
                    outcome: .interrupted,
                    finalDisplayHeight: finalDisplayHeight,
                    on: self
                )
            }
        }
        runtime.transition.isCompletingLayoutInterruptions = false
        runMovementsDeferredUntilLayoutInterruptionEnded()
    }

    private func runMovementsDeferredUntilLayoutInterruptionEnded() {
        guard !runtime.transition.isDrainingLayoutDeferredMovements else { return }
        runtime.transition.isDrainingLayoutDeferredMovements = true
        defer { runtime.transition.isDrainingLayoutDeferredMovements = false }
        while runtime.transition.pendingLayoutInterruptions.isEmpty,
              !runtime.transition.isCompletingLayoutInterruptions,
              !runtime.transition.movementsDeferredUntilLayoutInterruptionEnds.isEmpty {
            let action = runtime.transition.movementsDeferredUntilLayoutInterruptionEnds.removeFirst()
            action()
        }
    }

    /// Refreshing the same session during drag/deceleration (including a tracking-only touch that
    /// may interrupt it) transfers cleanup to the refreshed generation. A different session, or a
    /// capture created re-entrantly by a terminal callback, remains a newer independent owner.
    func transitionCaptureOwnershipDidRefresh(to session: BODragScrollCaptureSession) {
        guard !runtime.transition.isEmittingTerminalDragLifecycleCallback,
              let ownership = runtime.transition.captureCleanupOwnership,
              ownership.sessionID == session.id,
              runtime.capture.session === session else { return }
        let nativeState = nativeScrollState
        let continuesPhysicalInteraction = runtime.transition.isUserDragLifecycleActive
            || runtime.transition.isAwaitingDidEndDecelerating
            || nativeState.isTracking
            || nativeState.isDecelerating
            || (runtime.transition.activeTransaction?.reason == .dragRelease
                && runtime.transition.driver != nil)
        guard continuesPhysicalInteraction else { return }
        armCaptureCleanupOwnership()
    }

    var isPerformingViewTransition: Bool {
        runtime.transition.isViewAnimating
    }

    var isPerformingSystemScrollTransition: Bool {
        runtime.transition.driver == .systemAnimation
    }

    var lastSystemAnimationEndTimestamp: TimeInterval {
        get { runtime.transition.lastSystemAnimationEndTimestamp }
        set { runtime.transition.lastSystemAnimationEndTimestamp = newValue }
    }
}

// MARK: - Movement execution and transaction ownership

@MainActor
private extension BODragScrollView {
    func armCaptureCleanupOwnership() {
        let session = runtime.capture.session
        runtime.transition.captureCleanupOwnership = BODragScrollCaptureCleanupOwnership(
            sessionID: session?.id,
            sessionOwnershipGeneration: session?.ownershipGeneration
        )
    }

    func takeCaptureCleanupOwnership() -> BODragScrollCaptureCleanupOwnership? {
        defer { runtime.transition.captureCleanupOwnership = nil }
        return runtime.transition.captureCleanupOwnership
    }

    func takeCaptureCleanupOwnership(
        ifUnchanged expected: BODragScrollCaptureCleanupOwnership?
    ) -> BODragScrollCaptureCleanupOwnership? {
        guard runtime.transition.captureCleanupOwnership == expected else { return nil }
        runtime.transition.captureCleanupOwnership = nil
        return expected
    }

    func finishCapture(
        ifOwnedBy ownership: BODragScrollCaptureCleanupOwnership?,
        disposition: BODragScrollCaptureTeardownDisposition = .forced
    ) {
        guard let ownership,
              runtime.capture.session?.id == ownership.sessionID,
              runtime.capture.session?.ownershipGeneration
                == ownership.sessionOwnershipGeneration else { return }
        endCapture(disposition: disposition)
    }

    func beginMovementTransaction(
        requestedDisplayHeight: CGFloat,
        reason: BODragScrollMovementReason,
        completion: ((BODragScrollMovementResult) -> Void)?
    ) -> BODragScrollMovementTransaction {
        markMovementActivityBegan()
        // Any new intention supersedes a pre-layout immediate height owned by the previous request.
        runtime.panel.pendingInitialDisplayHeight = nil
        let closesNativeDeceleration = reason != .dragRelease
            && runtime.transition.isAwaitingDidEndDecelerating
        let participantToFinish = closesNativeDeceleration
            && runtime.transition.forwardedDragLifecycleToParticipant
            ? runtime.transition.forwardedParticipant
            : nil
        let captureOwnership = reason == .dragRelease
            ? nil
            : takeCaptureCleanupOwnership()
        if closesNativeDeceleration {
            // Suppress a synchronous UIKit callback while replacement stops native deceleration;
            // the lifecycle is completed exactly once below under the new transaction's ownership.
            runtime.transition.isAwaitingDidEndDecelerating = false
            runtime.transition.forwardedDragLifecycleToParticipant = false
            runtime.transition.forwardedParticipant = nil
        }
        let transactionID = runtime.transition.nextTransactionID
        runtime.transition.nextTransactionID &+= 1
        let transaction = BODragScrollMovementTransaction(
            id: transactionID,
            requestedDisplayHeight: requestedDisplayHeight,
            reason: reason,
            completion: completion
        )
        replaceActiveMovement(with: transaction, previousOutcome: .interrupted)

        if closesNativeDeceleration {
            // `replaceActiveMovement` has already atomically detached/stopped the old driver before
            // emitting any completion. Lifecycle pairing below still belongs to that cancelled
            // drag and must happen exactly once even if a completion installed a newer movement.
            runtime.transition.isEmittingTerminalDragLifecycleCallback = true
            if let participantToFinish {
                participantToFinish.delegate?.scrollViewDidEndDecelerating?(
                    participantToFinish
                )
            }
            eventDelegate?.dragScrollViewDidEndDecelerating(self)
            finishUserDragLifecycleAndRunDeferredMovements()
            runtime.transition.isEmittingTerminalDragLifecycleCallback = false
        }
        finishCapture(ifOwnedBy: captureOwnership)
        return transaction
    }

    // MARK: Movement driver selection and execution

    @discardableResult
    func executeMovement(
        transaction: BODragScrollMovementTransaction,
        animated: Bool,
        options: BODragScrollMovementOptions
    ) -> CGFloat {
        suspendCaptureAcquisition()
        defer { resumeCaptureAcquisition() }
        guard runtime.transition.activeTransaction === transaction else {
            return displayHeight
        }
        guard panelView != nil else {
            transaction.announceResolvedTarget(0, on: self)
            finishActiveMovement(transactionID: transaction.id, outcome: .cancelled, finalDisplayHeight: 0)
            return 0
        }

        // Programmatic height movement operates on the panel axis, as in the OC implementation.
        // End the capture before deriving limits so participant distance is removed from the outer axis.
        endCapture()
        guard runtime.transition.activeTransaction === transaction else {
            return displayHeight
        }
        reloadScrollMetrics()
        guard runtime.transition.activeTransaction === transaction else {
            return displayHeight
        }
        let movementState = decisionStateToken()

        // Programmatic movement is absolute on the panel axis. A bounce-constrained panel may have
        // a temporary nonzero frame translation, so deriving a relative delta from current geometry
        // would under/overshoot once scrolling returns the frame to zero.
        var targetOuterOffset = transaction.requestedDisplayHeight - bounds.height
        var resolvedDisplayHeight = transaction.requestedDisplayHeight
        guard targetOuterOffset.isFinite else {
            transaction.announceResolvedTarget(displayHeight, on: self)
            guard runtime.transition.activeTransaction === transaction else { return displayHeight }
            finishActiveMovement(
                transactionID: transaction.id,
                outcome: .cancelled,
                finalDisplayHeight: displayHeightForCurrentGeometry
            )
            return displayHeight
        }
        if targetOuterOffset < minimumOuterOffset,
           !configuration.bounce.allowsPanelTopBounce {
            targetOuterOffset = minimumOuterOffset
            resolvedDisplayHeight = effectiveMinimumDisplayHeight
        } else if targetOuterOffset > maximumOuterOffset,
                  !configuration.bounce.allowsPanelBottomBounce {
            targetOuterOffset = maximumOuterOffset
            resolvedDisplayHeight = maximumConfiguredDisplayHeight
        }

        guard resolvedDisplayHeight.isFinite else {
            transaction.announceResolvedTarget(displayHeight, on: self)
            guard runtime.transition.activeTransaction === transaction else { return displayHeight }
            finishActiveMovement(
                transactionID: transaction.id,
                outcome: .cancelled,
                finalDisplayHeight: displayHeightForCurrentGeometry
            )
            return displayHeight
        }
        transaction.announceResolvedTarget(resolvedDisplayHeight, on: self)
        guard runtime.transition.activeTransaction === transaction,
              decisionStateToken() == movementState else {
            if runtime.transition.activeTransaction === transaction {
                finishActiveMovement(
                    transactionID: transaction.id,
                    outcome: .cancelled,
                    finalDisplayHeight: displayHeightForCurrentGeometry
                )
            }
            return displayHeight
        }

        let targetContentOffset = CGPoint(x: contentOffset.x, y: targetOuterOffset)
        guard !CGPointEqualToPoint(contentOffset, targetContentOffset) else {
            // An on-screen system-scroll request with an exactly equal outer offset receives no
            // UIKit callback. Match the OC natural-scroll path only in that case; non-animated,
            // off-window and UIView-animation requests deliberately keep their original behavior.
            let needsNaturalNoScrollHandling = displayHeight != resolvedDisplayHeight
                || displayHeightForCurrentGeometry != resolvedDisplayHeight
            var finalDisplayHeight = displayHeightForCurrentGeometry
            if needsNaturalNoScrollHandling,
               animated,
               window != nil,
               !runtime.capture.isSuspendedForWindowTransition,
               options.style != .viewAnimation {
                // There is no animation to style when the host offset is already equal. Avoid a
                // policy callback and preserve the real frame; only the strict arithmetic tail of
                // this natural/system-style terminal value is canonicalized for publication.
                finalDisplayHeight = ProjectedHeight.authoritative(resolvedDisplayHeight)
                    .publishedValue(
                        actual: finalDisplayHeight,
                        comparison: comparisonPolicy
                    )
                setDisplayHeight(finalDisplayHeight, source: .panel)
                guard runtime.transition.activeTransaction === transaction else {
                    return resolvedDisplayHeight
                }
            }
            finishActiveMovement(
                transactionID: transaction.id,
                outcome: .completed,
                finalDisplayHeight: finalDisplayHeight
            )
            return resolvedDisplayHeight
        }

        guard animated,
              window != nil,
              !runtime.capture.isSuspendedForWindowTransition else {
            // Off-window/removing views cannot guarantee either UIKit or UIView animation-end
            // delivery. Apply atomically and settle the transaction now.
            setContentOffset(targetContentOffset, animated: false)
            finishActiveMovement(
                transactionID: transaction.id,
                outcome: .completed,
                finalDisplayHeight: displayHeightForCurrentGeometry
            )
            return resolvedDisplayHeight
        }

        let styleState = decisionStateToken()
        let style = resolvedMovementStyle(
            requested: options.style,
            fromDisplayHeight: displayHeight,
            toDisplayHeight: resolvedDisplayHeight,
            reason: transaction.reason
        )
        guard runtime.transition.activeTransaction === transaction,
              decisionStateToken() == styleState else {
            if runtime.transition.activeTransaction === transaction {
                finishActiveMovement(
                    transactionID: transaction.id,
                    outcome: .cancelled,
                    finalDisplayHeight: displayHeightForCurrentGeometry
                )
            }
            return displayHeight
        }
        switch style {
        case .viewAnimation:
            startViewAnimation(
                to: targetContentOffset,
                transaction: transaction,
                options: options
            )
        case .automatic, .systemScroll:
            startSystemScrollAnimation(
                to: targetContentOffset,
                transaction: transaction
            )
        }

        return resolvedDisplayHeight
    }

    func resolvedMovementStyle(
        requested: BODragScrollMovementStyle,
        fromDisplayHeight: CGFloat,
        toDisplayHeight: CGFloat,
        reason: BODragScrollMovementReason
    ) -> BODragScrollMovementStyle {
        if !requested.isAutomatic {
            return requested
        }

        let providerStyle = behaviorProvider?.dragScrollView(
            self,
            movementStyleFrom: fromDisplayHeight,
            to: toDisplayHeight,
            reason: reason
        ) ?? .automatic
        if !providerStyle.isAutomatic {
            return providerStyle
        }

        let configuredStyle = configuration.movement.defaultStyle
        return configuredStyle.isAutomatic ? .systemScroll : configuredStyle
    }

    // MARK: View-animation driver

    func startViewAnimation(
        to targetContentOffset: CGPoint,
        transaction: BODragScrollMovementTransaction,
        options: BODragScrollMovementOptions
    ) {
        guard runtime.transition.activeTransaction === transaction,
              targetContentOffset.x.isFinite,
              targetContentOffset.y.isFinite,
              window != nil,
              !runtime.capture.isSuspendedForWindowTransition else { return }
        let policy = configuration.movement
        let speed = max(100, min(100_000, policy.speed))
        let baseDuration = max(0, policy.baseDuration)
        let maximumDuration = max(baseDuration, policy.maximumDuration)
        var duration = min(
            maximumDuration,
            baseDuration + abs(contentOffset.y - targetContentOffset.y) / speed
        )
        if let requestedDuration = options.duration, requestedDuration.isFinite {
            duration = max(0, min(requestedDuration, 0.9))
        }

        let velocity = options.initialVelocity.isFinite ? abs(options.initialVelocity) : 0
        let damping: CGFloat
        if policy.usesSpring {
            let threshold = policy.highVelocityThreshold
            damping = velocity < threshold ? 1 : (velocity < threshold * 2 ? 0.8 : 0.6)
        } else {
            damping = 1
        }

        runtime.transition.driver = .viewAnimation
        runtime.transition.isViewAnimating = true
        let transactionID = transaction.id
        var animationOptions: UIView.AnimationOptions = [
            .beginFromCurrentState,
            .allowAnimatedContent,
            .allowUserInteraction,
            .layoutSubviews
        ]
        // Repeating/autoreversing animations do not have a stable terminal geometry and can leave
        // a completion-once movement transaction permanently active or completed at its origin.
        let terminallyUnsafeOptions: UIView.AnimationOptions = [.repeat, .autoreverse]
        animationOptions.formUnion(options.animationOptions.subtracting(terminallyUnsafeOptions))

        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: damping,
            initialSpringVelocity: 0,
            options: animationOptions,
            animations: { [weak self] in
                self?.contentOffset = targetContentOffset
            },
            completion: { [weak self] finished in
                self?.finishViewAnimation(transactionID: transactionID, finished: finished)
            }
        )

        guard runtime.transition.activeTransaction === transaction else { return }

        if policy.defersDisplayHeightUpdates {
            let deferredDisplayHeight = displayHeightForCurrentGeometry
            let deferredSource = runtime.drag.lastMotionSource
            scheduleDeferredDisplayHeightPublication(
                deferredDisplayHeight,
                source: deferredSource,
                transaction: transaction,
                animated: policy.animatesDeferredDisplayHeightUpdates,
                duration: duration,
                damping: damping,
                options: animationOptions
            )
        }
    }

    func finishViewAnimation(transactionID: UInt64, finished: Bool) {
        guard runtime.transition.activeTransaction?.id == transactionID,
              runtime.transition.driver.isViewAnimation else { return }
        runtime.transition.isViewAnimating = false

        let nativeState = nativeScrollState
        let captureOwnership = runtime.transition.captureCleanupOwnership
        let defersCaptureRelease = captureOwnership != nil
            && captureSessionMatches(captureOwnership)
            && (nativeState.isTracking || nativeState.isDecelerating)
        if !defersCaptureRelease {
            // Panel-to-panel drag replacement never crosses a participant segment. The current
            // axis phase is therefore already the authoritative terminal projection;
            // reloading here would falsely mark this still-owned session as metrics-dirty.
            finishCaptureAfterMovementIfNeeded(
                disposition: finished ? .settled : .forced
            )
        }
        guard runtime.transition.activeTransaction?.id == transactionID else { return }
        finishActiveMovement(
            transactionID: transactionID,
            outcome: finished ? .completed : .interrupted,
            finalDisplayHeight: displayHeightForCurrentGeometry
        )

        if defersCaptureRelease {
            // The animation result and real geometry are final now; only the capture lease waits.
            // A real drag will take over through its ordinary lifecycle, while a tracking-only
            // touch releases the same-session generation after lift.
            scheduleCaptureReleaseAfterTrackingOnlyTouch(
                captureOwnership: captureOwnership
            )
        }
    }

    func scheduleDeferredDisplayHeightPublication(
        _ deferredDisplayHeight: CGFloat,
        source: BODragScrollMotionSource,
        transaction: BODragScrollMovementTransaction,
        animated: Bool,
        duration: TimeInterval,
        damping: CGFloat,
        options: UIView.AnimationOptions
    ) {
        // Match the source timing: the content-offset animation is installed first, then the final
        // display-height value is published on the next main-actor turn. Per-scroll updates are not
        // deferred and continue to carry their exact projected height.
        let scheduledPanelGeneration = runtime.panel.replacementGeneration
        let scheduledPanel = panelView
        let scheduledDecisionRevision = runtime.decisionGeometryRevision
        let scheduledBoundsSize = bounds.size
        let scheduledCaptureSessionID = runtime.capture.session?.id
        let scheduledScrollCallbackEpoch = runtime.scrolling.callbackEpoch
        Task { @MainActor [weak self, transaction] in
            guard let self else { return }
            guard self.runtime.panel.replacementGeneration == scheduledPanelGeneration,
                  self.panelView === scheduledPanel,
                  self.runtime.decisionGeometryRevision == scheduledDecisionRevision,
                  self.bounds.size == scheduledBoundsSize,
                  self.runtime.capture.session?.id == scheduledCaptureSessionID,
                  self.runtime.scrolling.callbackEpoch == scheduledScrollCallbackEpoch else { return }
            let transactionStillOwnsMovement = self.runtime.transition.activeTransaction === transaction
            let transactionAlreadyCompletedWithoutReplacement = transaction.outcome == .completed
                && self.runtime.transition.nextTransactionID == transaction.id &+ 1
            guard transactionStillOwnsMovement || transactionAlreadyCompletedWithoutReplacement else {
                return
            }
            if transactionAlreadyCompletedWithoutReplacement {
                guard self.comparisonPolicy.isValueEqual(
                    self.displayHeightForCurrentGeometry,
                    deferredDisplayHeight
                ) else { return }
            }

            guard animated else {
                self.setDisplayHeight(deferredDisplayHeight, source: source)
                return
            }

            UIView.animate(
                withDuration: duration,
                delay: 0,
                usingSpringWithDamping: damping,
                initialSpringVelocity: 0,
                options: options,
                animations: { [weak self] in
                    self?.setDisplayHeight(deferredDisplayHeight, source: source)
                }
            )
        }
    }

    // MARK: System-driven settlement monitoring

    /// Installs all ownership before asking UIKit to animate because `setContentOffset` may emit
    /// synchronous delegate/KVO callbacks. Both programmatic motion and drag-bounce settlement use
    /// this single driver path.
    func startSystemScrollAnimation(
        to targetContentOffset: CGPoint,
        transaction: BODragScrollMovementTransaction
    ) {
        guard runtime.transition.activeTransaction === transaction,
              targetContentOffset.x.isFinite,
              targetContentOffset.y.isFinite,
              window != nil,
              !runtime.capture.isSuspendedForWindowTransition else { return }
        runtime.transition.driver = .systemAnimation
        runtime.transition.systemAnimationTransactionID = transaction.id
        runtime.transition.systemAnimationTargetOffsetY = targetContentOffset.y
        runtime.transition.systemAnimationSettlementMonitorTransactionID = nil
        runtime.transition.systemAnimationStartOffsetY = contentOffset.y
        runtime.transition.systemAnimationHasObservedProgress = false
        setContentOffset(targetContentOffset, animated: true)
        beginMonitoringSystemAnimationSettlement(transactionID: transaction.id)
    }

    /// UIKit's animation-end callback carries no animation identifier, so a delayed callback from a
    /// cancelled animation cannot itself be trusted to settle the current transaction. Instead,
    /// sample the transaction-specific target until the scroll axis is physically stable. A stale
    /// callback can at most start this monitor; it cannot complete a newer animation mid-flight.
    func beginMonitoringSystemAnimationSettlement(transactionID: UInt64) {
        guard runtime.transition.activeTransaction?.id == transactionID,
              runtime.transition.driver.isSystemAnimation,
              runtime.transition.systemAnimationTransactionID == transactionID else { return }
        guard runtime.transition.systemAnimationSettlementMonitorTransactionID != transactionID else {
            return
        }
        runtime.transition.systemAnimationSettlementMonitorTransactionID = transactionID
        scheduleSystemAnimationSettlementSample(
            transactionID: transactionID,
            observedScrollEpoch: runtime.scrolling.callbackEpoch,
            stableSampleCount: 0
        )
    }

    func scheduleSystemAnimationSettlementSample(
        transactionID: UInt64,
        observedScrollEpoch: UInt64,
        stableSampleCount: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            guard let self,
                  self.runtime.transition.activeTransaction?.id == transactionID,
                  self.runtime.transition.driver.isSystemAnimation,
                  self.runtime.transition.systemAnimationTransactionID == transactionID,
                  self.runtime.transition.systemAnimationSettlementMonitorTransactionID
                    == transactionID else { return }

            let currentScrollEpoch = self.runtime.scrolling.callbackEpoch
            let nativeState = self.nativeScrollState
            let isStable = currentScrollEpoch == observedScrollEpoch
                && !nativeState.isTracking
                && !nativeState.isDecelerating
                && !self.hasInFlightBoundsAnimation
            let nextStableSampleCount = isStable ? stableSampleCount + 1 : 0
            let reachedTarget = self.runtime.transition.systemAnimationTargetOffsetY.map {
                self.transitionValueEqual(self.contentOffset.y, $0)
            } ?? false
            if let startOffsetY = self.runtime.transition.systemAnimationStartOffsetY,
               !self.transitionValueEqual(self.contentOffset.y, startOffsetY) {
                self.runtime.transition.systemAnimationHasObservedProgress = true
            }
            // UIKit's end callback has no animation identifier and can belong to a replaced
            // transaction. Only geometry observed under this transaction may prove that it began
            // and later stopped short; otherwise retain the 12-frame no-progress fallback.
            let maySettleInterrupted = self.runtime.transition.systemAnimationHasObservedProgress

            if nextStableSampleCount >= 12,
               !reachedTarget,
               !maySettleInterrupted,
               let targetOffsetY = self.runtime.transition.systemAnimationTargetOffsetY {
                // UIKit can decline to start a requested scroll animation (for example while its
                // previous tracking transaction is still unwinding). Never leave the movement and
                // capture owned forever: after a generous no-progress window, commit the same host
                // target once without animation. The ordinary didScroll projection still performs
                // the participant/panel update, so there is no second geometry path.
                self.setContentOffset(
                    CGPoint(x: self.contentOffset.x, y: targetOffsetY),
                    animated: false
                )
                guard self.runtime.transition.activeTransaction?.id == transactionID,
                      self.runtime.transition.driver.isSystemAnimation else { return }
                self.scheduleSystemAnimationSettlementSample(
                    transactionID: transactionID,
                    observedScrollEpoch: self.runtime.scrolling.callbackEpoch,
                    stableSampleCount: 0
                )
                return
            }

            if nextStableSampleCount >= 3,
               reachedTarget || maySettleInterrupted {
                self.runtime.transition.systemAnimationSettlementMonitorTransactionID = nil
                self.finishCaptureAfterMovementIfNeeded(
                    disposition: reachedTarget ? .settled : .forced
                )
                guard self.runtime.transition.activeTransaction?.id == transactionID else { return }
                self.finishActiveMovement(
                    transactionID: transactionID,
                    outcome: reachedTarget ? .completed : .interrupted,
                    finalDisplayHeight: self.displayHeightForCurrentGeometry
                )
                return
            }

            self.scheduleSystemAnimationSettlementSample(
                transactionID: transactionID,
                observedScrollEpoch: currentScrollEpoch,
                stableSampleCount: nextStableSampleCount
            )
        }
    }

    func beginMonitoringScrollToTopSettlement(transactionID: UInt64) {
        guard runtime.transition.activeTransaction?.id == transactionID,
              runtime.transition.driver.isScrollToTop else { return }
        guard runtime.transition.scrollToTopSettlementMonitorTransactionID != transactionID else {
            return
        }
        runtime.transition.scrollToTopSettlementMonitorTransactionID = transactionID
        scheduleScrollToTopSettlementSample(
            transactionID: transactionID,
            observedScrollEpoch: runtime.scrolling.callbackEpoch,
            stableSampleCount: 0
        )
    }

    func scheduleScrollToTopSettlementSample(
        transactionID: UInt64,
        observedScrollEpoch: UInt64,
        stableSampleCount: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            guard let self,
                  self.runtime.transition.activeTransaction?.id == transactionID,
                  self.runtime.transition.driver.isScrollToTop,
                  self.runtime.transition.scrollToTopSettlementMonitorTransactionID
                    == transactionID else { return }

            let currentScrollEpoch = self.runtime.scrolling.callbackEpoch
            let nativeState = self.nativeScrollState
            let isStable = currentScrollEpoch == observedScrollEpoch
                && !nativeState.isTracking
                && !nativeState.isDecelerating
                && !self.hasInFlightBoundsAnimation
            let nextStableSampleCount = isStable ? stableSampleCount + 1 : 0
            let reachedTarget = self.runtime.transition.scrollToTopTargetOffsetY.map {
                self.transitionValueEqual(self.contentOffset.y, $0)
            } ?? false
            if let startOffsetY = self.runtime.transition.scrollToTopStartOffsetY,
               !self.transitionValueEqual(self.contentOffset.y, startOffsetY) {
                self.runtime.transition.scrollToTopHasObservedProgress = true
            }
            // `scrollViewDidScrollToTop` has no transaction identifier, so its callback cannot be
            // evidence for this transaction. Only geometry observed while this transaction owns
            // the driver may prove progress or completion.
            let maySettleInterrupted = self.runtime.transition.scrollToTopHasObservedProgress

            if nextStableSampleCount >= 12,
               !reachedTarget,
               !maySettleInterrupted,
               let targetOffsetY = self.runtime.transition.scrollToTopTargetOffsetY {
                // UIKit may decline to start after the delegate authorizes scroll-to-top. Commit
                // the same resolved target once after a generous no-progress window; ordinary
                // didScroll projection remains the only geometry path.
                self.setContentOffset(
                    CGPoint(x: self.contentOffset.x, y: targetOffsetY),
                    animated: false
                )
                guard self.runtime.transition.activeTransaction?.id == transactionID,
                      self.runtime.transition.driver.isScrollToTop else { return }
                self.scheduleScrollToTopSettlementSample(
                    transactionID: transactionID,
                    observedScrollEpoch: self.runtime.scrolling.callbackEpoch,
                    stableSampleCount: 0
                )
                return
            }

            if nextStableSampleCount >= 3,
               reachedTarget || maySettleInterrupted {
                self.runtime.transition.scrollToTopSettlementMonitorTransactionID = nil
                self.finishCaptureAfterMovementIfNeeded(
                    disposition: reachedTarget ? .settled : .forced
                )
                guard self.runtime.transition.activeTransaction?.id == transactionID else { return }
                self.finishActiveMovement(
                    transactionID: transactionID,
                    outcome: reachedTarget ? .completed : .interrupted,
                    finalDisplayHeight: self.displayHeightForCurrentGeometry
                )
                return
            }

            self.scheduleScrollToTopSettlementSample(
                transactionID: transactionID,
                observedScrollEpoch: currentScrollEpoch,
                stableSampleCount: nextStableSampleCount
            )
        }
    }

    // MARK: Interruption, replacement, and completion

    /// Atomically releases the transient driver identity and all callback/monitor keys owned by
    /// it. A native drag can exist without a movement transaction (for example with no detent),
    /// so driver cleanup must not depend on `activeTransaction` being present.
    @discardableResult
    func clearTransitionDriverState() -> BODragScrollTransitionState.Driver? {
        let driver = runtime.transition.driver
        runtime.transition.driver = nil
        runtime.transition.systemAnimationTransactionID = nil
        runtime.transition.systemAnimationTargetOffsetY = nil
        runtime.transition.systemAnimationSettlementMonitorTransactionID = nil
        runtime.transition.systemAnimationStartOffsetY = nil
        runtime.transition.systemAnimationHasObservedProgress = false
        runtime.transition.scrollToTopTargetOffsetY = nil
        runtime.transition.scrollToTopSettlementMonitorTransactionID = nil
        runtime.transition.scrollToTopStartOffsetY = nil
        runtime.transition.scrollToTopHasObservedProgress = false
        runtime.transition.isViewAnimating = false
        return driver
    }

    func interruptRunningMovement(
        outcome: BODragScrollMovementOutcome,
        finalDisplayHeight: CGFloat? = nil,
        reconcilesGeometry: Bool = true
    ) {
        replaceActiveMovement(
            with: nil,
            previousOutcome: outcome,
            finalDisplayHeight: finalDisplayHeight,
            reconcilesGeometry: reconcilesGeometry
        )
    }

    /// Transfers Swift ownership away from an interrupted native drag deceleration without
    /// touching the scroll view's physical offset.
    ///
    /// UIKit invokes `scrollViewWillBeginDragging` when a new finger interrupts deceleration. The
    /// OC implementation only clears its bookkeeping at that callback node; it never performs a
    /// same-value `setContentOffset`. Doing so from inside UIKit's pan-begin callback can suppress
    /// the matching zero-velocity will-end/did-end callbacks and strand the drag lifecycle. Keep
    /// the transaction/re-entrancy guarantees of `replaceActiveMovement`, but leave UIKit's own
    /// recognizer state machine authoritative for the new touch.
    func interruptNativeDragDecelerationForNewTouch(
        outcome: BODragScrollMovementOutcome,
        finalDisplayHeight: CGFloat? = nil
    ) {
        guard runtime.transition.driver == .dragDeceleration else {
            interruptRunningMovement(
                outcome: outcome,
                finalDisplayHeight: finalDisplayHeight
            )
            return
        }

        let transaction = runtime.transition.activeTransaction
        withInternalMutation {
            runtime.transition.activeTransaction = nil
            runtime.transition.pendingLayoutMovement = nil
            runtime.panel.pendingInitialDisplayHeight = nil
            clearTransitionDriverState()
            transaction?.finish(
                outcome: outcome,
                finalDisplayHeight: finalDisplayHeight ?? displayHeightForCurrentGeometry,
                on: self
            )
        }
    }

    /// Detach animation ownership without firing completion while bounds and panel geometry belong
    /// to different layout generations. `completePendingLayoutInterruptionIfNeeded()` publishes the
    /// interruption after the next coherent layout.
    func freezeRunningMovementForLayoutChange() {
        let transaction = runtime.transition.activeTransaction
        let isStillTracking = nativeScrollState.isTracking
        let shouldFinishCancelledDecelerationLifecycle = !isStillTracking
            && runtime.transition.isAwaitingDidEndDecelerating
        guard transaction != nil || shouldFinishCancelledDecelerationLifecycle else { return }
        let forwardedParticipant = shouldFinishCancelledDecelerationLifecycle
            && runtime.transition.forwardedDragLifecycleToParticipant
            ? runtime.transition.forwardedParticipant
            : nil
        let captureOwnership = isStillTracking ? nil : takeCaptureCleanupOwnership()
        if shouldFinishCancelledDecelerationLifecycle {
            // Stopping the scroll view below may synchronously emit UIKit's callback. Clear native
            // ownership first and complete the snapshotted lifecycle after coherent layout.
            runtime.transition.isAwaitingDidEndDecelerating = false
            runtime.transition.forwardedDragLifecycleToParticipant = false
            runtime.transition.forwardedParticipant = nil
        }

        runtime.transition.activeTransaction = nil
        runtime.transition.pendingLayoutMovement = nil
        runtime.panel.pendingInitialDisplayHeight = nil
        let driver = clearTransitionDriverState()
        runtime.transition.pendingLayoutInterruptions.append(
            BODragScrollPendingLayoutInterruption(
                transaction: transaction,
                captureCleanupOwnership: captureOwnership,
                shouldFinishCancelledDecelerationLifecycle:
                    shouldFinishCancelledDecelerationLifecycle,
                forwardedParticipant: forwardedParticipant
            )
        )

        if driver.isViewAnimation {
            let visibleOffset = layer.presentation()?.bounds.origin ?? contentOffset
            layer.removeAllAnimations()
            panelView?.layer.removeAllAnimations()
            withInternalMutation {
                setContentOffset(visibleOffset, animated: false)
            }
        } else if driver.isSystemDriven {
            withInternalMutation {
                setContentOffset(contentOffset, animated: false)
            }
        }
    }

    /// Replace transition ownership before emitting callbacks from the interrupted transaction.
    /// This makes callback re-entrancy deterministic: the newest request always remains the owner.
    func replaceActiveMovement(
        with replacement: BODragScrollMovementTransaction?,
        previousOutcome: BODragScrollMovementOutcome,
        finalDisplayHeight: CGFloat? = nil,
        reconcilesGeometry: Bool = true
    ) {
        let transaction = runtime.transition.activeTransaction
        guard transaction != nil || runtime.transition.driver != nil else {
            runtime.transition.activeTransaction = replacement
            return
        }

        let panelGeneration = runtime.panel.replacementGeneration
        // Keep callback-originated movements deferred until the old transaction has emitted its
        // interruption. This preserves old-finish-before-new-start ordering even when stopping a
        // UIKit animation synchronously invokes KVO/client code.
        withInternalMutation {
            // Clear ownership before stopping animations because UIKit may synchronously issue an end callback.
            runtime.transition.activeTransaction = replacement
            runtime.transition.pendingLayoutMovement = nil
            runtime.panel.pendingInitialDisplayHeight = nil
            let driver = clearTransitionDriverState()

            if driver.isViewAnimation {
                let visibleOffset = layer.presentation()?.bounds.origin ?? contentOffset
                layer.removeAllAnimations()
                panelView?.layer.removeAllAnimations()
                setContentOffset(visibleOffset, animated: false)

                let replacementStillOwns: Bool
                if let replacement {
                    replacementStillOwns = runtime.transition.activeTransaction === replacement
                } else {
                    replacementStillOwns = runtime.transition.activeTransaction == nil
                }
                if reconcilesGeometry,
                   replacementStillOwns,
                   runtime.panel.replacementGeneration == panelGeneration {
                    // A UIView driver is used only for panel-to-panel travel. The existing model
                    // remains valid at every intermediate host offset; rebuilding it here would
                    // misclassify this internal animation interruption as a participant-metrics
                    // change when the interrupting owner is a new drag.
                    setDisplayHeight(displayHeightForCurrentGeometry, source: .panel)
                }
            } else if driver.isSystemDriven {
                setContentOffset(contentOffset, animated: false)
            }

            transaction?.finish(
                outcome: previousOutcome,
                finalDisplayHeight: finalDisplayHeight ?? displayHeightForCurrentGeometry,
                on: self
            )
        }
    }

    func finishActiveMovement(
        transactionID: UInt64,
        outcome: BODragScrollMovementOutcome,
        finalDisplayHeight: CGFloat
    ) {
        guard let transaction = runtime.transition.activeTransaction,
              transaction.id == transactionID else { return }

        runtime.transition.activeTransaction = nil
        runtime.transition.pendingLayoutMovement = nil
        clearTransitionDriverState()
        let verifiedOutcome: BODragScrollMovementOutcome
        if outcome == .completed,
           let resolvedDisplayHeight = transaction.resolvedDisplayHeight,
           !comparisonPolicy.isValueEqual(resolvedDisplayHeight, finalDisplayHeight) {
            // Axis geometry may be rebuilt while UIKit is animating/decelerating. Never report a
            // completed intention when the terminal visible height no longer matches its target.
            verifiedOutcome = .interrupted
        } else {
            verifiedOutcome = outcome
        }
        transaction.finish(
            outcome: verifiedOutcome,
            finalDisplayHeight: finalDisplayHeight,
            on: self
        )
    }

    func finishCaptureAfterMovementIfNeeded(
        disposition: BODragScrollCaptureTeardownDisposition
    ) {
        finishCapture(
            ifOwnedBy: takeCaptureCleanupOwnership(),
            disposition: disposition
        )
    }

    func displayHeightForOuterOffset(_ outerOffset: CGFloat) -> CGFloat {
        if let model = activeScrollModel {
            return model.projection(at: outerOffset).displayHeight
        }
        return displayHeightForCurrentGeometry + outerOffset - contentOffset.y
    }
}

// MARK: - Release target resolution

@MainActor
private extension BODragScrollView {
    struct ResolvedReleaseTarget {
        var contentOffset: CGPoint
        var displayHeight: CGFloat
        var decision: TargetDecision?
    }

    func resolveReleaseTarget(
        proposedContentOffset: CGPoint,
        velocity: CGPoint
    ) -> ResolvedReleaseTarget {
        let resolutionEpoch = runtime.transition.nextTransactionID
        func supersededTarget() -> ResolvedReleaseTarget {
            ResolvedReleaseTarget(
                contentOffset: contentOffset,
                displayHeight: displayHeightForCurrentGeometry,
                decision: nil
            )
        }

        // Release targeting is a read-only decision over the current axis phase. Any adaptive
        // rebase has already happened in did-scroll; rebuilding here from live bounce/deceleration
        // offsets would mutate geometry while UIKit is merely asking for a target.
        let resolutionState = decisionStateToken()

        guard let model = releaseTargetModel(), !model.segments.isEmpty else {
            var target = proposedContentOffset
            let providerFallback = finiteTargetContentOffset(
                target,
                ultimateFallback: contentOffset
            )
            behaviorProvider?.dragScrollView(
                self,
                adjustTargetContentOffset: &target,
                velocity: velocity
            )
            guard runtime.transition.nextTransactionID == resolutionEpoch,
                  runtime.transition.activeTransaction == nil,
                  decisionStateToken() == resolutionState else {
                return supersededTarget()
            }
            target = finiteTargetContentOffset(
                target,
                ultimateFallback: providerFallback
            )
            let resolvedDisplayHeight = displayHeightForOuterOffset(target.y)
            guard resolvedDisplayHeight.isFinite else {
                return supersededTarget()
            }
            return ResolvedReleaseTarget(
                contentOffset: target,
                displayHeight: resolvedDisplayHeight,
                decision: nil
            )
        }

        var decision = solveTarget(
            model: model,
            proposedOuterOffset: proposedContentOffset.y,
            velocity: velocity.y
        )
        guard runtime.transition.nextTransactionID == resolutionEpoch,
              runtime.transition.activeTransaction == nil,
              decisionStateToken() == resolutionState else {
            return supersededTarget()
        }
        var target = CGPoint(x: proposedContentOffset.x, y: decision.targetOuterOffset)

        target.y = targetAdjustedByParticipantDelegate(
            decision: decision,
            model: model,
            velocity: velocity,
            currentTargetOuterOffset: target.y
        )
        guard runtime.transition.nextTransactionID == resolutionEpoch,
              runtime.transition.activeTransaction == nil,
              decisionStateToken() == resolutionState else {
            return supersededTarget()
        }
        // This is the final target owned by the component plus the primary participant delegate.
        // Only an exact later difference means the external behavior provider replaced that intent.
        let componentTargetOuterOffset = target.y
        let providerFallback = finiteTargetContentOffset(
            target,
            ultimateFallback: contentOffset
        )

        // The behavior provider has the final decision opportunity, matching the source order after
        // the participant's own UIScrollViewDelegate adjustment.
        behaviorProvider?.dragScrollView(
            self,
            adjustTargetContentOffset: &target,
            velocity: velocity
        )
        guard runtime.transition.nextTransactionID == resolutionEpoch,
              runtime.transition.activeTransaction == nil,
              decisionStateToken() == resolutionState else {
            return supersededTarget()
        }
        target = finiteTargetContentOffset(
            target,
            ultimateFallback: providerFallback
        )

        if target.y != decision.targetOuterOffset {
            let adjustedProjection = model.projection(at: target.y)
            guard adjustedProjection.displayHeight.isFinite else {
                return supersededTarget()
            }
            // Preserve classification/selected-anchor metadata but use the provider's final geometry.
            decision = TargetDecision(
                targetOuterOffset: target.y,
                targetDisplayHeight: adjustedProjection.displayHeight,
                scrollType: decision.scrollType,
                selectedAnchor: decision.selectedAnchor,
                proposedAnchor: decision.proposedAnchor,
                bypassedSnapping: decision.bypassedSnapping
            )
        }

        let finalProjection = model.projection(at: target.y)
        guard target.x.isFinite,
              target.y.isFinite,
              finalProjection.displayHeight.isFinite else {
            return supersededTarget()
        }

        let finalDisplayHeight: CGFloat
        if target.y == componentTargetOuterOffset,
           let segment = decision.selectedAnchor?.segment,
           target.y == segment.outerStart || target.y == segment.outerEnd {
            // A component-selected attach endpoint has a model-authoritative height. Do not rebuild
            // that value by subtracting and adding outer-axis distances.
            finalDisplayHeight = segment.displayHeight
        } else {
            // A behavior-provider override remains authoritative and is projected from its real
            // target offset, even if it happens to be numerically near an attach endpoint.
            finalDisplayHeight = finalProjection.displayHeight
        }

        return ResolvedReleaseTarget(
            contentOffset: target,
            displayHeight: finalDisplayHeight,
            decision: decision
        )
    }

    func solveTarget(
        model: ScrollModel,
        proposedOuterOffset: CGFloat,
        velocity: CGFloat,
        forceSnapping: Bool = false
    ) -> TargetDecision {
        let provisional = TargetSolver.locate(
            outerOffset: proposedOuterOffset,
            anchors: model.segments,
            accuracy: model.comparison.boundaryBand
        )
        let targetIsParticipant = provisional.location == .inside
            && provisional.segment.isParticipantSegment
        let proposedDisplayHeight = model.projection(at: proposedOuterOffset).displayHeight
        let nonSnappingOverride: Bool?
        if forceSnapping {
            // This explicit API must settle even inside a configured/provider non-snapping range.
            nonSnappingOverride = false
        } else if model.hasDetents, !targetIsParticipant {
            nonSnappingOverride = behaviorProvider?.dragScrollView(
                self,
                shouldBypassDetentsAt: proposedDisplayHeight
            )
        } else {
            nonSnappingOverride = nil
        }

        let policy = configuration.movement
        let solverConfiguration = TargetSolverConfiguration(
            disableInnerMomentumTransfer: configuration.handoff.preventsInnerToPanelHandoff,
            collapseResistance: configuration.handoff.resistsCollapse,
            lowVelocityThreshold: policy.lowVelocityThreshold,
            highVelocityThreshold: policy.highVelocityThreshold,
            adjacentAnchorDistance: policy.nearBoundaryDistance,
            panelToParticipantCaptureDistance: policy.outerToInnerSnapDistance,
            nonSnappingRanges: nonSnappingRanges.map {
                NonSnappingRange(.native($0.lowerBound), .native($0.upperBound))
            }
        )
        return TargetSolver.solve(
            TargetSolverInput(
                model: model,
                currentOuterOffset: contentOffset.y,
                proposedOuterOffset: proposedOuterOffset,
                velocity: velocity,
                minimumOuterOffset: minimumOuterOffset,
                maximumOuterOffset: maximumOuterOffset,
                configuration: solverConfiguration,
                nonSnappingOverride: nonSnappingOverride
            )
        )
    }

    /// Detents must resolve even when the touched panel subtree contains no inner scroll view.
    /// Capture sessions add participant segments; this fallback builds the same axis with panel
    /// anchors only, keeping target behavior independent from whether capture found a candidate.
    func releaseTargetModel() -> ScrollModel? {
        if let activeScrollModel {
            return activeScrollModel
        }
        guard bounds.height.isFinite,
              bounds.height > 0,
              !runtimeDetentHeights.isEmpty else {
            return nil
        }
        return try? ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: bounds.height,
                displayScale: displayScale,
                detents: runtimeDetentHeights.map(ScrollSourceScalar.native),
                participantOrder: [],
                participantSegments: []
            )
        )
    }

    func targetAdjustedByParticipantDelegate(
        decision: TargetDecision,
        model: ScrollModel,
        velocity: CGPoint,
        currentTargetOuterOffset: CGFloat
    ) -> CGFloat {
        guard let session = runtime.capture.session,
              let primaryParticipant = session.primaryParticipant,
              let participant = runtime.transition.forwardedParticipant
                ?? primaryParticipant.scrollView,
              let participantDelegate = participant.delegate else {
            return currentTargetOuterOffset
        }

        let participantID = primaryParticipant.id
        let originalInnerTarget = model.projection(at: currentTargetOuterOffset)
            .offset(for: participantID) ?? participant.contentOffset.y
        var delegateTarget = CGPoint(x: participant.contentOffset.x, y: originalInnerTarget)
        // Match UIScrollView's lifecycle: the same primary participant receives begin, will-end,
        // did-end and did-end-decelerating. The selected composite segment may be an ancestor, but
        // that must not redirect lifecycle callbacks to a different object.
        participantDelegate.scrollViewWillEndDragging?(
            participant,
            withVelocity: velocity,
            targetContentOffset: &delegateTarget
        )

        // The source always forwards will-end, but only lets the delegate alter a target that lands
        // inside a participant segment. An ancestor-owned target cannot be adjusted through the
        // primary participant's offset space.
        guard decision.scrollType == .participantToParticipant
                || decision.scrollType == .panelToParticipant,
              let selectedAnchor = decision.selectedAnchor,
              case .participant(let selectedParticipantID) = selectedAnchor.segment.owner,
              selectedParticipantID == participantID else {
            return currentTargetOuterOffset
        }

        let segment = selectedAnchor.segment
        guard delegateTarget.y.isFinite else {
            return currentTargetOuterOffset
        }
        guard delegateTarget.y != originalInnerTarget else {
            return currentTargetOuterOffset
        }

        let rawAdjustedOuterOffset = currentTargetOuterOffset
            + delegateTarget.y
            - originalInnerTarget
        guard rawAdjustedOuterOffset.isFinite else {
            return currentTargetOuterOffset
        }
        guard decision.containsDelegateAdjustedTarget(rawAdjustedOuterOffset, in: model) else {
            return currentTargetOuterOffset
        }

        // Intentional source fix: once the adjusted value resolves to the same attach index, clamp the
        // target itself to that segment. The OC code accidentally assigns an offset to its `loc` integer.
        return max(segment.outerStart, min(segment.outerEnd, rawAdjustedOuterOffset))
    }

    func finiteTargetContentOffset(
        _ candidate: CGPoint,
        ultimateFallback: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: candidate.x.isFinite ? candidate.x : ultimateFallback.x,
            y: candidate.y.isFinite ? candidate.y : ultimateFallback.y
        )
    }

    func finishUserDragLifecycleAndRunDeferredMovements() {
        runtime.transition.isUserDragLifecycleActive = false
        guard !runtime.transition.isDrainingDragDeferredMovements else { return }
        runtime.transition.isDrainingDragDeferredMovements = true
        defer {
            runtime.transition.isDrainingDragDeferredMovements = false
            scheduleMovementIdlePublicationIfNeeded()
        }
        while !runtime.transition.isUserDragLifecycleActive,
              !runtime.transition.movementsDeferredUntilDragEnds.isEmpty {
            let action = runtime.transition.movementsDeferredUntilDragEnds.removeFirst()
            action()
        }
    }

    /// Close only the begin notifications that were actually sent before a synchronous callback
    /// invalidated this touch's host/panel hierarchy. This differs from window-removal cleanup:
    /// the host begin may not have been emitted yet even though the participant begin was.
    func finishInvalidatedDragBegin() {
        let participant = runtime.transition.forwardedDragLifecycleToParticipant
            ? runtime.transition.forwardedParticipant
            : nil
        let shouldForwardHostDragEnd = runtime.transition.forwardedDragBeginToEventDelegate
        runtime.transition.forwardedDragLifecycleToParticipant = false
        runtime.transition.forwardedParticipant = nil
        runtime.transition.forwardedDragBeginToEventDelegate = false
        runtime.transition.isAwaitingDidEndDecelerating = false
        runtime.transition.isEmittingTerminalDragLifecycleCallback = true
        if let participant {
            participant.delegate?.scrollViewDidEndDragging?(
                participant,
                willDecelerate: false
            )
        }
        if shouldForwardHostDragEnd {
            eventDelegate?.dragScrollViewDidEndDragging(self, willDecelerate: false)
        }
        runtime.transition.isEmittingTerminalDragLifecycleCallback = false
        let ownership = takeCaptureCleanupOwnership()
        finishCapture(ifOwnedBy: ownership, disposition: .forced)
        finishUserDragLifecycleAndRunDeferredMovements()
    }

    func captureSessionMatches(
        _ ownership: BODragScrollCaptureCleanupOwnership?
    ) -> Bool {
        let session = runtime.capture.session
        guard let ownership else { return session == nil }
        return session?.id == ownership.sessionID
            && session?.ownershipGeneration == ownership.sessionOwnershipGeneration
    }

    /// Follow an ownership transfer only while it still names the same capture session and the
    /// session itself confirms the latest generation. Refreshes performed by the active physical
    /// touch update `captureCleanupOwnership`; a re-entrant terminal callback deliberately does
    /// not, so its independent capture cannot be adopted by an older async cleanup task.
    func captureCleanupOwnershipContinuingSameSession(
        from expected: BODragScrollCaptureCleanupOwnership?
    ) -> (matches: Bool, ownership: BODragScrollCaptureCleanupOwnership?) {
        let current = runtime.transition.captureCleanupOwnership
        if current == expected, captureSessionMatches(current) {
            return (true, current)
        }
        guard let expected,
              let expectedSessionID = expected.sessionID,
              let current,
              current.sessionID == expectedSessionID,
              captureSessionMatches(current) else {
            return (false, nil)
        }
        return (true, current)
    }

    /// Finish a drag release only after UIKit has relinquished tracking/deceleration. If the host is
    /// still outside its legal axis, its UIScrollView owns the return animation and the ordinary
    /// projection path moves the visible bounce owner each frame. A tracking-only touch may instead
    /// become a real drag; transaction and capture generations make that newer owner cancel this task.
    func scheduleDragReleaseSettlement(
        transactionID: UInt64,
        expectedDriver: BODragScrollTransitionState.Driver?,
        captureOwnership: BODragScrollCaptureCleanupOwnership?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let transaction = self.runtime.transition.activeTransaction,
                  transaction.id == transactionID,
                  transaction.reason == .dragRelease,
                  self.runtime.transition.driver == expectedDriver else {
                return
            }

            let continuingOwnership = self.captureCleanupOwnershipContinuingSameSession(
                from: captureOwnership
            )
            guard continuingOwnership.matches else {
                // A terminal callback installed/refreshed another capture without starting a new
                // movement. It is a newer interaction owner, so only close the old transaction.
                _ = self.takeCaptureCleanupOwnership(ifUnchanged: captureOwnership)
                self.finishActiveMovement(
                    transactionID: transactionID,
                    outcome: .interrupted,
                    finalDisplayHeight: self.displayHeightForCurrentGeometry
                )
                return
            }
            let currentCaptureOwnership = continuingOwnership.ownership

            guard self.window != nil,
                  !self.runtime.capture.isSuspendedForWindowTransition else {
                let ownership = self.takeCaptureCleanupOwnership(
                    ifUnchanged: currentCaptureOwnership
                )
                self.finishCapture(ifOwnedBy: ownership, disposition: .forced)
                guard self.runtime.transition.activeTransaction?.id == transactionID else { return }
                self.finishActiveMovement(
                    transactionID: transactionID,
                    outcome: .interrupted,
                    finalDisplayHeight: self.displayHeightForCurrentGeometry
                )
                return
            }

            let nativeState = self.nativeScrollState
            if nativeState.isTracking || nativeState.isDecelerating {
                // A real drag will synchronously interrupt this transaction in willBeginDragging.
                // A tap can temporarily make the host tracking without ever beginning a drag, and
                // native bounce deceleration can outlive didEndDragging(false). Recheck after the
                // current native interaction instead of abandoning this transaction and capture.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
                    self?.scheduleDragReleaseSettlement(
                        transactionID: transactionID,
                        expectedDriver: expectedDriver,
                        captureOwnership: currentCaptureOwnership
                    )
                }
                return
            }

            guard let overscroll = self.hostOverscrollState() else {
                let ownership = self.takeCaptureCleanupOwnership(
                    ifUnchanged: currentCaptureOwnership
                )
                self.finishCapture(ifOwnedBy: ownership, disposition: .settled)
                guard self.runtime.transition.activeTransaction?.id == transactionID else { return }
                self.finishActiveMovement(
                    transactionID: transactionID,
                    outcome: .completed,
                    finalDisplayHeight: self.displayHeightForCurrentGeometry
                )
                return
            }

            self.startSystemScrollAnimation(
                to: CGPoint(x: self.contentOffset.x, y: overscroll.boundaryOffset),
                transaction: transaction
            )
        }
    }

    /// UIKit can omit `willEndDragging`, leaving a valid native-deceleration lifecycle without a
    /// movement transaction. If its terminal callback arrives during a tracking-only touch, retain
    /// that touch's refreshed capture until it either becomes a real drag or lifts. Capture still
    /// uses its existing generation/user-drag ownership. UIControl disposition is deliberately not
    /// coupled to this cleanup task; only the bound physical UITouch observer owns that decision.
    func scheduleCaptureReleaseAfterTrackingOnlyTouch(
        captureOwnership: BODragScrollCaptureCleanupOwnership?
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            guard let self else { return }
            guard self.runtime.transition.activeTransaction == nil,
                  self.runtime.transition.driver == nil else {
                return
            }
            let continuingOwnership = self.captureCleanupOwnershipContinuingSameSession(
                from: captureOwnership
            )
            guard continuingOwnership.matches else {
                // Drop only the stale token. A different session, or a same-session generation
                // installed re-entrantly by a terminal callback, remains independently captured.
                _ = self.takeCaptureCleanupOwnership(ifUnchanged: captureOwnership)
                self.scheduleMovementIdlePublicationIfNeeded()
                return
            }
            let currentCaptureOwnership = continuingOwnership.ownership

            // A real drag now owns this capture and its ordinary did-end path will release it.
            guard !self.runtime.transition.isUserDragLifecycleActive else { return }

            let nativeState = self.nativeScrollState
            if nativeState.isTracking || nativeState.isDecelerating {
                self.scheduleCaptureReleaseAfterTrackingOnlyTouch(
                    captureOwnership: currentCaptureOwnership
                )
                return
            }

            let ownership = self.takeCaptureCleanupOwnership(
                ifUnchanged: currentCaptureOwnership
            )
            let disposition: BODragScrollCaptureTeardownDisposition =
                self.hostOverscrollState() == nil ? .settled : .forced
            self.finishCapture(ifOwnedBy: ownership, disposition: disposition)
            self.scheduleMovementIdlePublicationIfNeeded()
        }
    }

}

// MARK: - UIScrollViewDelegate settlement lifecycle

@MainActor
extension BODragScrollView: UIScrollViewDelegate {
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        markMovementActivityBegan()
        // The new touch owns the synchronous callback window. Callback-originated movements wait
        // until this tracking lifecycle ends instead of tearing down the capture needed by the new
        // drag. The previous native deceleration debt deliberately remains open until UIKit ends it.
        runtime.transition.isUserDragLifecycleActive = true
        runtime.transition.forwardedDragBeginToEventDelegate = false
        // OC clears the touch-completion candidate at the start of will-begin-dragging, before any
        // participant/control/event callback can re-enter the host. The real drag now owns landing.
        cancelPendingTouchCompletionSettlement()
        let windowAtEntry = window
        let panelAtEntry = panelView
        let panelGenerationAtEntry = runtime.panel.replacementGeneration
        var captureSessionAtEntry = runtime.capture.session
        func dragEntryIsStillValid() -> Bool {
            let captureIsStillValid: Bool
            if let captureSessionAtEntry {
                captureIsStillValid = runtime.capture.session === captureSessionAtEntry
                    && captureSessionIsCurrentAndHierarchyValid(captureSessionAtEntry)
            } else {
                captureIsStillValid = runtime.capture.session == nil
            }
            return runtime.transition.isUserDragLifecycleActive
                && window === windowAtEntry
                && panelView === panelAtEntry
                && runtime.panel.replacementGeneration == panelGenerationAtEntry
                && !runtime.capture.isSuspendedForWindowTransition
                && captureIsStillValid
        }
        // This emits `.touchCancel`, so establish and validate the drag-entry snapshot around that
        // external target-action boundary just like every other callback below.
        cancelDeferredControlIfOnlyLiveTouchBecameDrag()
        // UIScrollView does not expose which finger crossed its drag threshold. With one observed
        // touch the UIControl owner is unambiguous and was cancelled above. With multiple touches,
        // the observer uses per-touch movement to keep an unrelated stationary control intact.
        guard dragEntryIsStillValid() else {
            finishInvalidatedDragBegin()
            return
        }
        // Match OC's continuous native lifecycle exactly. A touch that interrupts deceleration
        // starts another will-begin/will-end/did-end sequence, while the original deceleration debt
        // remains open until UIKit's single real did-end-decelerating callback. Do not synthesize
        // that terminal callback here; the new release below inherits the native lifecycle.
        if runtime.transition.driver == .dragDeceleration {
            // Match OC at this exact callback node: release the old drag-deceleration owner, but
            // do not write contentOffset while UIKit is beginning the replacement pan. UIKit will
            // deliver will-end/did-end for this touch and the ordinary release solver owns landing.
            interruptNativeDragDecelerationForNewTouch(outcome: .interrupted)
        } else {
            interruptRunningMovement(outcome: .interrupted)
        }
        // Completing the interrupted movement is an external callback boundary. It may remove the
        // host or replace the panel; never arm the invalid touch against that new hierarchy or
        // forward a mismatched begin lifecycle.
        guard dragEntryIsStillValid() else {
            finishInvalidatedDragBegin()
            return
        }
        if let touchedView = runtime.capture.deferredTouchViewForFreshCapture {
            // Touch-down must not replace the axis while the previous deceleration still owns its
            // physics. Now that a real drag has interrupted that driver, build one fresh model from
            // current metrics before forwarding the new begin lifecycle.
            runtime.capture.deferredTouchViewForFreshCapture = nil
            _ = beginCapture(from: touchedView, requiresFreshSession: true)
            captureSessionAtEntry = runtime.capture.session
            guard dragEntryIsStillValid() else {
                finishInvalidatedDragBegin()
                return
            }
        }
        // A clean same-chain capture keeps its leases and metric snapshots when it interrupts
        // deceleration. For an adaptive no-detent axis, silently move only the automatic inner
        // activation block to the currently rendered legal height before begin callbacks observe
        // the new drag. Dirty or different-chain captures were rebuilt by the branch above.
        rebaseAdaptiveAxisForNewDragIfNeeded()
        guard dragEntryIsStillValid() else {
            finishInvalidatedDragBegin()
            return
        }
        armCaptureCleanupOwnership()
        let forwardedParticipant = hasParticipantSegments ? primaryParticipantScrollView : nil
        runtime.transition.forwardedParticipant = forwardedParticipant
        runtime.transition.forwardedDragLifecycleToParticipant = forwardedParticipant != nil

        if let participant = forwardedParticipant {
            participant.delegate?.scrollViewWillBeginDragging?(participant)
            // Participant delegates are also external callback boundaries. If this callback
            // invalidates the hierarchy, pair the participant begin locally; the host-level begin
            // has not been sent yet and therefore must not receive a synthetic end.
            guard dragEntryIsStillValid() else {
                finishInvalidatedDragBegin()
                return
            }
        }
        runtime.transition.forwardedDragBeginToEventDelegate = true
        eventDelegate?.dragScrollViewWillBeginDragging(self)
        guard dragEntryIsStillValid() else {
            finishInvalidatedDragBegin()
            return
        }
        // `beginCapture(from:)` has already installed the model for a fresh touch. When this touch
        // interrupts deceleration, retaining that model preserves the current projected overscroll
        // and lets the new pan continue from exactly what is visible on screen.
    }

    public func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard runtime.transition.isUserDragLifecycleActive else {
            targetContentOffset.pointee = contentOffset
            return
        }
        let transactionEpoch = runtime.transition.nextTransactionID
        let resolved = resolveReleaseTarget(
            proposedContentOffset: targetContentOffset.pointee,
            velocity: velocity
        )
        targetContentOffset.pointee = resolved.contentOffset

        // A provider or participant callback used during resolution may have started a newer
        // movement. Do not emit stale release events for the superseded drag.
        guard runtime.transition.nextTransactionID == transactionEpoch,
              runtime.transition.activeTransaction == nil else {
            targetContentOffset.pointee = contentOffset
            return
        }

        let resolvedState = decisionStateToken()
        eventDelegate?.dragScrollViewWillEndDragging(
            self,
            velocity: velocity,
            resolvedTargetContentOffset: resolved.contentOffset
        )

        // An event callback is allowed to initiate a movement. Do not let the older system release
        // overwrite that newer intention or run native deceleration alongside it.
        guard runtime.transition.nextTransactionID == transactionEpoch,
              runtime.transition.activeTransaction == nil,
              decisionStateToken() == resolvedState else {
            targetContentOffset.pointee = contentOffset
            return
        }

        // These are UIKit's concrete current and target offsets. Any exact difference represents a
        // real target movement; no numeric tolerance may suppress its lifecycle or callback path.
        let willDecelerate = resolved.contentOffset.y != contentOffset.y

        // A release target is an event/intent, not a value-changed notification. Emit a movement
        // transaction for every valid will-end-dragging callback, including a same-height target.
        let transaction = beginMovementTransaction(
            requestedDisplayHeight: resolved.displayHeight,
            reason: .dragRelease,
            completion: nil
        )
        guard runtime.transition.activeTransaction === transaction else {
            targetContentOffset.pointee = contentOffset
            return
        }
        let announcementState = decisionStateToken()
        transaction.announceResolvedTarget(resolved.displayHeight, on: self)
        guard runtime.transition.activeTransaction === transaction,
              decisionStateToken() == announcementState else {
            // The will-move notification synchronously installed a newer movement. Prevent UIKit
            // from also decelerating toward the superseded release target.
            if runtime.transition.activeTransaction === transaction {
                finishActiveMovement(
                    transactionID: transaction.id,
                    outcome: .cancelled,
                    finalDisplayHeight: displayHeightForCurrentGeometry
                )
            }
            targetContentOffset.pointee = contentOffset
            return
        }

        let crossesParticipant = activeScrollModel.map {
            movementCrossesParticipantSegment(
                in: $0,
                from: contentOffset.y,
                to: resolved.contentOffset.y
            )
        } ?? false
        let canReplaceSystemDeceleration = resolved.decision?.scrollType == .panelToPanel
            && willDecelerate
            && !crossesParticipant
        if canReplaceSystemDeceleration {
            let styleState = decisionStateToken()
            let style = resolvedMovementStyle(
                requested: .automatic,
                fromDisplayHeight: displayHeight,
                toDisplayHeight: resolved.displayHeight,
                reason: .dragRelease
            )
            guard runtime.transition.activeTransaction === transaction,
                  decisionStateToken() == styleState else {
                if runtime.transition.activeTransaction === transaction {
                    finishActiveMovement(
                        transactionID: transaction.id,
                        outcome: .cancelled,
                        finalDisplayHeight: displayHeightForCurrentGeometry
                    )
                }
                targetContentOffset.pointee = contentOffset
                return
            }
            if style.isViewAnimation {
                let animationTarget = resolved.contentOffset
                targetContentOffset.pointee = contentOffset
                // Stop UIKit's predicted deceleration before installing the view animation.
                setContentOffset(contentOffset, animated: false)
                guard runtime.transition.activeTransaction === transaction,
                      decisionStateToken() == styleState else {
                    if runtime.transition.activeTransaction === transaction {
                        finishActiveMovement(
                            transactionID: transaction.id,
                            outcome: .cancelled,
                            finalDisplayHeight: displayHeightForCurrentGeometry
                        )
                    }
                    targetContentOffset.pointee = contentOffset
                    return
                }
                let initialVelocity: CGFloat
                if (animationTarget.y > contentOffset.y) == (velocity.y > 0) {
                    initialVelocity = abs(velocity.y)
                } else {
                    initialVelocity = 0
                }
                startViewAnimation(
                    to: animationTarget,
                    transaction: transaction,
                    options: BODragScrollMovementOptions(
                        style: .viewAnimation,
                        initialVelocity: initialVelocity
                    )
                )
                return
            }
        }

        guard runtime.transition.activeTransaction === transaction else {
            targetContentOffset.pointee = contentOffset
            return
        }
        runtime.transition.driver = willDecelerate
            ? .dragDeceleration
            : .dragWithoutDeceleration
    }

    // MARK: Drag and deceleration settlement

    public func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        guard runtime.transition.isUserDragLifecycleActive else {
            // A touch that only stopped participant inertia never crossed the drag threshold.
            // Its physical touch observer exclusively owns UIControl completion; this lifecycle
            // callback must not race a later system cancellation into a false touchUpInside.
            scheduleMovementIdlePublicationIfNeeded()
            return
        }
        // The owner UITouch's movement observer has already cancelled a real control drag. Do not
        // cancel here: this delegate callback may belong to an unrelated second finger.
        // Deferral protects only the synchronous tracking lifecycle. Once did-end returns, a
        // programmatic movement is authoritative and may interrupt native deceleration immediately.
        defer {
            runtime.transition.isEmittingTerminalDragLifecycleCallback = false
            finishUserDragLifecycleAndRunDeferredMovements()
        }
        if decelerate, !runtime.transition.driver.isAnimation {
            // UIKit's actual lifecycle result is authoritative when its prediction differs from
            // will-end, or when UIKit omitted will-end for a cancelled/synthetic drag. A movement
            // already replaced by a component-owned animation remains under that driver's owner.
            runtime.transition.driver = .dragDeceleration
        }
        let finishingTransactionID = runtime.transition.activeTransaction?.id
        let finishingDriver = runtime.transition.driver
        // `decelerate` describes UIKit's callback, but will-end may already have replaced that
        // native motion with a component-owned view animation. Only the native driver waits for
        // `didEndDecelerating`; every other driver keeps its own completion ownership.
        let awaitsNativeDeceleration = decelerate && finishingDriver == .dragDeceleration
        let finishesWithoutDeceleration = !awaitsNativeDeceleration && !finishingDriver.isAnimation
        let captureOwnership = finishesWithoutDeceleration
            ? runtime.transition.captureCleanupOwnership
            : nil
        let needsHostOverscrollReturn = finishesWithoutDeceleration
            && hostOverscrollState() != nil
            && finishingTransactionID != nil
            && runtime.transition.activeTransaction?.reason == .dragRelease

        let participant = runtime.transition.forwardedDragLifecycleToParticipant
            ? runtime.transition.forwardedParticipant
            : nil
        runtime.transition.forwardedDragBeginToEventDelegate = false
        runtime.transition.isAwaitingDidEndDecelerating = awaitsNativeDeceleration
        if !awaitsNativeDeceleration {
            runtime.transition.forwardedDragLifecycleToParticipant = false
            runtime.transition.forwardedParticipant = nil
        }

        runtime.transition.isEmittingTerminalDragLifecycleCallback = true
        if let participant {
            participant.delegate?.scrollViewDidEndDragging?(
                participant,
                willDecelerate: awaitsNativeDeceleration
            )
        }
        eventDelegate?.dragScrollViewDidEndDragging(
            self,
            willDecelerate: awaitsNativeDeceleration
        )

        guard runtime.transition.activeTransaction?.id == finishingTransactionID,
              runtime.transition.driver == finishingDriver else {
            return
        }
        if finishesWithoutDeceleration {
            if needsHostOverscrollReturn, let transactionID = finishingTransactionID {
                scheduleDragReleaseSettlement(
                    transactionID: transactionID,
                    expectedDriver: finishingDriver,
                    captureOwnership: captureOwnership
                )
                return
            }

            // End only the generation captured by this drag. A terminal callback may have installed
            // a newer capture, which must survive this older UIKit lifecycle.
            let ownership = takeCaptureCleanupOwnership(ifUnchanged: captureOwnership)
            let disposition: BODragScrollCaptureTeardownDisposition = hostOverscrollState() == nil
                ? .settled
                : .forced
            finishCapture(ifOwnedBy: ownership, disposition: disposition)
            guard runtime.transition.activeTransaction?.id == finishingTransactionID,
                  runtime.transition.driver == finishingDriver else { return }
            if let transactionID = finishingTransactionID {
                finishActiveMovement(
                    transactionID: transactionID,
                    outcome: .completed,
                    finalDisplayHeight: displayHeightForCurrentGeometry
                )
            }
        }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let nativeState = nativeScrollState
        guard runtime.transition.isAwaitingDidEndDecelerating,
              !nativeState.isDecelerating else {
            scheduleMovementIdlePublicationIfNeeded()
            return
        }
        defer {
            runtime.transition.isEmittingTerminalDragLifecycleCallback = false
            finishUserDragLifecycleAndRunDeferredMovements()
        }
        let finishingTransactionID = runtime.transition.activeTransaction?.id
        let finishingDriver = runtime.transition.driver
        let captureOwnership = runtime.transition.captureCleanupOwnership
        runtime.transition.isAwaitingDidEndDecelerating = false

        let participant = runtime.transition.forwardedDragLifecycleToParticipant
            ? runtime.transition.forwardedParticipant
            : nil
        runtime.transition.forwardedDragLifecycleToParticipant = false
        runtime.transition.forwardedParticipant = nil

        runtime.transition.isEmittingTerminalDragLifecycleCallback = true
        if let participant {
            participant.delegate?.scrollViewDidEndDecelerating?(participant)
        }
        eventDelegate?.dragScrollViewDidEndDecelerating(self)

        guard runtime.transition.activeTransaction?.id == finishingTransactionID,
              runtime.transition.driver == finishingDriver else {
            // A terminal callback may replace the panel, remove the host, or install a newer
            // movement/capture. Drop only the snapshotted cleanup token when it is still current;
            // a re-entrant capture owns a different generation and must survive this old terminal.
            _ = takeCaptureCleanupOwnership(ifUnchanged: captureOwnership)
            return
        }
        // UIKit may deliver this old deceleration's sole terminal callback while a new finger is
        // merely tracking, before that touch either becomes a drag or lifts. Pair callbacks now,
        // but keep the transaction/capture until tracking ends so a real drag can take them over.
        let mustWaitForTrackingToEnd = nativeScrollState.isTracking
        if (mustWaitForTrackingToEnd || hostOverscrollState() != nil),
           runtime.transition.activeTransaction?.reason == .dragRelease,
           let transactionID = finishingTransactionID {
            scheduleDragReleaseSettlement(
                transactionID: transactionID,
                expectedDriver: finishingDriver,
                captureOwnership: captureOwnership
            )
            return
        }

        if finishingTransactionID == nil {
            // A native drag can legitimately have no movement transaction when UIKit omitted
            // will-end. Its terminal callback must still release the driver identity; otherwise
            // all future metrics/configuration updates look perpetually active.
            clearTransitionDriverState()
            if mustWaitForTrackingToEnd {
                scheduleCaptureReleaseAfterTrackingOnlyTouch(
                    captureOwnership: captureOwnership
                )
                return
            }
        }

        let ownership = takeCaptureCleanupOwnership(ifUnchanged: captureOwnership)
        let disposition: BODragScrollCaptureTeardownDisposition = hostOverscrollState() == nil
            ? .settled
            : .forced
        finishCapture(ifOwnedBy: ownership, disposition: disposition)
        let expectedTerminalDriver = finishingTransactionID == nil ? nil : finishingDriver
        guard runtime.transition.activeTransaction?.id == finishingTransactionID,
              runtime.transition.driver == expectedTerminalDriver else { return }
        if finishingDriver == .dragDeceleration,
           let transactionID = finishingTransactionID {
            finishActiveMovement(
                transactionID: transactionID,
                outcome: .completed,
                finalDisplayHeight: displayHeightForCurrentGeometry
            )
        }
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if runtime.transition.driver.isSystemAnimation,
           let transactionID = runtime.transition.activeTransaction?.id,
           runtime.transition.systemAnimationTransactionID == transactionID {
            // Transaction-sensitive settlement monitoring remains scoped to the current owner.
            beginMonitoringSystemAnimationSettlement(transactionID: transactionID)
        }
        eventDelegate?.dragScrollViewDidEndScrollingAnimation(self)
        scheduleMovementIdlePublicationIfNeeded()

        // Match OC's callback node exactly: every did-end-scrolling-animation callback records its
        // time after delegate forwarding. `gestureRecognizerShouldBegin` consumes it once.
        runtime.transition.lastSystemAnimationEndTimestamp = Date().timeIntervalSince1970
    }

    // MARK: Scroll-to-top

    public func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        let transactionEpoch = runtime.transition.nextTransactionID
        let activeTransactionBeforeProvider = runtime.transition.activeTransaction
        let driverBeforeProvider = runtime.transition.driver
        let providerState = decisionStateToken()
        let shouldScroll = behaviorProvider?.dragScrollViewShouldScrollToTop(self) ?? true
        guard shouldScroll else { return false }
        let movementOwnerIsUnchanged: Bool
        if let activeTransactionBeforeProvider {
            movementOwnerIsUnchanged = runtime.transition.activeTransaction
                === activeTransactionBeforeProvider
                && runtime.transition.driver == driverBeforeProvider
        } else {
            movementOwnerIsUnchanged = runtime.transition.activeTransaction == nil
                && runtime.transition.driver == driverBeforeProvider
        }
        guard runtime.transition.nextTransactionID == transactionEpoch,
              movementOwnerIsUnchanged,
              decisionStateToken() == providerState,
              !runtime.transition.isUserDragLifecycleActive,
              panelView != nil,
              runtime.panel.hasCompletedLayout,
              runtime.transition.isPanelLayoutReady else {
            return false
        }

        let transaction = beginMovementTransaction(
            requestedDisplayHeight: displayHeight,
            reason: .scrollToTop,
            completion: nil
        )
        guard runtime.transition.activeTransaction === transaction else { return false }
        // Taking ownership can synchronously close native deceleration and its old capture. Resolve
        // the top target only afterward so the target and decision token belong to the final axis.
        reloadScrollMetrics()
        guard runtime.transition.activeTransaction === transaction,
              panelView != nil,
              runtime.panel.hasCompletedLayout,
              runtime.transition.isPanelLayoutReady else {
            if runtime.transition.activeTransaction === transaction {
                finishActiveMovement(
                    transactionID: transaction.id,
                    outcome: .cancelled,
                    finalDisplayHeight: displayHeightForCurrentGeometry
                )
            }
            return false
        }
        let targetState = decisionStateToken()
        let targetOffsetY = minimumOuterOffset
        let targetDisplayHeight = displayHeightForOuterOffset(targetOffsetY)
        guard targetOffsetY.isFinite, targetDisplayHeight.isFinite else {
            finishActiveMovement(
                transactionID: transaction.id,
                outcome: .cancelled,
                finalDisplayHeight: displayHeightForCurrentGeometry
            )
            return false
        }
        transaction.retargetRequest(to: targetDisplayHeight)
        transaction.announceResolvedTarget(targetDisplayHeight, on: self)
        guard runtime.transition.activeTransaction === transaction,
              decisionStateToken() == targetState else {
            if runtime.transition.activeTransaction === transaction {
                finishActiveMovement(
                    transactionID: transaction.id,
                    outcome: .cancelled,
                    finalDisplayHeight: displayHeightForCurrentGeometry
                )
            }
            return false
        }
        if CGPointEqualToPoint(
            contentOffset,
            CGPoint(x: contentOffset.x, y: targetOffsetY)
        ),
           !hasInFlightBoundsAnimation {
            armCaptureCleanupOwnership()
            finishCaptureAfterMovementIfNeeded(disposition: .settled)
            guard runtime.transition.activeTransaction === transaction else { return false }
            finishActiveMovement(
                transactionID: transaction.id,
                outcome: .completed,
                finalDisplayHeight: displayHeightForCurrentGeometry
            )
            return false
        }
        runtime.transition.driver = .scrollToTop
        runtime.transition.scrollToTopTargetOffsetY = targetOffsetY
        runtime.transition.scrollToTopSettlementMonitorTransactionID = nil
        runtime.transition.scrollToTopStartOffsetY = contentOffset.y
        runtime.transition.scrollToTopHasObservedProgress = false
        armCaptureCleanupOwnership()
        beginMonitoringScrollToTopSettlement(transactionID: transaction.id)
        return true
    }

    public func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        // UIKit supplies no identifier that can associate this callback with the current
        // scroll-to-top request. Settlement monitoring already started with the transaction and
        // uses only its observed target/progress, so a stale callback has no internal side effect.
        eventDelegate?.dragScrollViewDidScrollToTop(self)
        scheduleMovementIdlePublicationIfNeeded()
    }
}

@MainActor
private extension BODragScrollView {
    func transitionValueEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        if let comparison = activeScrollModel?.comparison {
            return comparison.isValueEqual(lhs, rhs)
        }
        return comparisonPolicy.isValueEqual(lhs, rhs)
    }

    var hasInFlightBoundsAnimation: Bool {
        guard let presentationOffsetY = layer.presentation()?.bounds.origin.y else {
            return false
        }
        return !transitionValueEqual(presentationOffsetY, layer.bounds.origin.y)
    }

    func movementCrossesParticipantSegment(
        in model: ScrollModel,
        from start: CGFloat,
        to end: CGFloat
    ) -> Bool {
        let lower = min(start, end)
        let upper = max(start, end)
        guard upper > lower else { return false }
        return model.segments.contains { segment in
            guard segment.isParticipantSegment else { return false }
            if segment.outerLength == 0 {
                return segment.outerStart >= lower && segment.outerStart <= upper
            }
            return segment.outerEnd > lower && segment.outerStart < upper
        }
    }
}

private extension BODragScrollMovementStyle {
    var isAutomatic: Bool {
        if case .automatic = self { return true }
        return false
    }

    var isViewAnimation: Bool {
        if case .viewAnimation = self { return true }
        return false
    }
}

private extension Optional where Wrapped == BODragScrollTransitionState.Driver {
    var isViewAnimation: Bool {
        if case .viewAnimation? = self { return true }
        return false
    }

    var isSystemAnimation: Bool {
        if case .systemAnimation? = self { return true }
        return false
    }

    var isScrollToTop: Bool {
        if case .scrollToTop? = self { return true }
        return false
    }

    var isSystemDriven: Bool {
        switch self {
        case .systemAnimation?, .dragDeceleration?, .scrollToTop?:
            return true
        default:
            return false
        }
    }

    var isAnimation: Bool {
        switch self {
        case .systemAnimation?, .viewAnimation?:
            return true
        default:
            return false
        }
    }
}

#endif
