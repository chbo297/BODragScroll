#if DEBUG
@_spi(BODragScrollDemoDiagnostics) import BODragScroll
#else
import BODragScroll
#endif
import UIKit

@MainActor
final class SwiftDemoDragEngine: NSObject, DemoDragEngine {
    let implementation = DemoImplementation.swift
    let hostView = BODragScroll.BODragScrollView(frame: .zero)
    weak var delegate: DemoDragEngineDelegate?
#if DEBUG
    private enum DiagnosticMotionOwner: Equatable {
        case panel
        case participant(ObjectIdentifier)
    }

    private var diagnosticTouch = "0"
    private var lastDiagnosticMotionOwner: DiagnosticMotionOwner?
    private var lastDiagnosticMotionOwnerDescription: String?
#endif

    var scrollView: UIScrollView { hostView }
    var panelView: UIView? {
        get { hostView.panelView }
        set { hostView.panelView = newValue }
    }
    var displayHeight: CGFloat { hostView.displayHeight }
    var isAnimatingDisplayHeight: Bool { hostView.isAnimatingDisplayHeight }
    var detentHeights: [CGFloat] {
        get { hostView.detentHeights }
        set { hostView.detentHeights = newValue }
    }
    var nonSnappingRanges: [ClosedRange<CGFloat>] {
        get { hostView.nonSnappingRanges }
        set { hostView.nonSnappingRanges = newValue }
    }
    var minimumDisplayHeight: CGFloat? {
        get { hostView.minimumDisplayHeight }
        set { hostView.minimumDisplayHeight = newValue }
    }
    var configuration = DemoEngineConfiguration() {
        didSet { applyConfiguration() }
    }

    override init() {
        super.init()
#if DEBUG
        hostView._demoDiagnosticsSink = { [weak self] event in
            if event.category == "Touch", event.fields["phase"] == "begin" {
                self?.lastDiagnosticMotionOwner = nil
                self?.lastDiagnosticMotionOwnerDescription = nil
            }
            if let touch = event.fields["touch"] {
                self?.diagnosticTouch = touch
            }
            DemoDebugLogger.log(.swift, event.category, fields: event.fields)
        }
#endif
        hostView.behaviorProvider = self
        hostView.eventDelegate = self
        applyConfiguration()
    }

    @discardableResult
    func move(
        toDisplayHeight displayHeight: CGFloat,
        animated: Bool,
        options: DemoMovementOptions = .init(),
        completion: ((DemoMovementResult) -> Void)? = nil
    ) -> CGFloat {
        hostView.move(
            toDisplayHeight: displayHeight,
            animated: animated,
            options: options.modern
        ) { result in
            completion?(DemoMovementResult(modern: result))
        }
    }

    @discardableResult
    func settleToNearestDetent(
        animated: Bool = true,
        options: DemoMovementOptions = .init(),
        completion: ((DemoMovementResult) -> Void)? = nil
    ) -> CGFloat {
        hostView.settleToNearestDetent(animated: animated, options: options.modern) { result in
            completion?(DemoMovementResult(modern: result))
        }
    }

    func invalidatePanelLayout() {
        hostView.invalidatePanelLayout()
    }

    func reloadScrollMetrics() {
        hostView.reloadScrollMetrics()
    }

