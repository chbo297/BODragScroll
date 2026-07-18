import BODragScrollLegacy
import UIKit

@MainActor
final class LegacyDemoDragEngine: NSObject, DemoDragEngine {
    let implementation = DemoImplementation.objectiveC
    let host = BODemoLegacyDragHost(frame: .zero)
    weak var delegate: DemoDragEngineDelegate?

    var scrollView: UIScrollView { host.scrollView }
    var panelView: UIView? {
        get { host.panelView }
        set { host.panelView = newValue }
    }
    var displayHeight: CGFloat { host.displayHeight }
    var isAnimatingDisplayHeight: Bool { host.isAnimatingDisplayHeight }
    var detentHeights: [CGFloat] = [] {
        didSet { host.detentHeights = detentHeights.map { NSNumber(value: Double($0)) } }
    }
    var nonSnappingRanges: [ClosedRange<CGFloat>] = [] {
        didSet {
            host.nonSnappingRanges = nonSnappingRanges.map {
                NSValue(cgPoint: CGPoint(x: $0.lowerBound, y: $0.upperBound))
            }
        }
    }
    var minimumDisplayHeight: CGFloat? {
        didSet {
            host.minimumDisplayHeight = minimumDisplayHeight.map {
                NSNumber(value: Double($0))
            }
        }
    }
    var configuration = DemoEngineConfiguration() {
        didSet { applyConfiguration() }
    }

    override init() {
        super.init()
        host.delegate = self
        applyConfiguration()
    }

    @discardableResult
    func move(
        toDisplayHeight displayHeight: CGFloat,
        animated: Bool,
        options: DemoMovementOptions = .init(),
        completion: ((DemoMovementResult) -> Void)? = nil
    ) -> CGFloat {
        return host.move(
            toDisplayHeight: displayHeight,
            animated: animated,
            style: options.style.legacy,
            subInfo: legacySubInfo(for: options)
        ) { finalHeight in
            completion?(
                DemoMovementResult(
                    requestedDisplayHeight: displayHeight,
                    finalDisplayHeight: finalHeight,
                    reason: .programmatic,
                    outcome: .legacyCompletion
                )
            )
        }
    }

    @discardableResult
    func settleToNearestDetent(
        animated: Bool = true,
        options: DemoMovementOptions = .init(),
        completion: ((DemoMovementResult) -> Void)? = nil
    ) -> CGFloat {
        host.settleToNearestDetent(
            animated: animated,
            style: options.style.legacy,
            subInfo: legacySubInfo(for: options)
        ) {
            requestedHeight, finalHeight in
            completion?(
                DemoMovementResult(
                    requestedDisplayHeight: requestedHeight,
                    finalDisplayHeight: finalHeight,
                    reason: .nearestDetent,
                    outcome: .legacyCompletion
                )
            )
        }
    }

    func invalidatePanelLayout() {
        host.invalidatePanelLayout()
    }

    func reloadScrollMetrics() {
        host.reloadScrollMetrics()
    }

    func performAccessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        host.performAccessibilityScroll(direction)
    }

    func invalidate() {
        host.delegate = nil
        host.invalidate()
    }

    private func legacySubInfo(for options: DemoMovementOptions) -> [String: NSNumber]? {
        var subInfo: [String: NSNumber] = [:]
        if options.initialVelocity.isFinite, options.initialVelocity != 0 {
            subInfo["vel"] = NSNumber(value: Double(options.initialVelocity))
        }
        if let duration = options.duration, duration.isFinite {
            subInfo["sp_ani_dur"] = NSNumber(value: min(0.9, max(0, duration)))
        }
        if !options.animationOptions.isEmpty {
            subInfo["additionOptions"] = NSNumber(value: options.animationOptions.rawValue)
        }
        return subInfo.isEmpty ? nil : subInfo
    }

    private func applyConfiguration() {
        let legacy = BODemoLegacyConfiguration()
        legacy.handoffMode = configuration.handoff.mode.legacy
        switch configuration.handoff.innerScrollPlacement {
        case .automatic:
            legacy.innerPlacement = .automatic
            legacy.innerPlacementHeight = 0
        case .afterPanelFullyDisplayed:
            legacy.innerPlacement = .afterFullyDisplayed
            legacy.innerPlacementHeight = 0
        case let .atDisplayHeight(height):
            legacy.innerPlacement = .atDisplayHeight
            legacy.innerPlacementHeight = height
        case .fromTouchedPosition:
            legacy.innerPlacement = .fromTouchedPosition
            legacy.innerPlacementHeight = 0
        }
        legacy.offsetMismatch = configuration.handoff.offsetMismatch.legacy
        legacy.preventsInnerToPanelHandoff = configuration.handoff.preventsInnerToPanelHandoff
        legacy.resistsCollapse = configuration.handoff.resistsCollapse
        legacy.allowsPanelTopBounce = configuration.bounce.allowsPanelTopBounce
        legacy.allowsPanelBottomBounce = configuration.bounce.allowsPanelBottomBounce
        legacy.preferredTopBounceOwner = configuration.bounce.preferredTopOwner.legacy
        legacy.preferredBottomBounceOwner = configuration.bounce.preferredBottomOwner.legacy
        legacy.forcesInnerTopBounce = configuration.bounce.forcesInnerTopBounce
        legacy.ignoresMultipleNestedWebScrollViews = configuration.capture.ignoresMultipleNestedWebScrollViews
        legacy.disablesPanelInteractionInWebView = configuration.capture.disablesPanelInteractionInWebView
        legacy.defaultMovementStyle = configuration.movement.defaultStyle.legacy
        legacy.animationSpeed = configuration.movement.speed
        legacy.baseAnimationDuration = configuration.movement.baseDuration
        legacy.maximumAnimationDuration = configuration.movement.maximumDuration
        legacy.usesSpring = configuration.movement.usesSpring
        legacy.defersDisplayHeightUpdates = configuration.movement.defersDisplayHeightUpdates
        legacy.animatesDeferredDisplayHeightUpdates = configuration.movement.animatesDeferredDisplayHeightUpdates
        host.configuration = legacy
    }
}

