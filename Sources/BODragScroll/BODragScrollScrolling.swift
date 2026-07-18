//
//  BODragScrollScrolling.swift
//  BODragScroll
//
//  Cached-model projection for every outer UIScrollView offset update.
//

#if canImport(UIKit)
import UIKit

private enum BODragScrollAdaptivePanelSide {
    case beforeParticipantBlock
    case afterParticipantBlock
}

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

        let nativeStateAtStart = nativeScrollState
        rebaseAdaptiveAxisForReturningDragIfNeeded(
            nativeIsDragging: nativeStateAtStart.isDragging
        )

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
            let resolvedGeometry = resolveScrollGeometry(
                at: contentOffset.y,
                model: model,
                session: session
            )
            guard runtime.capture.session === session,
                  runtime.capture.operationEpoch == captureOperationEpoch,
                  runtime.scrolling.callbackEpoch == callbackEpoch,
                  panelView === panelAtStart,
                  ensureCaptureSessionIsCurrentAndHierarchyValid(session) else { return }
            guard commitResolvedScrollGeometry(resolvedGeometry, session: session),
                  runtime.capture.session === session,
                  runtime.capture.operationEpoch == captureOperationEpoch,
                  runtime.scrolling.callbackEpoch == callbackEpoch,
                  panelView === panelAtStart,
                  ensureCaptureSessionIsCurrentAndHierarchyValid(session) else {
                // A participant's delegate may synchronously end or replace capture while its
                // projected contentOffset is written. The new owner already rebuilt its geometry.
                return
            }
            source = motionSource(for: resolvedGeometry, session: session)
            let actualDisplayHeight = displayHeightForCurrentGeometry
            newDisplayHeight = resolvedGeometry.height.publishedValue(
                actual: actualDisplayHeight,
                comparison: comparisonPolicy
            )
            overscroll = resolvedGeometry.overscroll
            // This sample is committed only after the complete model projection reached UIKit.
            // On the next callback the frame and participant offsets still describe this exact
            // outer coordinate, even though UIKit has already advanced the host contentOffset.
            session.axisPhase?.lastCommittedOuterOffsetY = contentOffset.y
        } else {
            applyPanelOnlyBounceConstraints()
            source = .panel
            newDisplayHeight = displayHeightForCurrentGeometry
            overscroll = hostOverscrollState(fallbackOwner: .panel)
        }

        if nativeStateAtStart.isTracking {
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
            // Those newer callbacks already own publication.
            return
        }
        publishScrollUpdate(displayHeight: newDisplayHeight, source: source)
    }
}

// MARK: - Adaptive free-panel axis phases

@MainActor
extension BODragScrollView {
    /// A new real drag has already interrupted the previous deceleration/animation driver. If the
    /// same clean free-panel capture is still valid, move only its automatic participant block to
    /// the currently rendered legal height. A tap-only touch never reaches this method.
    func rebaseAdaptiveAxisForNewDragIfNeeded() {
        guard let session = runtime.capture.session,
              let phase = session.axisPhase,
              phase.rebasePolicy == .continuousPanel,
              let location = adaptivePanelLocation(
                  for: phase,
                  at: contentOffset.y
              ) else { return }
        _ = rebaseAdaptiveAxis(
            session: session,
            phase: phase,
            referenceOuterOffsetY: contentOffset.y,
            legalPivot: location.legalOuterOffset
        )
    }

    /// O(1) gate for the same-drag direction-change case. The old axis itself records the useful
    /// history: a committed coordinate outside its participant block means the inner ranges were
    /// exhausted and the panel subsequently moved. Returning toward that block is the only point
    /// at which the automatic activation height must change.
    func rebaseAdaptiveAxisForReturningDragIfNeeded(nativeIsDragging: Bool) {
        guard nativeIsDragging,
              runtime.scrolling.mismatchDirection == 0,
              let session = runtime.capture.session,
              let phase = session.axisPhase,
              phase.rebasePolicy == .continuousPanel,
              !session.hasDeferredMetricsChange else { return }

        let previous = phase.lastCommittedOuterOffsetY
        let current = contentOffset.y
        guard previous.isFinite, current.isFinite else { return }
        let delta = current - previous
        guard delta != 0 else { return }
        guard let location = adaptivePanelLocation(for: phase, at: previous) else { return }
        switch location.side {
        case .beforeParticipantBlock:
            guard delta > 0 else { return }
        case .afterParticipantBlock:
            guard delta < 0 else { return }
        }

        _ = rebaseAdaptiveAxis(
            session: session,
            phase: phase,
            referenceOuterOffsetY: previous,
            legalPivot: location.legalOuterOffset
        )
    }