    func performAccessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        hostView.accessibilityScroll(direction)
    }

    func invalidate() {
#if DEBUG
        hostView._demoDiagnosticsSink = nil
#endif
        hostView.behaviorProvider = nil
        hostView.eventDelegate = nil
        hostView.panelView = nil
        hostView.removeFromSuperview()
    }

    private func applyConfiguration() {
        var modern = hostView.configuration
        modern.handoff.mode = configuration.handoff.mode.modern
        modern.handoff.innerScrollPlacement = configuration.handoff.innerScrollPlacement.modern
        modern.handoff.offsetMismatch = configuration.handoff.offsetMismatch.modern
        modern.handoff.preventsInnerToPanelHandoff = configuration.handoff.preventsInnerToPanelHandoff
        modern.handoff.resistsCollapse = configuration.handoff.resistsCollapse
        modern.handoff.minimumInnerVisibilityRatio = configuration.handoff.minimumInnerVisibilityRatio
        modern.bounce.allowsPanelTopBounce = configuration.bounce.allowsPanelTopBounce
        modern.bounce.allowsPanelBottomBounce = configuration.bounce.allowsPanelBottomBounce
        modern.bounce.preferredTopOwner = configuration.bounce.preferredTopOwner.modern
        modern.bounce.preferredBottomOwner = configuration.bounce.preferredBottomOwner.modern
        modern.bounce.forcesInnerTopBounce = configuration.bounce.forcesInnerTopBounce
        modern.capture.ignoresMultipleNestedWebScrollViews = configuration.capture.ignoresMultipleNestedWebScrollViews
        modern.capture.disablesPanelInteractionInWebView = configuration.capture.disablesPanelInteractionInWebView
        modern.movement.defaultStyle = configuration.movement.defaultStyle.modern
        modern.movement.lowVelocityThreshold = configuration.movement.lowVelocityThreshold
        modern.movement.highVelocityThreshold = configuration.movement.highVelocityThreshold
        modern.movement.nearBoundaryDistance = configuration.movement.nearBoundaryDistance
        modern.movement.outerToInnerSnapDistance = configuration.movement.outerToInnerSnapDistance
        modern.movement.speed = configuration.movement.speed
        modern.movement.baseDuration = configuration.movement.baseDuration
        modern.movement.maximumDuration = configuration.movement.maximumDuration
        modern.movement.usesSpring = configuration.movement.usesSpring
        modern.movement.defersDisplayHeightUpdates = configuration.movement.defersDisplayHeightUpdates
        modern.movement.animatesDeferredDisplayHeightUpdates = configuration.movement.animatesDeferredDisplayHeightUpdates
        modern.indicator.automaticallyShowsInnerIndicator = configuration.indicator.automaticallyShowsInnerIndicator
        hostView.configuration = modern
    }
}

@MainActor
extension SwiftDemoDragEngine: BODragScrollBehaviorProvider {
    func dragScrollView(
        _ dragScrollView: BODragScroll.BODragScrollView,
        sizeFor panelView: UIView,
        firstLayout: Bool,
        proposedDisplayHeight: inout CGFloat
    ) -> CGSize? {
        delegate?.dragEngine(
            self,
            sizeFor: panelView,
            firstLayout: firstLayout,
            proposedDisplayHeight: &proposedDisplayHeight
        )
    }

    func dragScrollView(
        _ dragScrollView: BODragScroll.BODragScrollView,
        segmentsFor scrollView: UIScrollView
    ) -> [BODragScrollInnerScrollSegment]? {
        let demoSegments = delegate?.dragEngine(self, segmentsFor: scrollView)
#if DEBUG
        if let demoSegments {
            for (index, segment) in demoSegments.enumerated() {
                DemoDebugLogger.log(
                    .swift,
                    "ProviderSegment",
                    fields: [
                        "index": String(index),
                        "innerOffset": "\(segment.beginOffsetY.map(DemoDebugLogger.number) ?? "effectiveTop")->\(segment.endOffsetY.map(DemoDebugLogger.number) ?? "effectiveBottom")",
                        "panelDisplayHeight": DemoDebugLogger.number(segment.displayHeight),
                        "scrollView": DemoDebugLogger.describe(scrollView),
                        "touch": diagnosticTouch
                    ]
                )
            }
        }
#endif
        return demoSegments?.map {
            .init(displayHeight: $0.displayHeight, beginOffsetY: $0.beginOffsetY, endOffsetY: $0.endOffsetY)
        }
    }

