//
//  BODragScrollScrolling.swift
//  BODragScroll
//
//  Cached-model projection for every outer UIScrollView offset update.
//

#if canImport(UIKit)
import UIKit

@MainActor
extension BODragScrollView {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === self, !isInternallyMutating, panelView != nil else { return }

        runtime.scrolling.callbackEpoch &+= 1
        let callbackEpoch = runtime.scrolling.callbackEpoch

        if let session = runtime.capture.session,
           !ensureCaptureSessionIsCurrentAndHierarchyValid(session) {
            return
        }

        if !contentOffset.x.isFinite || !contentOffset.y.isFinite {
            guard bounds.height.isFinite,
                  let panelView,
                  panelView.frame.minY.isFinite,
                  displayHeight.isFinite else { return }
            let safeOffset = CGPoint(
                x: contentOffset.x.isFinite ? contentOffset.x : 0,
                y: displayHeight - bounds.height + panelView.frame.minY
            )
            guard safeOffset.y.isFinite else { return }
            withInternalMutation {
                setContentOffset(safeOffset, animated: false)
            }
            return
        }

        if recoverMismatchedCaptureIfNeeded() {
            return
        }

        if let session = runtime.capture.session,
           !ensureCaptureSessionIsCurrentAndHierarchyValid(session) {
            return
        }

        let panelAtStart = panelView
        let captureEpochAtStart = runtime.capture.operationEpoch
        let captureSessionAtStart = runtime.capture.session

        let source: BODragScrollMotionSource
        let newDisplayHeight: CGFloat
        if let session = runtime.capture.session,
           let model = session.model,
           captureSessionIsCurrentAndHierarchyValid(session) {
            let captureOperationEpoch = runtime.capture.operationEpoch
            let projected = projectedState(
                at: contentOffset.y,
                model: model,
                session: session
            )
            guard runtime.capture.session === session,
                  runtime.capture.operationEpoch == captureOperationEpoch,
                  runtime.scrolling.callbackEpoch == callbackEpoch,
                  panelView === panelAtStart,
                  ensureCaptureSessionIsCurrentAndHierarchyValid(session) else { return }
            apply(projected.projection, panelTranslation: projected.panelTranslation, session: session)
            guard runtime.capture.session === session,
                  runtime.capture.operationEpoch == captureOperationEpoch,
                  runtime.scrolling.callbackEpoch == callbackEpoch,
                  panelView === panelAtStart,
                  ensureCaptureSessionIsCurrentAndHierarchyValid(session) else {
                // A participant's delegate may synchronously end or replace capture while its
                // projected contentOffset is written. The new owner already rebuilt its geometry.
                return
            }
            source = motionSource(for: projected.projection, session: session)
            newDisplayHeight = bounds.height - ((panelView?.frame.minY ?? 0) - contentOffset.y)
        } else {
            applyPanelOnlyBounceConstraints()
            source = .panel
            newDisplayHeight = displayHeightForCurrentGeometry
        }

        if nativeScrollState.isTracking {
            withInternalMutation {
                switch source {
                case .participant:
                    decelerationRate = primaryParticipantScrollView?.decelerationRate
                        ?? panelDecelerationRate
                case .panel:
                    decelerationRate = panelDecelerationRate
                }
            }
        }

        guard runtime.scrolling.callbackEpoch == callbackEpoch,
              runtime.capture.operationEpoch == captureEpochAtStart,
              panelView === panelAtStart,
              ensureCaptureHierarchyStateMatches(captureSessionAtStart) else { return }