@MainActor
extension LegacyDemoDragEngine: @preconcurrency BODemoLegacyDragHostDelegate {
    func legacyHost(
        _ host: BODemoLegacyDragHost,
        sizeFor panelView: UIView,
        firstLayout: Bool,
        proposedDisplayHeight: UnsafeMutablePointer<CGFloat>
    ) -> CGSize {
        var proposed = proposedDisplayHeight.pointee
        let size = delegate?.dragEngine(
            self,
            sizeFor: panelView,
            firstLayout: firstLayout,
            proposedDisplayHeight: &proposed
        ) ?? scrollView.bounds.size
        proposedDisplayHeight.pointee = proposed
        return size
    }

    func legacyHost(
        _ host: BODemoLegacyDragHost,
        segmentsFor scrollView: UIScrollView
    ) -> [[String: NSNumber]]? {
        delegate?.dragEngine(self, segmentsFor: scrollView)?.map { segment in
            var dictionary: [String: NSNumber] = [
                "displayH": NSNumber(value: Double(segment.displayHeight))
            ]
            if let beginOffsetY = segment.beginOffsetY {
                dictionary["beginOffsetY"] = NSNumber(value: Double(beginOffsetY))
            }
            if let endOffsetY = segment.endOffsetY {
                dictionary["endOffsetY"] = NSNumber(value: Double(endOffsetY))
            }
            return dictionary
        }
    }

    func legacyHost(_ host: BODemoLegacyDragHost, canCapture scrollView: UIScrollView) -> Bool {
        delegate?.dragEngine(self, canCapture: scrollView) ?? true
    }

    func legacyHost(
        _ host: BODemoLegacyDragHost,
        adjustCaptureInfo captureInfo: [String: Any]
    ) -> [String: Any]? {
        let primary = captureInfo["catchSV"] as? UIScrollView
        let rawCandidates = captureInfo["otherSVBehaviorAr"] as? [[AnyHashable: Any]] ?? []
        var candidates = rawCandidates.enumerated().compactMap { index, entry -> DemoCaptureCandidate? in
            guard let scrollView = entry["sv"] as? UIScrollView else { return nil }
            let rawPriority = (entry["priority"] as? NSNumber)?.intValue ?? 2
            return DemoCaptureCandidate(
                id: ObjectIdentifier(scrollView),
                scrollView: scrollView,
                hierarchyDepth: index,
                isVerticallyScrollable: scrollView.contentSize.height
                    + scrollView.adjustedContentInset.top
                    + scrollView.adjustedContentInset.bottom > scrollView.bounds.height,
                priority: DemoCapturePriority(rawValue: rawPriority) ?? .systemDefault
            )
        }
        if let primary, !candidates.contains(where: { $0.scrollView === primary }) {
            candidates.insert(
                DemoCaptureCandidate(
                    id: ObjectIdentifier(primary),
                    scrollView: primary,
                    hierarchyDepth: 0,
                    isVerticallyScrollable: true,
                    priority: .participant
                ),
                at: 0
            )
        }
        var proposal = DemoCaptureProposal(
            primaryCandidateID: primary.map(ObjectIdentifier.init),
            candidates: candidates,
            containsWebView: captureInfo["webView"] != nil
        )
        delegate?.dragEngine(self, adjustCaptureProposal: &proposal)
        var adjustments: [String: Any] = [
            "candidatePriorities": proposal.candidates.map { candidate in
                [
                    "sv": candidate.scrollView,
                    "priority": NSNumber(value: candidate.priority.rawValue)
                ] as [String: Any]
            }
        ]
        if let primaryCandidate = proposal.primaryCandidate {
            adjustments["catchSV"] = primaryCandidate.scrollView
        }
        return adjustments
    }

    func legacyHost(
        _ host: BODemoLegacyDragHost,
        movementStyleFrom fromHeight: CGFloat,
        to toHeight: CGFloat,
        reason: String
    ) -> BODemoLegacyMovementStyle {
        delegate?.dragEngine(
            self,
            movementStyleFrom: fromHeight,
            to: toHeight,
            reason: .legacy(reason)
        ).legacy ?? .automatic
    }

