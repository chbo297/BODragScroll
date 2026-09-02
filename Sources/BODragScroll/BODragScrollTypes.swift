//
//  BODragScrollTypes.swift
//  BODragScroll
//
//  Public vocabulary and configuration for BODragScroll.
//

#if canImport(UIKit)
import UIKit

// MARK: - Movement

/// How a movement between panel display heights is performed.
public enum BODragScrollMovementStyle: Sendable {
    /// Resolve the style from the behavior provider and then from the configuration.
    case automatic

    /// Use `UIScrollView`'s native scrolling and deceleration behavior.
    case systemScroll

    /// Set the model value immediately and animate the presentation layer with `UIView` animation.
    case viewAnimation
}

/// The reason a panel movement was initiated.
public enum BODragScrollMovementReason: Sendable, Equatable {
    case dragRelease
    case programmatic
    case nearestDetent
    case scrollToTop
    case accessibility
}

/// The way an initiated movement ended.
public enum BODragScrollMovementOutcome: Sendable, Equatable {
    case completed
    case cancelled
    case interrupted
}

/// Options for `scroll(toDisplayHeight:animated:options:completion:)`.
public struct BODragScrollMovementOptions {
    /// `.automatic` uses the behavior provider and then `configuration.movement.defaultStyle`.
    public var style: BODragScrollMovementStyle

    /// Initial velocity used by view-animation damping selection.
    public var initialVelocity: CGFloat

    /// An explicit view-animation duration. Values above 0.9 seconds are capped by the engine.
    public var duration: TimeInterval?

    /// Additional options used only by view animation.
    public var animationOptions: UIView.AnimationOptions

    public init(
        style: BODragScrollMovementStyle = .automatic,
        initialVelocity: CGFloat = 0,
        duration: TimeInterval? = nil,
        animationOptions: UIView.AnimationOptions = []
    ) {
        self.style = style
        self.initialVelocity = initialVelocity
        self.duration = duration
        self.animationOptions = animationOptions
    }
}

/// Completion information for one movement intention.
public struct BODragScrollMovementResult {
    public let requestedDisplayHeight: CGFloat
    public let finalDisplayHeight: CGFloat
    public let reason: BODragScrollMovementReason
    public let outcome: BODragScrollMovementOutcome

    public init(
        requestedDisplayHeight: CGFloat,
        finalDisplayHeight: CGFloat,
        reason: BODragScrollMovementReason,
        outcome: BODragScrollMovementOutcome
    ) {
        self.requestedDisplayHeight = requestedDisplayHeight
        self.finalDisplayHeight = finalDisplayHeight
        self.reason = reason
        self.outcome = outcome
    }
}

/// Which part of the composite scroll axis consumed the current movement.
public enum BODragScrollMotionSource {
    case panel
    case participant(UIScrollView)
}

/// Per-scroll update delivered to the event delegate.
public struct BODragScrollUpdate {
    public let displayHeight: CGFloat
    public let source: BODragScrollMotionSource

    public init(displayHeight: CGFloat, source: BODragScrollMotionSource) {
        self.displayHeight = displayHeight
        self.source = source
    }
}

// MARK: - Inner scrolling

/// A portion of an inner scroll view's offset range that participates at one panel display height.
///
/// The first segment may omit `beginOffsetY` to start at the effective top inset. The last segment
/// may omit `endOffsetY` to end at the scroll view's effective bottom offset.
public struct BODragScrollInnerScrollSegment: Sendable, Equatable {
    public var displayHeight: CGFloat
    public var beginOffsetY: CGFloat?
    public var endOffsetY: CGFloat?

    public init(
        displayHeight: CGFloat,
        beginOffsetY: CGFloat? = nil,
        endOffsetY: CGFloat? = nil
    ) {
        self.displayHeight = displayHeight
        self.beginOffsetY = beginOffsetY
        self.endOffsetY = endOffsetY
    }
}

/// Which interaction gets priority when an inner scroll view and the panel can both respond.
public enum BODragScrollHandoffMode: Sendable {
    /// The outer BODragScroll axis coordinates panel and participant offsets.
    case coordinated

    /// The inner scroll view handles the gesture independently; the panel does not participate.
    case innerFirst

    /// Prefer the inner scroll view while it can move in the gesture direction, otherwise move the panel.
    case innerFirstAtBoundary
}

