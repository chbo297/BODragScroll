//
//  BODragScrollCapture.swift
//  BODragScroll
//
//  Responder-chain discovery, capture-session ownership, observation, and model construction.
//

#if canImport(UIKit)
import UIKit

// MARK: - Capture runtime

enum BODragScrollCaptureRebuildReason {
    case initialCapture
    case layout
    case observedMetrics
    case configuration
    case mismatchRecovery
    case explicitReload
}

private enum BODragScrollParticipantSegmentSource {
    case smart
    case specified
}

private struct BODragScrollParticipantSegmentBuild {
    let segments: [ParticipantSegmentSnapshot]
    let detentHeights: [CGFloat]
}

@MainActor
final class BODragScrollParticipant {
    let id: ParticipantID
    weak var scrollView: UIScrollView?
    var observations: [NSKeyValueObservation] = []
    var lastContentSize: CGSize

    init(id: ParticipantID, scrollView: UIScrollView) {
        self.id = id
        self.scrollView = scrollView
        self.lastContentSize = scrollView.contentSize
    }
}

@MainActor
final class BODragScrollCaptureSession {
    let id: UInt64
    var ownershipGeneration: UInt64
    let participantChain: [BODragScrollParticipant]
    let hierarchy: BODragScrollCaptureHierarchySnapshot
    var prioritiesByScrollViewID: [ObjectIdentifier: BODragScrollCapturePriority]
    weak var webView: UIView?
    var model: ScrollModel?

    init(
        id: UInt64,
        ownershipGeneration: UInt64,
        participantChain: [BODragScrollParticipant],
        hierarchy: BODragScrollCaptureHierarchySnapshot,
        prioritiesByScrollViewID: [ObjectIdentifier: BODragScrollCapturePriority],
        webView: UIView?
    ) {
        self.id = id
        self.ownershipGeneration = ownershipGeneration
        self.participantChain = participantChain
        self.hierarchy = hierarchy
        self.prioritiesByScrollViewID = prioritiesByScrollViewID
        self.webView = webView
    }

    var primaryParticipant: BODragScrollParticipant? { participantChain.first }

    func participant(with id: ParticipantID) -> BODragScrollParticipant? {
        participantChain.first { $0.id == id }
    }
}

@MainActor
final class BODragScrollCaptureState {
    var session: BODragScrollCaptureSession?
    let hostLeaseCleanup = BODragScrollHostLeaseCleanup()
    var nextSessionID: UInt64 = 1
    var nextOwnershipGeneration: UInt64 = 1
    var operationEpoch: UInt64 = 0
    var acquisitionSuspensionDepth = 0
    var isSuspendedForWindowTransition = false
#if DEBUG
    var allowsOffWindowCaptureForTesting = false
#endif
}

// MARK: - Public reload and shared capture façade

@MainActor
extension BODragScrollView {
    /// Re-snapshot the current participants and rebuild the composite scroll model.
    public func reloadScrollMetrics() {
        updateOuterInsetsPreservingOffset()
        rebuildCaptureSessionIfNeeded(reason: .explicitReload)
    }

    var activeScrollModel: ScrollModel? {
        guard let session = runtime.capture.session,
              captureSessionIsCurrentAndHierarchyValid(session) else { return nil }
        return session.model
    }

    var primaryParticipantScrollView: UIScrollView? {
        guard let session = runtime.capture.session,
              captureSessionIsCurrentAndHierarchyValid(session),
              let participant = session.primaryParticipant,
              let scrollView = participant.scrollView,
              scrollView.window != nil || window == nil else {
            return nil
        }
        return scrollView
    }

    var hasParticipantSegments: Bool {
        activeScrollModel?.segments.contains(where: \.isParticipantSegment) == true
    }

    var isWithinParticipantSegment: Bool {
        guard let model = activeScrollModel, !model.segments.isEmpty else { return false }
        let match = TargetSolver.locate(
            outerOffset: contentOffset.y,
            anchors: model.segments,
            accuracy: model.comparison.boundaryBand
        )
        return match.location == .inside && match.segment.isParticipantSegment
    }

    var lastMotionSource: BODragScrollMotionSource { runtime.drag.lastMotionSource }

    func scrollView(for participantID: ParticipantID) -> UIScrollView? {
        guard let session = runtime.capture.session,
              captureSessionIsCurrentAndHierarchyValid(session) else { return nil }
        return session.participant(with: participantID)?.scrollView
    }

    func capturePriority(for scrollView: UIScrollView) -> BODragScrollCapturePriority? {
        guard let session = runtime.capture.session,
              captureSessionIsCurrentAndHierarchyValid(session) else { return nil }
        return session.prioritiesByScrollViewID[ObjectIdentifier(scrollView)]
    }

    /// Pure identity query used by read-only façades and transition sampling. Cleanup is explicit
    /// at callback-safe capture/scroll boundaries so an innocent getter can never emit client code.
    func captureSessionIsCurrentAndHierarchyValid(
        _ session: BODragScrollCaptureSession
    ) -> Bool {
        runtime.capture.session === session && session.hierarchy.isValid()
    }

    /// Callback-bearing validation for explicit state-machine boundaries only.
    func ensureCaptureSessionIsCurrentAndHierarchyValid(
        _ session: BODragScrollCaptureSession
    ) -> Bool {
        guard runtime.capture.session === session else { return false }
        guard session.hierarchy.isValid() else {
            invalidateCaptureHierarchyIfNeeded(expectedSessionID: session.id)
            return false
        }
        return runtime.capture.session === session
    }

    func ensureCaptureHierarchyStateMatches(
        _ expectedSession: BODragScrollCaptureSession?
    ) -> Bool {
        guard let expectedSession else { return runtime.capture.session == nil }
        return ensureCaptureSessionIsCurrentAndHierarchyValid(expectedSession)
    }

    func invalidateCaptureHierarchyIfNeeded(expectedSessionID: UInt64) {
        guard let session = runtime.capture.session,
              session.id == expectedSessionID,
              !session.hierarchy.isValid() else { return }
        endCapture()
    }

