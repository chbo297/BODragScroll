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
        let overscroll: BODragScrollOverscrollState?
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
            if let correctedOuterOffsetY = projected.correctedOuterOffsetY {
                var correctedOffset = contentOffset
                correctedOffset.y = correctedOuterOffsetY
                withInternalMutation { setContentOffsetIfNeeded(correctedOffset) }
                guard runtime.capture.session === session,
                      runtime.capture.operationEpoch == captureOperationEpoch,
                      runtime.scrolling.callbackEpoch == callbackEpoch,
                      panelView === panelAtStart,
                      ensureCaptureSessionIsCurrentAndHierarchyValid(session) else { return }
            }
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
            newDisplayHeight = displayHeightForCurrentGeometry
            overscroll = projected.overscroll
        } else {
            applyPanelOnlyBounceConstraints()
            source = .panel
            newDisplayHeight = displayHeightForCurrentGeometry
            overscroll = hostOverscrollState(fallbackOwner: .panel)
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

        runtime.scrolling.overscroll = overscroll

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

// MARK: - Deferred participant-metrics reconciliation

@MainActor
extension BODragScrollView {
    /// UIKit may synchronously clamp a participant offset when its content size shrinks, before the
    /// metrics KVO callback reaches the host. While a physical lifecycle still owns its touch-down
    /// model, restore only that participant from the model's projection at the unchanged host
    /// offset. This is not a rebuild or second physics path, and it does not rewrite the panel or
    /// unrelated participants.
    func restoreProjectionAfterDeferredParticipantMetricsChange(
        for participantID: ParticipantID,
        scrollView: UIScrollView,
        in session: BODragScrollCaptureSession
    ) {
        guard runtime.capture.session === session,
              captureSessionIsCurrentAndHierarchyValid(session),
              session.participant(with: participantID)?.scrollView === scrollView,
              let model = session.model else { return }
        let captureOperationEpoch = runtime.capture.operationEpoch
        let scrollingCallbackEpoch = runtime.scrolling.callbackEpoch
        let panelAtStart = panelView
        let projected = projectedState(
            at: contentOffset.y,
            model: model,
            session: session
        )
        guard let participantProjection = projected.projection.participantOffsets.first(where: {
            $0.participantID == participantID
        }) else { return }
        guard runtime.capture.session === session,
              runtime.capture.operationEpoch == captureOperationEpoch,
              runtime.scrolling.callbackEpoch == scrollingCallbackEpoch,
              panelView === panelAtStart,
              captureSessionIsCurrentAndHierarchyValid(session) else { return }
        var restoredOffset = scrollView.contentOffset
        restoredOffset.y = participantProjection.contentOffset
        // This setter can call client code; deliberately perform no host/session writes afterward.
        scrollView.setContentOffsetIfNeeded(restoredOffset)
    }
}

// MARK: - Host overscroll snapshot

@MainActor
extension BODragScrollView {
    /// Returns the host's current legal-axis extension without changing UIKit geometry.
    /// Arithmetic residue at a known endpoint is canonicalized only for this decision; the host's
    /// real contentOffset remains untouched.
    func hostOverscrollState(
        fallbackOwner: SegmentOwner? = nil
    ) -> BODragScrollOverscrollState? {
        let minimum = minimumOuterOffset
        let maximum = maximumOuterOffset
        guard minimum.isFinite, maximum.isFinite, contentOffset.y.isFinite else { return nil }
        let normalizedOffset = comparisonPolicy.snappingToNearestEndpoint(
            contentOffset.y,
            minimum,
            maximum
        )

        let edge: BODragScrollOverscrollEdge
        let boundary: CGFloat
        let distance: CGFloat
        if normalizedOffset < minimum {
            edge = .top
            boundary = minimum
            distance = minimum - normalizedOffset
        } else if normalizedOffset > maximum {
            edge = .bottom
            boundary = maximum
            distance = normalizedOffset - maximum
        } else {
            return nil
        }

        let cachedOwner = runtime.scrolling.overscroll.flatMap { cached -> SegmentOwner? in
            cached.edge == edge ? cached.owner : nil
        }
        let owner = cachedOwner ?? fallbackOwner ?? configuredOverscrollOwner(for: edge)
        return BODragScrollOverscrollState(
            edge: edge,
            owner: owner,
            boundaryOffset: boundary,
            distance: distance
        )
    }

    private func configuredOverscrollOwner(
        for edge: BODragScrollOverscrollEdge
    ) -> SegmentOwner {
        guard let participant = runtime.capture.session?.primaryParticipant,
              let scrollView = participant.scrollView,
              scrollView.bounces else {
            return .panel
        }

        switch edge {
        case .top:
            if configuration.bounce.forcesInnerTopBounce {
                return .participant(participant.id)
            }
            let panelOwns = configuration.bounce.allowsPanelTopBounce
                && configuration.bounce.preferredTopOwner == .panel
            return panelOwns ? .panel : .participant(participant.id)
        case .bottom:
            let panelOwns = configuration.bounce.allowsPanelBottomBounce
                && configuration.bounce.preferredBottomOwner == .panel
            return panelOwns ? .panel : .participant(participant.id)
        }
    }
}

// MARK: - Projection and bounce allocation

@MainActor
private extension BODragScrollView {
    struct ProjectedScrollState {
        var projection: Projection
        var panelTranslation: CGFloat
        var overscroll: BODragScrollOverscrollState?
        /// A clamp request for the host's ordinary did-scroll owner. Keeping it as data makes model
        /// projection reusable by metrics reconciliation without hidden host writes.
        var correctedOuterOffsetY: CGFloat? = nil
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
                panelTranslation: projection.panelTranslation,
                overscroll: hostOverscrollState(fallbackOwner: .panel)
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
                return ProjectedScrollState(
                    projection: base,
                    panelTranslation: panelTranslation,
                    overscroll: nil,
                    correctedOuterOffsetY: minimum
                )
            }
            let owner: SegmentOwner
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
                    fixedDisplayHeight: base.fixedDisplayHeight,
                    activeOwner: .participant(primaryID),
                    isParticipantScrolling: true,
                    participantOffsets: offsets
                )
                owner = .participant(primaryID)
            } else {
                owner = .panel
            }
            if prefersPanel {
                // Panel-owned bounce is outside the normal inner segment. It must not inherit the
                // boundary segment's fixed-height correction target, otherwise the first sub-pixel
                // part of the panel bounce would be pulled back to the inner height and then jump.
                base = Projection(
                    outerOffset: outerOffset,
                    panelTranslation: panelTranslation,
                    displayHeight: base.displayHeight - extensionDistance,
                    fixedDisplayHeight: nil,
                    activeOwner: .panel,
                    isParticipantScrolling: false,
                    participantOffsets: base.participantOffsets
                )
            }
            return ProjectedScrollState(
                projection: base,
                panelTranslation: panelTranslation,
                overscroll: BODragScrollOverscrollState(
                    edge: .top,
                    owner: owner,
                    boundaryOffset: minimum,
                    distance: extensionDistance
                )
            )
        }

        if outerOffset > maximum {
            let extensionDistance = outerOffset - maximum
            var base = model.projection(at: maximum)
            var panelTranslation = base.panelTranslation
            let prefersPanel = configuration.bounce.allowsPanelBottomBounce
                && (configuration.bounce.preferredBottomOwner == .panel || !primary.bounces)
            if !prefersPanel, !primary.bounces {
                return ProjectedScrollState(
                    projection: base,
                    panelTranslation: panelTranslation,
                    overscroll: nil,
                    correctedOuterOffsetY: maximum
                )
            }
            let owner: SegmentOwner
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
                    fixedDisplayHeight: base.fixedDisplayHeight,
                    activeOwner: .participant(primaryID),
                    isParticipantScrolling: true,
                    participantOffsets: offsets
                )
                owner = .participant(primaryID)
            } else {
                owner = .panel
            }
            if prefersPanel {
                // As at the top boundary, panel-owned overscroll changes the real display height;
                // only inner-owned bounce may retain the participant segment's fixed height.
                base = Projection(
                    outerOffset: outerOffset,
                    panelTranslation: panelTranslation,
                    displayHeight: base.displayHeight + extensionDistance,
                    fixedDisplayHeight: nil,
                    activeOwner: .panel,
                    isParticipantScrolling: false,
                    participantOffsets: base.participantOffsets
                )
            }
            return ProjectedScrollState(
                projection: base,
                panelTranslation: panelTranslation,
                overscroll: BODragScrollOverscrollState(
                    edge: .bottom,
                    owner: owner,
                    boundaryOffset: maximum,
                    distance: extensionDistance
                )
            )
        }

        let projection = model.projection(at: outerOffset)
        return ProjectedScrollState(
            projection: projection,
            panelTranslation: projection.panelTranslation,
            overscroll: nil
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
            if let fixedDisplayHeight = projection.fixedDisplayHeight {
                correctDisplayHeightResidual(to: fixedDisplayHeight)
            }
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