/// How the default inner-scroll segment is selected when no segment is supplied by the provider.
public enum BODragScrollInnerScrollPlacement: Sendable, Equatable {
    case automatic
    case afterPanelFullyDisplayed
    case atDisplayHeight(CGFloat)
    case fromTouchedPosition
}

extension BODragScrollInnerScrollPlacement {
    var isSpecifiedHeight: Bool {
        if case .atDisplayHeight = self { return true }
        return false
    }
}

/// How to reconcile an inner offset that does not match the segment for the panel's current height.
public enum BODragScrollOffsetMismatchPolicy: Sendable {
    /// Preserve the inner offset and move the panel until the matching segment becomes reachable.
    case waitForValidSegment

    /// Reset the inner offset to the appropriate segment boundary.
    case restoreToBoundary

    /// Build a temporary segment beginning at the current panel and inner offsets.
    case continueFromCurrentOffset
}

/// Configuration for panel/inner-scroll handoff.
public struct BODragScrollHandoffPolicy: Sendable {
    public var mode: BODragScrollHandoffMode
    public var innerScrollPlacement: BODragScrollInnerScrollPlacement
    public var offsetMismatch: BODragScrollOffsetMismatchPolicy

    /// Prevent inertia that begins inside a participant from leaving its inner segment.
    public var preventsInnerToPanelHandoff: Bool

    /// Add resistance when moving from a larger display height toward a smaller detent.
    public var resistsCollapse: Bool

    /// Minimum portion of an inner scroll view that automatic placement tries to reveal before
    /// assigning an inner-scroll segment. The OC tuning value is 0.7.
    public var minimumInnerVisibilityRatio: CGFloat

    public init(
        mode: BODragScrollHandoffMode = .coordinated,
        innerScrollPlacement: BODragScrollInnerScrollPlacement = .automatic,
        offsetMismatch: BODragScrollOffsetMismatchPolicy = .waitForValidSegment,
        preventsInnerToPanelHandoff: Bool = false,
        resistsCollapse: Bool = false,
        minimumInnerVisibilityRatio: CGFloat = 0.7
    ) {
        self.mode = mode
        self.innerScrollPlacement = innerScrollPlacement
        self.offsetMismatch = offsetMismatch
        self.preventsInnerToPanelHandoff = preventsInnerToPanelHandoff
        self.resistsCollapse = resistsCollapse
        self.minimumInnerVisibilityRatio = minimumInnerVisibilityRatio
    }
}

// MARK: - Bounce

public enum BODragScrollBounceOwner: Sendable {
    case panel
    case innerScrollView
}

/// Configuration for transferring top and bottom overscroll between the panel and a participant.
public struct BODragScrollBouncePolicy: Sendable {
    public var allowsPanelTopBounce: Bool
    public var allowsPanelBottomBounce: Bool
    public var preferredTopOwner: BODragScrollBounceOwner
    public var preferredBottomOwner: BODragScrollBounceOwner

    /// Always choose the inner scroll view for top bounce, even when normal preference would choose the panel.
    public var forcesInnerTopBounce: Bool

    public init(
        allowsPanelTopBounce: Bool = true,
        allowsPanelBottomBounce: Bool = true,
        preferredTopOwner: BODragScrollBounceOwner = .panel,
        preferredBottomOwner: BODragScrollBounceOwner = .innerScrollView,
        forcesInnerTopBounce: Bool = false
    ) {
        self.allowsPanelTopBounce = allowsPanelTopBounce
        self.allowsPanelBottomBounce = allowsPanelBottomBounce
        self.preferredTopOwner = preferredTopOwner
        self.preferredBottomOwner = preferredBottomOwner
        self.forcesInnerTopBounce = forcesInnerTopBounce
    }
}

// MARK: - Capture

/// The default relationship between the panel gesture and another scroll view on the hit-test chain.
public enum BODragScrollCapturePriority: Int, Sendable {
    /// Do not recognize simultaneously; the panel gesture wins.
    case panelFirst = -1

    /// Recognize both interactions simultaneously.
    case simultaneous = 0

    /// Do not recognize simultaneously; the other scroll view wins.
    case otherFirst = 1

    /// Do not force either gesture to fail; defer to UIKit.
    case systemDefault = 2

    /// Include this scroll view as a participant in the composite scroll axis.
    case participant = 3
}

/// A scroll view discovered on the touch responder chain before a capture session is created.
public struct BODragScrollCaptureCandidate: Identifiable {
    public let id: ObjectIdentifier
    public let scrollView: UIScrollView
    public let hierarchyDepth: Int
    public let isVerticallyScrollable: Bool
    public var priority: BODragScrollCapturePriority