    /// A lease acquirer has already detached this exact session's associations. Close it even if
    /// a restoration callback put the views back on their former path; a newer session/context is
    /// protected by both identity checks.
    func endCaptureSessionIfOwned(
        expectedSessionID: UInt64,
        hierarchy: BODragScrollCaptureHierarchySnapshot
    ) {
        guard let session = runtime.capture.session,
              session.id == expectedSessionID,
              session.hierarchy === hierarchy else { return }
        endCapture()
    }

    func hierarchy(of view: UIView) -> Int {
        var current: UIView? = view
        while let candidate = current {
            if candidate === self {
                return view === candidate ? 0 : 1
            }
            if candidate === primaryParticipantScrollView {
                return view === candidate ? 2 : 3
            }
            current = candidate.superview
        }
        return -1
    }
}

// MARK: - Candidate discovery

@MainActor
extension BODragScrollView {
    private struct CandidateScan {
        var candidates: [BODragScrollCaptureCandidate]
        var eligibleIDs: Set<ObjectIdentifier>
        var proposedPrimaryID: ObjectIdentifier?
        var webView: UIView?
    }

    /// Start or refresh a capture session from the deepest hit-tested view. Returns its containing Web view.
    @discardableResult
    func beginCapture(from touchedView: UIView) -> UIView? {
#if DEBUG
        let canCaptureWithoutWindow = runtime.capture.allowsOffWindowCaptureForTesting
#else
        let canCaptureWithoutWindow = false
#endif
        guard window != nil || canCaptureWithoutWindow else {
            return scanCandidates(from: touchedView, asksProvider: false).webView
        }
        guard runtime.capture.acquisitionSuspensionDepth == 0,
              !runtime.capture.isSuspendedForWindowTransition else {
            // Preserve the Web-view return contract without consulting client policy while capture
            // acquisition is explicitly suspended by teardown/replacement/window removal.
            return scanCandidates(from: touchedView, asksProvider: false).webView
        }
        let operationEpoch = advanceCaptureOperationEpoch()
        let scan = scanCandidates(from: touchedView, asksProvider: true)
        let webView = scan.webView

        guard isCurrentCaptureOperation(operationEpoch) else {
            return webView
        }

        if webView != nil, configuration.capture.disablesPanelInteractionInWebView {
            endCapture()
            return webView
        }

        var proposal = BODragScrollCaptureProposal(
            primaryCandidateID: scan.proposedPrimaryID,
            candidates: scan.candidates,
            webView: webView
        )
        // This is intentionally called for zero/one/many candidates and for a single candidate in WKWebView.
        behaviorProvider?.dragScrollView(self, adjustCaptureProposal: &proposal)

        guard isCurrentCaptureOperation(operationEpoch) else {
            return webView
        }

        guard let requestedPrimaryID = proposal.primaryCandidateID,
              scan.eligibleIDs.contains(requestedPrimaryID),
              let originalPrimary = scan.candidates.first(where: { $0.id == requestedPrimaryID }),
              proposal.candidates.contains(where: { $0.id == requestedPrimaryID }) else {
            endCapture()
            return webView
        }

        var proposedPriorities: [ObjectIdentifier: BODragScrollCapturePriority] = [:]
        for candidate in proposal.candidates {
            proposedPriorities[candidate.id] = candidate.priority
        }
        var priorities: [ObjectIdentifier: BODragScrollCapturePriority] = [:]
        for candidate in scan.candidates {
            priorities[candidate.id] = proposedPriorities[candidate.id] ?? candidate.priority
        }
        priorities[requestedPrimaryID] = .participant

        if configuration.capture.ignoresMultipleNestedWebScrollViews,
           let webView,
           capturedScrollViews(
               from: originalPrimary.scrollView,
               until: webView,
               includeStart: true,
               participatingOnly: false
           ).count >= 2 {
            endCapture()
            return webView
        }

        guard let primaryIndex = scan.candidates.firstIndex(where: { $0.id == requestedPrimaryID }) else {
            endCapture()
            return webView
        }

        var chainViews = [originalPrimary.scrollView]
        if primaryIndex + 1 < scan.candidates.count {
            for candidate in scan.candidates[(primaryIndex + 1)...] {
                guard candidate.isVerticallyScrollable,
                      priorities[candidate.id] == .participant else { continue }
                chainViews.append(candidate.scrollView)
            }
        }

        // Provider callbacks are arbitrary client code. Re-scan without consulting policy and
        // require the physical scroll-candidate chain used by the proposal to still be current.
        let stableScan = scanCandidates(from: touchedView, asksProvider: false)
        guard stableScan.candidates.map({ ObjectIdentifier($0.scrollView) })
                == scan.candidates.map({ ObjectIdentifier($0.scrollView) }),
              stableScan.webView === webView,
              let capturePanel = panelView else {
            endCapture()
            return webView
        }
        let hierarchy = BODragScrollCaptureHierarchySnapshot(
            host: self,
            panelView: capturePanel,
            participantChain: chainViews
        )
        guard hierarchy.isValid(expectedPrimary: chainViews.first) else {
            endCapture()
            return webView
        }

        if let existing = runtime.capture.session,
           existing.participantChain.compactMap(\.scrollView).map(ObjectIdentifier.init)
            == chainViews.map(ObjectIdentifier.init),
           existing.hierarchy.isValid(),
           existing.hierarchy.hasSameIdentity(as: hierarchy),
           existing.participantChain.allSatisfy({ participant in
               guard let scrollView = participant.scrollView else { return false }
               return BODragScrollUIScrollViewBridge.ownsCaptureLease(
                   for: scrollView,
                   host: self,
                   captureSessionID: existing.id
               )
           }) {
            existing.ownershipGeneration = runtime.capture.nextOwnershipGeneration
            runtime.capture.nextOwnershipGeneration &+= 1
            transitionCaptureOwnershipDidRefresh(to: existing)
            existing.prioritiesByScrollViewID = priorities
            existing.webView = webView
            rebuildCaptureSessionIfNeeded(reason: .initialCapture)
            return webView
        }

        // Keep this capture operation's epoch while replacing the old session. Teardown may emit a
        // display-height callback; if that callback starts a newer operation, do not install the
        // superseded session afterward.
        teardownCaptureSession()
        guard isCurrentCaptureOperation(operationEpoch) else {
            return webView
        }
        let sessionID = runtime.capture.nextSessionID
        runtime.capture.nextSessionID &+= 1
        let ownershipGeneration = runtime.capture.nextOwnershipGeneration
        runtime.capture.nextOwnershipGeneration &+= 1
        let participants = chainViews.enumerated().map { index, scrollView in
            BODragScrollParticipant(
                id: ParticipantID(rawValue: UInt64(index + 1)),
                scrollView: scrollView
            )
        }
        var leasedScrollViews: [UIScrollView] = []
        func rollbackLeases() {
            for leasedScrollView in leasedScrollViews.reversed() {
                BODragScrollUIScrollViewBridge.releaseCaptureLease(
                    for: leasedScrollView,
                    host: self,
                    captureSessionID: sessionID
                )
            }
        }
        for scrollView in chainViews {
            guard BODragScrollUIScrollViewBridge.acquireCaptureLease(
                for: scrollView,
                host: self,
                captureSessionID: sessionID,
                hierarchy: hierarchy
            ) else {
                rollbackLeases()
                return webView
            }
            leasedScrollViews.append(scrollView)
            guard isCurrentCaptureOperation(operationEpoch),
                  runtime.capture.session == nil,
                  hierarchy.isValid() else {
                // `scrollsToTop` is overridable/KVO-observable. Its setter may synchronously end
                // this operation or install a newer session while a lease is being acquired.
                rollbackLeases()
                return webView
            }
        }
        guard isCurrentCaptureOperation(operationEpoch),
              runtime.capture.session == nil,
              hierarchy.isValid() else {
            rollbackLeases()
            return webView
        }
        let session = BODragScrollCaptureSession(
            id: sessionID,
            ownershipGeneration: ownershipGeneration,
            participantChain: participants,
            hierarchy: hierarchy,
            prioritiesByScrollViewID: priorities,
            webView: webView
        )
        runtime.capture.session = session
        transitionCaptureOwnershipDidRefresh(to: session)
        runtime.capture.hostLeaseCleanup.register(
            scrollViews: leasedScrollViews,
            host: self,
            captureSessionID: sessionID
        )

        for participant in participants {
            observe(participant, sessionID: sessionID)
        }
        rebuildCaptureSessionIfNeeded(reason: .initialCapture)
        return webView
    }