    func dragScrollView(
        _ dragScrollView: BODragScroll.BODragScrollView,
        canCapture scrollView: UIScrollView
    ) -> Bool {
        let result = delegate?.dragEngine(self, canCapture: scrollView) ?? true
#if DEBUG
        DemoDebugLogger.log(
            .swift,
            "CaptureEligibility",
            fields: [
                "canCapture": result ? "YES" : "NO",
                "scrollView": DemoDebugLogger.describe(scrollView),
                "touch": diagnosticTouch
            ]
        )
#endif
        return result
    }

    func dragScrollView(
        _ dragScrollView: BODragScroll.BODragScrollView,
        adjustCaptureProposal proposal: inout BODragScrollCaptureProposal
    ) {
#if DEBUG
        let proposedPrimaryBefore = proposal.primaryCandidateID
        for (index, candidate) in proposal.candidates.enumerated() {
            DemoDebugLogger.log(
                .swift,
                "CaptureCandidate",
                fields: [
                    "depth": String(candidate.hierarchyDepth),
                    "index": String(index),
                    "initialPriority": String(candidate.priority.rawValue),
                    "isInitialPrimary": candidate.id == proposedPrimaryBefore ? "YES" : "NO",
                    "scrollView": DemoDebugLogger.describe(candidate.scrollView),
                    "touch": diagnosticTouch,
                    "vertical": candidate.isVerticallyScrollable ? "YES" : "NO"
                ]
            )
        }
#endif
        var demo = DemoCaptureProposal(
            primaryCandidateID: proposal.primaryCandidateID,
            candidates: proposal.candidates.map(DemoCaptureCandidate.init),
            containsWebView: proposal.webView != nil
        )
        delegate?.dragEngine(self, adjustCaptureProposal: &demo)
        proposal.primaryCandidateID = demo.primaryCandidateID
        proposal.candidates = proposal.candidates.map { candidate in
            var candidate = candidate
            if let updated = demo.candidates.first(where: { $0.id == candidate.id }) {
                candidate.priority = updated.priority.modern
            }
            return candidate
        }
#if DEBUG
        let finalPrimary = proposal.primaryCandidateID
        DemoDebugLogger.log(
            .swift,
            "CaptureProposal",
            fields: [
                "candidateCount": String(proposal.candidates.count),
                "containsWebView": proposal.webView == nil ? "NO" : "YES",
                "finalPrimary": proposal.candidates.first(where: { $0.id == finalPrimary })
                    .map { DemoDebugLogger.describe($0.scrollView) } ?? "none",
                "touch": diagnosticTouch
            ]
        )
#endif
    }

    func dragScrollView(
        _ dragScrollView: BODragScroll.BODragScrollView,
        shouldBypassDetentsAt displayHeight: CGFloat
    ) -> Bool? {
        delegate?.dragEngine(self, shouldBypassDetentsAt: displayHeight)
    }

    func dragScrollView(
        _ dragScrollView: BODragScroll.BODragScrollView,
        movementStyleFrom fromDisplayHeight: CGFloat,
        to toDisplayHeight: CGFloat,
        reason: BODragScrollMovementReason
    ) -> BODragScrollMovementStyle {
        delegate?.dragEngine(
            self,
            movementStyleFrom: fromDisplayHeight,
            to: toDisplayHeight,
            reason: DemoMovementReason(modern: reason)
        ).modern ?? .automatic
    }

    func dragScrollView(
        _ dragScrollView: BODragScroll.BODragScrollView,
        adjustTargetContentOffset targetContentOffset: inout CGPoint,
        velocity: CGPoint
    ) {
        delegate?.dragEngine(self, adjustTargetContentOffset: &targetContentOffset, velocity: velocity)
    }

    func dragScrollViewShouldScrollToTop(_ dragScrollView: BODragScroll.BODragScrollView) -> Bool {
        delegate?.dragEngineShouldScrollToTop(self) ?? true
    }