    init(
        scrollView: UIScrollView,
        hierarchyDepth: Int,
        isVerticallyScrollable: Bool,
        priority: BODragScrollCapturePriority
    ) {
        self.id = ObjectIdentifier(scrollView)
        self.scrollView = scrollView
        self.hierarchyDepth = hierarchyDepth
        self.isVerticallyScrollable = isVerticallyScrollable
        self.priority = priority
    }
}

/// The engine's proposed primary candidate and gesture priorities for one touch.
///
/// A behavior provider may change `primaryCandidateID` to another ID in `candidates`, or set it to
/// `nil` to decline capture. Participant IDs used by the platform-neutral scroll model are created
/// only after this UIKit proposal has been resolved.
public struct BODragScrollCaptureProposal {
    public var primaryCandidateID: ObjectIdentifier?
    public var candidates: [BODragScrollCaptureCandidate]
    public internal(set) var webView: UIView?

    init(
        primaryCandidateID: ObjectIdentifier?,
        candidates: [BODragScrollCaptureCandidate],
        webView: UIView?
    ) {
        self.primaryCandidateID = primaryCandidateID
        self.candidates = candidates
        self.webView = webView
    }

    public var primaryCandidate: BODragScrollCaptureCandidate? {
        guard let primaryCandidateID else { return nil }
        return candidates.first { $0.id == primaryCandidateID }
    }
}

/// Configuration that controls automatic participant discovery in Web content.
public struct BODragScrollCapturePolicy: Sendable {
    /// Decline capture when a touched Web view contains multiple vertically scrollable layers.
    public var ignoresMultipleNestedWebScrollViews: Bool

    /// Prevent the panel gesture from beginning for touches inside a Web view.
    public var disablesPanelInteractionInWebView: Bool

    public init(
        ignoresMultipleNestedWebScrollViews: Bool = false,
        disablesPanelInteractionInWebView: Bool = false
    ) {
        self.ignoresMultipleNestedWebScrollViews = ignoresMultipleNestedWebScrollViews
        self.disablesPanelInteractionInWebView = disablesPanelInteractionInWebView
    }
}

// MARK: - Gesture and accessibility

/// Resolution for a conflict between the panel gesture and a non-primary gesture.
public enum BODragScrollGestureStrategy: Sendable {
    case simultaneous
    case panelFirst
    case otherFirst
    case systemDefault
}

public struct BODragScrollGesturePolicy: Sendable {
    public var recognizesSimultaneouslyWithOtherGestures: Bool
    public var failsOtherTapDuringDeceleration: Bool

    public init(
        recognizesSimultaneouslyWithOtherGestures: Bool = true,
        failsOtherTapDuringDeceleration: Bool = true
    ) {
        self.recognizesSimultaneouslyWithOtherGestures = recognizesSimultaneouslyWithOtherGestures
        self.failsOtherTapDuringDeceleration = failsOtherTapDuringDeceleration
    }
}

/// How the component proceeds after asking the behavior provider about an accessibility scroll.
public enum BODragScrollAccessibilityDisposition: Sendable {
    /// The component may inspect inner content and then perform its default behavior.
    case automatic

    /// The provider already handled the operation.
    case handled

    /// Perform the component's panel behavior without trying to scroll an inner participant.
    case panelOnly
}

// MARK: - Movement policy

public struct BODragScrollMovementPolicy: Sendable {
    public var defaultStyle: BODragScrollMovementStyle

    /// Velocity below which release is treated as effectively stationary. The OC tuning value is 0.2.
    public var lowVelocityThreshold: CGFloat

    /// Velocity above which release may advance an additional detent. The OC tuning value is 2.2.
    public var highVelocityThreshold: CGFloat

    /// Near-boundary distance used by inner/outer and detent handoff. The OC tuning value is 86 points.
    public var nearBoundaryDistance: CGFloat

    /// Distance used when an outer movement first enters an inner segment. The OC tuning value is 140 points.
    public var outerToInnerSnapDistance: CGFloat

    /// View-animation speed in points per second. The engine clamps it to 100...100_000.
    public var speed: CGFloat

    public var baseDuration: TimeInterval
    public var maximumDuration: TimeInterval
    public var usesSpring: Bool

    /// Defer `displayHeight` callbacks until the presentation animation has been scheduled.
    public var defersDisplayHeightUpdates: Bool

