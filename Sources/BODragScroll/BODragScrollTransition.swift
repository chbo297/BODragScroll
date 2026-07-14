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
    var systemAnimationDidReceiveEndCallback = false
    var systemAnimationStartOffsetY: CGFloat?
    var systemAnimationHasObservedProgress = false
    var scrollToTopTargetOffsetY: CGFloat?
    var scrollToTopSettlementMonitorTransactionID: UInt64?
    var scrollToTopDidReceiveEndCallback = false
    var scrollToTopStartOffsetY: CGFloat?
    var scrollToTopHasObservedProgress = false

    var dragStartDisplayHeight: CGFloat?
    var dragDisplayHeightDidChange = false
    var forwardedDragLifecycleToParticipant = false
    weak var forwardedParticipant: UIScrollView?
    var lastSystemAnimationEndTimestamp: TimeInterval = 0
    var isUserDragLifecycleActive = false
    var isEmittingTerminalDragLifecycleCallback = false
    var movementsDeferredUntilDragEnds: [() -> Void] = []
    var isDrainingDragDeferredMovements = false
    var isAwaitingDidEndDecelerating = false
}

// MARK: - Programmatic movement

@MainActor
extension BODragScrollView {
    /// Move the panel to a display height. Every accepted request owns one completion-once transaction.
    /// The return value is the synchronously resolved height when execution starts immediately. If
    /// UIKit is inside an atomic layout/drag mutation, it is the accepted requested height; use the
    /// completion result for the eventual resolved/final height.
    @discardableResult
    public func move(
        toDisplayHeight requestedDisplayHeight: CGFloat,
        animated: Bool,
        options: BODragScrollMovementOptions = .init(),
        completion: ((BODragScrollMovementResult) -> Void)? = nil
    ) -> CGFloat {
        move(
            toDisplayHeight: requestedDisplayHeight,
            animated: animated,
            options: options,
            reason: .programmatic,
            completion: completion
        )
    }