    /// Read-only selection used by hit testing while inertia is being interrupted.
    func preferredParticipantScrollView(from view: UIView) -> UIScrollView? {
        let operationEpoch = runtime.capture.operationEpoch
        let scan = scanCandidates(from: view, asksProvider: true)
        guard isCurrentCaptureOperation(operationEpoch) else { return nil }
        guard let id = scan.proposedPrimaryID else { return nil }
        return scan.candidates.first(where: { $0.id == id })?.scrollView
    }

    func capturedScrollViews(
        from startView: UIView?,
        until endView: UIView?,
        includeStart: Bool,
        participatingOnly: Bool
    ) -> [UIScrollView] {
        guard let startView else { return [] }
        let endView = endView ?? panelView
        var result: [UIScrollView] = []
        var responder: UIResponder? = includeStart ? startView : startView.next

        while let current = responder, current !== endView, current !== self {
            if let scrollView = current as? UIScrollView,
               scrollView.isScrollEnabled,
               isVerticallyScrollable(scrollView) {
                if !participatingOnly || capturePriority(for: scrollView) == .participant {
                    result.append(scrollView)
                }
            }
            responder = current.next
        }
        return result
    }

    private func scanCandidates(from view: UIView, asksProvider: Bool) -> CandidateScan {
        var candidates: [BODragScrollCaptureCandidate] = []
        var eligibleIDs = Set<ObjectIdentifier>()
        var firstVerticallyScrollable: UIScrollView?
        var tallestFallback: UIScrollView?
        var webView: UIView?
        var depth = 0

        var responder: UIResponder? = view
        while let current = responder, current !== self {
            if webView == nil, let currentView = current as? UIView, isWebView(currentView) {
                webView = currentView
            }

            if let scrollView = current as? UIScrollView, scrollView.isScrollEnabled {
                let canCapture = !asksProvider
                    || behaviorProvider?.dragScrollView(self, canCapture: scrollView) != false
                let vertical = isVerticallyScrollable(scrollView)
                let horizontal = isHorizontallyScrollable(scrollView)
                var priority: BODragScrollCapturePriority = .systemDefault

                if canCapture {
                    eligibleIDs.insert(ObjectIdentifier(scrollView))
                    priority = .participant
                    if firstVerticallyScrollable == nil, vertical {
                        firstVerticallyScrollable = scrollView
                    } else if horizontal {
                        priority = .systemDefault
                    } else if tallestFallback == nil
                                || scrollView.frame.height > (tallestFallback?.frame.height ?? 0) {
                        tallestFallback = scrollView
                    }
                }

                candidates.append(
                    BODragScrollCaptureCandidate(
                        scrollView: scrollView,
                        hierarchyDepth: depth,
                        isVerticallyScrollable: vertical,
                        priority: priority
                    )
                )
                depth += 1
            }
            responder = current.next
        }

        let proposed = firstVerticallyScrollable ?? tallestFallback
        return CandidateScan(
            candidates: candidates,
            eligibleIDs: eligibleIDs,
            proposedPrimaryID: proposed.map(ObjectIdentifier.init),
            webView: webView
        )
    }

    private func isWebView(_ view: UIView) -> Bool {
        guard let webViewClass = NSClassFromString("WKWebView") else { return false }
        return view.isKind(of: webViewClass)
    }

    private func isVerticallyScrollable(_ scrollView: UIScrollView) -> Bool {
        let inset = scrollView.effectiveContentInset
        return scrollView.contentSize.height + inset.top + inset.bottom > scrollView.bounds.height
    }

    private func isHorizontallyScrollable(_ scrollView: UIScrollView) -> Bool {
        let inset = scrollView.effectiveContentInset
        return scrollView.contentSize.width + inset.left + inset.right > scrollView.bounds.width
    }
}

// MARK: - Capture lifetime and observation

@MainActor
extension BODragScrollView {
    func suspendCaptureAcquisition() {
        runtime.capture.acquisitionSuspensionDepth += 1
    }

