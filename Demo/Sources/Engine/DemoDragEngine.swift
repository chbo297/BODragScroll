import UIKit

enum DemoImplementation: String {
    case swift
    case objectiveC

    var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .objectiveC: return "OC"
        }
    }

    var alternate: DemoImplementation {
        self == .swift ? .objectiveC : .swift
    }
}

enum DemoMovementStyle {
    case automatic
    case systemScroll
    case viewAnimation
}

enum DemoMovementReason: CustomStringConvertible {
    case dragRelease
    case programmatic
    case nearestDetent
    case scrollToTop
    case accessibility
    case legacy(String)

    var description: String {
        switch self {
        case .dragRelease: return "dragRelease"
        case .programmatic: return "programmatic"
        case .nearestDetent: return "nearestDetent"
        case .scrollToTop: return "scrollToTop"
        case .accessibility: return "accessibility"
        case let .legacy(reason): return reason
        }
    }
}

enum DemoMovementOutcome: String {
    case completed
    case cancelled
    case interrupted
    case legacyCompletion
}

struct DemoMovementOptions {
    var style: DemoMovementStyle = .automatic
    var initialVelocity: CGFloat = 0
    var duration: TimeInterval?
    var animationOptions: UIView.AnimationOptions = []
}

struct DemoMovementResult {
    let requestedDisplayHeight: CGFloat
    let finalDisplayHeight: CGFloat
    let reason: DemoMovementReason
    let outcome: DemoMovementOutcome
}

enum DemoMotionSource {
    case panel
    case participant(UIScrollView, name: String)
    case legacyInner

    var displayName: String {
        switch self {
        case .panel:
            return "panel"
        case let .participant(_, name):
            return name
        case .legacyInner:
            return "inner(OC)"
        }
    }
}

struct DemoInnerScrollSegment {
    var displayHeight: CGFloat
    var beginOffsetY: CGFloat?
    var endOffsetY: CGFloat?
}

enum DemoHandoffMode {
    case coordinated
    case innerFirst
    case innerFirstAtBoundary
}

enum DemoInnerScrollPlacement: Equatable {
    case automatic
    case afterPanelFullyDisplayed
    case atDisplayHeight(CGFloat)
    case fromTouchedPosition
}

enum DemoOffsetMismatchPolicy {
    case waitForValidSegment
    case restoreToBoundary
    case continueFromCurrentOffset
}

enum DemoBounceOwner {
    case panel
    case innerScrollView
}

enum DemoCapturePriority: Int {
    case panelFirst = -1
    case simultaneous = 0
    case otherFirst = 1
    case systemDefault = 2
    case participant = 3
}

struct DemoCaptureCandidate {
    let id: ObjectIdentifier
    let scrollView: UIScrollView
    let hierarchyDepth: Int
    let isVerticallyScrollable: Bool
    var priority: DemoCapturePriority
}

struct DemoCaptureProposal {
    var primaryCandidateID: ObjectIdentifier?
    var candidates: [DemoCaptureCandidate]
    var containsWebView: Bool

    var primaryCandidate: DemoCaptureCandidate? {
        guard let primaryCandidateID else { return nil }
        return candidates.first { $0.id == primaryCandidateID }
    }
}

enum DemoAccessibilityDisposition {
    case automatic
    case handled
    case panelOnly
}

struct DemoHandoffConfiguration {
    var mode: DemoHandoffMode = .coordinated
    var innerScrollPlacement: DemoInnerScrollPlacement = .automatic
    var offsetMismatch: DemoOffsetMismatchPolicy = .waitForValidSegment
    var preventsInnerToPanelHandoff = false
    var resistsCollapse = false
    var minimumInnerVisibilityRatio: CGFloat = 0.7
}

struct DemoBounceConfiguration {
    var allowsPanelTopBounce = true
    var allowsPanelBottomBounce = true
    var preferredTopOwner: DemoBounceOwner = .panel
    var preferredBottomOwner: DemoBounceOwner = .innerScrollView
    var forcesInnerTopBounce = false
}

struct DemoCaptureConfiguration {
    var ignoresMultipleNestedWebScrollViews = false
    var disablesPanelInteractionInWebView = false
}

struct DemoMovementConfiguration {
    var defaultStyle: DemoMovementStyle = .systemScroll
    var lowVelocityThreshold: CGFloat = 0.2
    var highVelocityThreshold: CGFloat = 2.2
    var nearBoundaryDistance: CGFloat = 86
    var outerToInnerSnapDistance: CGFloat = 140
    var speed: CGFloat = 1_000
    var baseDuration: TimeInterval = 0.12
    var maximumDuration: TimeInterval = 0.32
    var usesSpring = true
    var defersDisplayHeightUpdates = false
    var animatesDeferredDisplayHeightUpdates = false
}

struct DemoEngineConfiguration {
    var handoff = DemoHandoffConfiguration()
    var bounce = DemoBounceConfiguration()
    var capture = DemoCaptureConfiguration()
    var movement = DemoMovementConfiguration()
}