        if !(isPerformingViewTransition && configuration.movement.defersDisplayHeightUpdates) {
            setDisplayHeight(newDisplayHeight, source: source)
        }
        guard runtime.scrolling.callbackEpoch == callbackEpoch,
              runtime.capture.operationEpoch == captureEpochAtStart,
              panelView === panelAtStart,
              ensureCaptureHierarchyStateMatches(captureSessionAtStart) else {
            // `didChangeDisplayHeight` is synchronous and may move, recapture, or replace the panel.
            // Those newer callbacks already own publication and indicator state.
            return
        }
        publishScrollUpdate(displayHeight: newDisplayHeight, source: source)
        guard runtime.scrolling.callbackEpoch == callbackEpoch,
              runtime.capture.operationEpoch == captureEpochAtStart,
              panelView === panelAtStart,
              ensureCaptureHierarchyStateMatches(captureSessionAtStart) else { return }
        updateParticipantIndicatorIfNeeded(source: source)
    }
}

// MARK: - Projection and bounce allocation

@MainActor
private extension BODragScrollView {
    struct ProjectedScrollState {
        var projection: Projection
        var panelTranslation: CGFloat
    }

    func projectedState(
        at outerOffset: CGFloat,
        model: ScrollModel,
        session: BODragScrollCaptureSession
    ) -> ProjectedScrollState {
        let minimum = minimumOuterOffset
        let maximum = maximumOuterOffset
        guard let primary = session.primaryParticipant?.scrollView else {
            let projection = model.projection(at: outerOffset)
            return ProjectedScrollState(
                projection: projection,
                panelTranslation: projection.panelTranslation
            )
        }

        if outerOffset < minimum {
            let extensionDistance = minimum - outerOffset
            var base = model.projection(at: minimum)
            var panelTranslation = base.panelTranslation
            var prefersPanel = configuration.bounce.allowsPanelTopBounce
                && (configuration.bounce.preferredTopOwner == .panel || !primary.bounces)
            if configuration.bounce.forcesInnerTopBounce {
                prefersPanel = false
            }
            if !prefersPanel, !primary.bounces {
                var clampedOffset = contentOffset
                clampedOffset.y = minimum
                withInternalMutation { setContentOffsetIfNeeded(clampedOffset) }
                return ProjectedScrollState(
                    projection: base,
                    panelTranslation: panelTranslation
                )
            }
            if !prefersPanel,
               let primaryID = session.primaryParticipant?.id,
               let index = base.participantOffsets.firstIndex(where: {
                   $0.participantID == primaryID
               }) {
                var offsets = base.participantOffsets
                let original = offsets[index]
                offsets[index] = ParticipantProjection(
                    participantID: primaryID,
                    contentOffset: original.contentOffset - extensionDistance
                )
                panelTranslation -= extensionDistance
                base = Projection(
                    outerOffset: outerOffset,
                    panelTranslation: panelTranslation,
                    displayHeight: base.displayHeight,
                    activeOwner: .participant(primaryID),
                    isParticipantScrolling: true,
                    participantOffsets: offsets
                )
            }
            return ProjectedScrollState(projection: base, panelTranslation: panelTranslation)
        }

        if outerOffset > maximum {
            let extensionDistance = outerOffset - maximum
            var base = model.projection(at: maximum)
            var panelTranslation = base.panelTranslation
            let prefersPanel = configuration.bounce.allowsPanelBottomBounce
                && (configuration.bounce.preferredBottomOwner == .panel || !primary.bounces)
            if !prefersPanel, !primary.bounces {
                var clampedOffset = contentOffset
                clampedOffset.y = maximum
                withInternalMutation { setContentOffsetIfNeeded(clampedOffset) }
                return ProjectedScrollState(
                    projection: base,
                    panelTranslation: panelTranslation
                )
            }
            if !prefersPanel,
               let primaryID = session.primaryParticipant?.id,
               let index = base.participantOffsets.firstIndex(where: {
                   $0.participantID == primaryID
               }) {
                var offsets = base.participantOffsets
                let original = offsets[index]
                offsets[index] = ParticipantProjection(
                    participantID: primaryID,
                    contentOffset: original.contentOffset + extensionDistance
                )
                panelTranslation += extensionDistance
                base = Projection(
                    outerOffset: outerOffset,
                    panelTranslation: panelTranslation,
                    displayHeight: base.displayHeight,
                    activeOwner: .participant(primaryID),
                    isParticipantScrolling: true,
                    participantOffsets: offsets
                )
            }
            return ProjectedScrollState(projection: base, panelTranslation: panelTranslation)
        }

        let projection = model.projection(at: outerOffset)
        return ProjectedScrollState(
            projection: projection,
            panelTranslation: projection.panelTranslation
        )
    }