    func resumeCaptureAcquisition() {
        runtime.capture.acquisitionSuspensionDepth = max(
            0,
            runtime.capture.acquisitionSuspensionDepth - 1
        )
    }

    func endCapture() {
        suspendCaptureAcquisition()
        defer { resumeCaptureAcquisition() }
        _ = advanceCaptureOperationEpoch()
        teardownCaptureSession()
    }

    @discardableResult
    private func advanceCaptureOperationEpoch() -> UInt64 {
        runtime.capture.operationEpoch &+= 1
        return runtime.capture.operationEpoch
    }

    private func isCurrentCaptureOperation(_ epoch: UInt64) -> Bool {
        runtime.capture.operationEpoch == epoch
    }

    private func teardownCaptureSession() {
        guard let session = runtime.capture.session else { return }
        let currentDisplayHeight = displayHeightForCurrentGeometry
        let panelHeight = panelView?.frame.height ?? 0
        var panelFrame = panelView?.frame ?? .zero
        panelFrame.origin.y = 0
        runtime.capture.session = nil
        session.model = nil

        if let primary = session.primaryParticipant?.scrollView {
            BODragScrollUIScrollViewBridge.unbind(
                primaryParticipant: primary,
                from: self,
                captureSessionID: session.id
            )
        }

        let teardownEpoch = runtime.capture.operationEpoch
        runtime.scrolling.mismatchDirection = 0
        // Restore one complete panel-only geometry before any callback-bearing participant or
        // `scrollsToTop` write. Client code must never observe a nil session with composite
        // contentSize/panel translation still installed.
        withInternalMutation {
            setContentInsetIfNeeded(calculatedOuterInsets(panelHeight: panelHeight))
            setContentSizeIfNeeded(CGSize(width: bounds.width, height: panelHeight))
            setPanelFrame(panelFrame)
            setContentOffsetIfNeeded(
                CGPoint(x: contentOffset.x, y: currentDisplayHeight - bounds.height)
            )
            decelerationRate = panelDecelerationRate
        }

        // Normalize while this session still owns each global lease, then release it. Restoring
        // `scrollsToTop` is callback-bearing; another host may acquire immediately afterward, so
        // the old host must perform no participant writes after release.
        for participant in session.participantChain {
            participant.observations.forEach { $0.invalidate() }
            participant.observations.removeAll()
            guard let scrollView = participant.scrollView else { continue }
            if session.hierarchy.isValid(),
               BODragScrollUIScrollViewBridge.ownsCaptureLease(
                for: scrollView,
                host: self,
                captureSessionID: session.id
            ) {
                normalizeBounceOffset(of: scrollView)
            }
            BODragScrollUIScrollViewBridge.releaseCaptureLease(
                for: scrollView,
                host: self,
                captureSessionID: session.id
            )
        }
        runtime.capture.hostLeaseCleanup.clear(captureSessionID: session.id)

        guard isCurrentCaptureOperation(teardownEpoch),
              runtime.capture.session == nil else { return }
        setDisplayHeight(displayHeightForCurrentGeometry, source: .panel)
    }

    private func normalizeBounceOffset(of scrollView: UIScrollView) {
        let inset = scrollView.effectiveContentInset
        guard inset.top.isFinite,
              inset.bottom.isFinite,
              scrollView.contentSize.height.isFinite,
              scrollView.bounds.height.isFinite,
              scrollView.contentOffset.x.isFinite,
              scrollView.contentOffset.y.isFinite else { return }
        let minimum = -inset.top
        let maximum = max(
            scrollView.contentSize.height + inset.bottom - scrollView.bounds.height,
            minimum
        )
        guard minimum.isFinite, maximum.isFinite else { return }
        var target = scrollView.contentOffset
        target.y = min(maximum, max(minimum, target.y))
        guard target != scrollView.contentOffset else { return }
        scrollView.setContentOffset(target, animated: false)
    }

    private func observe(_ participant: BODragScrollParticipant, sessionID: UInt64) {
        guard let scrollView = participant.scrollView else { return }
        let participantID = participant.id
        let size = scrollView.observe(\.contentSize, options: [.new]) { [weak self, weak scrollView] _, _ in
            DispatchQueue.main.async { [weak self, weak scrollView] in
                self?.participantMetricsDidChange(
                    scrollView,
                    participantID: participantID,
                    sessionID: sessionID,
                    contentSizeChange: true
                )
            }
        }
        let inset = scrollView.observe(\.contentInset, options: [.new]) { [weak self, weak scrollView] _, _ in
            DispatchQueue.main.async { [weak self, weak scrollView] in
                self?.participantMetricsDidChange(
                    scrollView,
                    participantID: participantID,
                    sessionID: sessionID,
                    contentSizeChange: false
                )
            }
        }
        let adjustedInset = scrollView.observe(\.adjustedContentInset, options: [.new]) {
            [weak self, weak scrollView] _, _ in
            DispatchQueue.main.async { [weak self, weak scrollView] in
                self?.participantMetricsDidChange(
                    scrollView,
                    participantID: participantID,
                    sessionID: sessionID,
                    contentSizeChange: false
                )
            }
        }
        participant.observations = [size, inset, adjustedInset]
    }

    private func participantMetricsDidChange(
        _ scrollView: UIScrollView?,
        participantID: ParticipantID,
        sessionID: UInt64,
        contentSizeChange: Bool
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self, weak scrollView] in
                self?.participantMetricsDidChange(
                    scrollView,
                    participantID: participantID,
                    sessionID: sessionID,
                    contentSizeChange: contentSizeChange
                )
            }
            return
        }
        guard !isInternallyMutating,
              let session = runtime.capture.session,
              session.id == sessionID,
              let participant = session.participant(with: participantID),
              participant.scrollView === scrollView,
              let scrollView else { return }

        if contentSizeChange, participant.lastContentSize == scrollView.contentSize {
            return
        }
        participant.lastContentSize = scrollView.contentSize
        rebuildCaptureSessionIfNeeded(reason: .observedMetrics)
    }
}

// MARK: - Model construction