    /// Internal entry used by accessibility and other typed movement sources.
    @discardableResult
    func move(
        toDisplayHeight requestedDisplayHeight: CGFloat,
        animated: Bool,
        options: BODragScrollMovementOptions = .init(),
        reason: BODragScrollMovementReason,
        completion: ((BODragScrollMovementResult) -> Void)? = nil
    ) -> CGFloat {
        if !runtime.transition.pendingLayoutInterruptions.isEmpty
            || runtime.transition.isCompletingLayoutInterruptions {
            runtime.transition.movementsDeferredUntilLayoutInterruptionEnds.append { [weak self] in
                _ = self?.move(
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
                _ = self?.move(
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
                _ = self?.move(
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

        guard !detentHeights.isEmpty else {
            let announcementState = decisionStateToken()
            transaction.announceResolvedTarget(displayHeight, on: self)
            guard runtime.transition.activeTransaction === transaction,
                  decisionStateToken() == announcementState else {
                if runtime.transition.activeTransaction === transaction {
                    finishActiveMovement(
                        transactionID: transaction.id,
                        outcome: .cancelled,
                        finalDisplayHeight: displayHeightForCurrentGeometry
                    )
                }
                return displayHeight
            }
            finishActiveMovement(
                transactionID: transaction.id,
                outcome: .completed,
                finalDisplayHeight: displayHeight
            )
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

    func abortUserDragLifecycleForRemoval() {
        let wasTrackingLifecycle = runtime.transition.isUserDragLifecycleActive
        let wasAwaitingDeceleration = runtime.transition.isAwaitingDidEndDecelerating
        let participant = runtime.transition.forwardedDragLifecycleToParticipant
            ? runtime.transition.forwardedParticipant
            : nil
        let captureOwnership = takeCaptureCleanupOwnership()

        runtime.transition.dragStartDisplayHeight = nil
        runtime.transition.dragDisplayHeightDidChange = false
        runtime.transition.isAwaitingDidEndDecelerating = false
        runtime.transition.isEmittingTerminalDragLifecycleCallback = false
        runtime.transition.forwardedDragLifecycleToParticipant = false
        runtime.transition.forwardedParticipant = nil

        // UIKit is not required to deliver the terminal delegate callbacks after removal. Close the
        // exact lifecycle we forwarded so participant delegates never remain logically dragging.
        if wasTrackingLifecycle {
            if let participant {
                participant.delegate?.scrollViewDidEndDragging?(
                    participant,
                    willDecelerate: false
                )
            }
            eventDelegate?.dragScrollViewDidEndDragging(self, willDecelerate: false)
        } else if wasAwaitingDeceleration {
            if let participant {
                participant.delegate?.scrollViewDidEndDecelerating?(participant)
            }
            eventDelegate?.dragScrollViewDidEndDecelerating(self)
        }
        finishCapture(ifOwnedBy: captureOwnership)
        finishDeferredControlInteraction()
        finishUserDragLifecycleAndRunDeferredMovements()
    }

    func finishDecelerationLifecycleCancelledByLayout(participant: UIScrollView?) {
        if let participant {
            participant.delegate?.scrollViewDidEndDecelerating?(participant)
        }
        eventDelegate?.dragScrollViewDidEndDecelerating(self)
        finishDeferredControlInteraction()
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

    /// Called by the display-height setter when a drag has traversed a distinct height, even if it
    /// later returns to its starting value before release.
    func transitionDidChangeDisplayHeightDuringDrag() {
        guard runtime.transition.dragStartDisplayHeight != nil else { return }
        runtime.transition.dragDisplayHeightDidChange = true
    }

    /// A same-gesture capture refresh remains owned by that drag. A capture created from a terminal
    /// callback is a newer intention and deliberately keeps its new generation instead.
    func transitionCaptureOwnershipDidRefresh(to session: BODragScrollCaptureSession) {
        guard runtime.transition.isUserDragLifecycleActive,
              !runtime.transition.isEmittingTerminalDragLifecycleCallback,
              runtime.transition.captureCleanupOwnership != nil,
              runtime.capture.session === session else { return }
        armCaptureCleanupOwnership()
    }

    var isPerformingViewTransition: Bool {
        runtime.transition.isViewAnimating
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

    func finishCapture(ifOwnedBy ownership: BODragScrollCaptureCleanupOwnership?) {
        guard let ownership,
              runtime.capture.session?.id == ownership.sessionID,
              runtime.capture.session?.ownershipGeneration
                == ownership.sessionOwnershipGeneration else { return }
        endCapture()
    }

    func beginMovementTransaction(
        requestedDisplayHeight: CGFloat,
        reason: BODragScrollMovementReason,
        completion: ((BODragScrollMovementResult) -> Void)?
    ) -> BODragScrollMovementTransaction {
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
            // Finishing the interrupted transaction can synchronously enqueue and start a newer
            // movement. Only this replacement may destructively stop native motion; lifecycle
            // pairing below still belongs to the cancelled drag and must happen exactly once.
            if runtime.transition.activeTransaction === transaction {
                runtime.transition.driver = nil
                runtime.transition.systemAnimationTransactionID = nil
                runtime.transition.systemAnimationTargetOffsetY = nil
                runtime.transition.systemAnimationSettlementMonitorTransactionID = nil
                runtime.transition.systemAnimationDidReceiveEndCallback = false
                runtime.transition.systemAnimationStartOffsetY = nil
                runtime.transition.systemAnimationHasObservedProgress = false
                runtime.transition.scrollToTopTargetOffsetY = nil
                runtime.transition.scrollToTopSettlementMonitorTransactionID = nil
                runtime.transition.scrollToTopDidReceiveEndCallback = false
                runtime.transition.scrollToTopStartOffsetY = nil
                runtime.transition.scrollToTopHasObservedProgress = false
                withInternalMutation {
                    setContentOffset(contentOffset, animated: false)
                }
            }
            runtime.transition.isEmittingTerminalDragLifecycleCallback = true
            if let participantToFinish {
                participantToFinish.delegate?.scrollViewDidEndDecelerating?(
                    participantToFinish
                )
            }
            eventDelegate?.dragScrollViewDidEndDecelerating(self)
            finishDeferredControlInteraction()
            finishUserDragLifecycleAndRunDeferredMovements()
            runtime.transition.isEmittingTerminalDragLifecycleCallback = false
        }
        finishCapture(ifOwnedBy: captureOwnership)
        return transaction
    }

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
        } else if targetOuterOffset > maximumOuterOffset,
                  !configuration.bounce.allowsPanelBottomBounce {
            targetOuterOffset = maximumOuterOffset
        }

        let resolvedDisplayHeight = bounds.height + targetOuterOffset
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
            finishActiveMovement(
                transactionID: transaction.id,
                outcome: .completed,
                finalDisplayHeight: displayHeightForCurrentGeometry
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
            runtime.transition.driver = .systemAnimation
            runtime.transition.systemAnimationTransactionID = transaction.id
            runtime.transition.systemAnimationTargetOffsetY = targetContentOffset.y
            runtime.transition.systemAnimationSettlementMonitorTransactionID = nil
            runtime.transition.systemAnimationDidReceiveEndCallback = false
            runtime.transition.systemAnimationStartOffsetY = contentOffset.y
            runtime.transition.systemAnimationHasObservedProgress = false
            setContentOffset(targetContentOffset, animated: true)
            beginMonitoringSystemAnimationSettlement(transactionID: transaction.id)
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
                guard let self else { return }
                guard self.runtime.transition.activeTransaction?.id == transactionID else { return }
                self.runtime.transition.isViewAnimating = false
                self.reloadScrollMetrics()
                guard self.runtime.transition.activeTransaction?.id == transactionID else { return }
                self.finishCaptureAfterMovementIfNeeded()
                guard self.runtime.transition.activeTransaction?.id == transactionID else { return }
                self.finishActiveMovement(
                    transactionID: transactionID,
                    outcome: finished ? .completed : .interrupted,
                    finalDisplayHeight: self.displayHeightForCurrentGeometry
                )
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
                guard self.comparisonPolicy.isJitterEqual(
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
                self.transitionJitterEqual(self.contentOffset.y, $0)
            } ?? false
            if let startOffsetY = self.runtime.transition.systemAnimationStartOffsetY,
               !self.transitionJitterEqual(self.contentOffset.y, startOffsetY) {
                self.runtime.transition.systemAnimationHasObservedProgress = true
            }
            let maySettleInterrupted = self.runtime.transition.systemAnimationDidReceiveEndCallback
                || self.runtime.transition.systemAnimationHasObservedProgress

            if nextStableSampleCount >= 3,
               reachedTarget || maySettleInterrupted {
                self.runtime.transition.systemAnimationSettlementMonitorTransactionID = nil
                self.finishCaptureAfterMovementIfNeeded()
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
                self.transitionJitterEqual(self.contentOffset.y, $0)
            } ?? false
            if let startOffsetY = self.runtime.transition.scrollToTopStartOffsetY,
               !self.transitionJitterEqual(self.contentOffset.y, startOffsetY) {
                self.runtime.transition.scrollToTopHasObservedProgress = true
            }
            let maySettleInterrupted = self.runtime.transition.scrollToTopDidReceiveEndCallback
                || self.runtime.transition.scrollToTopHasObservedProgress

            if nextStableSampleCount >= 3,
               reachedTarget || maySettleInterrupted {
                self.runtime.transition.scrollToTopSettlementMonitorTransactionID = nil
                self.finishCaptureAfterMovementIfNeeded()
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
        let driver = runtime.transition.driver
        runtime.transition.driver = nil
        runtime.transition.systemAnimationTransactionID = nil
        runtime.transition.systemAnimationTargetOffsetY = nil
        runtime.transition.systemAnimationSettlementMonitorTransactionID = nil
        runtime.transition.systemAnimationDidReceiveEndCallback = false
        runtime.transition.systemAnimationStartOffsetY = nil
        runtime.transition.systemAnimationHasObservedProgress = false
        runtime.transition.scrollToTopTargetOffsetY = nil
        runtime.transition.scrollToTopSettlementMonitorTransactionID = nil
        runtime.transition.scrollToTopDidReceiveEndCallback = false
        runtime.transition.scrollToTopStartOffsetY = nil
        runtime.transition.scrollToTopHasObservedProgress = false
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
            runtime.transition.isViewAnimating = false
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
        guard let transaction = runtime.transition.activeTransaction else {
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
            let driver = runtime.transition.driver
            runtime.transition.driver = nil
            runtime.transition.systemAnimationTransactionID = nil
            runtime.transition.systemAnimationTargetOffsetY = nil
            runtime.transition.systemAnimationSettlementMonitorTransactionID = nil
            runtime.transition.systemAnimationDidReceiveEndCallback = false
            runtime.transition.systemAnimationStartOffsetY = nil
            runtime.transition.systemAnimationHasObservedProgress = false
            runtime.transition.scrollToTopTargetOffsetY = nil
            runtime.transition.scrollToTopSettlementMonitorTransactionID = nil
            runtime.transition.scrollToTopDidReceiveEndCallback = false
            runtime.transition.scrollToTopStartOffsetY = nil
            runtime.transition.scrollToTopHasObservedProgress = false

            if driver.isViewAnimation {
                let visibleOffset = layer.presentation()?.bounds.origin ?? contentOffset
                layer.removeAllAnimations()
                panelView?.layer.removeAllAnimations()
                runtime.transition.isViewAnimating = false
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
                    reloadScrollMetrics()
                    setDisplayHeight(displayHeightForCurrentGeometry, source: .panel)
                }
            } else if driver.isSystemDriven {
                setContentOffset(contentOffset, animated: false)
            }

            transaction.finish(
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
        runtime.transition.driver = nil
        runtime.transition.systemAnimationTransactionID = nil
        runtime.transition.systemAnimationTargetOffsetY = nil
        runtime.transition.systemAnimationSettlementMonitorTransactionID = nil
        runtime.transition.systemAnimationDidReceiveEndCallback = false
        runtime.transition.systemAnimationStartOffsetY = nil
        runtime.transition.systemAnimationHasObservedProgress = false
        runtime.transition.scrollToTopTargetOffsetY = nil
        runtime.transition.scrollToTopSettlementMonitorTransactionID = nil
        runtime.transition.scrollToTopDidReceiveEndCallback = false
        runtime.transition.scrollToTopStartOffsetY = nil
        runtime.transition.scrollToTopHasObservedProgress = false
        runtime.transition.isViewAnimating = false
        let verifiedOutcome: BODragScrollMovementOutcome
        if outcome == .completed,
           let resolvedDisplayHeight = transaction.resolvedDisplayHeight,
           !comparisonPolicy.isJitterEqual(resolvedDisplayHeight, finalDisplayHeight) {
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

    func finishCaptureAfterMovementIfNeeded() {
        finishCapture(ifOwnedBy: takeCaptureCleanupOwnership())
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

        reloadScrollMetrics()
        guard runtime.transition.nextTransactionID == resolutionEpoch,
              runtime.transition.activeTransaction == nil else {
            return supersededTarget()
        }
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

        return ResolvedReleaseTarget(
            contentOffset: target,
            displayHeight: finalProjection.displayHeight,
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
        guard !model.comparison.isJitterEqual(delegateTarget.y, originalInnerTarget) else {
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
        defer { runtime.transition.isDrainingDragDeferredMovements = false }
        while !runtime.transition.isUserDragLifecycleActive,
              !runtime.transition.movementsDeferredUntilDragEnds.isEmpty {
            let action = runtime.transition.movementsDeferredUntilDragEnds.removeFirst()
            action()
        }
    }

}

// MARK: - UIScrollViewDelegate settlement lifecycle

@MainActor
extension BODragScrollView: UIScrollViewDelegate {
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // The new touch owns the synchronous callback window, including any synthetic completion
        // of the previous deceleration. Callback-originated movements therefore wait until this
        // tracking lifecycle ends instead of tearing down the capture needed by the new drag.
        runtime.transition.isUserDragLifecycleActive = true
        if runtime.transition.isAwaitingDidEndDecelerating {
            // A new touch can cancel native deceleration before UIKit delivers its terminal
            // callback. Pair the previously forwarded lifecycle now, then transfer capture
            // ownership to the new drag below.
            let previousParticipant = runtime.transition.forwardedDragLifecycleToParticipant
                ? runtime.transition.forwardedParticipant
                : nil
            runtime.transition.isAwaitingDidEndDecelerating = false
            runtime.transition.forwardedDragLifecycleToParticipant = false
            runtime.transition.forwardedParticipant = nil
            runtime.transition.isEmittingTerminalDragLifecycleCallback = true
            if let previousParticipant {
                previousParticipant.delegate?.scrollViewDidEndDecelerating?(previousParticipant)
            }
            eventDelegate?.dragScrollViewDidEndDecelerating(self)
            finishDeferredControlInteraction()
            runtime.transition.isEmittingTerminalDragLifecycleCallback = false
        }
        cancelPendingTouchCompletionSettlement()
        interruptRunningMovement(outcome: .interrupted)
        runtime.transition.dragStartDisplayHeight = displayHeight
        runtime.transition.dragDisplayHeightDidChange = false
        armCaptureCleanupOwnership()
        let forwardedParticipant = hasParticipantSegments ? primaryParticipantScrollView : nil
        runtime.transition.forwardedParticipant = forwardedParticipant
        runtime.transition.forwardedDragLifecycleToParticipant = forwardedParticipant != nil

        if let participant = forwardedParticipant {
            participant.delegate?.scrollViewWillBeginDragging?(participant)
        }
        eventDelegate?.dragScrollViewWillBeginDragging(self)
        reloadScrollMetrics()
    }

    public func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
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
            runtime.transition.dragStartDisplayHeight = nil
            runtime.transition.dragDisplayHeightDidChange = false
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
            runtime.transition.dragStartDisplayHeight = nil
            runtime.transition.dragDisplayHeightDidChange = false
            targetContentOffset.pointee = contentOffset
            return
        }

        let willDecelerate = !transitionJitterEqual(
            resolved.contentOffset.y,
            contentOffset.y
        )
        let startDisplayHeight = runtime.transition.dragStartDisplayHeight ?? displayHeight
        let shouldEmitMovement = runtime.transition.dragDisplayHeightDidChange
            || !transitionJitterEqual(resolved.displayHeight, startDisplayHeight)

        runtime.transition.dragStartDisplayHeight = nil
        runtime.transition.dragDisplayHeightDidChange = false

        guard shouldEmitMovement else { return }

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

    public func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        // Deferral protects only the synchronous tracking lifecycle. Once did-end returns, a
        // programmatic movement is authoritative and may interrupt native deceleration immediately.
        defer {
            runtime.transition.isEmittingTerminalDragLifecycleCallback = false
            finishUserDragLifecycleAndRunDeferredMovements()
        }
        if decelerate, runtime.transition.driver == .dragWithoutDeceleration {
            // UIKit's actual lifecycle result is authoritative when its prediction differs from
            // our jitter-band estimate in willEndDragging.
            runtime.transition.driver = .dragDeceleration
        }
        let finishingTransactionID = runtime.transition.activeTransaction?.id
        let finishingDriver = runtime.transition.driver
        let finishesWithoutDeceleration = !decelerate && !finishingDriver.isAnimation
        let captureOwnership = finishesWithoutDeceleration
            ? takeCaptureCleanupOwnership()
            : nil

        let participant = runtime.transition.forwardedDragLifecycleToParticipant
            ? runtime.transition.forwardedParticipant
            : nil
        runtime.transition.isAwaitingDidEndDecelerating = decelerate
        if !decelerate {
            runtime.transition.forwardedDragLifecycleToParticipant = false
            runtime.transition.forwardedParticipant = nil
        }

        runtime.transition.isEmittingTerminalDragLifecycleCallback = true
        if let participant {
            participant.delegate?.scrollViewDidEndDragging?(
                participant,
                willDecelerate: decelerate
            )
        }
        eventDelegate?.dragScrollViewDidEndDragging(self, willDecelerate: decelerate)
        finishDeferredControlInteraction()

        // End only the session captured by this drag. A callback above may have installed a newer
        // capture, which must survive the older UIKit lifecycle.
        finishCapture(ifOwnedBy: captureOwnership)

        guard runtime.transition.activeTransaction?.id == finishingTransactionID,
              runtime.transition.driver == finishingDriver else {
            return
        }
        if finishesWithoutDeceleration {
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
              !nativeState.isTracking,
              !nativeState.isDecelerating else { return }
        defer {
            runtime.transition.isEmittingTerminalDragLifecycleCallback = false
            finishUserDragLifecycleAndRunDeferredMovements()
        }
        let finishingTransactionID = runtime.transition.activeTransaction?.id
        let finishingDriver = runtime.transition.driver
        let captureOwnership = takeCaptureCleanupOwnership()
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

        finishCapture(ifOwnedBy: captureOwnership)

        guard runtime.transition.activeTransaction?.id == finishingTransactionID,
              runtime.transition.driver == finishingDriver else {
            return
        }
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
        runtime.transition.lastSystemAnimationEndTimestamp = Date().timeIntervalSince1970

        if runtime.transition.driver.isSystemAnimation,
           let transactionID = runtime.transition.activeTransaction?.id,
           runtime.transition.systemAnimationTransactionID == transactionID {
            runtime.transition.systemAnimationDidReceiveEndCallback = true
            beginMonitoringSystemAnimationSettlement(transactionID: transactionID)
        }
        eventDelegate?.dragScrollViewDidEndScrollingAnimation(self)
    }

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
            finishCaptureAfterMovementIfNeeded()
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
        runtime.transition.scrollToTopDidReceiveEndCallback = false
        runtime.transition.scrollToTopStartOffsetY = contentOffset.y
        runtime.transition.scrollToTopHasObservedProgress = false
        armCaptureCleanupOwnership()
        beginMonitoringScrollToTopSettlement(transactionID: transaction.id)
        return true
    }

    public func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        if runtime.transition.driver.isScrollToTop,
           let transactionID = runtime.transition.activeTransaction?.id {
            runtime.transition.scrollToTopDidReceiveEndCallback = true
            beginMonitoringScrollToTopSettlement(transactionID: transactionID)
        }
        eventDelegate?.dragScrollViewDidScrollToTop(self)
    }
}

@MainActor
private extension BODragScrollView {
    func transitionJitterEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        if let comparison = activeScrollModel?.comparison {
            return comparison.isJitterEqual(lhs, rhs)
        }
        return comparisonPolicy.isJitterEqual(lhs, rhs)
    }

    var hasInFlightBoundsAnimation: Bool {
        guard let presentationOffsetY = layer.presentation()?.bounds.origin.y else {
            return false
        }
        return !transitionJitterEqual(presentationOffsetY, layer.bounds.origin.y)
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