    func apply(
        _ projection: Projection,
        panelTranslation: CGFloat,
        session: BODragScrollCaptureSession
    ) {
        var panelFrame = panelView?.frame ?? .zero
        panelFrame.origin.y = panelTranslation
        // Keep only host-owned geometry under the host's delegate-suppression scope. Writing a
        // participant offset can synchronously call arbitrary client code, including a new host
        // movement whose own `scrollViewDidScroll` must not be swallowed by this older projection.
        withInternalMutation {
            setPanelFrame(panelFrame)
        }
        // Frame first, then participant offsets: some UIKit scroll subclasses correct their offset on layout.
        applyParticipantOffsets(projection, session: session)
    }

    func applyPanelOnlyBounceConstraints() {
        var panelFrame = panelView?.frame ?? .zero
        let offset = contentOffset.y
        if offset > maximumOuterOffset, !configuration.bounce.allowsPanelBottomBounce {
            panelFrame.origin.y = offset - maximumOuterOffset
        } else if offset < minimumOuterOffset, !configuration.bounce.allowsPanelTopBounce {
            panelFrame.origin.y = offset - minimumOuterOffset
        } else {
            panelFrame.origin.y = 0
        }
        withInternalMutation { setPanelFrame(panelFrame) }
    }

    func motionSource(
        for projection: Projection,
        session: BODragScrollCaptureSession
    ) -> BODragScrollMotionSource {
        guard projection.isParticipantScrolling,
              case .participant(let participantID) = projection.activeOwner,
              let scrollView = session.participant(with: participantID)?.scrollView else {
            return .panel
        }
        return .participant(scrollView)
    }
}

// MARK: - Mismatch recovery and indicator

@MainActor
private extension BODragScrollView {
    func recoverMismatchedCaptureIfNeeded() -> Bool {
        let direction = runtime.scrolling.mismatchDirection
        guard direction != 0, runtime.capture.session != nil else { return false }

        let velocityY = panGestureRecognizer.velocity(in: window).y
        let movingTowardRecovery: Bool
        if direction == 1 {
            movingTowardRecovery = velocityY > 0
        } else if direction == -1 {
            movingTowardRecovery = velocityY < 0
        } else {
            // Direction-agnostic mismatch (the OC implementation used the sentinel value 3).
            movingTowardRecovery = velocityY != 0
        }
        let projectionEnteredParticipant = activeScrollModel.map {
            $0.projection(at: contentOffset.y).isParticipantScrolling
        } ?? false
        guard movingTowardRecovery || projectionEnteredParticipant else { return false }

        runtime.scrolling.mismatchDirection = 0
        runtime.scrolling.isForcingMismatchRecovery = true
        rebuildCaptureSessionIfNeeded(reason: .mismatchRecovery)
        runtime.scrolling.isForcingMismatchRecovery = false
        return true
    }

    func updateParticipantIndicatorIfNeeded(source: BODragScrollMotionSource) {
        let isParticipant: Bool
        switch source {
        case .panel:
            isParticipant = false
        case .participant:
            isParticipant = true
        }

        defer { runtime.scrolling.lastPublishedParticipantScrolling = isParticipant }
        guard isParticipant,
              !runtime.scrolling.lastPublishedParticipantScrolling,
              nativeScrollState.isTracking,
              configuration.indicator.automaticallyShowsInnerIndicator,
              let primary = primaryParticipantScrollView,
              primary.showsVerticalScrollIndicator else { return }

        // Use public UIKit behavior instead of mutating private indicator subviews by width/tag.
        primary.flashScrollIndicators()
    }
}

#endif