    func dragScrollView(
        _ dragScrollView: BODragScroll.BODragScrollView,
        accessibilityDispositionFor direction: UIAccessibilityScrollDirection
    ) -> BODragScrollAccessibilityDisposition {
        delegate?.dragEngine(self, accessibilityDispositionFor: direction).modern ?? .automatic
    }
}

@MainActor
extension SwiftDemoDragEngine: BODragScrollEventDelegate {
    func dragScrollView(
        _ dragScrollView: BODragScroll.BODragScrollView,
        didChangeDisplayHeight displayHeight: CGFloat
    ) {
        delegate?.dragEngine(self, didChangeDisplayHeight: displayHeight)
    }

    func dragScrollView(
        _ dragScrollView: BODragScroll.BODragScrollView,
        didScroll update: BODragScrollUpdate
    ) {
        let source: DemoMotionSource
#if DEBUG
        let diagnosticOwner: DiagnosticMotionOwner
        let diagnosticParticipant: UIScrollView?
#endif
        switch update.source {
        case .panel:
            source = .panel
#if DEBUG
            diagnosticOwner = .panel
            diagnosticParticipant = nil
#endif
        case let .participant(scrollView):
            source = .participant(
                scrollView,
                name: scrollView.accessibilityIdentifier ?? String(describing: type(of: scrollView))
            )
#if DEBUG
            diagnosticOwner = .participant(ObjectIdentifier(scrollView))
            diagnosticParticipant = scrollView
#endif
        }
#if DEBUG
        if diagnosticOwner != lastDiagnosticMotionOwner {
            let diagnosticOwnerDescription = diagnosticParticipant.map {
                "inner:\(DemoDebugLogger.describe($0))"
            } ?? "panel"
            let motionKind: String
            if hostView.isTracking || hostView.isDragging {
                motionKind = "touch"
            } else if hostView.isDecelerating {
                motionKind = "deceleration"
            } else if hostView.isAnimatingDisplayHeight {
                motionKind = "programmatic-animation"
            } else {
                motionKind = "programmatic-or-layout"
            }
            DemoDebugLogger.log(
                .swift,
                "OwnerTransition",
                fields: [
                    "displayHeight": DemoDebugLogger.number(update.displayHeight),
                    "from": lastDiagnosticMotionOwnerDescription ?? "none",
                    "hostOffsetY": DemoDebugLogger.number(hostView.contentOffset.y),
                    "motionKind": motionKind,
                    "to": diagnosticOwnerDescription,
                    "touch": diagnosticTouch
                ]
            )
            lastDiagnosticMotionOwner = diagnosticOwner
            lastDiagnosticMotionOwnerDescription = diagnosticOwnerDescription
        }
#endif
        delegate?.dragEngine(self, didScrollFrom: source)
    }

    func dragScrollView(
        _ dragScrollView: BODragScroll.BODragScrollView,
        willMoveToDisplayHeight displayHeight: CGFloat,
        reason: BODragScrollMovementReason
    ) {
        delegate?.dragEngine(
            self,
            willMoveToDisplayHeight: displayHeight,
            reason: DemoMovementReason(modern: reason)
        )
    }

    func dragScrollView(
        _ dragScrollView: BODragScroll.BODragScrollView,
        didFinishMovement result: BODragScrollMovementResult
    ) {
        delegate?.dragEngine(self, didFinishMovement: DemoMovementResult(modern: result))
    }

    func dragScrollViewWillBeginDragging(_ dragScrollView: BODragScroll.BODragScrollView) {
        delegate?.dragEngineWillBeginDragging(self)
    }

    func dragScrollViewWillEndDragging(
        _ dragScrollView: BODragScroll.BODragScrollView,
        velocity: CGPoint,
        resolvedTargetContentOffset: CGPoint
    ) {
        delegate?.dragEngine(
            self,
            willEndDraggingWithVelocity: velocity,
            resolvedTargetContentOffset: resolvedTargetContentOffset
        )
    }