    /// Returns a target only when the model has an authoritative height. Participant segments
    /// carry one directly. Every composite axis also keeps its capture-time exact host endpoints,
    /// independently of whether its participant block is fixed or adaptive, so ordinary scrolling
    /// and capture rebuilds cannot publish a composite-arithmetic tail.
    func authoritativeDisplayHeight(
        for projection: Projection,
        session: BODragScrollCaptureSession
    ) -> CGFloat? {
        guard let authority = session.axisPhase?.endpointAuthority else { return nil }
        let displayRange = authority.displayHeightRange
        let minimum = authority.outerOffsetRange.lowerBound
        let maximum = authority.outerOffsetRange.upperBound
        guard projection.outerOffset.isFinite,
              minimum.isFinite,
              maximum.isFinite,
              minimum <= maximum else { return nil }

        if projection.outerOffset < minimum {
            guard case .participant = projection.activeOwner else { return nil }
            return displayRange.lowerBound
        }
        if projection.outerOffset > maximum {
            guard case .participant = projection.activeOwner else { return nil }
            return displayRange.upperBound
        }
        if projection.outerOffset <= minimum.nextUp {
            return displayRange.lowerBound
        }
        if projection.outerOffset >= maximum.nextDown {
            return displayRange.upperBound
        }
        return projection.authoritativeDisplayHeight
    }
}

@MainActor
private extension BODragScrollView {
    /// Replaces one adaptive mathematical phase after proving that the old and candidate phases
    /// describe the same already-rendered pivot. This function performs no UIKit write and invokes
    /// no provider or delegate; the caller's ordinary did-scroll pass applies the next coordinate.
    @discardableResult
    func rebaseAdaptiveAxis(
        session: BODragScrollCaptureSession,
        phase: BODragScrollCompositeAxisPhase,
        referenceOuterOffsetY: CGFloat,
        legalPivot: CGFloat
    ) -> Bool {
        let operationEpoch = runtime.capture.operationEpoch
        guard runtime.capture.session === session,
              captureSessionIsCurrentAndHierarchyValid(session),
              phase.rebasePolicy == .continuousPanel,
              !session.hasDeferredMetricsChange,
              runtime.scrolling.mismatchDirection == 0,
              referenceOuterOffsetY.isFinite,
              legalPivot.isFinite,
              bounds.height.isFinite,
              bounds.height > 0,
              phase.model.comparison.isValueEqual(
                  bounds.height,
                  phase.model.viewportHeight
              ),
              let panelView,
              let oldActivationHeight = phase.model.segments.first?.displayHeight else {
            return false
        }
        // Bounce is temporary geometry. Derive the new activation from the corresponding legal
        // boundary, then validate the candidate at the original raw (possibly overscrolled) pivot.
        guard let targetActivationHeight = adaptiveActivationHeight(
                  for: phase.model,
                  legalPivot: legalPivot,
                  endpointAuthority: phase.endpointAuthority
              ),
              targetActivationHeight != oldActivationHeight,
              let candidateModel = phase.model.rebasedAdaptiveParticipantAxis(
                  to: targetActivationHeight
              ) else {
            return false
        }

        let oldState = resolveScrollGeometry(
            at: referenceOuterOffsetY,
            model: phase.model,
            session: session
        )
        let candidateState = resolveScrollGeometry(
            at: referenceOuterOffsetY,
            model: candidateModel,
            session: session
        )
        guard adaptiveVisibleState(oldState, equals: candidateState, comparison: phase.model.comparison),
              phase.model.comparison.isValueEqual(
                  panelView.frame.minY,
                  oldState.panelOriginY
              ),
              phase.model.comparison.isValueEqual(
                  bounds.height
                    + referenceOuterOffsetY
                    - panelView.frame.minY,
                  oldState.height.value
              ),
              adaptiveParticipantGeometryMatches(
                  oldState.participantOffsets,
                  session: session,
                  comparison: phase.model.comparison
              ) else {
            return false
        }

        // No callback-bearing work occurred above. Recheck the complete owner token, advance the
        // model-operation epoch so any older calculation stack becomes stale, and atomically install
        // the new phase without changing capture/session/cleanup ownership.
        guard runtime.capture.operationEpoch == operationEpoch,
              runtime.capture.session === session,
              captureSessionIsCurrentAndHierarchyValid(session) else {
            return false
        }
        runtime.capture.operationEpoch &+= 1
        session.axisPhase = BODragScrollCompositeAxisPhase(
            model: candidateModel,
            rebasePolicy: phase.rebasePolicy,
            endpointAuthority: phase.endpointAuthority,
            lastCommittedOuterOffsetY: referenceOuterOffsetY
        )
        return true
    }