@MainActor
extension BODragScrollView {
    func rebuildCaptureSessionIfNeeded(reason: BODragScrollCaptureRebuildReason) {
        let operationEpoch = advanceCaptureOperationEpoch()
        guard let session = runtime.capture.session else { return }
        guard let panelView,
              let primaryParticipant = session.primaryParticipant,
              let primaryScrollView = primaryParticipant.scrollView else {
            endCapture()
            return
        }
        guard ensureCaptureSessionIsCurrentAndHierarchyValid(session) else { return }

        guard bounds.height.isFinite, bounds.height > 0 else {
            clearCompositeModel(in: session)
            return
        }

        if configuration.handoff.mode == .innerFirst
            || (configuration.handoff.mode == .innerFirstAtBoundary
                && innerScrollCanConsume(primaryScrollView, gestureVelocityY: 0)) {
            deactivateCompositeModel(in: session)
            return
        }

        let currentDisplayHeight = displayHeightForCurrentGeometry
        let smartCaptureDetentHeights = detentHeightsForCapture(
            currentDisplayHeight: currentDisplayHeight
        )
        var segmentBuild = makeParticipantSegments(
            session: session,
            primary: primaryParticipant,
            currentDisplayHeight: currentDisplayHeight,
            smartDetentHeights: smartCaptureDetentHeights,
            forceCurrentActivation: runtime.scrolling.isForcingMismatchRecovery
        )
        var participantSegments = segmentBuild.segments
        var captureDetentHeights = segmentBuild.detentHeights
        guard isCurrentCaptureOperation(operationEpoch),
              runtime.capture.session === session,
              ensureCaptureSessionIsCurrentAndHierarchyValid(session) else {
            return
        }
        guard !participantSegments.isEmpty else {
            deactivateCompositeModel(in: session)
            return
        }

        var model = buildModel(
            session: session,
            detentHeights: captureDetentHeights,
            participantSegments: participantSegments
        )
        guard var builtModel = model else {
            deactivateCompositeModel(in: session)
            return
        }

        var state = compositeState(in: builtModel, session: session)
        var candidateOuterOffset = state.progress + currentDisplayHeight - bounds.height
        var candidateProjection = builtModel.projection(at: candidateOuterOffset)
        var compatible = state.isValidPrefix
            && projection(candidateProjection, matches: session)
            && builtModel.comparison.isJitterEqual(
                candidateProjection.displayHeight,
                currentDisplayHeight
            )

        if !compatible, configuration.handoff.offsetMismatch == .continueFromCurrentOffset {
            segmentBuild = makeParticipantSegments(
                session: session,
                primary: primaryParticipant,
                currentDisplayHeight: currentDisplayHeight,
                smartDetentHeights: smartCaptureDetentHeights,
                forceCurrentActivation: true
            )
            participantSegments = segmentBuild.segments
            captureDetentHeights = segmentBuild.detentHeights
            guard isCurrentCaptureOperation(operationEpoch),
                  runtime.capture.session === session,
                  ensureCaptureSessionIsCurrentAndHierarchyValid(session) else {
                return
            }
            model = buildModel(
                session: session,
                detentHeights: captureDetentHeights,
                participantSegments: participantSegments
            )
            if let continuationModel = model {
                builtModel = continuationModel
                state = compositeState(in: continuationModel, session: session)
                candidateOuterOffset = state.progress + currentDisplayHeight - bounds.height
                candidateProjection = continuationModel.projection(at: candidateOuterOffset)
                compatible = state.isValidPrefix
                    && projection(candidateProjection, matches: session)
            }
        }

        let shouldRestore = !compatible
            && configuration.handoff.offsetMismatch == .restoreToBoundary
        let shouldPreserveMismatch = !compatible && !shouldRestore
        if shouldRestore {
            candidateOuterOffset = currentDisplayHeight - bounds.height
            candidateProjection = builtModel.projection(at: candidateOuterOffset)
        }

        runtime.scrolling.mismatchDirection = shouldPreserveMismatch
            ? mismatchDirection(
                model: builtModel,
                session: session,
                expectedProjection: candidateProjection
            )
            : 0
        guard isCurrentCaptureOperation(operationEpoch),
              runtime.capture.session === session,
              ensureCaptureSessionIsCurrentAndHierarchyValid(session) else {
            return
        }
        session.model = builtModel

        let totalParticipantDistance = builtModel.segments.reduce(CGFloat.zero) {
            $0 + ($1.isParticipantSegment ? $1.outerLength : 0)
        }
        let compositeContentHeight = panelView.frame.height + totalParticipantDistance
        var compositeInsets = calculatedOuterInsets(panelHeight: panelView.frame.height)
        if let captureMinimumDisplayHeight = captureDetentHeights.first {
            // `forcesInnerTopBounce` makes the current exact detent the lower boundary for this
            // touch's composite axis. Keep the public detent list unchanged and restore its normal
            // inset when capture ends, matching the OC implementation's temporary attach-array.
            compositeInsets.top = bounds.height - captureMinimumDisplayHeight
        }
        if let firstSegment = builtModel.segments.first,
           let lastSegment = builtModel.segments.last {
            // Provider-defined participant activation heights may extend beyond panel detents.
            // Make every valid model coordinate physically reachable by the outer UIScrollView.
            compositeInsets.top = max(compositeInsets.top, -firstSegment.outerStart)
            compositeInsets.bottom = max(
                compositeInsets.bottom,
                lastSegment.outerEnd + bounds.height - compositeContentHeight
            )
        }
        var panelFrame = panelView.frame
        panelFrame.origin.y = shouldPreserveMismatch ? state.progress : candidateProjection.panelTranslation
        let finalOuterOffset = shouldPreserveMismatch
            ? state.progress + currentDisplayHeight - bounds.height
            : candidateOuterOffset

        withInternalMutation {
            setContentInsetIfNeeded(compositeInsets)
            setContentSizeIfNeeded(
                CGSize(
                    width: bounds.width,
                    height: compositeContentHeight
                )
            )
            setPanelFrame(panelFrame)
            setContentOffsetIfNeeded(CGPoint(x: contentOffset.x, y: finalOuterOffset))
        }
        guard isCurrentCaptureOperation(operationEpoch),
              runtime.capture.session === session,
              ensureCaptureSessionIsCurrentAndHierarchyValid(session) else { return }
        if !shouldPreserveMismatch {
            // Participant setters are callback-bearing and therefore intentionally outside the
            // host's internal-mutation scope. The epoch checks below discard this old rebuild if a
            // participant delegate starts a newer capture or movement.
            applyParticipantOffsets(candidateProjection, session: session)
        }

        guard isCurrentCaptureOperation(operationEpoch),
              runtime.capture.session === session,
              ensureCaptureSessionIsCurrentAndHierarchyValid(session) else {
            return
        }

        guard BODragScrollUIScrollViewBridge.bind(
            primaryParticipant: primaryScrollView,
            to: self,
            captureSessionID: session.id
        ) else {
            endCapture()
            return
        }
        setDisplayHeight(displayHeightForCurrentGeometry, source: .panel)
        _ = ensureCaptureSessionIsCurrentAndHierarchyValid(session)
    }