@MainActor
protocol DemoDragEngineDelegate: AnyObject {
    func dragEngine(
        _ engine: DemoDragEngine,
        sizeFor panelView: UIView,
        firstLayout: Bool,
        proposedDisplayHeight: inout CGFloat
    ) -> CGSize
    func dragEngine(
        _ engine: DemoDragEngine,
        segmentsFor scrollView: UIScrollView
    ) -> [DemoInnerScrollSegment]?
    func dragEngine(_ engine: DemoDragEngine, canCapture scrollView: UIScrollView) -> Bool
    func dragEngine(
        _ engine: DemoDragEngine,
        adjustCaptureProposal proposal: inout DemoCaptureProposal
    )
    func dragEngine(_ engine: DemoDragEngine, shouldBypassDetentsAt displayHeight: CGFloat) -> Bool?
    func dragEngine(
        _ engine: DemoDragEngine,
        movementStyleFrom fromDisplayHeight: CGFloat,
        to toDisplayHeight: CGFloat,
        reason: DemoMovementReason
    ) -> DemoMovementStyle
    func dragEngine(
        _ engine: DemoDragEngine,
        adjustTargetContentOffset targetContentOffset: inout CGPoint,
        velocity: CGPoint
    )
    func dragEngineShouldScrollToTop(_ engine: DemoDragEngine) -> Bool
    func dragEngine(
        _ engine: DemoDragEngine,
        accessibilityDispositionFor direction: UIAccessibilityScrollDirection
    ) -> DemoAccessibilityDisposition

    func dragEngine(_ engine: DemoDragEngine, didChangeDisplayHeight displayHeight: CGFloat)
    func dragEngine(_ engine: DemoDragEngine, didScrollFrom source: DemoMotionSource)
    func dragEngine(
        _ engine: DemoDragEngine,
        willMoveToDisplayHeight displayHeight: CGFloat,
        reason: DemoMovementReason
    )
    func dragEngine(_ engine: DemoDragEngine, didFinishMovement result: DemoMovementResult)
    func dragEngineWillBeginDragging(_ engine: DemoDragEngine)
    func dragEngine(
        _ engine: DemoDragEngine,
        willEndDraggingWithVelocity velocity: CGPoint,
        resolvedTargetContentOffset: CGPoint
    )
    func dragEngine(_ engine: DemoDragEngine, didEndDraggingWillDecelerate: Bool)
    func dragEngineDidEndDecelerating(_ engine: DemoDragEngine)
    func dragEngineDidEndScrollingAnimation(_ engine: DemoDragEngine)
    func dragEngineDidScrollToTop(_ engine: DemoDragEngine)
}

@MainActor
protocol DemoDragEngine: AnyObject {
    var implementation: DemoImplementation { get }
    var scrollView: UIScrollView { get }
    var delegate: DemoDragEngineDelegate? { get set }
    var panelView: UIView? { get set }
    var displayHeight: CGFloat { get }
    var isAnimatingDisplayHeight: Bool { get }
    var detentHeights: [CGFloat] { get set }
    var nonSnappingRanges: [ClosedRange<CGFloat>] { get set }
    var minimumDisplayHeight: CGFloat? { get set }
    var configuration: DemoEngineConfiguration { get set }

    @discardableResult
    func move(
        toDisplayHeight displayHeight: CGFloat,
        animated: Bool,
        options: DemoMovementOptions,
        completion: ((DemoMovementResult) -> Void)?
    ) -> CGFloat
    @discardableResult
    func settleToNearestDetent(
        animated: Bool,
        options: DemoMovementOptions,
        completion: ((DemoMovementResult) -> Void)?
    ) -> CGFloat
    func invalidatePanelLayout()
    func reloadScrollMetrics()
    func performAccessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool
    func invalidate()
}

@MainActor
enum DemoDragEngineFactory {
    static func make(implementation: DemoImplementation) -> DemoDragEngine {
        switch implementation {
        case .swift:
            return SwiftDemoDragEngine()
        case .objectiveC:
            return LegacyDemoDragEngine()
        }
    }
}

#if DEBUG
/// Keeps comparison diagnostics visually searchable and machine-filterable in the Xcode console.
/// Every emitted message begins with `~~~`; field order is stable so OC/Swift logs diff cleanly.
@MainActor
enum DemoDebugLogger {
    private static let outputQueue = DispatchQueue(label: "com.chbo297.BODragScrollDemo.diagnostics")

    static func log(
        _ implementation: DemoImplementation,
        _ category: String,
        fields: [String: String] = [:]
    ) {
        let renderedFields = fields.keys.sorted().map { key in
            let value = fields[key, default: "-"]
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "\(key)=\(value)"
        }.joined(separator: " ")
        let suffix = renderedFields.isEmpty ? "" : " \(renderedFields)"
        let message = "~~~[\(implementation.displayName)][\(category)]\(suffix)"
        outputQueue.async {
            NSLog("%@", message)
        }
    }

    static func describe(_ scrollView: UIScrollView) -> String {
        let pointer = Unmanaged.passUnretained(scrollView).toOpaque()
        let pointerText = "0x" + String(UInt(bitPattern: pointer), radix: 16)
        let identifier = scrollView.accessibilityIdentifier ?? "-"
        let inset = scrollView.adjustedContentInset
        let minimum = -inset.top
        let maximum = max(
            scrollView.contentSize.height + inset.bottom - scrollView.bounds.height,
            minimum
        )
        return [
            "\(String(describing: type(of: scrollView)))@\(pointerText)#\(identifier)",
            "offset=\(number(scrollView.contentOffset.y))",
            "range=\(number(minimum))->\(number(maximum))",
            "contentH=\(number(scrollView.contentSize.height))",
            "boundsH=\(number(scrollView.bounds.height))"
        ].joined(separator: ",")
    }

    static func number(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }
}
#endif
