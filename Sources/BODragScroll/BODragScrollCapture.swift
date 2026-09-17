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

/// How participant geometry is released when a composite capture ends.
enum BODragScrollCaptureTeardownDisposition {
    /// Normal physics reached a legal endpoint. Only remove arithmetic residue at that endpoint.
    case settled
    /// External ownership/layout changed before physics settled. Restore a legal standalone offset.
    case forced
}

private enum BODragScrollParticipantSegmentSource {
    case smart
    case specified
}

private struct BODragScrollParticipantSegmentBuild {
    let segments: [ParticipantSegmentSnapshot]
    let detentHeights: [CGFloat]
    /// Captured with the segment source so later configuration changes cannot reinterpret the
    /// already-built axis or replace its exact free-panel endpoints.
    let proposedRebasePolicy: BODragScrollAxisRebasePolicy
}

/// Whether a captured composite axis has a business-fixed activation height or may move its
/// automatically generated participant block within the capture-time free-panel range.
enum BODragScrollAxisRebasePolicy: Equatable {
    case fixed
    case continuousPanel
}

/// Exact correspondence between the host's legal outer offsets and their model display heights.
/// Keeping both ranges together prevents a later configuration read or a partially rebuilt inset
/// from pairing one phase's offset boundary with another phase's height.
struct BODragScrollAxisEndpointAuthority: Equatable {
    let outerOffsetRange: ClosedRange<CGFloat>
    let displayHeightRange: ClosedRange<CGFloat>
}

/// One mathematical phase of a capture session. Its model and rebase policy are immutable; only
/// the last successfully committed outer sample advances between scroll callbacks. The participant
/// topology and metrics belong to the session, while an adaptive phase may be atomically replaced.
struct BODragScrollCompositeAxisPhase {
    let model: ScrollModel
    let rebasePolicy: BODragScrollAxisRebasePolicy
    /// Exact capture-time host endpoint correspondence. It is independent of whether this phase is
    /// allowed to rebase.
    let endpointAuthority: BODragScrollAxisEndpointAuthority
    var lastCommittedOuterOffsetY: CGFloat
}

@MainActor
final class BODragScrollParticipant {
    let id: ParticipantID
    weak var scrollView: UIScrollView?
    var observations: [NSKeyValueObservation] = []
    var lastContentSize: CGSize
    /// Participant metrics frozen into the most recent model build. UIKit does not report a
    /// KVO-reliable `bounds` change, so the scroll path compares against these values to notice a
    /// host-driven viewport resize inside one physical lifecycle.
    var capturedViewportHeight: CGFloat?
    /// Maximum legal inner offset implied by that same snapshot.
    var capturedInnerMaximum: CGFloat?

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
    var axisPhase: BODragScrollCompositeAxisPhase?
    /// Participant metrics changed while this physical lifecycle was using its capture snapshot.
    /// Adaptive phases may move an activation height, but never reinterpret these metrics; the
    /// next capture must build a fresh session.
    var hasDeferredMetricsChange = false

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

    var model: ScrollModel? { axisPhase?.model }

    func participant(with id: ParticipantID) -> BODragScrollParticipant? {
        participantChain.first { $0.id == id }
    }
}