    private func deactivateCompositeModel(in session: BODragScrollCaptureSession) {
        clearCompositeModel(in: session)
        let currentHeight = displayHeightForCurrentGeometry
        var frame = panelView?.frame ?? .zero
        frame.origin.y = 0
        withInternalMutation {
            setContentInsetIfNeeded(
                calculatedOuterInsets(panelHeight: panelView?.frame.height ?? 0)
            )
            setContentSizeIfNeeded(
                CGSize(width: bounds.width, height: panelView?.frame.height ?? 0)
            )
            setPanelFrame(frame)
            setContentOffsetIfNeeded(CGPoint(x: contentOffset.x, y: currentHeight - bounds.height))
            decelerationRate = panelDecelerationRate
        }
        _ = ensureCaptureSessionIsCurrentAndHierarchyValid(session)
    }

    private func clearCompositeModel(in session: BODragScrollCaptureSession) {
        if let primary = session.primaryParticipant?.scrollView {
            BODragScrollUIScrollViewBridge.unbind(
                primaryParticipant: primary,
                from: self,
                captureSessionID: session.id
            )
        }
        session.model = nil
        runtime.scrolling.mismatchDirection = 0
    }

    private func buildModel(
        session: BODragScrollCaptureSession,
        detentHeights: [CGFloat],
        participantSegments: [ParticipantSegmentSnapshot]
    ) -> ScrollModel? {
        let snapshot = ScrollModelSnapshot(
            viewportHeight: bounds.height,
            displayScale: displayScale,
            detents: detentHeights.map(ScrollSourceScalar.native),
            participantOrder: session.participantChain.map(\.id),
            participantSegments: participantSegments
        )
        do {
            return try ScrollModelBuilder.build(from: snapshot)
        } catch {
            // Provider data and UIKit geometry are external inputs. Fail closed for this capture
            // pass instead of terminating a debug build; a later layout/KVO/reload pass retries.
            return nil
        }
    }

    private func makeParticipantSegments(
        session: BODragScrollCaptureSession,
        primary: BODragScrollParticipant,
        currentDisplayHeight: CGFloat,
        smartDetentHeights: [CGFloat],
        forceCurrentActivation: Bool
    ) -> BODragScrollParticipantSegmentBuild {
        func build(
            _ segments: [ParticipantSegmentSnapshot],
            source: BODragScrollParticipantSegmentSource
        ) -> BODragScrollParticipantSegmentBuild {
            BODragScrollParticipantSegmentBuild(
                segments: segments,
                detentHeights: source == .smart ? smartDetentHeights : runtimeDetentHeights
            )
        }

        guard let scrollView = primary.scrollView else {
            return build([], source: .smart)
        }
        let range = scrollableRange(of: scrollView)
        guard range.canParticipate else { return build([], source: .smart) }

        let explicit = forceCurrentActivation
            ? nil
            : explicitSegments(for: scrollView, participantID: primary.id, range: range)
        let source: BODragScrollParticipantSegmentSource
        if forceCurrentActivation {
            source = .smart
        } else if explicit != nil || configuration.handoff.innerScrollPlacement.isSpecifiedHeight {
            // The OC source builds both delegate-provided intervals and
            // `prefDragInnerScrollDisplayH` through `scinnerinfoar`. That path deliberately skips
            // the temporary force-bounce detent suffix used by its smart builder.
            source = .specified
        } else {
            source = .smart
        }
        if let explicit, explicit.count != 1 || session.participantChain.count == 1 {
            return build(explicit, source: source)
        }

        let displayScalar: ScrollSourceScalar
        if let explicit = explicit?.first {
            // The source combines a single explicit primary interval with every participating
            // ancestor. In that branch only the explicit display height is retained; the nested
            // chain contributes each scroll view's complete offset range.
            displayScalar = explicit.displayHeight
        } else {
            let activationHeight = forceCurrentActivation
                ? currentDisplayHeight
                : automaticActivationHeight(
                    for: scrollView,
                    currentDisplayHeight: currentDisplayHeight,
                    detentHeights: smartDetentHeights
                )
            displayScalar = ScrollSourceScalar.objectiveCNumber(activationHeight)
        }

        // The pure nested builder represents the real primary -> participating-ancestor chain and may split
        // the same ancestor before and after a descendant according to current geometry.
        let snapshots = nestedSnapshots(for: session)
        if snapshots.count == session.participantChain.count {
            do {
                let segments = try NestedParticipantBuilder.makeSegments(
                    chain: snapshots,
                    displayHeight: displayScalar,
                    comparison: comparisonPolicy
                )
                return build(segments, source: source)
            } catch {
                // UIKit can expose transient geometry while a hierarchy is being relaid out.
                // Preserve a valid primary-only model and retry on the next observed/layout pass.
            }
        }

        if let explicit {
            return build(explicit, source: source)
        }

        return build([
            ParticipantSegmentSnapshot(
                participantID: primary.id,
                displayHeight: displayScalar,
                innerStart: .native(range.minimum),
                innerEnd: .native(range.maximum)
            )
        ], source: source)
    }