    /// Animate the deferred `displayHeight` callback value rather than publishing it immediately.
    public var animatesDeferredDisplayHeightUpdates: Bool

    public init(
        defaultStyle: BODragScrollMovementStyle = .systemScroll,
        lowVelocityThreshold: CGFloat = 0.2,
        highVelocityThreshold: CGFloat = 2.2,
        nearBoundaryDistance: CGFloat = 86,
        outerToInnerSnapDistance: CGFloat = 140,
        speed: CGFloat = 1_000,
        baseDuration: TimeInterval = 0.12,
        maximumDuration: TimeInterval = 0.32,
        usesSpring: Bool = true,
        defersDisplayHeightUpdates: Bool = false,
        animatesDeferredDisplayHeightUpdates: Bool = false
    ) {
        self.defaultStyle = defaultStyle
        self.lowVelocityThreshold = lowVelocityThreshold
        self.highVelocityThreshold = highVelocityThreshold
        self.nearBoundaryDistance = nearBoundaryDistance
        self.outerToInnerSnapDistance = outerToInnerSnapDistance
        self.speed = speed
        self.baseDuration = baseDuration
        self.maximumDuration = maximumDuration
        self.usesSpring = usesSpring
        self.defersDisplayHeightUpdates = defersDisplayHeightUpdates
        self.animatesDeferredDisplayHeightUpdates = animatesDeferredDisplayHeightUpdates
    }
}

// MARK: - Configuration

/// Typed behavior configuration for `BODragScrollView`.
public struct BODragScrollConfiguration: Sendable {
    public var handoff: BODragScrollHandoffPolicy
    public var bounce: BODragScrollBouncePolicy
    public var capture: BODragScrollCapturePolicy
    public var gesture: BODragScrollGesturePolicy
    public var movement: BODragScrollMovementPolicy

    public init(
        handoff: BODragScrollHandoffPolicy = .init(),
        bounce: BODragScrollBouncePolicy = .init(),
        capture: BODragScrollCapturePolicy = .init(),
        gesture: BODragScrollGesturePolicy = .init(),
        movement: BODragScrollMovementPolicy = .init()
    ) {
        self.handoff = handoff
        self.bounce = bounce
        self.capture = capture
        self.gesture = gesture
        self.movement = movement
    }
}

// MARK: - Behavior provider

/// Synchronous decisions requested by `BODragScrollView` while laying out or resolving interaction.
@MainActor
public protocol BODragScrollBehaviorProvider: AnyObject {
    /// Optionally provide the panel size and adjust the display height proposed for this layout pass.
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        sizeFor panelView: UIView,
        firstLayout: Bool,
        proposedDisplayHeight: inout CGFloat
    ) -> CGSize?

    /// Return explicit inner-scroll segments, or nil/empty to use automatic placement.
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        segmentsFor scrollView: UIScrollView
    ) -> [BODragScrollInnerScrollSegment]?

    /// Whether a discovered scroll view may become the primary capture participant.
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        canCapture scrollView: UIScrollView
    ) -> Bool

    /// Adjust the primary candidate and per-candidate interaction priorities. This decision is requested
    /// for every eligible touch, including a single candidate in a single `WKWebView`.
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        adjustCaptureProposal proposal: inout BODragScrollCaptureProposal
    )

    /// Resolve a conflict with a gesture that is not the primary participant's pan gesture.
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        strategyFor gesture: UIGestureRecognizer,
        otherGesture: UIGestureRecognizer
    ) -> BODragScrollGestureStrategy?

    /// Return true to bypass detent resolution at this display height, false to require it, or nil
    /// to use the view's `nonSnappingRanges`.
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        shouldBypassDetentsAt displayHeight: CGFloat
    ) -> Bool?

    /// Choose how a resolved movement should be performed. `.automatic` uses the configuration.
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        movementStyleFrom fromDisplayHeight: CGFloat,
        to toDisplayHeight: CGFloat,
        reason: BODragScrollMovementReason
    ) -> BODragScrollMovementStyle

    /// Adjust the outer target after the component and primary participant have resolved their target.
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        adjustTargetContentOffset targetContentOffset: inout CGPoint,
        velocity: CGPoint
    )

    /// Decide whether a system scroll-to-top request should proceed.
    func dragScrollViewShouldScrollToTop(_ dragScrollView: BODragScrollView) -> Bool

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        accessibilityDispositionFor direction: UIAccessibilityScrollDirection
    ) -> BODragScrollAccessibilityDisposition
}