    /// Resolves only known host endpoints from the capture-time range. Intermediate panel heights
    /// remain the old model's real projection, while min/max arithmetic cannot be baked into a new
    /// phase as values such as `873.0000000000001`.
    func adaptiveActivationHeight(
        for model: ScrollModel,
        legalPivot: CGFloat,
        endpointAuthority: BODragScrollAxisEndpointAuthority
    ) -> CGFloat? {
        let displayRange = endpointAuthority.displayHeightRange
        let hostMinimum = endpointAuthority.outerOffsetRange.lowerBound
        let hostMaximum = endpointAuthority.outerOffsetRange.upperBound
        guard legalPivot.isFinite,
              hostMinimum.isFinite,
              hostMaximum.isFinite,
              hostMinimum <= hostMaximum else { return nil }

        if legalPivot <= hostMinimum.nextUp {
            return displayRange.lowerBound
        }
        if legalPivot >= hostMaximum.nextDown {
            return displayRange.upperBound
        }

        let projectedHeight = model.projection(at: legalPivot).displayHeight
        guard projectedHeight.isFinite,
              displayRange.contains(projectedHeight) else { return nil }
        return projectedHeight
    }

    /// Returns a legal pivot only after the panel has genuinely moved at least one physical pixel
    /// beyond the old participant block. Raw bounce distance is intentionally excluded here.
    func adaptivePanelLocation(
        for phase: BODragScrollCompositeAxisPhase,
        at outerOffsetY: CGFloat
    ) -> (side: BODragScrollAdaptivePanelSide, legalOuterOffset: CGFloat)? {
        let model = phase.model
        let minimumOuterOffset = phase.endpointAuthority.outerOffsetRange.lowerBound
        let maximumOuterOffset = phase.endpointAuthority.outerOffsetRange.upperBound
        guard outerOffsetY.isFinite,
              minimumOuterOffset.isFinite,
              maximumOuterOffset.isFinite,
              minimumOuterOffset <= maximumOuterOffset,
              let firstSegment = model.segments.first,
              let lastSegment = model.segments.last else { return nil }
        let legalOuterOffset = min(
            maximumOuterOffset,
            max(minimumOuterOffset, outerOffsetY)
        )
        let onePixel = model.comparison.boundaryBand
        let beforeThreshold = firstSegment.outerStart - onePixel
        let afterThreshold = lastSegment.outerEnd + onePixel
        guard beforeThreshold.isFinite, afterThreshold.isFinite else { return nil }
        // Compare against shifted boundaries instead of subtracting two large coordinates. At the
        // exact one-pixel boundary this avoids cancellation. UIKit can read that exact coordinate
        // back at its adjacent representable value, so accept that single ULP and nothing wider;
        // every meaningful value strictly inside the one-pixel scene band remains inside.
        if legalOuterOffset <= beforeThreshold.nextUp {
            return (.beforeParticipantBlock, legalOuterOffset)
        }
        if legalOuterOffset >= afterThreshold.nextDown {
            return (.afterParticipantBlock, legalOuterOffset)
        }
        return nil
    }

    func adaptiveVisibleState(
        _ lhs: ResolvedScrollGeometry,
        equals rhs: ResolvedScrollGeometry,
        comparison: ScrollComparisonPolicy
    ) -> Bool {
        guard comparison.isValueEqual(lhs.panelOriginY, rhs.panelOriginY),
              comparison.isValueEqual(
                  lhs.height.value,
                  rhs.height.value
              ),
              adaptiveOptionalValue(lhs.correctedOuterOffsetY, equals: rhs.correctedOuterOffsetY, comparison: comparison),
              adaptiveOverscroll(lhs.overscroll, equals: rhs.overscroll, comparison: comparison),
              lhs.participantOffsets.count == rhs.participantOffsets.count
        else { return false }

        return zip(lhs.participantOffsets, rhs.participantOffsets)
            .allSatisfy { left, right in
                left.participantID == right.participantID
                    && comparison.isValueEqual(left.contentOffset, right.contentOffset)
            }
    }

    func adaptiveParticipantGeometryMatches(
        _ participantOffsets: [ParticipantProjection],
        session: BODragScrollCaptureSession,
        comparison: ScrollComparisonPolicy
    ) -> Bool {
        participantOffsets.allSatisfy { expected in
            guard let actual = session.participant(with: expected.participantID)?
                .scrollView?.contentOffset.y else { return false }
            return comparison.isValueEqual(actual, expected.contentOffset)
        }
    }