    private func explicitSegments(
        for scrollView: UIScrollView,
        participantID: ParticipantID,
        range: (minimum: CGFloat, maximum: CGFloat, canParticipate: Bool)
    ) -> [ParticipantSegmentSnapshot]? {
        let providerOperationEpoch = runtime.capture.operationEpoch
        let providerSession = runtime.capture.session
        let providerState = decisionStateToken()
        let suppliedSegments = behaviorProvider?.dragScrollView(self, segmentsFor: scrollView)
        guard decisionStateToken() == providerState else {
            guard runtime.capture.operationEpoch == providerOperationEpoch,
                  runtime.capture.session === providerSession else {
                // The callback already installed/rebuilt newer capture state. Let the caller's
                // operation guard discard this older stack without tearing the new session down.
                return nil
            }
            // A synchronous provider mutated the exact hierarchy/metrics used to calculate `range`.
            // Fail this capture closed; a later layout/KVO/explicit reload can build a fresh model.
            endCapture()
            return nil
        }
        guard let supplied = suppliedSegments,
              !supplied.isEmpty else { return nil }

        var result: [ParticipantSegmentSnapshot] = []
        var previousDisplayHeight: CGFloat?
        var previousEnd: CGFloat?
        for (index, segment) in supplied.enumerated() {
            let displayHeight = CGFloat(Float(segment.displayHeight))
            let start = CGFloat(Float(
                segment.beginOffsetY ?? (index == 0 ? range.minimum : .nan)
            ))
            let end = CGFloat(Float(
                segment.endOffsetY ?? (index == supplied.count - 1 ? range.maximum : .nan)
            ))
            guard displayHeight.isFinite, start.isFinite, end.isFinite, end >= start else { continue }
            guard previousDisplayHeight.map({ displayHeight >= $0 }) ?? true,
                  previousEnd.map({ start >= $0 }) ?? true else { continue }

            result.append(
                ParticipantSegmentSnapshot(
                    participantID: participantID,
                    displayHeight: .native(displayHeight),
                    innerStart: .native(start),
                    innerEnd: .native(end)
                )
            )
            previousDisplayHeight = displayHeight
            previousEnd = end
        }
        // Invalid provider entries are ignored individually. If none survive, preserve the
        // protocol's nil/empty contract and fall back to automatic segment construction.
        return result.isEmpty ? nil : result
    }

    private func automaticActivationHeight(
        for scrollView: UIScrollView,
        currentDisplayHeight: CGFloat,
        detentHeights: [CGFloat]
    ) -> CGFloat {
        switch configuration.handoff.innerScrollPlacement {
        case .fromTouchedPosition:
            return currentDisplayHeight
        case .atDisplayHeight(let height):
            return height
        case .afterPanelFullyDisplayed:
            return detentForFullyDisplayed(scrollView, detentHeights: detentHeights)
                ?? maximumConfiguredDisplayHeight
        case .automatic:
            break
        }

        guard !detentHeights.isEmpty else { return currentDisplayHeight }
        let originY = panelOriginY(of: scrollView)
        let scrollHeight = max(scrollView.frame.height, 1)
        let minimumRatio = configuration.handoff.minimumInnerVisibilityRatio
        let startIndex = ScrollMath.sortedIndex(
            in: detentHeights.map(ScrollSourceScalar.native),
            value: currentDisplayHeight,
            nearby: false,
            ceil: true
        )

        for index in startIndex..<detentHeights.count {
            let detent = detentHeights[index]
            if (detent - originY) / scrollHeight >= minimumRatio {
                return detent
            }
        }

        let fullyVisibleHeight = originY + scrollHeight
        let lowerIndex = ScrollMath.sortedIndex(
            in: detentHeights.map(ScrollSourceScalar.native),
            value: fullyVisibleHeight,
            nearby: false,
            ceil: false
        )
        let fallback = detentHeights[lowerIndex]
        return (fallback - originY) / scrollHeight >= minimumRatio
            ? fallback
            : currentDisplayHeight
    }

    private func detentForFullyDisplayed(
        _ scrollView: UIScrollView,
        detentHeights: [CGFloat]
    ) -> CGFloat? {
        let requiredHeight = panelOriginY(of: scrollView) + scrollView.frame.height
        return detentHeights.first {
            $0 + comparisonPolicy.boundaryBand >= requiredHeight
        } ?? detentHeights.last
    }

    /// Mirrors the source's temporary `theattachar` suffix. This is an exact source-number
    /// decision: the one-physical-pixel comparison band is intentionally not used here.
    private func detentHeightsForCapture(currentDisplayHeight: CGFloat) -> [CGFloat] {
        let detents = runtimeDetentHeights
        guard configuration.bounce.forcesInnerTopBounce,
              detents.count > 1 else { return detents }

        let index = ScrollMath.sortedIndex(
            in: detents.map(ScrollSourceScalar.native),
            value: currentDisplayHeight,
            nearby: true,
            ceil: false
        )
        guard index > 0,
              detents.indices.contains(index),
              detents[index] == currentDisplayHeight else { return detents }
        return Array(detents[index...])
    }

    private func panelOriginY(of scrollView: UIScrollView) -> CGFloat {
        guard let panelView, scrollView !== panelView, let superview = scrollView.superview else {
            return 0
        }
        return panelView.convert(scrollView.frame, from: superview).minY
    }

    private func nestedSnapshots(for session: BODragScrollCaptureSession) -> [NestedParticipantSnapshot] {
        var result: [NestedParticipantSnapshot] = []
        for (index, participant) in session.participantChain.enumerated() {
            guard let scrollView = participant.scrollView else { return [] }
            let inset = scrollView.effectiveContentInset
            var childFrame: ClosedRange<CGFloat>?
            if index > 0,
               let child = session.participantChain[index - 1].scrollView,
               let childSuperview = child.superview {
                let converted = scrollView.convert(child.frame, from: childSuperview)
                let minimumY = converted.minY
                let maximumY = converted.maxY
                guard minimumY.isFinite,
                      maximumY.isFinite,
                      minimumY <= maximumY else {
                    // CGRect.null/NaN/infinity can otherwise trap while forming ClosedRange before
                    // the pure model gets an opportunity to reject transient UIKit geometry.
                    return []
                }
                childFrame = minimumY...maximumY
            }
            result.append(
                NestedParticipantSnapshot(
                    id: participant.id,
                    contentHeight: scrollView.contentSize.height,
                    viewportHeight: scrollView.bounds.height,
                    insetTop: inset.top,
                    insetBottom: inset.bottom,
                    contentOffset: scrollView.contentOffset.y,
                    childFrame: childFrame
                )
            )
        }
        return result
    }