    func legacyHost(
        _ host: BODemoLegacyDragHost,
        accessibilityDispositionFor direction: UIAccessibilityScrollDirection
    ) -> BODemoLegacyAccessibilityDisposition {
        delegate?.dragEngine(self, accessibilityDispositionFor: direction).legacy ?? .automatic
    }

    func legacyHost(
        _ host: BODemoLegacyDragHost,
        shouldBypassDetentsAt displayHeight: CGFloat
    ) -> NSNumber? {
        delegate?.dragEngine(self, shouldBypassDetentsAt: displayHeight).map(NSNumber.init(value:))
    }

    func legacyHost(
        _ host: BODemoLegacyDragHost,
        adjustTargetContentOffset targetContentOffset: UnsafeMutablePointer<CGPoint>,
        velocity: CGPoint
    ) {
        var target = targetContentOffset.pointee
        delegate?.dragEngine(self, adjustTargetContentOffset: &target, velocity: velocity)
        targetContentOffset.pointee = target
    }

    func legacyHostShouldScrollToTop(_ host: BODemoLegacyDragHost) -> Bool {
        delegate?.dragEngineShouldScrollToTop(self) ?? true
    }

    func legacyHost(_ host: BODemoLegacyDragHost, didChangeDisplayHeight displayHeight: CGFloat) {
        delegate?.dragEngine(self, didChangeDisplayHeight: displayHeight)
    }

    func legacyHost(
        _ host: BODemoLegacyDragHost,
        didScrollToDisplayHeight displayHeight: CGFloat,
        isInner: Bool
    ) {
        delegate?.dragEngine(self, didScrollFrom: isInner ? .legacyInner : .panel)
    }

    func legacyHost(
        _ host: BODemoLegacyDragHost,
        willMoveToDisplayHeight displayHeight: CGFloat,
        reason: String
    ) {
        delegate?.dragEngine(self, willMoveToDisplayHeight: displayHeight, reason: .legacy(reason))
    }

    func legacyHost(
        _ host: BODemoLegacyDragHost,
        didMoveToDisplayHeight displayHeight: CGFloat,
        reason: String
    ) {
        // The original callback carries no transaction identifier. Report its terminal snapshot
        // without pretending to pair it to one of several overlapping willTarget callbacks.
        delegate?.dragEngine(
            self,
            didFinishMovement: DemoMovementResult(
                requestedDisplayHeight: displayHeight,
                finalDisplayHeight: displayHeight,
                reason: .legacy(reason),
                outcome: .legacyCompletion
            )
        )
    }

    func legacyHostWillBeginDragging(_ host: BODemoLegacyDragHost) {
        delegate?.dragEngineWillBeginDragging(self)
    }

    func legacyHost(
        _ host: BODemoLegacyDragHost,
        willEndDraggingWithVelocity velocity: CGPoint,
        resolvedTargetContentOffset: CGPoint
    ) {
        delegate?.dragEngine(
            self,
            willEndDraggingWithVelocity: velocity,
            resolvedTargetContentOffset: resolvedTargetContentOffset
        )
    }

    func legacyHost(_ host: BODemoLegacyDragHost, didEndDraggingWillDecelerate: Bool) {
        delegate?.dragEngine(self, didEndDraggingWillDecelerate: didEndDraggingWillDecelerate)
    }

    func legacyHostDidEndDecelerating(_ host: BODemoLegacyDragHost) {
        delegate?.dragEngineDidEndDecelerating(self)
    }

    func legacyHostDidEndScrollingAnimation(_ host: BODemoLegacyDragHost) {
        delegate?.dragEngineDidEndScrollingAnimation(self)
    }

    func legacyHostDidScrollToTop(_ host: BODemoLegacyDragHost) {
        delegate?.dragEngineDidScrollToTop(self)
    }
}

private extension DemoMovementStyle {
    var legacy: BODemoLegacyMovementStyle {
        switch self {
        case .automatic: return .automatic
        case .systemScroll: return .systemScroll
        case .viewAnimation: return .viewAnimation
        }
    }
}

private extension DemoHandoffMode {
    var legacy: BODemoLegacyHandoffMode {
        switch self {
        case .coordinated: return .coordinated
        case .innerFirst: return .innerFirst
        case .innerFirstAtBoundary: return .innerFirstAtBoundary
        }
    }
}

private extension DemoOffsetMismatchPolicy {
    var legacy: BODemoLegacyOffsetMismatch {
        switch self {
        case .waitForValidSegment: return .wait
        case .restoreToBoundary: return .restore
        case .continueFromCurrentOffset: return .continue
        }
    }
}

private extension DemoBounceOwner {
    var legacy: BODemoLegacyBounceOwner {
        self == .panel ? .panel : .innerScrollView
    }
}

private extension DemoAccessibilityDisposition {
    var legacy: BODemoLegacyAccessibilityDisposition {
        switch self {
        case .automatic: return .automatic
        case .handled: return .handled
        case .panelOnly: return .panelOnly
        }
    }
}