    func adaptiveOptionalValue(
        _ lhs: CGFloat?,
        equals rhs: CGFloat?,
        comparison: ScrollComparisonPolicy
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (.some(let lhs), .some(let rhs)):
            return comparison.isValueEqual(lhs, rhs)
        default:
            return false
        }
    }

    func adaptiveOverscroll(
        _ lhs: BODragScrollOverscrollState?,
        equals rhs: BODragScrollOverscrollState?,
        comparison: ScrollComparisonPolicy
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (.some(let lhs), .some(let rhs)):
            return lhs.edge == rhs.edge
                && lhs.owner == rhs.owner
                && comparison.isValueEqual(lhs.boundaryOffset, rhs.boundaryOffset)
                && comparison.isValueEqual(lhs.distance, rhs.distance)
        default:
            return false
        }
    }
}

// MARK: - Deferred participant-metrics reconciliation

@MainActor
extension BODragScrollView {
    /// UIKit may synchronously clamp a participant offset when its content size shrinks, before the
    /// metrics KVO callback reaches the host. While a physical lifecycle still owns its captured
    /// metrics, restore only that participant from the current axis phase at the unchanged host
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
        let resolvedGeometry = resolveScrollGeometry(
            at: contentOffset.y,
            model: model,
            session: session
        )
        guard let participantProjection = resolvedGeometry.participantOffsets.first(where: {
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
    /// One ephemeral UIKit plan resolved from the pure model plus the current bounce policy.
    /// It is never persisted: the committed views remain the only source of rendered geometry.
    struct ResolvedScrollGeometry {
        let panelOriginY: CGFloat
        let height: ProjectedHeight
        let participantOffsets: [ParticipantProjection]
        let motionOwner: SegmentOwner
        let overscroll: BODragScrollOverscrollState?
        /// A clamp request for the host's ordinary did-scroll owner. Keeping it as data makes model
        /// projection reusable by metrics reconciliation without hidden host writes.
        let correctedOuterOffsetY: CGFloat?
    }

    func resolveScrollGeometry(
        at outerOffset: CGFloat,
        model: ScrollModel,
        session: BODragScrollCaptureSession
    ) -> ResolvedScrollGeometry {
        let minimum = minimumOuterOffset
        let maximum = maximumOuterOffset
        guard let primary = session.primaryParticipant?.scrollView else {
            let projection = model.projection(at: outerOffset)
            return resolvedScrollGeometry(
                from: projection,
                model: model,
                session: session,
                overscroll: hostOverscrollState(fallbackOwner: .panel)
            )
        }

        if outerOffset < minimum {
            let extensionDistance = minimum - outerOffset
            var base = model.projection(at: minimum)
            var prefersPanel = configuration.bounce.allowsPanelTopBounce
                && (configuration.bounce.preferredTopOwner == .panel || !primary.bounces)
            if configuration.bounce.forcesInnerTopBounce {
                prefersPanel = false
            }
            if !prefersPanel, !primary.bounces {
                return resolvedScrollGeometry(
                    from: base,
                    model: model,
                    session: session,
                    overscroll: nil,
                    correctedOuterOffsetY: minimum
                )
            }
            let owner: SegmentOwner
            if !prefersPanel {
                guard let primaryID = session.primaryParticipant?.id,
                      let index = base.participantOffsets.firstIndex(where: {
                          $0.participantID == primaryID
                      }) else {
                    // A malformed/stale model cannot safely allocate inner bounce. Fail closed at
                    // the legal host boundary instead of silently changing bounce ownership.
                    return resolvedScrollGeometry(
                        from: base,
                        model: model,
                        session: session,
                        overscroll: nil,
                        correctedOuterOffsetY: minimum
                    )
                }
                var offsets = base.participantOffsets
                let original = offsets[index]
                offsets[index] = ParticipantProjection(
                    participantID: primaryID,
                    contentOffset: original.contentOffset - extensionDistance
                )
                base = Projection(
                    outerOffset: outerOffset,
                    panelOriginY: base.panelOriginY - extensionDistance,
                    height: base.height,
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
                    panelOriginY: base.panelOriginY,
                    height: .geometric(base.displayHeight - extensionDistance),
                    activeOwner: .panel,
                    isParticipantScrolling: false,
                    participantOffsets: base.participantOffsets
                )
            }
            return resolvedScrollGeometry(
                from: base,
                model: model,
                session: session,
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
            let prefersPanel = configuration.bounce.allowsPanelBottomBounce
                && (configuration.bounce.preferredBottomOwner == .panel || !primary.bounces)
            if !prefersPanel, !primary.bounces {
                return resolvedScrollGeometry(
                    from: base,
                    model: model,
                    session: session,
                    overscroll: nil,
                    correctedOuterOffsetY: maximum
                )
            }
            let owner: SegmentOwner
            if !prefersPanel {
                guard let primaryID = session.primaryParticipant?.id,
                      let index = base.participantOffsets.firstIndex(where: {
                          $0.participantID == primaryID
                      }) else {
                    return resolvedScrollGeometry(
                        from: base,
                        model: model,
                        session: session,
                        overscroll: nil,
                        correctedOuterOffsetY: maximum
                    )
                }
                var offsets = base.participantOffsets
                let original = offsets[index]
                offsets[index] = ParticipantProjection(
                    participantID: primaryID,
                    contentOffset: original.contentOffset + extensionDistance
                )
                base = Projection(
                    outerOffset: outerOffset,
                    panelOriginY: base.panelOriginY + extensionDistance,
                    height: base.height,
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
                    panelOriginY: base.panelOriginY,
                    height: .geometric(base.displayHeight + extensionDistance),
                    activeOwner: .panel,
                    isParticipantScrolling: false,
                    participantOffsets: base.participantOffsets
                )
            }
            return resolvedScrollGeometry(
                from: base,
                model: model,
                session: session,
                overscroll: BODragScrollOverscrollState(
                    edge: .bottom,
                    owner: owner,
                    boundaryOffset: maximum,
                    distance: extensionDistance
                )
            )
        }

        let projection = model.projection(at: outerOffset)
        return resolvedScrollGeometry(
            from: projection,
            model: model,
            session: session,
            overscroll: nil
        )
    }

    func resolvedScrollGeometry(
        from projection: Projection,
        model: ScrollModel,
        session: BODragScrollCaptureSession,
        overscroll: BODragScrollOverscrollState?,
        correctedOuterOffsetY: CGFloat? = nil
    ) -> ResolvedScrollGeometry {
        let height = authoritativeDisplayHeight(for: projection, session: session)
            .map(ProjectedHeight.authoritative)
            ?? projection.height
        let committedOuterOffsetY = correctedOuterOffsetY ?? projection.outerOffset
        let panelOriginY = height.panelOriginY(
            viewportHeight: model.viewportHeight,
            outerOffsetY: committedOuterOffsetY,
            geometricFallback: projection.panelOriginY
        )
        let motionOwner = projection.isParticipantScrolling
            ? projection.activeOwner
            : .panel
        return ResolvedScrollGeometry(
            panelOriginY: panelOriginY,
            height: height,
            participantOffsets: projection.participantOffsets,
            motionOwner: motionOwner,
            overscroll: overscroll,
            correctedOuterOffsetY: correctedOuterOffsetY
        )
    }

    /// Commits one coherent scroll sample. Host-owned geometry is written atomically and the panel
    /// is submitted at most once; callback-bearing participant offsets are deliberately last.
    func commitResolvedScrollGeometry(
        _ geometry: ResolvedScrollGeometry,
        session: BODragScrollCaptureSession
    ) -> Bool {
        let captureOperationEpoch = runtime.capture.operationEpoch
        let scrollingCallbackEpoch = runtime.scrolling.callbackEpoch
        let panelAtStart = panelView
        var panelFrame = panelView?.frame ?? .zero
        panelFrame.origin.y = geometry.panelOriginY
        withInternalMutation {
            if let correctedOuterOffsetY = geometry.correctedOuterOffsetY {
                var correctedOffset = contentOffset
                correctedOffset.y = correctedOuterOffsetY
                setContentOffsetIfNeeded(correctedOffset)
            }
            setPanelFrame(panelFrame)
        }
        guard runtime.capture.session === session,
              runtime.capture.operationEpoch == captureOperationEpoch,
              runtime.scrolling.callbackEpoch == scrollingCallbackEpoch,
              panelView === panelAtStart,
              ensureCaptureSessionIsCurrentAndHierarchyValid(session) else { return false }

        applyParticipantOffsets(geometry.participantOffsets, session: session)
        return runtime.capture.session === session
            && runtime.capture.operationEpoch == captureOperationEpoch
            && runtime.scrolling.callbackEpoch == scrollingCallbackEpoch
            && panelView === panelAtStart
            && ensureCaptureSessionIsCurrentAndHierarchyValid(session)
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
        for geometry: ResolvedScrollGeometry,
        session: BODragScrollCaptureSession
    ) -> BODragScrollMotionSource {
        guard case .participant(let participantID) = geometry.motionOwner,
              let scrollView = session.participant(with: participantID)?.scrollView else {
            return .panel
        }
        return .participant(scrollView)
    }
}

// MARK: - Mismatch recovery

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

}

#endif