    func dragScrollViewDidEndDragging(
        _ dragScrollView: BODragScroll.BODragScrollView,
        willDecelerate: Bool
    ) {
        delegate?.dragEngine(self, didEndDraggingWillDecelerate: willDecelerate)
    }

    func dragScrollViewDidEndDecelerating(_ dragScrollView: BODragScroll.BODragScrollView) {
        delegate?.dragEngineDidEndDecelerating(self)
    }

    func dragScrollViewDidEndScrollingAnimation(_ dragScrollView: BODragScroll.BODragScrollView) {
        delegate?.dragEngineDidEndScrollingAnimation(self)
    }

    func dragScrollViewDidScrollToTop(_ dragScrollView: BODragScroll.BODragScrollView) {
        delegate?.dragEngineDidScrollToTop(self)
    }
}

private extension DemoMovementOptions {
    var modern: BODragScrollMovementOptions {
        .init(
            style: style.modern,
            initialVelocity: initialVelocity,
            duration: duration,
            animationOptions: animationOptions
        )
    }
}

private extension DemoMovementResult {
    init(modern result: BODragScrollMovementResult) {
        requestedDisplayHeight = result.requestedDisplayHeight
        finalDisplayHeight = result.finalDisplayHeight
        reason = DemoMovementReason(modern: result.reason)
        switch result.outcome {
        case .completed: outcome = .completed
        case .cancelled: outcome = .cancelled
        case .interrupted: outcome = .interrupted
        }
    }
}

private extension DemoMovementReason {
    init(modern reason: BODragScrollMovementReason) {
        switch reason {
        case .dragRelease: self = .dragRelease
        case .programmatic: self = .programmatic
        case .nearestDetent: self = .nearestDetent
        case .scrollToTop: self = .scrollToTop
        case .accessibility: self = .accessibility
        }
    }
}

private extension DemoMovementStyle {
    var modern: BODragScrollMovementStyle {
        switch self {
        case .automatic: return .automatic
        case .systemScroll: return .systemScroll
        case .viewAnimation: return .viewAnimation
        }
    }
}

private extension DemoHandoffMode {
    var modern: BODragScrollHandoffMode {
        switch self {
        case .coordinated: return .coordinated
        case .innerFirst: return .innerFirst
        case .innerFirstAtBoundary: return .innerFirstAtBoundary
        }
    }
}

private extension DemoInnerScrollPlacement {
    var modern: BODragScrollInnerScrollPlacement {
        switch self {
        case .automatic: return .automatic
        case .afterPanelFullyDisplayed: return .afterPanelFullyDisplayed
        case let .atDisplayHeight(height): return .atDisplayHeight(height)
        case .fromTouchedPosition: return .fromTouchedPosition
        }
    }
}

private extension DemoOffsetMismatchPolicy {
    var modern: BODragScrollOffsetMismatchPolicy {
        switch self {
        case .waitForValidSegment: return .waitForValidSegment
        case .restoreToBoundary: return .restoreToBoundary
        case .continueFromCurrentOffset: return .continueFromCurrentOffset
        }
    }
}

private extension DemoBounceOwner {
    var modern: BODragScrollBounceOwner {
        self == .panel ? .panel : .innerScrollView
    }
}

private extension DemoCaptureCandidate {
    init(modern candidate: BODragScrollCaptureCandidate) {
        id = candidate.id
        scrollView = candidate.scrollView
        hierarchyDepth = candidate.hierarchyDepth
        isVerticallyScrollable = candidate.isVerticallyScrollable
        priority = DemoCapturePriority(rawValue: candidate.priority.rawValue) ?? .systemDefault
    }
}

private extension DemoCapturePriority {
    var modern: BODragScrollCapturePriority {
        BODragScrollCapturePriority(rawValue: rawValue) ?? .systemDefault
    }
}

private extension DemoAccessibilityDisposition {
    var modern: BODragScrollAccessibilityDisposition {
        switch self {
        case .automatic: return .automatic
        case .handled: return .handled
        case .panelOnly: return .panelOnly
        }
    }
}