@MainActor
final class BODragScrollCaptureState {
    var session: BODragScrollCaptureSession?
    /// The view whose touch encountered a dirty session while an older physical release still
    /// owned it. A tracking-only touch keeps the old model; an actual drag rebuilds from this view
    /// only after the old driver has been interrupted.
    weak var deferredTouchViewForFreshCapture: UIView?
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
        // 临时排查用日志（不要提交）：dropped=true 说明宿主这次 reload 被丢掉了，
        // 模型继续用按下瞬间的 viewportHeight/contentHeight 快照。
        let dropped = deferCaptureMetricsReloadIfPhysicalLifecycleIsActive()
        bodragJitterLog("reloadScrollMetrics", "dropped=\(dropped)")
        guard !dropped else { return }
        reloadCaptureMetrics(reason: .explicitReload)
    }

    /// Policy objects become visible immediately, while the active capture keeps its topology,
    /// metrics, and phase provenance. Returns whether the reload was applied synchronously.
    @discardableResult
    func reloadCaptureMetricsForConfigurationChange() -> Bool {
        // No dirty flag is needed here: unlike participant metrics, configuration changes never
        // require forced reconciliation. Keeping the current model is sufficient; teardown drops
        // it and the next capture/layout naturally reads the new policy.
        guard runtime.capture.session == nil || !captureModelIsOwnedByPhysicalLifecycle else {
            return false
        }
        reloadCaptureMetrics(reason: .configuration)
        return true
    }

    private func reloadCaptureMetrics(reason: BODragScrollCaptureRebuildReason) {
        updateOuterInsetsPreservingOffset()
        rebuildCaptureSessionIfNeeded(reason: reason)
    }

    @discardableResult
    func deferCaptureMetricsReloadIfPhysicalLifecycleIsActive() -> Bool {
        guard let session = runtime.capture.session else { return false }
        guard captureModelIsOwnedByPhysicalLifecycle else { return false }
        session.hasDeferredMetricsChange = true
        return true
    }

    /// Notices a host-driven viewport resize of a participant.
    ///
    /// `bounds` is not dependably KVO-observable on UIView, so the scroll path polls the frozen
    /// snapshot instead — two float comparisons per participant per sample. When a lifecycle owns
    /// the model the change is absorbed by `rebaseParticipantMetricsForLifecycle(_:)`; if that
    /// cannot express it, the session is marked dirty and the write-time pin keeps the participant
    /// inside its live range until teardown reconciles.
    ///
    /// Returns true when the axis was reloaded from scratch and the caller should abandon the
    /// current sample.
    @discardableResult
    func reconcileParticipantViewportChangeIfNeeded() -> Bool {
        guard let session = runtime.capture.session,
              session.model != nil,
              let resizedViewportHeight = resizedParticipantViewportHeight(in: session) else {
            return false
        }

        bodragJitterLog(
            "participantViewportDidChange",
            "live=\(BODragScrollJitterLog.number(resizedViewportHeight))"
                + " ownedByLifecycle=\(captureModelIsOwnedByPhysicalLifecycle)"
        )
        guard captureModelIsOwnedByPhysicalLifecycle else {
            reloadCaptureMetrics(reason: .observedMetrics)
            return true
        }
        if rebaseParticipantMetricsForLifecycle(session) {
            // The axis now describes the new metrics at the unchanged visible geometry, so this
            // sample continues on it instead of being dropped.
            return false
        }
        session.hasDeferredMetricsChange = true
        return false
    }

    /// The first participant whose live viewport no longer matches the frozen model snapshot.
    private func resizedParticipantViewportHeight(
        in session: BODragScrollCaptureSession
    ) -> CGFloat? {
        for participant in session.participantChain {
            guard let scrollView = participant.scrollView,
                  let capturedViewportHeight = participant.capturedViewportHeight else { continue }
            let live = scrollView.bounds.height
            guard live.isFinite, abs(live - capturedViewportHeight) > 0.5 else { continue }
            return live
        }
        return nil
    }

    /// Follows a participant metrics change inside one physical lifecycle without rebuilding the
    /// capture.
    ///
    /// Only the participants' remaining inner distance moves. The detent table, rebase policy and
    /// capture-time endpoint authority are carried over untouched, so detent settling, bounce
    /// ownership and mismatch recovery keep the semantics they were captured with — that is the
    /// difference from `rebuildCaptureSessionIfNeeded(reason:)`, which also re-derives the detent
    /// list, the routing provenance and the operation epoch and must therefore stay out of a live
    /// gesture.
    ///
    /// Returns false when the change cannot be expressed that way; the caller then falls back to the
    /// frozen ranges plus the write-time pin.
    @discardableResult
    func rebaseParticipantMetricsForLifecycle(_ session: BODragScrollCaptureSession) -> Bool {
        guard let phase = session.axisPhase,
              let panelView,
              captureSessionIsCurrentAndHierarchyValid(session),
              bounds.height.isFinite, bounds.height > 0 else { return false }

        // A bounce lives outside the legal axis; moving the axis length mid-flight would change the
        // amplitude UIKit is animating. Those frames are covered by the pin instead.
        guard runtime.scrolling.overscroll == nil,
              hostOverscrollState() == nil,
              runtime.scrolling.mismatchDirection == 0,
              !runtime.scrolling.isForcingMismatchRecovery else {
            bodragJitterLog("metricsRebase.skip", "reason=temporaryGeometry")
            return false
        }

        var innerEndDeltas: [ParticipantID: CGFloat] = [:]
        for participant in session.participantChain {
            guard let scrollView = participant.scrollView,
                  let capturedInnerMaximum = participant.capturedInnerMaximum else { return false }
            let liveInnerMaximum = scrollableRange(of: scrollView).maximum
            guard liveInnerMaximum.isFinite else { return false }
            guard !comparisonPolicy.isValueEqual(liveInnerMaximum, capturedInnerMaximum) else {
                continue
            }
            innerEndDeltas[participant.id] = liveInnerMaximum - capturedInnerMaximum
        }
        guard !innerEndDeltas.isEmpty else {
            // Viewport moved but the legal distance did not (content grew by the same amount).
            // Nothing to rebase; just re-baseline so later samples compare against live geometry.
            refreshCapturedParticipantMetrics(in: session)
            return true
        }
        guard let rebasedModel = phase.model.rebasedParticipantInnerDistances(
            shiftingInnerEndBy: innerEndDeltas
        ) else {
            bodragJitterLog("metricsRebase.skip", "reason=modelRefused")
            return false
        }

        // Preserve the visible geometry: invert the participants' current offsets through the new
        // axis, then require that projection to reproduce both them and the current display height.
        let currentDisplayHeight = displayHeightForCurrentGeometry
        let state = compositeState(in: rebasedModel, session: session)
        let rebasedOuterOffsetY = state.progress + currentDisplayHeight - bounds.height
        guard state.isValidPrefix, rebasedOuterOffsetY.isFinite else {
            bodragJitterLog("metricsRebase.skip", "reason=invalidPrefix")
            return false
        }
        let rebasedProjection = rebasedModel.projection(at: rebasedOuterOffsetY)
        guard projection(rebasedProjection, matches: session),
              rebasedModel.comparison.isValueEqual(
                  rebasedProjection.displayHeight,
                  currentDisplayHeight
              ) else {
            bodragJitterLog("metricsRebase.skip", "reason=geometryMismatch")
            return false
        }

        let participantDistance = rebasedModel.segments.reduce(CGFloat.zero) {
            $0 + ($1.isParticipantSegment ? $1.outerLength : 0)
        }
        let compositeContentHeight = panelView.frame.height + participantDistance
        guard compositeContentHeight.isFinite else { return false }

        session.axisPhase = BODragScrollCompositeAxisPhase(
            model: rebasedModel,
            rebasePolicy: phase.rebasePolicy,
            endpointAuthority: phase.endpointAuthority,
            lastCommittedOuterOffsetY: rebasedOuterOffsetY
        )
        withInternalMutation {
            setContentSizeIfNeeded(CGSize(width: bounds.width, height: compositeContentHeight))
            setContentOffsetIfNeeded(CGPoint(x: contentOffset.x, y: rebasedOuterOffsetY))
        }
        refreshCapturedParticipantMetrics(in: session)
        // The new metrics are part of the axis now, so teardown may settle normally.
        session.hasDeferredMetricsChange = false
        bodragJitterLog(
            "metricsRebase",
            "outer=\(BODragScrollJitterLog.number(rebasedOuterOffsetY))"
                + " display=\(BODragScrollJitterLog.number(currentDisplayHeight))"
                + " participantDistance=\(BODragScrollJitterLog.number(participantDistance))"
        )
        return true
    }

    /// Re-baselines the comparison values after the axis absorbed the current participant metrics.
    private func refreshCapturedParticipantMetrics(in session: BODragScrollCaptureSession) {
        for participant in session.participantChain {
            guard let scrollView = participant.scrollView else { continue }
            participant.capturedViewportHeight = scrollView.bounds.height
            participant.capturedInnerMaximum = scrollableRange(of: scrollView).maximum
        }
    }

    /// Pins a projected participant target to what that participant can physically reach while its
    /// viewport disagrees with the snapshot the frozen ranges were derived from.
    ///
    /// This is not a bounce guard: it only engages for a participant the host resized under an
    /// active lifecycle whose metrics change could not be rebased, where a projection past the live
    /// range is an expired target rather than a real overscroll. Teardown still reconciles the axis
    /// through `hasDeferredMetricsChange`.
    func pinnedParticipantOffset(
        _ target: CGFloat,
        of participant: BODragScrollParticipant
    ) -> CGFloat {
        guard let scrollView = participant.scrollView,
              let capturedViewportHeight = participant.capturedViewportHeight,
              abs(scrollView.bounds.height - capturedViewportHeight) > 0.5 else { return target }
        let range = scrollableRange(of: scrollView)
        guard range.minimum.isFinite, range.maximum.isFinite else { return target }
        let pinned = min(range.maximum, max(range.minimum, target))
        guard abs(pinned - target) > 0.5 else { return target }

        bodragJitterLog(
            "pinStaleParticipantTarget",
            "target=\(BODragScrollJitterLog.number(target))"
                + " pinned=\(BODragScrollJitterLog.number(pinned))"
                + " capturedViewport=\(BODragScrollJitterLog.number(capturedViewportHeight))"
                + " liveViewport=\(BODragScrollJitterLog.number(scrollView.bounds.height))"
        )
        return pinned
    }

    private var captureModelIsOwnedByPhysicalLifecycle: Bool {
        let nativeState = nativeScrollState
        return runtime.transition.isUserDragLifecycleActive
            || runtime.transition.driver != nil
            || runtime.transition.isAwaitingDidEndDecelerating
            || nativeState.isTracking
            || nativeState.isDecelerating
            || hostOverscrollState() != nil
    }

    /// Whether an existing session still owns the stable capture topology of this physical touch.
    /// Tracking alone is insufficient because it can also be the first touch of a new lifecycle;
    /// in the continuation case the exact cleanup token still names this session generation.
    private func physicalLifecycleStillOwnsExistingCapture(
        _ session: BODragScrollCaptureSession
    ) -> Bool {
        let nativeState = nativeScrollState
        let cleanupOwnership = runtime.transition.captureCleanupOwnership
        let trackingOwnsSession = nativeState.isTracking
            && cleanupOwnership?.sessionID == session.id
            && cleanupOwnership?.sessionOwnershipGeneration == session.ownershipGeneration
        return runtime.transition.isUserDragLifecycleActive
            || runtime.transition.driver != nil
            || runtime.transition.isAwaitingDidEndDecelerating
            || nativeState.isDecelerating
            || trackingOwnsSession
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
    func beginCapture(
        from touchedView: UIView,
        requiresFreshSession: Bool = false
    ) -> UIView? {
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
        let physicalSessionAtEntry: BODragScrollCaptureSession? = {
            guard !requiresFreshSession,
                  let session = runtime.capture.session,
                  session.hierarchy.isValid(),
                  physicalLifecycleStillOwnsExistingCapture(session) else { return nil }
            return session
        }()
        func deferPhysicalCaptureReplacementIfNeeded() -> Bool {
            guard let session = physicalSessionAtEntry,
                  runtime.capture.session === session,
                  session.hierarchy.isValid(),
                  physicalLifecycleStillOwnsExistingCapture(session) else { return false }
            // Touch-down may select another sibling chain, no participant, or a Web view. Keep the
            // old capture and its current axis phase until UIKit confirms a real drag; the
            // will-begin path then asks for a fresh session from this exact touched view. A tap-only
            // touch never swaps axes.
            runtime.capture.deferredTouchViewForFreshCapture = touchedView
            return true
        }
        let operationEpoch = advanceCaptureOperationEpoch()
        let scan = scanCandidates(from: touchedView, asksProvider: true)
        let webView = scan.webView

        guard isCurrentCaptureOperation(operationEpoch) else {
            return webView
        }

        if webView != nil, configuration.capture.disablesPanelInteractionInWebView {
            if !deferPhysicalCaptureReplacementIfNeeded() {
                endCapture()
            }
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
            if !deferPhysicalCaptureReplacementIfNeeded() {
                endCapture()
            }
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
            if !deferPhysicalCaptureReplacementIfNeeded() {
                endCapture()
            }
            return webView
        }

        guard let primaryIndex = scan.candidates.firstIndex(where: { $0.id == requestedPrimaryID }) else {
            if !deferPhysicalCaptureReplacementIfNeeded() {
                endCapture()
            }
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
            if !deferPhysicalCaptureReplacementIfNeeded() {
                endCapture()
            }
            return webView
        }
        let hierarchy = BODragScrollCaptureHierarchySnapshot(
            host: self,
            panelView: capturePanel,
            participantChain: chainViews
        )
        guard hierarchy.isValid(expectedPrimary: chainViews.first) else {
            if !deferPhysicalCaptureReplacementIfNeeded() {
                endCapture()
            }
            return webView
        }

        if !requiresFreshSession, let existing = runtime.capture.session {
            let physicalLifecycleStillOwnsCapture =
                physicalLifecycleStillOwnsExistingCapture(existing)
            if (!existing.hasDeferredMetricsChange || physicalLifecycleStillOwnsCapture),
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
                runtime.capture.deferredTouchViewForFreshCapture = existing.hasDeferredMetricsChange
                    ? touchedView
                    : nil
                // A touch that interrupts an in-flight movement is taking over the same physical
                // composite axis. Rebuilding from temporarily projected participant offsets would
                // reinterpret bounce/deceleration geometry as a new model and can fold overscroll
                // back to a boundary. A real drag explicitly requests a fresh dirty session after
                // it has interrupted the old driver in `scrollViewWillBeginDragging`.
                if !physicalLifecycleStillOwnsCapture {
                    rebuildCaptureSessionIfNeeded(reason: .initialCapture)
                }
                return webView
            }
        }

        if deferPhysicalCaptureReplacementIfNeeded() {
            return webView
        }

        // Keep this capture operation's epoch while replacing the old session. Teardown may emit a
        // display-height callback; if that callback starts a newer operation, do not install the
        // superseded session afterward.
        runtime.capture.deferredTouchViewForFreshCapture = nil
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

    func endCapture(
        disposition: BODragScrollCaptureTeardownDisposition = .forced
    ) {
        suspendCaptureAcquisition()
        defer { resumeCaptureAcquisition() }
        _ = advanceCaptureOperationEpoch()
        teardownCaptureSession(disposition: disposition)
    }

    @discardableResult
    private func advanceCaptureOperationEpoch() -> UInt64 {
        runtime.capture.operationEpoch &+= 1
        return runtime.capture.operationEpoch
    }

    private func isCurrentCaptureOperation(_ epoch: UInt64) -> Bool {
        runtime.capture.operationEpoch == epoch
    }

    private func teardownCaptureSession(
        disposition: BODragScrollCaptureTeardownDisposition = .forced
    ) {
        runtime.capture.deferredTouchViewForFreshCapture = nil
        guard let session = runtime.capture.session else { return }
        let hadCompositeModel = session.model != nil
        let effectiveDisposition: BODragScrollCaptureTeardownDisposition = session
            .hasDeferredMetricsChange ? .forced : disposition
        let currentDisplayHeight = displayHeightForCurrentGeometry
        let panelHeight = panelView?.frame.height ?? 0
        var panelFrame = panelView?.frame ?? .zero
        panelFrame.origin.y = 0
        runtime.capture.session = nil
        session.axisPhase = nil

        if let primary = session.primaryParticipant?.scrollView {
            BODragScrollUIScrollViewBridge.unbind(
                primaryParticipant: primary,
                from: self,
                captureSessionID: session.id
            )
        }

        let teardownEpoch = runtime.capture.operationEpoch
        runtime.scrolling.mismatchDirection = 0
        runtime.scrolling.overscroll = nil
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
            if hadCompositeModel,
               session.hierarchy.isValid(),
               BODragScrollUIScrollViewBridge.ownsCaptureLease(
                   for: scrollView,
                   host: self,
                   captureSessionID: session.id
               ) {
                reconcileParticipantOffset(
                    of: scrollView,
                    disposition: effectiveDisposition
                )
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
        guard isCurrentCaptureOperation(teardownEpoch),
              runtime.capture.session == nil else { return }
        if runtime.panel.defersConfigurationLayoutUntilCaptureEnds {
            runtime.panel.defersConfigurationLayoutUntilCaptureEnds = false
            setNeedsLayout()
        }
    }

    private func reconcileParticipantOffset(
        of scrollView: UIScrollView,
        disposition: BODragScrollCaptureTeardownDisposition
    ) {
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
        switch disposition {
        case .settled:
            // A normal terminal path must never hide a real bounce by synchronously clamping it.
            // UIKit/model arithmetic may leave an endpoint such as 600.0000000000001; only that
            // numeric residue is canonicalized before the participant resumes standalone ownership.
            if comparisonPolicy.isValueEqual(target.y, minimum) {
                target.y = minimum
            } else if comparisonPolicy.isValueEqual(target.y, maximum) {
                target.y = maximum
            } else {
                return
            }
        case .forced:
            target.y = min(maximum, max(minimum, target.y))
        }
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
        // 临时排查用日志（不要提交）：拖动中收到 metrics 变化只能走 deferred restore，
        // 模型里的 viewportHeight/contentHeight 仍是按下瞬间的快照。
        let willDefer = deferCaptureMetricsReloadIfPhysicalLifecycleIsActive()
        bodragJitterLog(
            "participantMetricsDidChange",
            "kind=\(contentSizeChange ? "contentSize" : "inset")"
                + " deferred=\(willDefer)"
                + " inner=[\(BODragScrollJitterLog.describe(scrollView))]"
        )
        if willDefer {
            // A metrics change that the axis can absorb keeps this lifecycle coherent instead of
            // pinning the participant to stale ranges until teardown.
            if rebaseParticipantMetricsForLifecycle(session) {
                return
            }
            // One physical lifecycle owns one immutable participant-metrics snapshot. Rebuilding
            // it from a projected bounce offset would reinterpret temporary geometry as a new
            // mathematical start and can fold the bounce to a boundary. An adaptive phase may
            // still move the existing ranges as one unit; teardown reconciles against the new
            // standalone range, then the next touch builds a fresh session/model.
            restoreProjectionAfterDeferredParticipantMetricsChange(
                for: participantID,
                scrollView: scrollView,
                in: session
            )
            return
        }
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
        let previousRebasePolicy = session.axisPhase?.rebasePolicy
        let initialProposedRebasePolicy = segmentBuild.proposedRebasePolicy
        let proposedRebasePolicy: BODragScrollAxisRebasePolicy
        if case .mismatchRecovery = reason {
            // Mismatch recovery deliberately synthesizes a current-height segment. Preserve the
            // captured source's authority instead of accidentally turning an explicit/fixed model
            // into an adaptive one merely because this rebuild used the smart continuation path.
            proposedRebasePolicy = previousRebasePolicy ?? .fixed
        } else {
            proposedRebasePolicy = initialProposedRebasePolicy
        }
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
            && builtModel.comparison.isValueEqual(
                candidateProjection.displayHeight,
                currentDisplayHeight
            )

        let configuredMinimumDisplayHeight = effectiveMinimumDisplayHeight
        let configuredMaximumDisplayHeight = maximumConfiguredDisplayHeight
        let isTemporaryContinuousPanelBounce = proposedRebasePolicy == .continuousPanel
            && (
                currentDisplayHeight < configuredMinimumDisplayHeight
                    && !builtModel.comparison.isValueEqual(
                        currentDisplayHeight,
                        configuredMinimumDisplayHeight
                    )
                || currentDisplayHeight > configuredMaximumDisplayHeight
                    && !builtModel.comparison.isValueEqual(
                        currentDisplayHeight,
                        configuredMaximumDisplayHeight
                    )
            )
        if isTemporaryContinuousPanelBounce, !compatible {
            // The legal-clamped automatic model can preserve a panel bounce only when the captured
            // participant offsets already describe that boundary (for example inner content is at
            // its bottom during a bottom bounce). Otherwise continuation synthesis would either
            // consume the bounce as inner progress or enlarge the legal host inset to the bounced
            // height. Keep this capture panel-only; a later real capture retries after settlement.
            deactivateCompositeModel(in: session)
            return
        }

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
        let totalParticipantDistance = builtModel.segments.reduce(CGFloat.zero) {
            $0 + ($1.isParticipantSegment ? $1.outerLength : 0)
        }
        let compositeContentHeight = panelView.frame.height + totalParticipantDistance
        var compositeInsets = calculatedOuterInsets(panelHeight: panelView.frame.height)
        var minimumEndpointDisplayHeight = effectiveMinimumDisplayHeight
        var maximumEndpointDisplayHeight = maximumConfiguredDisplayHeight
        if let captureMinimumDisplayHeight = captureDetentHeights.first {
            // `forcesInnerTopBounce` makes the current exact detent the lower boundary for this
            // touch's composite axis. Keep the public detent list unchanged and restore its normal
            // inset when capture ends, matching the OC implementation's temporary attach-array.
            compositeInsets.top = bounds.height - captureMinimumDisplayHeight
            minimumEndpointDisplayHeight = captureMinimumDisplayHeight
        }
        if let firstSegment = builtModel.segments.first,
           let lastSegment = builtModel.segments.last {
            // Provider-defined participant activation heights may extend beyond panel detents.
            // Make every valid model coordinate physically reachable by the outer UIScrollView.
            let requiredTopInset = -firstSegment.outerStart
            if requiredTopInset > compositeInsets.top,
               !builtModel.comparison.isValueEqual(requiredTopInset, compositeInsets.top) {
                compositeInsets.top = requiredTopInset
                minimumEndpointDisplayHeight = firstSegment.displayHeight
            }
            let requiredBottomInset = lastSegment.outerEnd
                + bounds.height
                - compositeContentHeight
            if requiredBottomInset > compositeInsets.bottom,
               !builtModel.comparison.isValueEqual(requiredBottomInset, compositeInsets.bottom) {
                compositeInsets.bottom = requiredBottomInset
                maximumEndpointDisplayHeight = lastSegment.displayHeight
            }
        }
        guard minimumEndpointDisplayHeight.isFinite,
              maximumEndpointDisplayHeight.isFinite,
              minimumEndpointDisplayHeight <= maximumEndpointDisplayHeight else {
            deactivateCompositeModel(in: session)
            return
        }
        let derivedEndpointDisplayRange = (
            minimumEndpointDisplayHeight...maximumEndpointDisplayHeight
        )
        let minimumEndpointOuterOffset = -compositeInsets.top
        let maximumEndpointOuterOffset = max(
            compositeContentHeight + compositeInsets.bottom - bounds.height,
            minimumEndpointOuterOffset
        )
        guard minimumEndpointOuterOffset.isFinite,
              maximumEndpointOuterOffset.isFinite else {
            deactivateCompositeModel(in: session)
            return
        }
        let endpointAuthority = BODragScrollAxisEndpointAuthority(
            outerOffsetRange: minimumEndpointOuterOffset...maximumEndpointOuterOffset,
            displayHeightRange: derivedEndpointDisplayRange
        )
        let finalOuterOffset = shouldPreserveMismatch
            ? state.progress + currentDisplayHeight - bounds.height
            : candidateOuterOffset

        let rebasePolicy: BODragScrollAxisRebasePolicy = builtModel.isAdaptiveParticipantAxis
            ? proposedRebasePolicy
            : .fixed
        session.axisPhase = BODragScrollCompositeAxisPhase(
            model: builtModel,
            rebasePolicy: rebasePolicy,
            // This correspondence describes the actual insets installed immediately below.
            // Keeping an old range while a mismatch rebuild writes new insets would split the
            // geometry authority and could pull the new real boundary toward a stale height.
            endpointAuthority: endpointAuthority,
            lastCommittedOuterOffsetY: finalOuterOffset
        )

        let committedHeight: ProjectedHeight
        if shouldPreserveMismatch {
            // Mismatch preservation owns the currently rendered geometry, not a candidate model
            // anchor. Publishing or deriving from candidate authority would move the panel.
            committedHeight = .geometric(currentDisplayHeight)
        } else {
            committedHeight = authoritativeDisplayHeight(
                for: candidateProjection,
                session: session
            ).map(ProjectedHeight.authoritative) ?? candidateProjection.height
        }
        var panelFrame = panelView.frame
        panelFrame.origin.y = committedHeight.panelOriginY(
            viewportHeight: bounds.height,
            outerOffsetY: finalOuterOffset,
            geometricFallback: shouldPreserveMismatch
                ? state.progress
                : candidateProjection.panelOriginY
        )

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
            applyParticipantOffsets(candidateProjection.participantOffsets, session: session)
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
        // Layout owns the one final publication after the complete capture rebuild. Publishing here
        // would expose an intermediate geometry and let a reentrant movement race the layout target.
        // Other rebuild reasons read the committed geometry once and publish it immediately.
        if case .layout = reason {
            // Intentionally deferred to `layoutPanel(previousBounds:)`.
        } else {
            let actualDisplayHeight = displayHeightForCurrentGeometry
            setDisplayHeight(
                committedHeight.publishedValue(
                    actual: actualDisplayHeight,
                    comparison: comparisonPolicy
                ),
                source: .panel
            )
        }
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
        session.axisPhase = nil
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
#if DEBUG
            debugModelBuildFailed(error)
#endif
            return nil
        }
    }

    // MARK: Participant segment planning

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
            let placementAllowsAdaptiveRebase: Bool
            switch configuration.handoff.innerScrollPlacement {
            case .automatic, .fromTouchedPosition:
                placementAllowsAdaptiveRebase = true
            case .atDisplayHeight, .afterPanelFullyDisplayed:
                placementAllowsAdaptiveRebase = false
            }
            let minimumDisplayHeight = effectiveMinimumDisplayHeight
            let maximumDisplayHeight = maximumConfiguredDisplayHeight
            let proposedRebasePolicy: BODragScrollAxisRebasePolicy
            if source == .smart,
               smartDetentHeights.isEmpty,
               placementAllowsAdaptiveRebase,
               configuration.handoff.mode == .coordinated,
               minimumDisplayHeight.isFinite,
               maximumDisplayHeight.isFinite,
               minimumDisplayHeight <= maximumDisplayHeight {
                proposedRebasePolicy = .continuousPanel
            } else {
                proposedRebasePolicy = .fixed
            }
            return BODragScrollParticipantSegmentBuild(
                segments: segments,
                detentHeights: source == .smart ? smartDetentHeights : runtimeDetentHeights,
                proposedRebasePolicy: proposedRebasePolicy
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
        } else if forceCurrentActivation {
            // This value is measured from the current UIKit geometry. It never passed through an
            // Objective-C NSNumber boundary, so preserving CGFloat precision is part of its source
            // semantics (and matters when rebuilding a continuation segment at the exact position).
            // Mismatch continuation also serves fixed/provider-defined axes whose legal segment
            // may intentionally sit outside the configured panel range. Its provenance is restored
            // below from the previous phase, so preserve the real continuation height here.
            displayScalar = .native(currentDisplayHeight)
        } else {
            displayScalar = automaticActivationScalar(
                for: scrollView,
                currentDisplayHeight: currentDisplayHeight,
                detentHeights: smartDetentHeights
            )
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

    private func automaticActivationScalar(
        for scrollView: UIScrollView,
        currentDisplayHeight: CGFloat,
        detentHeights: [CGFloat]
    ) -> ScrollSourceScalar {
        switch configuration.handoff.innerScrollPlacement {
        case .fromTouchedPosition:
            return .native(
                detentHeights.isEmpty
                    ? legalContinuousPanelActivationHeight(from: currentDisplayHeight)
                    : currentDisplayHeight
            )
        case .atDisplayHeight(let height):
            // Mirrors `prefDragInnerScrollDisplayH`, which the Objective-C implementation reads
            // through NSNumber.floatValue.
            return .objectiveCNumber(height)
        case .afterPanelFullyDisplayed:
            return .native(
                detentForFullyDisplayed(scrollView, detentHeights: detentHeights)
                    ?? maximumConfiguredDisplayHeight
            )
        case .automatic:
            break
        }

        // An empty detent list means the panel moves continuously; it does not disable coordinated
        // participant scrolling. Build the default segment at the touch's current *legal* display
        // height. A panel-owned bounce is temporary extension, not a new business endpoint; folding
        // it into the segment would enlarge the host's legal inset and make the bounce permanent.
        guard !detentHeights.isEmpty else {
            return .native(
                legalContinuousPanelActivationHeight(from: currentDisplayHeight)
            )
        }
        let originY = panelOriginY(of: scrollView)
        let scrollHeight = max(scrollView.frame.height, 1)
        let minimumRatio = configuration.handoff.minimumInnerVisibilityRatio
        var startIndex = ScrollMath.sortedIndex(
            in: detentHeights.map(ScrollSourceScalar.native),
            value: currentDisplayHeight,
            nearby: true,
            ceil: true
        )
        let nearbyHeight = detentHeights[startIndex]
        // Within the one-pixel scene band, start from the nearest detent. Outside it, restore ceil
        // semantics so the automatic search never begins below the panel's current scene.
        if !comparisonPolicy.isWithinBoundaryBand(currentDisplayHeight, nearbyHeight),
           nearbyHeight < currentDisplayHeight,
           startIndex + 1 < detentHeights.count {
            startIndex += 1
        }

        for index in startIndex..<detentHeights.count {
            let detent = detentHeights[index]
            if (detent - originY) / scrollHeight >= minimumRatio {
                return .native(detent)
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
            ? .native(fallback)
            : .native(currentDisplayHeight)
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

    /// Maps temporary panel bounce geometry back to the configured continuous-panel axis. This is
    /// an exact range clamp, not a tolerance: legal intermediate heights are preserved verbatim,
    /// while an arithmetic tail just beyond an endpoint becomes that exact endpoint naturally.
    private func legalContinuousPanelActivationHeight(from displayHeight: CGFloat) -> CGFloat {
        let minimum = effectiveMinimumDisplayHeight
        let maximum = maximumConfiguredDisplayHeight
        guard displayHeight.isFinite,
              minimum.isFinite,
              maximum.isFinite,
              minimum <= maximum else { return displayHeight }
        return min(maximum, max(minimum, displayHeight))
    }

    /// Mirrors the source's temporary `theattachar` suffix. The nearest detent belongs to the
    /// current force-bounce scene only when it is strictly inside the one-physical-pixel band.
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
              comparisonPolicy.isWithinBoundaryBand(
                  detents[index],
                  currentDisplayHeight
              ) else { return detents }
        return Array(detents[index...])
    }

    private func panelOriginY(of scrollView: UIScrollView) -> CGFloat {
        guard let panelView, scrollView !== panelView, let superview = scrollView.superview else {
            return 0
        }
        return panelView.convert(scrollView.frame, from: superview).minY
    }

    // MARK: Geometry snapshots and model reconciliation

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
            let snapshot = NestedParticipantSnapshot(
                id: participant.id,
                contentHeight: scrollView.contentSize.height,
                viewportHeight: scrollView.bounds.height,
                insetTop: inset.top,
                insetBottom: inset.bottom,
                contentOffset: scrollView.contentOffset.y,
                childFrame: childFrame
            )
            result.append(snapshot)
            // Baselines for the in-lifecycle metrics rebase. `bounds` has no reliable KVO, so the
            // scroll path compares live geometry against the values this model was built from.
            participant.capturedViewportHeight = snapshot.viewportHeight
            participant.capturedInnerMaximum = snapshot.maximumOffset
            // 临时排查用日志（不要提交）：这就是一次物理生命周期内被冻结的 participant 快照。
            bodragJitterLog(
                "modelSnapshot",
                "index=\(index)"
                    + " content=\(BODragScrollJitterLog.number(snapshot.contentHeight))"
                    + " viewport=\(BODragScrollJitterLog.number(snapshot.viewportHeight))"
                    + " insetT=\(BODragScrollJitterLog.number(snapshot.insetTop))"
                    + " insetB=\(BODragScrollJitterLog.number(snapshot.insetBottom))"
                    + " off=\(BODragScrollJitterLog.number(snapshot.contentOffset))"
                    + " innerMax=\(BODragScrollJitterLog.number(snapshot.maximumOffset))"
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
        let comparison = model.comparison
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
            let normalizedValue = comparison.snappingToNearestEndpoint(
                value,
                segment.innerStart,
                segment.innerEnd
            )
            guard normalizedValue >= segment.innerStart,
                  normalizedValue <= segment.innerEnd else { continue }

            candidateOuterOffsets.append(
                segment.outerStart + normalizedValue - segment.innerStart
            )
        }

        for candidateOuterOffset in candidateOuterOffsets {
            let candidate = model.projection(at: candidateOuterOffset)
            if projection(candidate, matches: session) {
                return CompositeState(
                    progress: candidate.panelOriginY,
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
            let normalizedValue = comparison.snappingToNearestEndpoint(
                value,
                segment.innerStart,
                segment.innerEnd
            )
            if normalizedValue >= segment.innerEnd {
                progress += segment.innerLength
            } else if normalizedValue > segment.innerStart {
                progress += normalizedValue - segment.innerStart
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
            return comparisonPolicy.isValueEqual(current, projected.contentOffset)
        }
    }

    private func mismatchDirection(
        model: ScrollModel,
        session: BODragScrollCaptureSession,
        expectedProjection: Projection
    ) -> Int {
        let comparison = model.comparison

        // Compare every participant with the projection at the preserved composite position. The
        // first segment may belong to an ancestor, so using the primary scroll view unconditionally
        // would choose the wrong recovery direction for a nested chain.
        for expected in expectedProjection.participantOffsets {
            guard let actual = session.participant(with: expected.participantID)?
                .scrollView?.contentOffset.y else { continue }
            guard !comparison.isValueEqual(actual, expected.contentOffset) else { continue }
            if actual > expected.contentOffset {
                return 1
            }
            if actual < expected.contentOffset {
                return -1
            }
        }

        let displayDelta = displayHeightForCurrentGeometry - expectedProjection.displayHeight
        if !comparison.isValueEqual(displayDelta, 0), displayDelta < 0 {
            return 1
        }
        if !comparison.isValueEqual(displayDelta, 0), displayDelta > 0 {
            return -1
        }

        // A non-prefix nested state can be incompatible even when its scalar totals happen to
        // cancel. Mark it as direction-agnostic so the first deliberate vertical drag rebuilds a
        // continuation model instead of leaving the capture permanently unresolved.
        return 3
    }

    // MARK: Projection application and native handoff

    func applyParticipantOffsets(
        _ participantOffsets: [ParticipantProjection],
        session: BODragScrollCaptureSession
    ) {
        let operationEpoch = runtime.capture.operationEpoch
        let scrollingCallbackEpoch = runtime.scrolling.callbackEpoch
        for projected in participantOffsets {
            guard runtime.capture.session === session,
                  runtime.capture.operationEpoch == operationEpoch,
                  runtime.scrolling.callbackEpoch == scrollingCallbackEpoch,
                  ensureCaptureSessionIsCurrentAndHierarchyValid(session) else { return }
            guard let participant = session.participant(with: projected.participantID),
                  let scrollView = participant.scrollView else { continue }
            if projected.participantID != session.primaryParticipant?.id,
               !scrollView.isScrollEnabled {
                continue
            }
            var offset = scrollView.contentOffset
            offset.y = pinnedParticipantOffset(projected.contentOffset, of: participant)
            // 临时排查用日志（不要提交）：target 是模型算出的目标，after 是 UIKit 实际落点，
            // 两者不等说明 UIKit 按当前 bounds/contentSize 又夹了一次 —— 抖动的直接现场。
            let offsetBefore = scrollView.contentOffset.y
            scrollView.setContentOffsetIfNeeded(offset)
            bodragJitterLog(
                "applyParticipantOffset",
                "target=\(BODragScrollJitterLog.number(projected.contentOffset))"
                    + " before=\(BODragScrollJitterLog.number(offsetBefore))"
                    + " after=\(BODragScrollJitterLog.number(scrollView.contentOffset.y))"
                    + " inner=[\(BODragScrollJitterLog.describe(scrollView))]"
            )
            guard runtime.capture.session === session,
                  runtime.capture.operationEpoch == operationEpoch,
                  runtime.scrolling.callbackEpoch == scrollingCallbackEpoch,
                  ensureCaptureSessionIsCurrentAndHierarchyValid(session) else { return }
        }
    }

    func innerScrollCanConsume(_ scrollView: UIScrollView, gestureVelocityY: CGFloat) -> Bool {
        let range = scrollableRange(of: scrollView)
        guard range.maximum > range.minimum else { return false }
        let current = comparisonPolicy.snappingToNearestEndpoint(
            scrollView.contentOffset.y,
            range.minimum,
            range.maximum
        )
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