    private func scrollableRange(
        of scrollView: UIScrollView
    ) -> (minimum: CGFloat, maximum: CGFloat, canParticipate: Bool) {
        let inset = scrollView.effectiveContentInset
        let minimum = -inset.top
        let maximum = max(
            scrollView.contentSize.height + inset.bottom - scrollView.bounds.height,
            minimum
        )
        return (
            minimum,
            maximum,
            maximum > minimum || (scrollView.bounces && scrollView.alwaysBounceVertical)
        )
    }

    private struct CompositeState {
        var progress: CGFloat
        var isValidPrefix: Bool
    }

    private func compositeState(
        in model: ScrollModel,
        session: BODragScrollCaptureSession
    ) -> CompositeState {
        let epsilon = model.comparison.jitterEpsilon
        let participantSegments = model.segments.filter(\.isParticipantSegment)
        guard !participantSegments.isEmpty else {
            return CompositeState(progress: 0, isValidPrefix: true)
        }

        // A nested ancestor may own one slice before its child and another after it. Validating
        // each future slice against its own `innerStart` is incorrect before the earlier prefix has
        // been consumed: the ancestor's one real contentOffset must still equal its first slice's
        // start. Invert candidate positions through the already-built model instead, then compare
        // the complete projected chain with UIKit's current offsets.
        var candidateOuterOffsets: [CGFloat] = []
        for segment in participantSegments {
            guard let id = segment.participantID,
                  let value = session.participant(with: id)?.scrollView?.contentOffset.y else {
                return CompositeState(progress: 0, isValidPrefix: false)
            }
            guard value >= segment.innerStart - epsilon,
                  value <= segment.innerEnd + epsilon else { continue }

            let clampedValue = min(segment.innerEnd, max(segment.innerStart, value))
            candidateOuterOffsets.append(
                segment.outerStart + clampedValue - segment.innerStart
            )
        }

        for candidateOuterOffset in candidateOuterOffsets {
            let candidate = model.projection(at: candidateOuterOffset)
            if projection(candidate, matches: session) {
                return CompositeState(
                    progress: candidate.panelTranslation,
                    isValidPrefix: true
                )
            }
        }

        // Preserve a useful monotonic fallback for offset-mismatch recovery. It intentionally does
        // not claim validity; restore/continue policy still decides how the incompatible external
        // state is reconciled.
        var progress: CGFloat = 0
        for segment in model.segments where segment.isParticipantSegment {
            guard let id = segment.participantID,
                  let value = session.participant(with: id)?.scrollView?.contentOffset.y else {
                return CompositeState(progress: progress, isValidPrefix: false)
            }
            if value >= segment.innerEnd - epsilon {
                progress += segment.innerLength
            } else if value > segment.innerStart + epsilon {
                progress += value - segment.innerStart
                break
            } else {
                break
            }
        }
        return CompositeState(progress: progress, isValidPrefix: false)
    }

    private func projection(
        _ projection: Projection,
        matches session: BODragScrollCaptureSession
    ) -> Bool {
        projection.participantOffsets.allSatisfy { projected in
            guard let current = session.participant(with: projected.participantID)?.scrollView?.contentOffset.y
            else { return false }
            return abs(current - projected.contentOffset) <= comparisonPolicy.jitterEpsilon
        }
    }

    private func mismatchDirection(
        model: ScrollModel,
        session: BODragScrollCaptureSession,
        expectedProjection: Projection
    ) -> Int {
        let epsilon = model.comparison.jitterEpsilon

        // Compare every participant with the projection at the preserved composite position. The
        // first segment may belong to an ancestor, so using the primary scroll view unconditionally
        // would choose the wrong recovery direction for a nested chain.
        for expected in expectedProjection.participantOffsets {
            guard let actual = session.participant(with: expected.participantID)?
                .scrollView?.contentOffset.y else { continue }
            if actual > expected.contentOffset + epsilon {
                return 1
            }
            if actual < expected.contentOffset - epsilon {
                return -1
            }
        }

        let displayDelta = displayHeightForCurrentGeometry - expectedProjection.displayHeight
        if displayDelta < -epsilon {
            return 1
        }
        if displayDelta > epsilon {
            return -1
        }

        // A non-prefix nested state can be incompatible even when its scalar totals happen to
        // cancel. Mark it as direction-agnostic so the first deliberate vertical drag rebuilds a
        // continuation model instead of leaving the capture permanently unresolved.
        return 3
    }

    func applyParticipantOffsets(_ projection: Projection, session: BODragScrollCaptureSession) {
        let operationEpoch = runtime.capture.operationEpoch
        let scrollingCallbackEpoch = runtime.scrolling.callbackEpoch
        for projected in projection.participantOffsets {
            guard runtime.capture.session === session,
                  runtime.capture.operationEpoch == operationEpoch,
                  runtime.scrolling.callbackEpoch == scrollingCallbackEpoch,
                  ensureCaptureSessionIsCurrentAndHierarchyValid(session) else { return }
            guard let scrollView = session.participant(with: projected.participantID)?.scrollView else { continue }
            if projected.participantID != session.primaryParticipant?.id,
               !scrollView.isScrollEnabled {
                continue
            }
            var offset = scrollView.contentOffset
            offset.y = projected.contentOffset
            scrollView.setContentOffsetIfNeeded(offset)
            guard runtime.capture.session === session,
                  runtime.capture.operationEpoch == operationEpoch,
                  runtime.scrolling.callbackEpoch == scrollingCallbackEpoch,
                  ensureCaptureSessionIsCurrentAndHierarchyValid(session) else { return }
        }
    }

    func innerScrollCanConsume(_ scrollView: UIScrollView, gestureVelocityY: CGFloat) -> Bool {
        let range = scrollableRange(of: scrollView)
        guard range.maximum > range.minimum else { return false }
        let current = scrollView.contentOffset.y
        if current < range.minimum || current > range.maximum {
            return true
        }
        if gestureVelocityY < 0 {
            return current < range.maximum
        }
        if gestureVelocityY > 0 {
            return current > range.minimum
        }
        return BODragScrollUIScrollViewBridge.nativeState(of: scrollView).isDecelerating
    }
}

#endif