public extension BODragScrollBehaviorProvider {
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        sizeFor panelView: UIView,
        firstLayout: Bool,
        proposedDisplayHeight: inout CGFloat
    ) -> CGSize? { nil }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        segmentsFor scrollView: UIScrollView
    ) -> [BODragScrollInnerScrollSegment]? { nil }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        canCapture scrollView: UIScrollView
    ) -> Bool { true }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        adjustCaptureProposal proposal: inout BODragScrollCaptureProposal
    ) {}

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        strategyFor gesture: UIGestureRecognizer,
        otherGesture: UIGestureRecognizer
    ) -> BODragScrollGestureStrategy? { nil }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        shouldBypassDetentsAt displayHeight: CGFloat
    ) -> Bool? { nil }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        movementStyleFrom fromDisplayHeight: CGFloat,
        to toDisplayHeight: CGFloat,
        reason: BODragScrollMovementReason
    ) -> BODragScrollMovementStyle { .automatic }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        adjustTargetContentOffset targetContentOffset: inout CGPoint,
        velocity: CGPoint
    ) {}

    func dragScrollViewShouldScrollToTop(_ dragScrollView: BODragScrollView) -> Bool { true }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        accessibilityDispositionFor direction: UIAccessibilityScrollDirection
    ) -> BODragScrollAccessibilityDisposition { .automatic }
}

// MARK: - Event delegate

/// Event-only notifications emitted by `BODragScrollView`. Methods are invoked synchronously on the
/// main actor at their documented UIKit lifecycle point; decisions belong to the behavior provider.
@MainActor
public protocol BODragScrollEventDelegate: AnyObject {
    /// A value-change notification for the panel's current real display height.
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didChangeDisplayHeight displayHeight: CGFloat
    )

    /// Called once after the latest drag, deceleration, animation, bounce return, or deferred
    /// movement has completely stopped. This is a lifecycle event and may carry the same height as
    /// the preceding value-change callback.
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didBecomeIdleAtDisplayHeight displayHeight: CGFloat
    )

    /// A scrolling-event notification. Each host scroll event accepted by the engine is forwarded;
    /// it is not coalesced merely because the display height is unchanged.
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didScroll update: BODragScrollUpdate
    )

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        willMoveToDisplayHeight displayHeight: CGFloat,
        reason: BODragScrollMovementReason
    )

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didFinishMovement result: BODragScrollMovementResult
    )

    func dragScrollViewWillBeginDragging(_ dragScrollView: BODragScrollView)

    func dragScrollViewWillEndDragging(
        _ dragScrollView: BODragScrollView,
        velocity: CGPoint,
        resolvedTargetContentOffset: CGPoint
    )

    func dragScrollViewDidEndDragging(
        _ dragScrollView: BODragScrollView,
        willDecelerate: Bool
    )

    func dragScrollViewDidEndDecelerating(_ dragScrollView: BODragScrollView)
    func dragScrollViewDidEndScrollingAnimation(_ dragScrollView: BODragScrollView)
    func dragScrollViewDidScrollToTop(_ dragScrollView: BODragScrollView)
}

public extension BODragScrollEventDelegate {
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didChangeDisplayHeight displayHeight: CGFloat
    ) {}

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didBecomeIdleAtDisplayHeight displayHeight: CGFloat
    ) {}

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didScroll update: BODragScrollUpdate
    ) {}

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        willMoveToDisplayHeight displayHeight: CGFloat,
        reason: BODragScrollMovementReason
    ) {}

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didFinishMovement result: BODragScrollMovementResult
    ) {}

    func dragScrollViewWillBeginDragging(_ dragScrollView: BODragScrollView) {}

    func dragScrollViewWillEndDragging(
        _ dragScrollView: BODragScrollView,
        velocity: CGPoint,
        resolvedTargetContentOffset: CGPoint
    ) {}

    func dragScrollViewDidEndDragging(
        _ dragScrollView: BODragScrollView,
        willDecelerate: Bool
    ) {}

    func dragScrollViewDidEndDecelerating(_ dragScrollView: BODragScrollView) {}
    func dragScrollViewDidEndScrollingAnimation(_ dragScrollView: BODragScrollView) {}
    func dragScrollViewDidScrollToTop(_ dragScrollView: BODragScrollView) {}
}

#endif
