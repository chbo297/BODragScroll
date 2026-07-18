#if canImport(UIKit)
import UIKit
import WebKit
import XCTest
@testable import BODragScroll

@MainActor
private final class CaptureProposalSpy: BODragScrollBehaviorProvider {
    private(set) var adjustmentCallCount = 0
    private(set) var candidateCount = 0
    private(set) var hadPrimaryCandidate = false
    private(set) var containedWebView = false

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        adjustCaptureProposal proposal: inout BODragScrollCaptureProposal
    ) {
        adjustmentCallCount += 1
        candidateCount = proposal.candidates.count
        hadPrimaryCandidate = proposal.primaryCandidate != nil
        containedWebView = proposal.webView is WKWebView
    }
}

@MainActor
private final class OffsetObservingScrollView: UIScrollView {
    var offsetDidChange: ((CGPoint) -> Void)?

    override var contentOffset: CGPoint {
        didSet {
            guard contentOffset != oldValue else { return }
            offsetDidChange?(contentOffset)
        }
    }
}

@MainActor
private final class ContentOffsetRequestRecordingScrollView: UIScrollView {
    struct Request {
        let contentOffset: CGPoint
        let animated: Bool
    }

    private(set) var requests: [Request] = []
    private(set) var flashScrollIndicatorsCallCount = 0

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        requests.append(Request(contentOffset: contentOffset, animated: animated))
        super.setContentOffset(contentOffset, animated: animated)
    }

    override func flashScrollIndicators() {
        flashScrollIndicatorsCallCount += 1
        // This spy observes whether the coordinator crosses the indicator ownership boundary.
        // Do not invoke UIKit's presentation side effect: geometry is asserted independently.
    }

    func resetRequests() {
        requests.removeAll()
    }
}

@MainActor
private final class GeometryObservingPanelView: UIView {
    var onFirstCenterChange: (() -> Void)?
    private var hasFired = false
    private(set) var centerChanges: [CGPoint] = []

    override var center: CGPoint {
        didSet {
            guard center != oldValue else { return }
            centerChanges.append(center)
            if !hasFired, let onFirstCenterChange {
                hasFired = true
                onFirstCenterChange()
            }
        }
    }

    func resetCenterChanges() {
        centerChanges.removeAll()
        hasFired = false
    }
}

@MainActor
private final class FixedPanelSizeProvider: BODragScrollBehaviorProvider {
    let size: CGSize
    private(set) var layoutCallCount = 0

    init(size: CGSize) {
        self.size = size
    }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        sizeFor panelView: UIView,
        firstLayout: Bool,
        proposedDisplayHeight: inout CGFloat
    ) -> CGSize? {
        layoutCallCount += 1
        return size
    }
}

@MainActor
private final class LayoutDisplayHeightProvider: BODragScrollBehaviorProvider {
    let targetDisplayHeight: CGFloat
    var isArmed = false

    init(targetDisplayHeight: CGFloat) {
        self.targetDisplayHeight = targetDisplayHeight
    }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        sizeFor panelView: UIView,
        firstLayout: Bool,
        proposedDisplayHeight: inout CGFloat
    ) -> CGSize? {
        if isArmed {
            proposedDisplayHeight = targetDisplayHeight
        }
        return nil
    }
}

@MainActor
private final class CallbackPanelSizeProvider: BODragScrollBehaviorProvider {
    let size: CGSize
    var isArmed = false
    var onSize: ((BODragScrollView) -> Void)?
    private var hasFired = false

    init(size: CGSize) {
        self.size = size
    }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        sizeFor panelView: UIView,
        firstLayout: Bool,
        proposedDisplayHeight: inout CGFloat
    ) -> CGSize? {
        if isArmed, !hasFired {
            hasFired = true
            onSize?(dragScrollView)
        }
        return size
    }
}

@MainActor
private final class ParticipantLifecycleSpy: NSObject, UIScrollViewDelegate {
    var onWillBeginDragging: (() -> Void)?
    private(set) var began: [UIScrollView] = []
    private(set) var willEnd: [UIScrollView] = []
    private(set) var didEnd: [UIScrollView] = []
    private(set) var didDecelerate: [UIScrollView] = []

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        began.append(scrollView)
        onWillBeginDragging?()
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        willEnd.append(scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        didEnd.append(scrollView)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        didDecelerate.append(scrollView)
    }
}

@MainActor
private final class ReentrantDragLifecycleEventDelegate: BODragScrollEventDelegate {
    var onWillBeginDragging: (() -> Void)?
    private(set) var willBeginDraggingCount = 0
    private(set) var didEndDraggingValues: [Bool] = []

    func dragScrollViewWillBeginDragging(_ dragScrollView: BODragScrollView) {
        willBeginDraggingCount += 1
        onWillBeginDragging?()
    }

    func dragScrollViewDidEndDragging(
        _ dragScrollView: BODragScrollView,
        willDecelerate: Bool
    ) {
        didEndDraggingValues.append(willDecelerate)
    }
}

@MainActor
private final class ReentrantParticipantLifecycleDelegate: NSObject, UIScrollViewDelegate {
    var onDidEndDragging: (() -> Void)?

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        onDidEndDragging?()
    }
}

@MainActor
private final class SyntheticDecelerationMutationDelegate: NSObject, UIScrollViewDelegate {
    var onDidEndDecelerating: (() -> Void)?
    private(set) var didEndDeceleratingCount = 0
    private(set) var willBeginDraggingCount = 0

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        willBeginDraggingCount += 1
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        didEndDeceleratingCount += 1
        onDidEndDecelerating?()
    }
}

@MainActor
private final class AccessibilityPanelOnlyProvider: BODragScrollBehaviorProvider {
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        accessibilityDispositionFor direction: UIAccessibilityScrollDirection
    ) -> BODragScrollAccessibilityDisposition {
        .panelOnly
    }
}

@MainActor
private final class ReentrantDecelerationDelegate: BODragScrollEventDelegate {
    var onDidEndDecelerating: (() -> Void)?
    var onDidFinishMovement: ((BODragScrollMovementResult) -> Void)?
    private(set) var willBeginDraggingCount = 0
    private(set) var didEndDeceleratingCount = 0
    private(set) var results: [BODragScrollMovementResult] = []

    func dragScrollViewWillBeginDragging(_ dragScrollView: BODragScrollView) {
        willBeginDraggingCount += 1
    }

    func dragScrollViewDidEndDecelerating(_ dragScrollView: BODragScrollView) {
        didEndDeceleratingCount += 1
        onDidEndDecelerating?()
    }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didFinishMovement result: BODragScrollMovementResult
    ) {
        results.append(result)
        onDidFinishMovement?(result)
    }
}

@MainActor
private final class EndingCaptureProvider: BODragScrollBehaviorProvider {
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        segmentsFor scrollView: UIScrollView
    ) -> [BODragScrollInnerScrollSegment]? {
        dragScrollView.endCapture()
        return nil
    }
}

@MainActor
private final class DisplayHeightCallbackDelegate: BODragScrollEventDelegate {
    var onFirstChange: ((BODragScrollView) -> Void)?
    private var hasFired = false

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didChangeDisplayHeight displayHeight: CGFloat
    ) {
        guard !hasFired else { return }
        hasFired = true
        onFirstChange?(dragScrollView)
    }
}

@MainActor
private final class MovementEventRecorder: BODragScrollEventDelegate {
    private(set) var changedDisplayHeights: [CGFloat] = []
    private(set) var scrollUpdates: [BODragScrollUpdate] = []
    private(set) var announcedDisplayHeights: [CGFloat] = []
    private(set) var results: [BODragScrollMovementResult] = []

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didChangeDisplayHeight displayHeight: CGFloat
    ) {
        changedDisplayHeights.append(displayHeight)
    }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didScroll update: BODragScrollUpdate
    ) {
        scrollUpdates.append(update)
    }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        willMoveToDisplayHeight displayHeight: CGFloat,
        reason: BODragScrollMovementReason
    ) {
        announcedDisplayHeights.append(displayHeight)
    }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didFinishMovement result: BODragScrollMovementResult
    ) {
        results.append(result)
    }
}

@MainActor
private final class TargetOffsetAdjustmentProvider: BODragScrollBehaviorProvider {
    let deltaY: CGFloat

    init(deltaY: CGFloat) {
        self.deltaY = deltaY
    }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        adjustTargetContentOffset targetContentOffset: inout CGPoint,
        velocity: CGPoint
    ) {
        targetContentOffset.y += deltaY
    }
}

@MainActor
private final class SegmentProvider: BODragScrollBehaviorProvider {
    let segments: [BODragScrollInnerScrollSegment]

    init(_ segments: [BODragScrollInnerScrollSegment]) {
        self.segments = segments
    }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        segmentsFor scrollView: UIScrollView
    ) -> [BODragScrollInnerScrollSegment]? {
        segments
    }
}

@MainActor
private final class ReentrantMovementStyleProvider: BODragScrollBehaviorProvider {
    private var hasMoved = false

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        movementStyleFrom fromDisplayHeight: CGFloat,
        to toDisplayHeight: CGFloat,
        reason: BODragScrollMovementReason
    ) -> BODragScrollMovementStyle {
        if !hasMoved {
            hasMoved = true
            dragScrollView.move(toDisplayHeight: 180, animated: false)
        }
        return .viewAnimation
    }
}

@MainActor
private final class MovementStyleCallRecorder: BODragScrollBehaviorProvider {
    private(set) var callCount = 0

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        movementStyleFrom fromDisplayHeight: CGFloat,
        to toDisplayHeight: CGFloat,
        reason: BODragScrollMovementReason
    ) -> BODragScrollMovementStyle {
        callCount += 1
        return .systemScroll
    }
}

@MainActor
private final class ReentrantBypassProvider: BODragScrollBehaviorProvider {
    var onDecision: ((BODragScrollView) -> Void)?
    private var hasFired = false

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        shouldBypassDetentsAt displayHeight: CGFloat
    ) -> Bool? {
        guard !hasFired else { return nil }
        hasFired = true
        onDecision?(dragScrollView)
        return nil
    }
}

@MainActor
private final class ReentrantSegmentProvider: BODragScrollBehaviorProvider {
    var isArmed = false
    var onSegments: ((BODragScrollView) -> Void)?
    private var hasFired = false

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        segmentsFor scrollView: UIScrollView
    ) -> [BODragScrollInnerScrollSegment]? {
        if isArmed, !hasFired {
            hasFired = true
            onSegments?(dragScrollView)
        }
        return nil
    }
}

@MainActor
private final class ScrollsToTopCallbackScrollView: UIScrollView {
    var onFirstDisable: (() -> Void)?
    private var hasFired = false

    override var scrollsToTop: Bool {
        didSet {
            guard !scrollsToTop, !hasFired else { return }
            hasFired = true
            onFirstDisable?()
        }
    }
}

@MainActor
final class BODragScrollUIKitIntegrationTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 320, height: 640)

    // MARK: - Public layout and movement

    func testPublicLayoutUsesDefaultDisplayHeight() {
        let (dragScrollView, panelView) = makeHost()

        XCTAssertTrue(dragScrollView.panelView === panelView)
        XCTAssertTrue(panelView.superview === dragScrollView)
        XCTAssertEqual(dragScrollView.displayHeight, 66, accuracy: 0.001)
        XCTAssertEqual(dragScrollView.contentSize, CGSize(width: 320, height: 800))
        XCTAssertEqual(dragScrollView.contentOffset.y, -574, accuracy: 0.001)
    }

    func testExternalNilDelegateAssignmentCannotDetachEngineDelegate() {
        let (dragScrollView, _) = makeHost()

        dragScrollView.delegate = nil

        XCTAssertTrue(dragScrollView.delegate === dragScrollView)
        dragScrollView.contentOffset.y += 20
        dragScrollView.scrollViewDidScroll(dragScrollView)
        XCTAssertEqual(dragScrollView.displayHeight, 86, accuracy: 0.001)
    }

    func testEngineDelegateInvariantDoesNotPreventHostDeallocation() {
        weak var weakHost: BODragScrollView?

        autoreleasepool {
            let dragScrollView = BODragScrollView(frame: viewport)
            weakHost = dragScrollView
            dragScrollView.delegate = nil
            XCTAssertTrue(dragScrollView.delegate === dragScrollView)
        }

        XCTAssertNil(weakHost)
    }

    func testDetentsNormalizeToFiniteFloat32ValuesAndDeduplicate() {
        let dragScrollView = BODragScrollView(frame: viewport)
        let losesOneAtFloat32 = CGFloat(16_777_217)

        dragScrollView.detentHeights = [
            .infinity,
            100,
            losesOneAtFloat32,
            .nan,
            100,
            16_777_216,
            -.infinity
        ]

        XCTAssertEqual(dragScrollView.detentHeights, [100, 16_777_216])
        XCTAssertEqual(
            dragScrollView.detentHeights.last,
            CGFloat(Float(losesOneAtFloat32))
        )
    }

    func testPreLayoutUnanimatedMoveIsAppliedAfterFirstLayout() {
        let (dragScrollView, _) = makeHost(layout: false)

        let acceptedHeight = dragScrollView.move(toDisplayHeight: 240, animated: false)

        XCTAssertEqual(acceptedHeight, 240)
        XCTAssertEqual(dragScrollView.displayHeight, 0)

        layout(dragScrollView)

        XCTAssertEqual(dragScrollView.displayHeight, 240, accuracy: 0.001)
        XCTAssertEqual(dragScrollView.contentOffset.y, -400, accuracy: 0.001)
    }

    func testPreLayoutUnanimatedMoveUsesDisabledPanelBounceLimits() {
        func makeConstrainedHost() -> BODragScrollView {
            let (host, _) = makeHost(detents: [100, 300], layout: false)
            var configuration = host.configuration
            configuration.bounce.allowsPanelTopBounce = false
            configuration.bounce.allowsPanelBottomBounce = false
            host.configuration = configuration
            return host
        }

        let upperHost = makeConstrainedHost()
        var upperResults: [BODragScrollMovementResult] = []
        XCTAssertEqual(
            upperHost.move(toDisplayHeight: 500, animated: false) {
                upperResults.append($0)
            },
            500
        )
        layout(upperHost)
        XCTAssertEqual(upperHost.displayHeight, 300, accuracy: 0.001)
        XCTAssertEqual(upperResults.map(\.finalDisplayHeight), [300])
        XCTAssertEqual(upperResults.map(\.outcome), [.completed])

        let lowerHost = makeConstrainedHost()
        var lowerResults: [BODragScrollMovementResult] = []
        XCTAssertEqual(
            lowerHost.move(toDisplayHeight: 0, animated: false) {
                lowerResults.append($0)
            },
            0
        )
        layout(lowerHost)
        XCTAssertEqual(lowerHost.displayHeight, 100, accuracy: 0.001)
        XCTAssertEqual(lowerResults.map(\.finalDisplayHeight), [100])
        XCTAssertEqual(lowerResults.map(\.outcome), [.completed])
    }

    func testUnanimatedMoveCompletesExactlyOnce() {
        let (dragScrollView, _) = makeHost()
        var results: [BODragScrollMovementResult] = []

        let resolvedHeight = dragScrollView.move(
            toDisplayHeight: 260,
            animated: false
        ) { results.append($0) }

        XCTAssertEqual(resolvedHeight, 260, accuracy: 0.001)
        XCTAssertEqual(dragScrollView.displayHeight, 260, accuracy: 0.001)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.requestedDisplayHeight, 260)
        XCTAssertEqual(results.first?.finalDisplayHeight, 260)
        XCTAssertEqual(results.first?.reason, .programmatic)
        XCTAssertEqual(results.first?.outcome, .completed)

        // A late UIKit lifecycle callback must not finish an already-completed intention again.
        dragScrollView.scrollViewDidEndScrollingAnimation(dragScrollView)
        XCTAssertEqual(results.count, 1)
    }

    func testDisplayHeightStoresEveryRealValueButValueChangeCallbackUsesCumulativeBaseline() {
        let (dragScrollView, _) = makeHost()
        let recorder = MovementEventRecorder()
        dragScrollView.eventDelegate = recorder
        let baseline = dragScrollView.displayHeight

        dragScrollView.setDisplayHeight(baseline + 0.000_05, source: .panel)

        XCTAssertEqual(dragScrollView.displayHeight, baseline + 0.000_05)
        XCTAssertTrue(recorder.changedDisplayHeights.isEmpty)

        dragScrollView.setDisplayHeight(baseline + 0.000_15, source: .panel)

        XCTAssertEqual(dragScrollView.displayHeight, baseline + 0.000_15)
        XCTAssertEqual(recorder.changedDisplayHeights, [baseline + 0.000_15])

        let scrollCountBefore = recorder.scrollUpdates.count
        dragScrollView.scrollViewDidScroll(dragScrollView)
        dragScrollView.scrollViewDidScroll(dragScrollView)
        XCTAssertEqual(recorder.scrollUpdates.count - scrollCountBefore, 2)
    }

    func testSameHeightDragReleaseStillPublishesMovementIntentAndCompletion() {
        let (dragScrollView, _) = makeHost(detents: [100, 300])
        let recorder = MovementEventRecorder()
        dragScrollView.eventDelegate = recorder
        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        var target = dragScrollView.contentOffset

        dragScrollView.scrollViewWillEndDragging(
            dragScrollView,
            withVelocity: .zero,
            targetContentOffset: &target
        )
        dragScrollView.scrollViewDidEndDragging(dragScrollView, willDecelerate: false)

        XCTAssertEqual(recorder.announcedDisplayHeights, [dragScrollView.displayHeight])
        XCTAssertEqual(recorder.results.count, 1)
        XCTAssertEqual(recorder.results.first?.reason, .dragRelease)
        XCTAssertEqual(recorder.results.first?.outcome, .completed)
    }

    func testExternalTargetAdjustmentSmallerThanValueToleranceRemainsAuthoritative() {
        let (dragScrollView, _) = makeHost(detents: [100, 300])
        let provider = TargetOffsetAdjustmentProvider(deltaY: 0.000_05)
        let recorder = MovementEventRecorder()
        dragScrollView.behaviorProvider = provider
        _ = dragScrollView.move(toDisplayHeight: 180, animated: false)
        dragScrollView.eventDelegate = recorder
        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        var target = CGPoint(x: 0, y: 300 - dragScrollView.bounds.height)

        dragScrollView.scrollViewWillEndDragging(
            dragScrollView,
            withVelocity: CGPoint(x: 0, y: 3),
            targetContentOffset: &target
        )

        XCTAssertEqual(target.y, 300 - dragScrollView.bounds.height + 0.000_05)
        XCTAssertEqual(recorder.announcedDisplayHeights, [300.000_05])
        XCTAssertNotEqual(recorder.announcedDisplayHeights.first, 300)

        dragScrollView.scrollViewDidEndDragging(dragScrollView, willDecelerate: true)
        dragScrollView.interruptActiveMovement(outcome: .interrupted)
    }

    func testNoScrollSystemTargetCanonicalizesPublicHeightWithoutRewritingPanel() {
        let (dragScrollView, panelView) = makeHost(detents: [100, 200, 300])
        let window = attachToWindow(dragScrollView)
        defer { window.isHidden = true }
        _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
        var residualFrame = panelView.frame
        residualFrame.origin.y += 0.000_01
        dragScrollView.setPanelFrame(residualFrame)
        let residualDisplayHeight = dragScrollView.displayHeightForCurrentGeometry
        let panelFrameBeforeMovement = panelView.frame
        XCTAssertNotEqual(residualDisplayHeight, 300)
        var results: [BODragScrollMovementResult] = []

        let resolved = dragScrollView.move(
            toDisplayHeight: 300,
            animated: true,
            options: BODragScrollMovementOptions(style: .systemScroll)
        ) { results.append($0) }

        XCTAssertEqual(resolved, 300)
        XCTAssertEqual(dragScrollView.contentOffset.y, 300 - dragScrollView.bounds.height)
        XCTAssertEqual(dragScrollView.displayHeightForCurrentGeometry, residualDisplayHeight)
        XCTAssertEqual(panelView.frame, panelFrameBeforeMovement)
        XCTAssertEqual(dragScrollView.displayHeight, 300)
        XCTAssertEqual(results.map(\.finalDisplayHeight), [300])

        let styleRecorder = MovementStyleCallRecorder()
        dragScrollView.behaviorProvider = styleRecorder
        _ = dragScrollView.move(toDisplayHeight: 300, animated: true)
        XCTAssertEqual(styleRecorder.callCount, 0)
    }

    func testNoScrollNonSystemMovementsDoNotApplyNaturalScrollResidualCorrection() {
        do {
            let (dragScrollView, panelView) = makeHost(detents: [100, 300])
            let window = attachToWindow(dragScrollView)
            defer { window.isHidden = true }
            _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
            var residualFrame = panelView.frame
            residualFrame.origin.y += 0.000_01
            dragScrollView.setPanelFrame(residualFrame)
            let residualHeight = dragScrollView.displayHeightForCurrentGeometry

            _ = dragScrollView.move(
                toDisplayHeight: 300,
                animated: true,
                options: BODragScrollMovementOptions(style: .viewAnimation)
            )

            XCTAssertEqual(
                dragScrollView.displayHeightForCurrentGeometry,
                residualHeight,
                accuracy: 0.000_000_001
            )
            XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
        }

        do {
            let (dragScrollView, panelView) = makeHost(detents: [100, 300])
            _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
            var residualFrame = panelView.frame
            residualFrame.origin.y += 0.000_01
            dragScrollView.setPanelFrame(residualFrame)
            let residualHeight = dragScrollView.displayHeightForCurrentGeometry

            _ = dragScrollView.move(toDisplayHeight: 300, animated: false)

            XCTAssertEqual(
                dragScrollView.displayHeightForCurrentGeometry,
                residualHeight,
                accuracy: 0.000_000_001
            )
            XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
        }
    }

    func testSettleWithoutDetentsIsANoOpWithoutMovementEvents() {
        let (dragScrollView, _) = makeHost()
        let recorder = MovementEventRecorder()
        dragScrollView.eventDelegate = recorder
        var completionCount = 0
        let originalOffset = dragScrollView.contentOffset

        let result = dragScrollView.settleToNearestDetent(animated: false) { _ in
            completionCount += 1
        }

        XCTAssertEqual(result, dragScrollView.displayHeight)
        XCTAssertEqual(dragScrollView.contentOffset, originalOffset)
        XCTAssertTrue(recorder.announcedDisplayHeights.isEmpty)
        XCTAssertTrue(recorder.results.isEmpty)
        XCTAssertEqual(completionCount, 0)
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
    }

    func testNewMovementInterruptsPendingMovementAndEachCompletionFiresOnce() {
        let (dragScrollView, _) = makeHost(layout: false)
        var firstResults: [BODragScrollMovementResult] = []
        var secondResults: [BODragScrollMovementResult] = []

        dragScrollView.move(toDisplayHeight: 180, animated: false) {
            firstResults.append($0)
        }
        dragScrollView.move(toDisplayHeight: 300, animated: false) {
            secondResults.append($0)
        }

        XCTAssertEqual(firstResults.map(\.outcome), [.interrupted])
        XCTAssertTrue(secondResults.isEmpty)

        layout(dragScrollView)
        layout(dragScrollView)

        XCTAssertEqual(firstResults.count, 1)
        XCTAssertEqual(secondResults.map(\.outcome), [.completed])
        XCTAssertEqual(dragScrollView.displayHeight, 300, accuracy: 0.001)
    }

    func testPanelMovementClampsWhenPanelBounceIsDisabled() {
        let (dragScrollView, _) = makeHost(detents: [100, 300], layout: false)
        var configuration = dragScrollView.configuration
        configuration.bounce.allowsPanelTopBounce = false
        configuration.bounce.allowsPanelBottomBounce = false
        dragScrollView.configuration = configuration
        layout(dragScrollView)

        let upperResult = dragScrollView.move(toDisplayHeight: 500, animated: false)
        XCTAssertEqual(upperResult, 300, accuracy: 0.001)
        XCTAssertEqual(dragScrollView.displayHeight, 300, accuracy: 0.001)

        let lowerResult = dragScrollView.move(toDisplayHeight: 0, animated: false)
        XCTAssertEqual(lowerResult, 100, accuracy: 0.001)
        XCTAssertEqual(dragScrollView.displayHeight, 100, accuracy: 0.001)
    }

    func testProgrammaticMovementIsAbsoluteAfterDisabledBounceTranslation() {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300], layout: false)
        var configuration = dragScrollView.configuration
        configuration.bounce.allowsPanelTopBounce = false
        configuration.bounce.allowsPanelBottomBounce = false
        dragScrollView.configuration = configuration
        layout(dragScrollView)

        dragScrollView.contentOffset.y = dragScrollView.minimumOuterOffset - 50
        dragScrollView.scrollViewDidScroll(dragScrollView)
        XCTAssertNotEqual(panelView.frame.minY, 0)
        XCTAssertEqual(dragScrollView.displayHeight, 100, accuracy: 0.001)

        _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
        XCTAssertEqual(panelView.frame.minY, 0, accuracy: 0.001)
        XCTAssertEqual(dragScrollView.displayHeight, 300, accuracy: 0.001)

        dragScrollView.contentOffset.y = dragScrollView.maximumOuterOffset + 50
        dragScrollView.scrollViewDidScroll(dragScrollView)
        XCTAssertNotEqual(panelView.frame.minY, 0)
        XCTAssertEqual(dragScrollView.displayHeight, 300, accuracy: 0.001)

        _ = dragScrollView.move(toDisplayHeight: 100, animated: false)
        XCTAssertEqual(panelView.frame.minY, 0, accuracy: 0.001)
        XCTAssertEqual(dragScrollView.displayHeight, 100, accuracy: 0.001)
    }

    func testFirstLayoutUsesProviderPanelHeightForNoDetentGeometry() {
        let dragScrollView = BODragScrollView(frame: viewport)
        let provider = FixedPanelSizeProvider(size: CGSize(width: 320, height: 800))
        dragScrollView.behaviorProvider = provider
        dragScrollView.panelView = UIView(frame: .zero)

        layout(dragScrollView)

        XCTAssertEqual(dragScrollView.contentSize.height, 800, accuracy: 0.001)
        XCTAssertEqual(dragScrollView.maximumOuterOffset, 160, accuracy: 0.001)
        XCTAssertEqual(
            dragScrollView.move(toDisplayHeight: 800, animated: false),
            800,
            accuracy: 0.001
        )
    }

    func testReplacingBehaviorProviderRelayoutsSameSizedHost() throws {
        let dragScrollView = BODragScrollView(frame: viewport)
        let firstProvider = FixedPanelSizeProvider(size: CGSize(width: 320, height: 800))
        dragScrollView.behaviorProvider = firstProvider
        dragScrollView.panelView = UIView(frame: .zero)
        layout(dragScrollView)

        let secondProvider = FixedPanelSizeProvider(size: CGSize(width: 320, height: 900))
        dragScrollView.behaviorProvider = secondProvider
        layout(dragScrollView)

        XCTAssertEqual(try XCTUnwrap(dragScrollView.panelView).frame.height, 900, accuracy: 0.001)
        XCTAssertEqual(secondProvider.layoutCallCount, 1)
    }

    func testSizingProviderReplacementDiscardsOlderProviderResult() {
        let dragScrollView = BODragScrollView(frame: viewport)
        let newerProvider = FixedPanelSizeProvider(size: CGSize(width: 320, height: 900))
        let olderProvider = CallbackPanelSizeProvider(size: CGSize(width: 320, height: 700))
        olderProvider.isArmed = true
        olderProvider.onSize = { host in
            host.behaviorProvider = newerProvider
        }
        dragScrollView.behaviorProvider = olderProvider
        dragScrollView.panelView = UIView(frame: .zero)

        layout(dragScrollView)
        layout(dragScrollView)

        XCTAssertTrue(dragScrollView.behaviorProvider === newerProvider)
        XCTAssertEqual(dragScrollView.panelView?.frame.height ?? .nan, 900, accuracy: 0.001)
    }

    func testLayoutSetterReentrancyPreservesReplacementPanelsPendingMovement() {
        let dragScrollView = BODragScrollView(frame: viewport)
        let originalPanel = GeometryObservingPanelView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 800)
        )
        let replacementPanel = UIView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 800)
        )
        var results: [BODragScrollMovementResult] = []
        dragScrollView.panelView = originalPanel
        originalPanel.onFirstCenterChange = {
            // Both calls occur inside layout's internal UIKit mutation and are drained in order
            // before the older layout stack resumes.
            dragScrollView.panelView = replacementPanel
            dragScrollView.move(toDisplayHeight: 240, animated: false) {
                results.append($0)
            }
        }

        layout(dragScrollView)
        layout(dragScrollView)

        XCTAssertTrue(dragScrollView.panelView === replacementPanel)
        XCTAssertEqual(dragScrollView.displayHeight, 240, accuracy: 0.001)
        XCTAssertEqual(results.map(\.outcome), [.completed])
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
        XCTAssertNil(dragScrollView.runtime.transition.pendingLayoutMovement)
    }

    func testSizeChangeFinishesOldMovementBeforeDeferredNewMovement() {
        let (dragScrollView, _) = makeHost(detents: [100, 300])
        let window = attachToWindow(dragScrollView)
        defer { window.isHidden = true }
        let provider = CallbackPanelSizeProvider(size: CGSize(width: 320, height: 800))
        dragScrollView.behaviorProvider = provider
        layout(dragScrollView)
        var configuration = dragScrollView.configuration
        configuration.movement.defaultStyle = .viewAnimation
        configuration.movement.baseDuration = 0.5
        configuration.movement.maximumDuration = 0.5
        dragScrollView.configuration = configuration
        var order: [String] = []
        var oldResult: BODragScrollMovementResult?
        var oldCallbackHeight: CGFloat?

        dragScrollView.move(toDisplayHeight: 300, animated: true) { result in
            order.append("old")
            oldResult = result
            oldCallbackHeight = dragScrollView.displayHeight
        }
        provider.onSize = { host in
            host.move(toDisplayHeight: 220, animated: false) { _ in
                order.append("new")
            }
        }
        provider.isArmed = true

        dragScrollView.frame.size.height = 700
        layout(dragScrollView)

        XCTAssertEqual(order, ["old", "new"])
        XCTAssertEqual(oldResult?.outcome, .interrupted)
        XCTAssertEqual(oldResult?.finalDisplayHeight, oldCallbackHeight)
        XCTAssertEqual(dragScrollView.displayHeight, 220, accuracy: 0.001)
    }

    func testPanelOnlySettleUsesDetentsWithoutACaptureSession() {
        let (dragScrollView, _) = makeHost(detents: [100, 300])
        XCTAssertNil(dragScrollView.runtime.capture.session)
        _ = dragScrollView.move(toDisplayHeight: 180, animated: false)

        let settled = dragScrollView.settleToNearestDetent(animated: false)

        XCTAssertEqual(settled, 100, accuracy: 0.001)
        XCTAssertEqual(dragScrollView.displayHeight, 100, accuracy: 0.001)
    }

    func testZeroDurationDeferredViewAnimationPublishesFinalDisplayHeight() async {
        let (dragScrollView, _) = makeHost(detents: [100, 300])
        var configuration = dragScrollView.configuration
        configuration.movement.defaultStyle = .viewAnimation
        configuration.movement.baseDuration = 0
        configuration.movement.maximumDuration = 0
        configuration.movement.defersDisplayHeightUpdates = true
        configuration.movement.animatesDeferredDisplayHeightUpdates = false
        dragScrollView.configuration = configuration

        let completed = expectation(description: "view animation completion")
        dragScrollView.move(toDisplayHeight: 300, animated: true) { _ in
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 1)
        await Task.yield()
        XCTAssertEqual(dragScrollView.displayHeight, 300, accuracy: 0.001)
    }

    func testViewAnimationDragReleaseUsesItsActualNondeceleratingLifecycle() {
        let (dragScrollView, _) = makeHost(detents: [100, 300])
        let window = attachToWindow(dragScrollView)
        let lifecycle = ReentrantDragLifecycleEventDelegate()
        defer {
            dragScrollView.eventDelegate = nil
            dragScrollView.interruptActiveMovement(outcome: .interrupted)
            window.isHidden = true
        }
        var configuration = dragScrollView.configuration
        configuration.movement.defaultStyle = .viewAnimation
        configuration.movement.baseDuration = 1
        configuration.movement.maximumDuration = 1
        dragScrollView.configuration = configuration
        dragScrollView.eventDelegate = lifecycle
        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        let offsetBeforeRelease = dragScrollView.contentOffset
        var target = CGPoint(
            x: dragScrollView.contentOffset.x,
            y: 300 - dragScrollView.bounds.height
        )

        dragScrollView.scrollViewWillEndDragging(
            dragScrollView,
            withVelocity: CGPoint(x: 0, y: 1),
            targetContentOffset: &target
        )

        XCTAssertEqual(dragScrollView.runtime.transition.driver, .viewAnimation)
        XCTAssertEqual(target, offsetBeforeRelease)

        // UIKit's predicted flag is stale after BODragScroll pins its target and replaces native
        // deceleration with a view animation. Public lifecycle must describe the actual owner.
        dragScrollView.scrollViewDidEndDragging(
            dragScrollView,
            willDecelerate: true
        )

        XCTAssertFalse(dragScrollView.runtime.transition.isAwaitingDidEndDecelerating)
        XCTAssertFalse(dragScrollView.runtime.transition.isUserDragLifecycleActive)
        XCTAssertEqual(dragScrollView.runtime.transition.driver, .viewAnimation)
        XCTAssertEqual(lifecycle.willBeginDraggingCount, 1)
        XCTAssertEqual(lifecycle.didEndDraggingValues, [false])
    }

    func testViewAnimationDragReleaseDoesNotCreateFalseMetricsInvalidation() async throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 200, 300])
        let window = attachToWindow(dragScrollView)
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        let provider = SegmentProvider([
            BODragScrollInnerScrollSegment(
                displayHeight: 300,
                beginOffsetY: 0,
                endOffsetY: 600
            )
        ])
        dragScrollView.behaviorProvider = provider
        var configuration = dragScrollView.configuration
        configuration.movement.defaultStyle = .viewAnimation
        configuration.movement.baseDuration = 0.01
        configuration.movement.maximumDuration = 0.01
        dragScrollView.configuration = configuration
        layout(dragScrollView)
        dragScrollView.beginCapture(from: leafView)
        let session = try XCTUnwrap(dragScrollView.runtime.capture.session)
        _ = try XCTUnwrap(session.model)
        let events = ReentrantDecelerationDelegate()
        let completed = expectation(description: "view-animation drag release completed")
        events.onDidFinishMovement = { result in
            guard result.reason == .dragRelease else { return }
            completed.fulfill()
        }
        dragScrollView.eventDelegate = events
        defer {
            dragScrollView.eventDelegate = nil
            dragScrollView.interruptActiveMovement(outcome: .interrupted)
            dragScrollView.endCapture()
            window.isHidden = true
            _ = provider
        }

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        var target = CGPoint(
            x: dragScrollView.contentOffset.x,
            y: 200 - dragScrollView.bounds.height
        )
        dragScrollView.scrollViewWillEndDragging(
            dragScrollView,
            withVelocity: CGPoint(x: 0, y: 1),
            targetContentOffset: &target
        )
        XCTAssertEqual(dragScrollView.runtime.transition.driver, .viewAnimation)
        dragScrollView.scrollViewDidEndDragging(dragScrollView, willDecelerate: false)

        await fulfillment(of: [completed], timeout: 1)

        XCTAssertFalse(session.hasDeferredMetricsChange)
        XCTAssertEqual(events.results.map(\.outcome), [.completed])
        XCTAssertNil(dragScrollView.runtime.capture.session)
    }

    func testViewAnimationCompletionDuringTrackingKeepsCaptureForRealDrag() async throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 200, 300])
        let window = attachToWindow(dragScrollView)
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        let provider = SegmentProvider([
            BODragScrollInnerScrollSegment(
                displayHeight: 300,
                beginOffsetY: 0,
                endOffsetY: 600
            )
        ])
        dragScrollView.behaviorProvider = provider
        var configuration = dragScrollView.configuration
        configuration.movement.defaultStyle = .viewAnimation
        configuration.movement.baseDuration = 0.03
        configuration.movement.maximumDuration = 0.03
        dragScrollView.configuration = configuration
        layout(dragScrollView)
        dragScrollView.beginCapture(from: leafView)
        let session = try XCTUnwrap(dragScrollView.runtime.capture.session)
        let events = ReentrantDecelerationDelegate()
        let completed = expectation(description: "view animation completed under tracking touch")
        events.onDidFinishMovement = { result in
            guard result.reason == .dragRelease else { return }
            completed.fulfill()
        }
        dragScrollView.eventDelegate = events
        let trackingDidBegin = NSSelectorFromString("_trackingDidBegin")
        let trackingDidEnd = NSSelectorFromString("_trackingDidEnd")
        guard dragScrollView.responds(to: trackingDidBegin),
              dragScrollView.responds(to: trackingDidEnd) else {
            XCTFail("This UIKit runtime cannot expose a physical tracking-only test state.")
            return
        }
        defer {
            if dragScrollView.nativeScrollState.isTracking {
                dragScrollView.perform(trackingDidEnd)
            }
            if dragScrollView.runtime.transition.isUserDragLifecycleActive {
                dragScrollView.scrollViewDidEndDragging(
                    dragScrollView,
                    willDecelerate: false
                )
            }
            dragScrollView.interruptActiveMovement(outcome: .interrupted)
            dragScrollView.endCapture()
            dragScrollView.eventDelegate = nil
            window.isHidden = true
            _ = provider
        }

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        var target = CGPoint(
            x: dragScrollView.contentOffset.x,
            y: 200 - dragScrollView.bounds.height
        )
        dragScrollView.scrollViewWillEndDragging(
            dragScrollView,
            withVelocity: CGPoint(x: 0, y: 1),
            targetContentOffset: &target
        )
        dragScrollView.scrollViewDidEndDragging(dragScrollView, willDecelerate: false)

        dragScrollView.perform(trackingDidBegin)
        dragScrollView.beginCapture(from: leafView)
        await fulfillment(of: [completed], timeout: 1)

        XCTAssertTrue(dragScrollView.nativeScrollState.isTracking)
        XCTAssertTrue(dragScrollView.runtime.capture.session === session)
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
        XCTAssertNil(dragScrollView.runtime.transition.driver)

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)

        XCTAssertTrue(dragScrollView.runtime.transition.isUserDragLifecycleActive)
        XCTAssertTrue(dragScrollView.runtime.capture.session === session)
    }

    func testNewDragInterruptingViewAnimationDoesNotCreateFalseMetricsInvalidation() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 200, 300])
        let window = attachToWindow(dragScrollView)
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        let provider = SegmentProvider([
            BODragScrollInnerScrollSegment(
                displayHeight: 300,
                beginOffsetY: 0,
                endOffsetY: 600
            )
        ])
        dragScrollView.behaviorProvider = provider
        var configuration = dragScrollView.configuration
        configuration.movement.defaultStyle = .viewAnimation
        configuration.movement.baseDuration = 1
        configuration.movement.maximumDuration = 1
        dragScrollView.configuration = configuration
        layout(dragScrollView)
        dragScrollView.beginCapture(from: leafView)
        let session = try XCTUnwrap(dragScrollView.runtime.capture.session)
        let model = try XCTUnwrap(session.model)
        defer {
            if dragScrollView.runtime.transition.isUserDragLifecycleActive {
                dragScrollView.scrollViewDidEndDragging(
                    dragScrollView,
                    willDecelerate: false
                )
            }
            dragScrollView.interruptActiveMovement(outcome: .interrupted)
            dragScrollView.endCapture()
            window.isHidden = true
            _ = provider
        }

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        var target = CGPoint(
            x: dragScrollView.contentOffset.x,
            y: 200 - dragScrollView.bounds.height
        )
        dragScrollView.scrollViewWillEndDragging(
            dragScrollView,
            withVelocity: CGPoint(x: 0, y: 1),
            targetContentOffset: &target
        )
        dragScrollView.scrollViewDidEndDragging(
            dragScrollView,
            willDecelerate: false
        )
        XCTAssertEqual(dragScrollView.runtime.transition.driver, .viewAnimation)

        // Touch-down retains the immutable model while the old animation still owns physics. The
        // real drag then interrupts that animation without pretending participant metrics changed.
        dragScrollView.beginCapture(from: leafView)
        dragScrollView.scrollViewWillBeginDragging(dragScrollView)

        XCTAssertTrue(dragScrollView.runtime.capture.session === session)
        XCTAssertEqual(session.model, model)
        XCTAssertFalse(session.hasDeferredMetricsChange)
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
        XCTAssertNil(dragScrollView.runtime.transition.driver)
        XCTAssertTrue(dragScrollView.runtime.transition.isUserDragLifecycleActive)
    }

    func testDidEndDeceleratingCannotFinishAReentrantNewMovement() throws {
        let (dragScrollView, _) = makeHost(detents: [100, 300])
        let delegate = ReentrantDecelerationDelegate()
        dragScrollView.eventDelegate = delegate

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        dragScrollView.contentOffset.y = 180 - dragScrollView.bounds.height
        dragScrollView.scrollViewDidScroll(dragScrollView)
        var target = CGPoint(x: 0, y: 300 - dragScrollView.bounds.height)
        withUnsafeMutablePointer(to: &target) { pointer in
            dragScrollView.scrollViewWillEndDragging(
                dragScrollView,
                withVelocity: CGPoint(x: 0, y: 1),
                targetContentOffset: pointer
            )
        }
        _ = try XCTUnwrap(dragScrollView.runtime.transition.activeTransaction)
        dragScrollView.scrollViewDidEndDragging(dragScrollView, willDecelerate: true)

        delegate.onDidEndDecelerating = {
            dragScrollView.move(toDisplayHeight: 300, animated: false)
        }
        dragScrollView.scrollViewDidEndDecelerating(dragScrollView)

        XCTAssertEqual(delegate.results.map(\.reason), [.dragRelease, .programmatic])
        XCTAssertEqual(delegate.results.map(\.outcome), [.interrupted, .completed])
        XCTAssertEqual(dragScrollView.displayHeight, 300, accuracy: 0.001)
    }

    func testProgrammaticMovementPairsAndOwnsCancelledNativeDeceleration() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let lifecycle = ParticipantLifecycleSpy()
        participant.delegate = lifecycle
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        _ = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        dragScrollView.scrollViewDidEndDragging(dragScrollView, willDecelerate: true)
        XCTAssertTrue(dragScrollView.runtime.transition.isAwaitingDidEndDecelerating)

        var results: [BODragScrollMovementResult] = []
        dragScrollView.move(toDisplayHeight: 250, animated: false) {
            results.append($0)
        }

        XCTAssertEqual(lifecycle.didDecelerate.count, 1)
        XCTAssertFalse(dragScrollView.runtime.transition.isAwaitingDidEndDecelerating)
        XCTAssertNil(dragScrollView.runtime.capture.session)
        XCTAssertEqual(results.map(\.outcome), [.completed])
        XCTAssertEqual(dragScrollView.displayHeight, 250, accuracy: 0.001)

        // UIKit may still deliver the callback belonging to the cancelled deceleration.
        dragScrollView.scrollViewDidEndDecelerating(dragScrollView)
        XCTAssertEqual(lifecycle.didDecelerate.count, 1)
        XCTAssertEqual(results.count, 1)
    }

    func testCancelledDecelerationCallbackCannotClearReentrantNewMovement() throws {
        let (dragScrollView, _) = makeHost(detents: [100, 300, 500])
        let window = attachToWindow(dragScrollView)
        defer { window.isHidden = true }
        let delegate = ReentrantDecelerationDelegate()
        dragScrollView.eventDelegate = delegate

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        dragScrollView.contentOffset.y = 180 - dragScrollView.bounds.height
        dragScrollView.scrollViewDidScroll(dragScrollView)
        var releaseTarget = CGPoint(x: 0, y: 300 - dragScrollView.bounds.height)
        withUnsafeMutablePointer(to: &releaseTarget) { pointer in
            dragScrollView.scrollViewWillEndDragging(
                dragScrollView,
                withVelocity: CGPoint(x: 0, y: 1),
                targetContentOffset: pointer
            )
        }
        _ = try XCTUnwrap(dragScrollView.runtime.transition.activeTransaction)
        dragScrollView.scrollViewDidEndDragging(dragScrollView, willDecelerate: true)

        delegate.onDidFinishMovement = { result in
            guard result.reason == .dragRelease, result.outcome == .interrupted else { return }
            dragScrollView.move(
                toDisplayHeight: 500,
                animated: true,
                options: BODragScrollMovementOptions(
                    style: .viewAnimation,
                    duration: 1
                )
            )
        }

        // A interrupts the drag-release transaction. Its callback starts B before A's begin call
        // returns; A must not subsequently clear B's driver or animation ownership.
        _ = dragScrollView.move(toDisplayHeight: 250, animated: false)

        XCTAssertEqual(delegate.didEndDeceleratingCount, 1)
        XCTAssertEqual(delegate.results.first?.reason, .dragRelease)
        XCTAssertEqual(delegate.results.first?.outcome, .interrupted)
        XCTAssertEqual(
            dragScrollView.runtime.transition.activeTransaction?.requestedDisplayHeight,
            500
        )
        XCTAssertEqual(dragScrollView.runtime.transition.driver, .viewAnimation)
        XCTAssertTrue(dragScrollView.runtime.transition.isViewAnimating)

        dragScrollView.interruptActiveMovement(outcome: .interrupted)
        XCTAssertEqual(delegate.didEndDeceleratingCount, 1)
    }

    func testScrollToTopCanTakeOverParticipantOnlyDeceleration() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let lifecycle = ParticipantLifecycleSpy()
        participant.delegate = lifecycle
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        _ = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        dragScrollView.scrollViewDidEndDragging(dragScrollView, willDecelerate: true)
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
        XCTAssertTrue(dragScrollView.runtime.transition.isAwaitingDidEndDecelerating)

        XCTAssertTrue(dragScrollView.scrollViewShouldScrollToTop(dragScrollView))

        XCTAssertEqual(lifecycle.didDecelerate.count, 1)
        XCTAssertFalse(dragScrollView.runtime.transition.isAwaitingDidEndDecelerating)
        XCTAssertNil(dragScrollView.runtime.capture.session)
        XCTAssertEqual(dragScrollView.runtime.transition.activeTransaction?.reason, .scrollToTop)
        XCTAssertEqual(dragScrollView.runtime.transition.driver, .scrollToTop)
        dragScrollView.interruptActiveMovement(outcome: .interrupted)
    }

    func testDecelerationWithoutReleaseTransactionClearsDriverAtNaturalEnd() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let window = attachToWindow(dragScrollView)
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        defer {
            dragScrollView.interruptActiveMovement(outcome: .interrupted)
            dragScrollView.endCapture()
            window.isHidden = true
        }

        // UIKit may omit will-end for an interrupted/cancelled gesture. did-end still reports real
        // deceleration, so the driver exists without a drag-release movement transaction.
        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        dragScrollView.scrollViewDidEndDragging(
            dragScrollView,
            willDecelerate: true
        )
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
        XCTAssertEqual(dragScrollView.runtime.transition.driver, .dragDeceleration)
        XCTAssertTrue(dragScrollView.runtime.transition.isAwaitingDidEndDecelerating)

        dragScrollView.scrollViewDidEndDecelerating(dragScrollView)

        XCTAssertFalse(dragScrollView.runtime.transition.isAwaitingDidEndDecelerating)
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
        XCTAssertNil(dragScrollView.runtime.transition.driver)
        XCTAssertNil(dragScrollView.runtime.capture.session)
    }

    func testWindowRemovalClearsDecelerationWithoutReleaseTransaction() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let window = attachToWindow(dragScrollView)
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        defer { window.isHidden = true }

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        dragScrollView.scrollViewDidEndDragging(
            dragScrollView,
            willDecelerate: true
        )
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
        XCTAssertEqual(dragScrollView.runtime.transition.driver, .dragDeceleration)

        dragScrollView.removeFromSuperview()

        XCTAssertNil(dragScrollView.window)
        XCTAssertFalse(dragScrollView.runtime.transition.isAwaitingDidEndDecelerating)
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
        XCTAssertNil(dragScrollView.runtime.transition.driver)
        XCTAssertNil(dragScrollView.runtime.capture.session)
        XCTAssertNil(dragScrollView.runtime.transition.captureCleanupOwnership)
    }

    func testTransactionlessDecelerationEndDuringTrackingKeepsCaptureForNewDrag() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let window = attachToWindow(dragScrollView)
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        let trackingDidBegin = NSSelectorFromString("_trackingDidBegin")
        let trackingDidEnd = NSSelectorFromString("_trackingDidEnd")
        guard dragScrollView.responds(to: trackingDidBegin),
              dragScrollView.responds(to: trackingDidEnd) else {
            XCTFail("This UIKit runtime cannot expose a physical tracking-only test state.")
            return
        }
        defer {
            if dragScrollView.nativeScrollState.isTracking {
                dragScrollView.perform(trackingDidEnd)
            }
            if dragScrollView.runtime.transition.isUserDragLifecycleActive {
                dragScrollView.scrollViewDidEndDragging(
                    dragScrollView,
                    willDecelerate: false
                )
            }
            dragScrollView.interruptActiveMovement(outcome: .interrupted)
            dragScrollView.endCapture()
            window.isHidden = true
        }

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        dragScrollView.scrollViewDidEndDragging(
            dragScrollView,
            willDecelerate: true
        )
        dragScrollView.perform(trackingDidBegin)
        dragScrollView.beginCapture(from: leafView)
        let refreshedSession = try XCTUnwrap(dragScrollView.runtime.capture.session)

        // The old deceleration ends under the new finger. Its driver is terminal, but capture must
        // survive until the touch either lifts or becomes a real drag.
        dragScrollView.scrollViewDidEndDecelerating(dragScrollView)
        XCTAssertNil(dragScrollView.runtime.transition.driver)
        XCTAssertTrue(dragScrollView.runtime.capture.session === refreshedSession)

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)

        XCTAssertTrue(dragScrollView.runtime.transition.isUserDragLifecycleActive)
        XCTAssertTrue(dragScrollView.runtime.capture.session === refreshedSession)
        XCTAssertNil(dragScrollView.runtime.transition.driver)
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
    }

    func testDecelerationTouchOnSiblingDefersAxisSwapUntilRealDrag() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let window = attachToWindow(dragScrollView)
        let firstParticipant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 160, height: 300),
            contentHeight: 900
        )
        let secondParticipant = makeScrollView(
            frame: CGRect(x: 160, y: 0, width: 160, height: 300),
            contentHeight: 900
        )
        let firstLeaf = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        let secondLeaf = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        firstParticipant.addSubview(firstLeaf)
        secondParticipant.addSubview(secondLeaf)
        panelView.addSubview(firstParticipant)
        panelView.addSubview(secondParticipant)
        dragScrollView.beginCapture(from: firstLeaf)
        let firstSession = try XCTUnwrap(dragScrollView.runtime.capture.session)
        let firstModel = try XCTUnwrap(firstSession.model)
        let trackingDidBegin = NSSelectorFromString("_trackingDidBegin")
        let trackingDidEnd = NSSelectorFromString("_trackingDidEnd")
        guard dragScrollView.responds(to: trackingDidBegin),
              dragScrollView.responds(to: trackingDidEnd) else {
            XCTFail("This UIKit runtime cannot expose a physical tracking-only test state.")
            return
        }
        defer {
            if dragScrollView.nativeScrollState.isTracking {
                dragScrollView.perform(trackingDidEnd)
            }
            if dragScrollView.runtime.transition.isUserDragLifecycleActive {
                dragScrollView.scrollViewDidEndDragging(
                    dragScrollView,
                    willDecelerate: false
                )
            }
            dragScrollView.interruptActiveMovement(outcome: .interrupted)
            dragScrollView.endCapture()
            window.isHidden = true
        }

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        dragScrollView.scrollViewDidEndDragging(
            dragScrollView,
            willDecelerate: true
        )
        dragScrollView.perform(trackingDidBegin)

        dragScrollView.beginCapture(from: secondLeaf)

        XCTAssertTrue(dragScrollView.runtime.capture.session === firstSession)
        XCTAssertEqual(firstSession.model, firstModel)
        XCTAssertTrue(dragScrollView.primaryParticipantScrollView === firstParticipant)
        XCTAssertTrue(
            dragScrollView.runtime.capture.deferredTouchViewForFreshCapture === secondLeaf
        )

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)

        let secondSession = try XCTUnwrap(dragScrollView.runtime.capture.session)
        XCTAssertFalse(secondSession === firstSession)
        XCTAssertTrue(dragScrollView.primaryParticipantScrollView === secondParticipant)
        XCTAssertNil(dragScrollView.runtime.capture.deferredTouchViewForFreshCapture)
        XCTAssertTrue(dragScrollView.runtime.transition.isUserDragLifecycleActive)
    }

    func testTransactionlessDecelerationTrackingOnlyRefreshReleasesCaptureAfterLift() async throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let window = attachToWindow(dragScrollView)
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        let trackingDidBegin = NSSelectorFromString("_trackingDidBegin")
        let trackingDidEnd = NSSelectorFromString("_trackingDidEnd")
        guard dragScrollView.responds(to: trackingDidBegin),
              dragScrollView.responds(to: trackingDidEnd) else {
            XCTFail("This UIKit runtime cannot expose a physical tracking-only test state.")
            return
        }
        defer {
            if dragScrollView.nativeScrollState.isTracking {
                dragScrollView.perform(trackingDidEnd)
            }
            dragScrollView.interruptActiveMovement(outcome: .interrupted)
            dragScrollView.endCapture()
            window.isHidden = true
        }

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        dragScrollView.scrollViewDidEndDragging(
            dragScrollView,
            willDecelerate: true
        )
        let session = try XCTUnwrap(dragScrollView.runtime.capture.session)
        let model = try XCTUnwrap(session.model)
        participant.contentSize = CGSize(width: 320, height: 420)
        let metricsCallbackDrained = expectation(description: "dirty metrics callback drained")
        DispatchQueue.main.async { metricsCallbackDrained.fulfill() }
        await fulfillment(of: [metricsCallbackDrained], timeout: 1)
        XCTAssertTrue(session.hasDeferredMetricsChange)

        dragScrollView.perform(trackingDidBegin)
        dragScrollView.beginCapture(from: leafView)
        dragScrollView.scrollViewDidEndDecelerating(dragScrollView)

        let ownershipAtTerminal = try XCTUnwrap(
            dragScrollView.runtime.transition.captureCleanupOwnership
        )
        dragScrollView.beginCapture(from: leafView)
        let refreshedOwnership = try XCTUnwrap(
            dragScrollView.runtime.transition.captureCleanupOwnership
        )

        XCTAssertNil(dragScrollView.runtime.transition.driver)
        XCTAssertTrue(dragScrollView.runtime.capture.session === session)
        XCTAssertEqual(session.model, model)
        XCTAssertEqual(refreshedOwnership.sessionID, ownershipAtTerminal.sessionID)
        XCTAssertNotEqual(
            refreshedOwnership.sessionOwnershipGeneration,
            ownershipAtTerminal.sessionOwnershipGeneration
        )
        dragScrollView.perform(trackingDidEnd)

        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertNil(dragScrollView.runtime.capture.session)
        XCTAssertNil(dragScrollView.runtime.transition.captureCleanupOwnership)
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
        XCTAssertNil(dragScrollView.runtime.transition.driver)
    }

    func testStaleSystemAnimationEndCallbackCannotFinishReplacement() async {
        let (dragScrollView, _) = makeHost(detents: [100, 200, 300])
        let window = attachToWindow(dragScrollView)
        defer {
            dragScrollView.interruptActiveMovement(outcome: .interrupted)
            window.isHidden = true
        }
        var firstResults: [BODragScrollMovementResult] = []
        var secondResults: [BODragScrollMovementResult] = []
        let secondFinished = expectation(description: "replacement system animation finished")

        dragScrollView.move(
            toDisplayHeight: 300,
            animated: true,
            options: BODragScrollMovementOptions(style: .systemScroll)
        ) { firstResults.append($0) }
        dragScrollView.move(
            toDisplayHeight: 200,
            animated: true,
            options: BODragScrollMovementOptions(style: .systemScroll)
        ) {
            secondResults.append($0)
            secondFinished.fulfill()
        }

        XCTAssertEqual(firstResults.map(\.outcome), [.interrupted])
        let replacementID = dragScrollView.runtime.transition.activeTransaction?.id
        XCTAssertFalse(dragScrollView.runtime.transition.systemAnimationHasObservedProgress)

        // Simulate animation A's identifier-less UIKit callback arriving after B owns the driver.
        dragScrollView.scrollViewDidEndScrollingAnimation(dragScrollView)

        XCTAssertEqual(dragScrollView.runtime.transition.activeTransaction?.id, replacementID)
        XCTAssertTrue(secondResults.isEmpty)

        // Three stable samples are enough to validate a real completion only after B itself made
        // progress or reached its target. A's stale callback cannot settle B at that threshold.
        let passedThreeSamples = expectation(description: "passed three settlement samples")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            passedThreeSamples.fulfill()
        }
        await fulfillment(of: [passedThreeSamples], timeout: 1)

        XCTAssertEqual(dragScrollView.runtime.transition.activeTransaction?.id, replacementID)
        XCTAssertEqual(dragScrollView.runtime.transition.driver, .systemAnimation)
        XCTAssertTrue(secondResults.isEmpty)

        // B may now complete through real UIKit progress/target arrival or the existing 12-sample
        // no-progress fallback. Either path belongs to B and must publish a completed result.
        await fulfillment(of: [secondFinished], timeout: 1)

        XCTAssertEqual(secondResults.map(\.outcome), [.completed])
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
        XCTAssertNil(dragScrollView.runtime.transition.driver)
        XCTAssertEqual(dragScrollView.displayHeight, 200, accuracy: 0.001)
    }

    func testScrollToTopInterruptsActiveViewAnimationAndTakesOwnership() {
        let (dragScrollView, _) = makeHost(detents: [100, 300])
        let window = attachToWindow(dragScrollView)
        defer { window.isHidden = true }
        var previousResults: [BODragScrollMovementResult] = []
        dragScrollView.move(
            toDisplayHeight: 300,
            animated: true,
            options: BODragScrollMovementOptions(style: .viewAnimation, duration: 0.5)
        ) { previousResults.append($0) }

        XCTAssertTrue(dragScrollView.scrollViewShouldScrollToTop(dragScrollView))

        XCTAssertEqual(previousResults.map(\.outcome), [.interrupted])
        XCTAssertEqual(dragScrollView.runtime.transition.activeTransaction?.reason, .scrollToTop)
        XCTAssertEqual(dragScrollView.runtime.transition.driver, .scrollToTop)
        dragScrollView.interruptActiveMovement(outcome: .interrupted)
    }

    func testScrollToTopAlreadyAtTargetSettlesWithoutUIKitEndCallback() {
        let (dragScrollView, _) = makeHost(detents: [100, 300])
        XCTAssertEqual(dragScrollView.contentOffset.y, dragScrollView.minimumOuterOffset)

        XCTAssertFalse(dragScrollView.scrollViewShouldScrollToTop(dragScrollView))

        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
        XCTAssertNil(dragScrollView.runtime.transition.driver)
    }

    func testProgrammaticMoveStopsAndSupersedesActiveScrollToTop() {
        let (dragScrollView, _) = makeHost(detents: [100, 200, 300])
        let window = attachToWindow(dragScrollView)
        defer { window.isHidden = true }
        _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
        XCTAssertTrue(dragScrollView.scrollViewShouldScrollToTop(dragScrollView))
        XCTAssertEqual(dragScrollView.runtime.transition.driver, .scrollToTop)

        _ = dragScrollView.move(toDisplayHeight: 200, animated: false)

        XCTAssertEqual(dragScrollView.displayHeight, 200, accuracy: 0.001)
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
        dragScrollView.scrollViewDidScrollToTop(dragScrollView)
        XCTAssertEqual(dragScrollView.displayHeight, 200, accuracy: 0.001)
    }

    func testStaleScrollToTopCallbackCannotFinishReplacementRequest() async throws {
        let (dragScrollView, _) = makeHost(detents: [100, 200, 300])
        let window = attachToWindow(dragScrollView)
        defer {
            dragScrollView.interruptActiveMovement(outcome: .interrupted)
            window.isHidden = true
        }
        _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
        XCTAssertTrue(dragScrollView.scrollViewShouldScrollToTop(dragScrollView))
        let firstID = try XCTUnwrap(
            dragScrollView.runtime.transition.activeTransaction?.id
        )

        // Replace A completely, return to a non-top position, then authorize B. UIKit can still
        // deliver A's identifier-less didScrollToTop callback while B is current.
        _ = dragScrollView.move(toDisplayHeight: 200, animated: false)
        _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
        XCTAssertTrue(dragScrollView.scrollViewShouldScrollToTop(dragScrollView))
        let replacementID = try XCTUnwrap(
            dragScrollView.runtime.transition.activeTransaction?.id
        )
        XCTAssertNotEqual(firstID, replacementID)

        dragScrollView.scrollViewDidScrollToTop(dragScrollView)

        let passedThreeSamples = expectation(description: "passed three scroll-to-top samples")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            passedThreeSamples.fulfill()
        }
        await fulfillment(of: [passedThreeSamples], timeout: 1)

        XCTAssertEqual(
            dragScrollView.runtime.transition.activeTransaction?.id,
            replacementID
        )
        XCTAssertEqual(dragScrollView.runtime.transition.driver, .scrollToTop)

        // B has no UIKit progress in this direct-delegate test. Its own 12-sample fallback, not
        // A's stale callback, commits the already-resolved target and completes B.
        let fallbackFinished = expectation(description: "replacement fallback finished")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            fallbackFinished.fulfill()
        }
        await fulfillment(of: [fallbackFinished], timeout: 1)

        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
        XCTAssertNil(dragScrollView.runtime.transition.driver)
        XCTAssertEqual(dragScrollView.displayHeight, 100, accuracy: 0.001)
    }

    func testDisplayHeightCallbackMovementOwnsCompletedLayout() {
        let (dragScrollView, _) = makeHost(layout: false)
        let delegate = DisplayHeightCallbackDelegate()
        delegate.onFirstChange = { host in
            host.move(toDisplayHeight: 240, animated: false)
        }
        dragScrollView.eventDelegate = delegate

        layout(dragScrollView)

        XCTAssertEqual(dragScrollView.displayHeight, 240, accuracy: 0.001)
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
        XCTAssertNil(dragScrollView.runtime.transition.pendingLayoutMovement)
    }

    func testLayoutRebuildCannotOverwriteReentrantSamePanelMovement() {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        var configuration = dragScrollView.configuration
        configuration.handoff.offsetMismatch = .restoreToBoundary
        dragScrollView.configuration = configuration
        layout(dragScrollView)

        let participant = OffsetObservingScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
        )
        participant.contentSize = CGSize(width: 320, height: 900)
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)

        let oldLayoutHeight = dragScrollView.displayHeight
        let newMovementHeight = oldLayoutHeight + dragScrollView.comparisonPolicy.boundaryBand * 0.5
        participant.contentOffset.y = -10
        var didStartNewMovement = false
        participant.offsetDidChange = { _ in
            guard !didStartNewMovement else { return }
            didStartNewMovement = true
            _ = dragScrollView.move(toDisplayHeight: newMovementHeight, animated: false)
            // UIScrollView pixel-aligns a programmatic half-pixel `contentOffset`. Inject the exact
            // bounds sample that may arise from composite arithmetic, then let the normal callback
            // publish it. Without the layout transaction epoch guard, the stale layout correction
            // below would pull this newer sub-pixel geometry back to `oldLayoutHeight`.
            var exactBounds = dragScrollView.bounds
            exactBounds.origin.y = newMovementHeight - exactBounds.height
            dragScrollView.bounds = exactBounds
            XCTAssertEqual(
                dragScrollView.contentOffset.y,
                exactBounds.origin.y,
                accuracy: 0.000_000_001
            )
            dragScrollView.scrollViewDidScroll(dragScrollView)
        }

        dragScrollView.invalidatePanelLayout()
        layout(dragScrollView)

        XCTAssertTrue(didStartNewMovement)
        XCTAssertEqual(dragScrollView.displayHeight, newMovementHeight, accuracy: 0.000_001)
        XCTAssertEqual(
            dragScrollView.contentOffset.y,
            newMovementHeight - dragScrollView.bounds.height,
            accuracy: 0.000_001
        )
        XCTAssertNil(dragScrollView.runtime.capture.session)
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
    }

    func testLayoutPublishesRealGeometryAfterReentrantMovementCancelsImmediately() {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        var configuration = dragScrollView.configuration
        configuration.handoff.offsetMismatch = .restoreToBoundary
        dragScrollView.configuration = configuration
        let provider = LayoutDisplayHeightProvider(targetDisplayHeight: 180)
        dragScrollView.behaviorProvider = provider
        layout(dragScrollView)

        let participant = OffsetObservingScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300)
        )
        participant.contentSize = CGSize(width: 320, height: 900)
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        participant.contentOffset.y = -10

        let recorder = MovementEventRecorder()
        dragScrollView.eventDelegate = recorder
        var didAttemptInvalidMovement = false
        participant.offsetDidChange = { _ in
            guard !didAttemptInvalidMovement else { return }
            didAttemptInvalidMovement = true
            _ = dragScrollView.move(toDisplayHeight: .nan, animated: false)
        }

        provider.isArmed = true
        dragScrollView.invalidatePanelLayout()
        layout(dragScrollView)

        XCTAssertTrue(didAttemptInvalidMovement)
        XCTAssertEqual(dragScrollView.displayHeightForCurrentGeometry, 180, accuracy: 0.000_001)
        XCTAssertEqual(dragScrollView.displayHeight, 180, accuracy: 0.000_001)
        XCTAssertEqual(recorder.changedDisplayHeights, [180])
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
    }

    func testMovementStyleCallbackCannotOverwriteReentrantMovement() {
        let (dragScrollView, _) = makeHost(detents: [100, 300])
        let window = attachToWindow(dragScrollView)
        defer { window.isHidden = true }
        let provider = ReentrantMovementStyleProvider()
        dragScrollView.behaviorProvider = provider
        var firstResults: [BODragScrollMovementResult] = []

        dragScrollView.move(toDisplayHeight: 300, animated: true) {
            firstResults.append($0)
        }

        XCTAssertEqual(firstResults.map(\.outcome), [.interrupted])
        XCTAssertEqual(dragScrollView.displayHeight, 180, accuracy: 0.001)
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
    }

    func testSettleProviderCannotOverwriteNewPreLayoutMovement() {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        _ = dragScrollView.move(toDisplayHeight: 180, animated: false)
        let provider = ReentrantSegmentProvider()
        dragScrollView.behaviorProvider = provider
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        let replacementPanel = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 800))
        provider.onSegments = { host in
            host.panelView = replacementPanel
            host.move(toDisplayHeight: 250, animated: false)
        }
        provider.isArmed = true

        _ = dragScrollView.settleToNearestDetent(animated: false)
        layout(dragScrollView)

        XCTAssertTrue(dragScrollView.panelView === replacementPanel)
        XCTAssertEqual(dragScrollView.displayHeight, 250, accuracy: 0.001)
        XCTAssertNil(dragScrollView.runtime.transition.pendingLayoutMovement)
    }

    func testFiniteExtremeMovementNeverWritesInfinity() {
        let (dragScrollView, _) = makeHost()
        var results: [BODragScrollMovementResult] = []
        dragScrollView.contentOffset.y = .greatestFiniteMagnitude

        _ = dragScrollView.move(
            toDisplayHeight: .greatestFiniteMagnitude,
            animated: false
        ) { results.append($0) }

        XCTAssertTrue(dragScrollView.contentOffset.y.isFinite)
        XCTAssertTrue(dragScrollView.displayHeight.isFinite)
        XCTAssertEqual(results.map(\.outcome), [.completed])
    }

    func testMovementRequestedDuringDragBeginsAfterDragEnds() {
        let (dragScrollView, _) = makeHost(detents: [100, 300])
        var results: [BODragScrollMovementResult] = []

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        _ = dragScrollView.move(toDisplayHeight: 250, animated: false) {
            results.append($0)
        }

        XCTAssertTrue(results.isEmpty)
        XCTAssertNotEqual(dragScrollView.displayHeight, 250)

        dragScrollView.scrollViewDidEndDragging(dragScrollView, willDecelerate: false)

        XCTAssertEqual(results.map(\.outcome), [.completed])
        XCTAssertEqual(dragScrollView.displayHeight, 250, accuracy: 0.001)
    }

    func testReentrantPanelReplacementKeepsNewestPanel() {
        let (dragScrollView, _) = makeHost(detents: [100, 300])
        let window = attachToWindow(dragScrollView)
        defer { window.isHidden = true }
        var configuration = dragScrollView.configuration
        configuration.movement.defaultStyle = .viewAnimation
        configuration.movement.baseDuration = 0.5
        configuration.movement.maximumDuration = 0.5
        dragScrollView.configuration = configuration
        let olderReplacement = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 800))
        let newestReplacement = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 800))

        dragScrollView.move(toDisplayHeight: 300, animated: true) { _ in
            dragScrollView.panelView = newestReplacement
        }
        dragScrollView.panelView = olderReplacement

        XCTAssertTrue(dragScrollView.panelView === newestReplacement)
    }

    func testRepeatingAutoreversingOptionsAreSanitizedAndComplete() async {
        let (dragScrollView, _) = makeHost(detents: [100, 300])
        let window = attachToWindow(dragScrollView)
        defer { window.isHidden = true }
        let completed = expectation(description: "terminal view animation")

        dragScrollView.move(
            toDisplayHeight: 300,
            animated: true,
            options: BODragScrollMovementOptions(
                style: .viewAnimation,
                duration: 0.01,
                animationOptions: [.repeat, .autoreverse]
            )
        ) { result in
            XCTAssertEqual(result.outcome, .completed)
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(dragScrollView.displayHeight, 300, accuracy: 0.001)
    }

    // MARK: - Responder-chain capture and projection

    func testSingleResponderChainScrollViewBecomesPrimaryParticipant() throws {
        let (dragScrollView, panelView) = makeHost()
        let captureDisplayHeight = dragScrollView.displayHeight
        let scrollView = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 20, width: 40, height: 40))
        scrollView.addSubview(leafView)
        panelView.addSubview(scrollView)

        dragScrollView.beginCapture(from: leafView)
        defer { dragScrollView.endCapture() }

        let session = try XCTUnwrap(dragScrollView.runtime.capture.session)
        XCTAssertEqual(session.participantChain.count, 1)
        XCTAssertTrue(session.primaryParticipant?.scrollView === scrollView)
        XCTAssertTrue(dragScrollView.primaryParticipantScrollView === scrollView)
        let model = try XCTUnwrap(session.model)
        XCTAssertTrue(model.detentDisplayHeights.isEmpty)

        let participantSegments = model.segments.filter(\.isParticipantSegment)
        let segment = try XCTUnwrap(participantSegments.first)
        XCTAssertEqual(participantSegments.count, 1)
        XCTAssertEqual(segment.displayHeight, captureDisplayHeight, accuracy: 0.001)

        let midpoint = segment.outerStart + segment.outerLength * 0.5
        let projection = model.projection(at: midpoint)
        XCTAssertEqual(projection.displayHeight, captureDisplayHeight, accuracy: 0.001)
        let projectedOffset = try XCTUnwrap(
            projection.offset(for: session.participantChain[0].id)
        )
        XCTAssertEqual(
            projectedOffset,
            segment.innerStart + segment.innerLength * 0.5,
            accuracy: 0.001
        )
    }

    func testNoDetentAutomaticActivationPreservesNativeCurrentDisplayHeight() throws {
        let (dragScrollView, panelView) = makeHost()
        let requestedGeometryHeight: CGFloat = 321.123_456_789
        var panelFrame = panelView.frame
        panelFrame.origin.y = dragScrollView.bounds.height
            + dragScrollView.contentOffset.y
            - requestedGeometryHeight
        dragScrollView.setPanelFrame(panelFrame)
        let nativeDisplayHeight = dragScrollView.displayHeightForCurrentGeometry
        XCTAssertNotEqual(nativeDisplayHeight, CGFloat(Float(nativeDisplayHeight)))
        XCTAssertEqual(nativeDisplayHeight, requestedGeometryHeight, accuracy: 1e-12)

        let scrollView = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 20, width: 40, height: 40))
        scrollView.addSubview(leafView)
        panelView.addSubview(scrollView)

        dragScrollView.beginCapture(from: leafView)
        defer { dragScrollView.endCapture() }

        let model = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
        let segment = try XCTUnwrap(model.segments.first(where: \.isParticipantSegment))
        XCTAssertTrue(model.detentDisplayHeights.isEmpty)
        XCTAssertEqual(segment.displayHeight, nativeDisplayHeight)
    }

    func testInnerSegmentScrollKeepsRealGeometryAtExactModelHeight() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let provider = SegmentProvider([
            BODragScrollInnerScrollSegment(
                displayHeight: 300.123_456,
                beginOffsetY: 0,
                endOffsetY: 600
            )
        ])
        dragScrollView.behaviorProvider = provider
        let scrollView = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 20, width: 40, height: 40))
        scrollView.addSubview(leafView)
        panelView.addSubview(scrollView)
        dragScrollView.beginCapture(from: leafView)
        defer { dragScrollView.endCapture() }
        let session = try XCTUnwrap(dragScrollView.runtime.capture.session)
        let model = try XCTUnwrap(session.model)
        let segment = try XCTUnwrap(model.segments.first(where: \.isParticipantSegment))
        let targetOuterOffset = segment.outerStart + segment.outerLength * 0.5

        dragScrollView.contentOffset.y = targetOuterOffset
        dragScrollView.scrollViewDidScroll(dragScrollView)

        XCTAssertEqual(scrollView.contentOffset.y, 300)
        XCTAssertEqual(dragScrollView.displayHeightForCurrentGeometry, segment.displayHeight)
        XCTAssertEqual(dragScrollView.displayHeight, segment.displayHeight)
        XCTAssertEqual(
            panelView.frame.minY,
            dragScrollView.bounds.height + dragScrollView.contentOffset.y - segment.displayHeight
        )
    }

    func testContinuationActivationPreservesNativeCurrentDisplayHeight() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let requestedGeometryHeight: CGFloat = 233.123_456_789
        var panelFrame = panelView.frame
        panelFrame.origin.y = dragScrollView.bounds.height
            + dragScrollView.contentOffset.y
            - requestedGeometryHeight
        dragScrollView.setPanelFrame(panelFrame)
        let nativeDisplayHeight = dragScrollView.displayHeightForCurrentGeometry
        XCTAssertNotEqual(nativeDisplayHeight, CGFloat(Float(nativeDisplayHeight)))
        XCTAssertEqual(nativeDisplayHeight, requestedGeometryHeight, accuracy: 1e-12)

        let scrollView = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        scrollView.contentOffset.y = 123
        let leafView = UIView(frame: CGRect(x: 0, y: 20, width: 40, height: 40))
        scrollView.addSubview(leafView)
        panelView.addSubview(scrollView)

        var configuration = dragScrollView.configuration
        configuration.handoff.offsetMismatch = .continueFromCurrentOffset
        dragScrollView.configuration = configuration
        dragScrollView.beginCapture(from: leafView)
        defer { dragScrollView.endCapture() }

        let model = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
        let segment = try XCTUnwrap(model.segments.first(where: \.isParticipantSegment))
        XCTAssertEqual(segment.displayHeight, nativeDisplayHeight)
        XCTAssertEqual(
            model.projection(at: dragScrollView.contentOffset.y).displayHeight,
            nativeDisplayHeight,
            accuracy: 1e-12
        )
    }

    func testFixedActivationRetainsObjectiveCFloatInputSemantics() throws {
        let (dragScrollView, panelView) = makeHost()
        let requestedDisplayHeight: CGFloat = 321.123_456_789
        let objectiveCDisplayHeight = CGFloat(Float(requestedDisplayHeight))
        XCTAssertNotEqual(requestedDisplayHeight, objectiveCDisplayHeight)

        var configuration = dragScrollView.configuration
        configuration.handoff.innerScrollPlacement = .atDisplayHeight(requestedDisplayHeight)
        dragScrollView.configuration = configuration

        let scrollView = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 20, width: 40, height: 40))
        scrollView.addSubview(leafView)
        panelView.addSubview(scrollView)

        dragScrollView.beginCapture(from: leafView)
        defer { dragScrollView.endCapture() }

        let model = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
        let segment = try XCTUnwrap(model.segments.first(where: \.isParticipantSegment))
        XCTAssertEqual(segment.displayHeight, objectiveCDisplayHeight)
    }

    func testNestedResponderChainBuildsPrimaryAndAncestorModelOwners() throws {
        let (dragScrollView, panelView) = makeHost()
        let ancestor = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 500),
            contentHeight: 1_200
        )
        let ancestorContent = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 1_200))
        ancestor.addSubview(ancestorContent)

        let primary = makeScrollView(
            frame: CGRect(x: 0, y: 200, width: 320, height: 200),
            contentHeight: 600
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 10, width: 40, height: 40))
        primary.addSubview(leafView)
        ancestorContent.addSubview(primary)
        panelView.addSubview(ancestor)

        dragScrollView.beginCapture(from: leafView)
        defer { dragScrollView.endCapture() }

        let session = try XCTUnwrap(dragScrollView.runtime.capture.session)
        XCTAssertEqual(session.participantChain.count, 2)
        XCTAssertTrue(session.participantChain[0].scrollView === primary)
        XCTAssertTrue(session.participantChain[1].scrollView === ancestor)

        let primaryID = session.participantChain[0].id
        let ancestorID = session.participantChain[1].id
        let model = try XCTUnwrap(session.model)
        let participantOwners = model.segments.compactMap { segment -> ParticipantID? in
            guard case .participant(let participantID) = segment.owner else { return nil }
            return participantID
        }

        XCTAssertEqual(participantOwners.first, ancestorID)
        XCTAssertTrue(participantOwners.contains(primaryID))
        XCTAssertTrue(participantOwners.contains(ancestorID))
    }

    func testThreeLevelNestedInitialPrefixProjectsIntoOutermostBeforeSlice() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300, 500])
        _ = dragScrollView.move(toDisplayHeight: 500, animated: false)

        let outer = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 400),
            contentHeight: 1_200
        )
        let outerContent = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 1_200))
        outer.addSubview(outerContent)

        let middle = makeScrollView(
            frame: CGRect(x: 0, y: 100, width: 320, height: 500),
            contentHeight: 900
        )
        let middleContent = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 900))
        middle.addSubview(middleContent)
        outerContent.addSubview(middle)

        let deep = makeScrollView(
            frame: CGRect(x: 0, y: 100, width: 320, height: 200),
            contentHeight: 600
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 10, width: 40, height: 40))
        deep.addSubview(leafView)
        middleContent.addSubview(deep)
        panelView.addSubview(outer)

        dragScrollView.beginCapture(from: leafView)
        let session = try XCTUnwrap(dragScrollView.runtime.capture.session)
        let model = try XCTUnwrap(session.model)
        XCTAssertEqual(session.participantChain.count, 3)
        XCTAssertEqual(dragScrollView.runtime.scrolling.mismatchDirection, 0)

        let owners = model.segments.compactMap(\.participantID)
        XCTAssertEqual(owners.first, session.participantChain[2].id)
        XCTAssertEqual(owners.last, session.participantChain[2].id)

        let initialOuterOffset = dragScrollView.contentOffset.y
        dragScrollView.contentOffset.y = initialOuterOffset + 80
        dragScrollView.scrollViewDidScroll(dragScrollView)

        XCTAssertEqual(outer.contentOffset.y, 80, accuracy: 0.001)
        XCTAssertEqual(middle.contentOffset.y, 0, accuracy: 0.001)
        XCTAssertEqual(deep.contentOffset.y, 0, accuracy: 0.001)
        XCTAssertEqual(dragScrollView.displayHeight, 500, accuracy: 0.001)
    }

    func testProjectionWritesPanelFrameBeforeParticipantOffset() throws {
        let (dragScrollView, panelView) = makeHost()
        let participant = OffsetObservingScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300)
        )
        participant.contentSize = CGSize(width: 320, height: 900)
        let leafView = UIView(frame: CGRect(x: 0, y: 10, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)

        dragScrollView.beginCapture(from: leafView)
        defer { dragScrollView.endCapture() }

        let session = try XCTUnwrap(dragScrollView.runtime.capture.session)
        let primaryID = try XCTUnwrap(session.primaryParticipant?.id)
        let model = try XCTUnwrap(session.model)
        let segment = try XCTUnwrap(
            model.segments.first {
                $0.participantID == primaryID && $0.outerLength > 0
            }
        )
        let targetOuterOffset = segment.outerStart + segment.outerLength * 0.5
        let expected = model.projection(at: targetOuterOffset)
        let expectedParticipantOffset = try XCTUnwrap(
            expected.participantOffsets.first { $0.participantID == primaryID }
        ).contentOffset

        var panelOriginsObservedDuringOffsetWrite: [CGFloat] = []
        participant.offsetDidChange = { [weak panelView] _ in
            panelOriginsObservedDuringOffsetWrite.append(panelView?.frame.minY ?? .nan)
        }

        dragScrollView.setContentOffset(
            CGPoint(x: dragScrollView.contentOffset.x, y: targetOuterOffset),
            animated: false
        )
        // Directly mirror the UIKit callback as well; this is harmless if UIKit delivered it synchronously.
        dragScrollView.scrollViewDidScroll(dragScrollView)

        XCTAssertEqual(participant.contentOffset.y, expectedParticipantOffset, accuracy: 0.001)
        XCTAssertEqual(panelView.frame.minY, expected.panelOriginY, accuracy: 0.001)
        let observedPanelOrigin = try XCTUnwrap(panelOriginsObservedDuringOffsetWrite.last)
        XCTAssertEqual(
            observedPanelOrigin,
            expected.panelOriginY,
            accuracy: 0.001
        )
    }

    func testEndCaptureRestoresOriginalScrollsToTopValue() throws {
        let (dragScrollView, panelView) = makeHost()
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        participant.scrollsToTop = true
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)

        dragScrollView.beginCapture(from: leafView)
        _ = try XCTUnwrap(dragScrollView.runtime.capture.session)
        XCTAssertFalse(participant.scrollsToTop)

        dragScrollView.endCapture()

        XCTAssertTrue(participant.scrollsToTop)
        XCTAssertNil(dragScrollView.runtime.capture.session)
    }

    func testProductionCaptureDoesNotAcquireLeaseBeforeEnteringAWindow() {
        let dragScrollView = BODragScrollView(frame: viewport)
        let panelView = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 800))
        dragScrollView.panelView = panelView
        layout(dragScrollView)
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        participant.scrollsToTop = true
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)

        dragScrollView.beginCapture(from: leafView)

        XCTAssertNil(dragScrollView.runtime.capture.session)
        XCTAssertTrue(participant.scrollsToTop)
    }

    func testScrollsToTopSetterEndingCaptureCannotInstallStaleSession() {
        let (dragScrollView, panelView) = makeHost()
        let participant = ScrollsToTopCallbackScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300)
        )
        participant.contentSize = CGSize(width: 320, height: 900)
        participant.scrollsToTop = true
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        participant.onFirstDisable = { [weak dragScrollView] in
            dragScrollView?.endCapture()
        }

        dragScrollView.beginCapture(from: leafView)

        XCTAssertNil(dragScrollView.runtime.capture.session)
        XCTAssertTrue(participant.scrollsToTop)
    }

    func testCaptureLeaseIsExclusiveAcrossHostsAndRestoresOriginalValue() {
        let (firstHost, firstPanel) = makeHost()
        let (secondHost, secondPanel) = makeHost()
        let participant = UIScrollView()
        participant.scrollsToTop = true
        firstPanel.addSubview(participant)
        let firstHierarchy = BODragScrollCaptureHierarchySnapshot(
            host: firstHost,
            panelView: firstPanel,
            participantChain: [participant]
        )
        let invalidSecondHierarchy = BODragScrollCaptureHierarchySnapshot(
            host: secondHost,
            panelView: secondPanel,
            participantChain: [participant]
        )

        XCTAssertTrue(
            BODragScrollUIScrollViewBridge.acquireCaptureLease(
                for: participant,
                host: firstHost,
                captureSessionID: 11,
                hierarchy: firstHierarchy
            )
        )
        XCTAssertFalse(
            BODragScrollUIScrollViewBridge.acquireCaptureLease(
                for: participant,
                host: secondHost,
                captureSessionID: 22,
                hierarchy: invalidSecondHierarchy
            )
        )
        XCTAssertTrue(
            BODragScrollUIScrollViewBridge.releaseCaptureLease(
                for: participant,
                host: firstHost,
                captureSessionID: 11
            )
        )
        XCTAssertTrue(participant.scrollsToTop)
        secondPanel.addSubview(participant)
        let secondHierarchy = BODragScrollCaptureHierarchySnapshot(
            host: secondHost,
            panelView: secondPanel,
            participantChain: [participant]
        )
        XCTAssertTrue(
            BODragScrollUIScrollViewBridge.acquireCaptureLease(
                for: participant,
                host: secondHost,
                captureSessionID: 22,
                hierarchy: secondHierarchy
            )
        )
        _ = BODragScrollUIScrollViewBridge.releaseCaptureLease(
            for: participant,
            host: secondHost,
            captureSessionID: 22
        )
        XCTAssertTrue(participant.scrollsToTop)
    }

    func testReparentedParticipantCanBeCapturedImmediatelyByAnotherHost() throws {
        let (firstHost, firstPanel) = makeHost(detents: [100, 300])
        let (secondHost, secondPanel) = makeHost(detents: [100, 300])
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        participant.scrollsToTop = true
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        firstPanel.addSubview(participant)
        firstHost.beginCapture(from: leafView)
        let firstModel = try XCTUnwrap(firstHost.runtime.capture.session?.model)
        let oldParticipantSegment = try XCTUnwrap(
            firstModel.segments.first(where: { $0.isParticipantSegment && $0.outerLength > 0 })
        )
        XCTAssertFalse(participant.scrollsToTop)

        secondPanel.addSubview(participant)
        secondHost.beginCapture(from: leafView)

        XCTAssertNil(firstHost.runtime.capture.session)
        XCTAssertTrue(secondHost.primaryParticipantScrollView === participant)
        XCTAssertFalse(participant.scrollsToTop)

        let offsetOwnedBySecondHost = participant.contentOffset
        firstHost.contentOffset.y = oldParticipantSegment.outerStart
            + oldParticipantSegment.outerLength * 0.5
        firstHost.scrollViewDidScroll(firstHost)
        XCTAssertEqual(participant.contentOffset, offsetOwnedBySecondHost)

        secondHost.endCapture()
        XCTAssertTrue(participant.scrollsToTop)
    }

    func testInsertedScrollAncestorInvalidatesAndRebuildsCaptureChain() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        XCTAssertEqual(dragScrollView.runtime.capture.session?.participantChain.count, 1)

        let insertedAncestor = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 400),
            contentHeight: 1_000
        )
        panelView.addSubview(insertedAncestor)
        insertedAncestor.addSubview(participant)

        XCTAssertNil(dragScrollView.primaryParticipantScrollView)

        dragScrollView.beginCapture(from: leafView)
        let rebuilt = try XCTUnwrap(dragScrollView.runtime.capture.session)
        XCTAssertEqual(rebuilt.participantChain.count, 2)
        XCTAssertTrue(rebuilt.participantChain[0].scrollView === participant)
        XCTAssertTrue(rebuilt.participantChain[1].scrollView === insertedAncestor)
        dragScrollView.endCapture()
    }

    func testTransientHierarchyMismatchDoesNotPermanentlyDropBridgeLink() async throws {
        let (dragScrollView, panelView) = makeHost()
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        let sessionID = try XCTUnwrap(dragScrollView.runtime.capture.session?.id)
        let temporaryContainer = UIView(frame: panelView.bounds)

        temporaryContainer.addSubview(participant)
        _ = participant.isDragging // bridge observes invalidity and fails open for this read
        panelView.addSubview(participant)

        let queueDrained = expectation(description: "bridge validation drained")
        DispatchQueue.main.async { queueDrained.fulfill() }
        await fulfillment(of: [queueDrained], timeout: 1)

        XCTAssertEqual(dragScrollView.runtime.capture.session?.id, sessionID)
        XCTAssertTrue(
            BODragScrollUIScrollViewBridge.unbind(
                primaryParticipant: participant,
                from: dragScrollView,
                captureSessionID: sessionID
            )
        )
        dragScrollView.endCapture()
    }

    func testInvalidExplicitSegmentsFallBackToAutomaticCapture() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let provider = SegmentProvider([
            BODragScrollInnerScrollSegment(
                displayHeight: .nan,
                beginOffsetY: .infinity,
                endOffsetY: -.infinity
            )
        ])
        dragScrollView.behaviorProvider = provider
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)

        dragScrollView.beginCapture(from: leafView)
        defer { dragScrollView.endCapture() }

        let model = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
        XCTAssertTrue(model.segments.contains(where: \.isParticipantSegment))
    }

    func testExplicitSegmentBeyondDetentsRemainsFullyReachable() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let provider = SegmentProvider([
            BODragScrollInnerScrollSegment(
                displayHeight: 600,
                beginOffsetY: 0,
                endOffsetY: 1_000
            )
        ])
        dragScrollView.behaviorProvider = provider
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 1_300
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)

        dragScrollView.beginCapture(from: leafView)
        defer { dragScrollView.endCapture() }

        let model = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
        XCTAssertLessThanOrEqual(
            dragScrollView.minimumOuterOffset,
            try XCTUnwrap(model.segments.first).outerStart + 0.001
        )
        XCTAssertGreaterThanOrEqual(
            dragScrollView.maximumOuterOffset,
            try XCTUnwrap(model.segments.last).outerEnd - 0.001
        )
    }

    func testParticipantOffsetCallbackMovementInvalidatesOlderProjection() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let participant = OffsetObservingScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300)
        )
        participant.contentSize = CGSize(width: 320, height: 900)
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        let model = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
        let participantSegment = try XCTUnwrap(
            model.segments.first(where: { $0.isParticipantSegment && $0.outerLength > 0 })
        )
        var hasMoved = false
        participant.offsetDidChange = { _ in
            guard !hasMoved else { return }
            hasMoved = true
            dragScrollView.move(toDisplayHeight: 250, animated: false)
        }

        dragScrollView.contentOffset.y = participantSegment.outerStart
            + participantSegment.outerLength * 0.5
        dragScrollView.scrollViewDidScroll(dragScrollView)

        XCTAssertNil(dragScrollView.runtime.capture.session)
        XCTAssertEqual(dragScrollView.displayHeight, 250, accuracy: 0.001)
        XCTAssertNil(dragScrollView.runtime.transition.activeTransaction)
    }

    func testParticipantOffsetCallbackReparentEndsOldCompositeOwnership() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let participant = OffsetObservingScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300)
        )
        participant.contentSize = CGSize(width: 320, height: 900)
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        let model = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
        let participantSegment = try XCTUnwrap(
            model.segments.first(where: { $0.isParticipantSegment && $0.outerLength > 0 })
        )
        let detachedContainer = UIView(frame: panelView.bounds)
        var hasReparented = false
        participant.offsetDidChange = { _ in
            guard !hasReparented else { return }
            hasReparented = true
            detachedContainer.addSubview(participant)
        }

        dragScrollView.contentOffset.y = participantSegment.outerStart
            + participantSegment.outerLength * 0.5
        dragScrollView.scrollViewDidScroll(dragScrollView)

        XCTAssertTrue(hasReparented)
        XCTAssertNil(dragScrollView.runtime.capture.session)
        let detachedOffset = participant.contentOffset
        dragScrollView.contentOffset.y = participantSegment.outerEnd
        dragScrollView.scrollViewDidScroll(dragScrollView)
        XCTAssertEqual(participant.contentOffset, detachedOffset)
    }

    func testBottomInnerOverscrollWillEndDoesNotMutateLiveGeometry() throws {
        let fixture = try makeBottomInnerOverscrollFixture()
        defer {
            if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                fixture.dragScrollView.scrollViewDidEndDragging(
                    fixture.dragScrollView,
                    willDecelerate: false
                )
            }
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
            _ = fixture.provider
        }
        let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let hostOffset = fixture.dragScrollView.contentOffset
        let hostInset = fixture.dragScrollView.contentInset
        let hostContentSize = fixture.dragScrollView.contentSize
        let panelFrame = fixture.panelView.frame
        let participantOffset = fixture.participant.contentOffset
        let captureOperationEpoch = fixture.dragScrollView.runtime.capture.operationEpoch
        fixture.participant.resetRequests()
        var target = CGPoint(
            x: hostOffset.x,
            y: fixture.maximumOuterOffset
        )

        fixture.dragScrollView.scrollViewWillEndDragging(
            fixture.dragScrollView,
            withVelocity: .zero,
            targetContentOffset: &target
        )

        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === session)
        XCTAssertEqual(fixture.dragScrollView.runtime.capture.operationEpoch, captureOperationEpoch)
        XCTAssertEqual(fixture.dragScrollView.contentOffset, hostOffset)
        XCTAssertEqual(fixture.dragScrollView.contentInset, hostInset)
        XCTAssertEqual(fixture.dragScrollView.contentSize, hostContentSize)
        XCTAssertEqual(fixture.panelView.frame, panelFrame)
        XCTAssertEqual(fixture.participant.contentOffset, participantOffset)
        XCTAssertTrue(fixture.participant.requests.isEmpty)
        XCTAssertEqual(target.y, fixture.maximumOuterOffset, accuracy: 0.001)
    }

    func testCoordinatedBottomInnerBounceDoesNotFlashParticipantIndicator() throws {
        let fixture = try makeBottomInnerOverscrollFixture(nativeTracking: true)
        let trackingDidEnd = NSSelectorFromString("_trackingDidEnd")
        defer {
            if fixture.dragScrollView.nativeScrollState.isTracking,
               fixture.dragScrollView.responds(to: trackingDidEnd) {
                fixture.dragScrollView.perform(trackingDidEnd)
            }
            if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                fixture.dragScrollView.scrollViewDidEndDragging(
                    fixture.dragScrollView,
                    willDecelerate: false
                )
            }
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
            _ = fixture.provider
        }

        XCTAssertTrue(fixture.dragScrollView.nativeScrollState.isTracking)
        XCTAssertEqual(
            fixture.participant.flashScrollIndicatorsCallCount,
            0,
            "The coordinator must not start UIKit indicator presentation while it owns bounce geometry."
        )
        XCTAssertEqual(
            fixture.participant.contentOffset.y,
            fixture.participantMaximumOffset + 30,
            accuracy: 0.001
        )
    }

    func testInnerOwnedBottomBounceCommitsOnePanelGeometryBeforeParticipantOffset() throws {
        let observingPanel = GeometryObservingPanelView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 873)
        )
        let (dragScrollView, panelView) = makeHost(
            detents: [100, 873],
            panelHeight: 873,
            suppliedPanelView: observingPanel
        )
        let window = attachToWindow(dragScrollView)
        defer {
            if dragScrollView.runtime.transition.isUserDragLifecycleActive {
                dragScrollView.scrollViewDidEndDragging(
                    dragScrollView,
                    willDecelerate: false
                )
            }
            dragScrollView.endCapture()
            window.isHidden = true
        }

        let participant = OffsetObservingScrollView(
            frame: CGRect(x: 0, y: 40, width: 320, height: 300)
        )
        participant.contentSize = CGSize(width: 320, height: 900)
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.behaviorProvider = SegmentProvider([
            BODragScrollInnerScrollSegment(
                displayHeight: 873,
                beginOffsetY: 0,
                endOffsetY: 600
            )
        ])
        var configuration = dragScrollView.configuration
        configuration.bounce.preferredBottomOwner = .innerScrollView
        dragScrollView.configuration = configuration
        layout(dragScrollView)
        dragScrollView.beginCapture(from: leafView)
        dragScrollView.scrollViewWillBeginDragging(dragScrollView)

        let maximumOuterOffset = dragScrollView.maximumOuterOffset
        let participantMaximumOffset = participant.contentSize.height
            + participant.effectiveContentInset.bottom
            - participant.bounds.height
        deliverHostScroll(dragScrollView, to: maximumOuterOffset)
        let viewportRelativePanelOrigin = panelView.frame.minY - dragScrollView.contentOffset.y
        observingPanel.resetCenterChanges()
        var panelOriginsDuringParticipantWrite: [CGFloat] = []
        participant.offsetDidChange = { [weak panelView] _ in
            panelOriginsDuringParticipantWrite.append(panelView?.frame.minY ?? .nan)
        }

        let bounceDistance: CGFloat = 30.25
        deliverHostScroll(dragScrollView, to: maximumOuterOffset + bounceDistance)
        let committedBounceDistance = dragScrollView.contentOffset.y - maximumOuterOffset

        XCTAssertEqual(observingPanel.centerChanges.count, 1)
        XCTAssertTrue(
            dragScrollView.comparisonPolicy.isValueEqual(
                panelView.frame.minY - dragScrollView.contentOffset.y,
                viewportRelativePanelOrigin
            )
        )
        XCTAssertEqual(
            panelOriginsDuringParticipantWrite.last,
            panelView.frame.minY
        )
        XCTAssertEqual(dragScrollView.displayHeight, 873)
        XCTAssertEqual(
            participant.contentOffset.y,
            participantMaximumOffset + committedBounceDistance,
            accuracy: 0.0001
        )

        panelView.layoutIfNeeded()
        participant.layoutIfNeeded()
        XCTAssertEqual(
            participant.contentOffset.y,
            participantMaximumOffset + committedBounceDistance,
            accuracy: 0.0001
        )
    }

    func testBottomInnerOverscrollDidEndWithoutDecelerationDoesNotSynchronouslyClampParticipant() throws {
        let fixture = try makeBottomInnerOverscrollFixture()
        defer {
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
            _ = fixture.provider
        }
        var target = CGPoint(
            x: fixture.dragScrollView.contentOffset.x,
            y: fixture.maximumOuterOffset
        )
        fixture.dragScrollView.scrollViewWillEndDragging(
            fixture.dragScrollView,
            withVelocity: .zero,
            targetContentOffset: &target
        )
        fixture.participant.resetRequests()

        fixture.dragScrollView.scrollViewDidEndDragging(
            fixture.dragScrollView,
            willDecelerate: false
        )

        XCTAssertFalse(
            fixture.participant.requests.contains { request in
                !request.animated
                    && abs(request.contentOffset.y - fixture.participantMaximumOffset) < 0.001
            },
            "A normal drag release must not synchronously clamp the participant bounce to its boundary."
        )
        XCTAssertGreaterThan(
            fixture.participant.contentOffset.y,
            fixture.participantMaximumOffset
        )
    }

    func testBottomInnerOverscrollWithoutNativeDecelerationReturnsThroughHostSystemAnimation() async throws {
        let fixture = try makeBottomInnerOverscrollFixture()
        let originalSession = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let events = ReentrantDecelerationDelegate()
        let completed = expectation(description: "host overscroll return completed")
        events.onDidFinishMovement = { result in
            if result.reason == .dragRelease {
                completed.fulfill()
            }
        }
        fixture.dragScrollView.eventDelegate = events
        defer {
            fixture.dragScrollView.eventDelegate = nil
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
            _ = fixture.provider
        }
        var target = CGPoint(
            x: fixture.dragScrollView.contentOffset.x,
            y: fixture.maximumOuterOffset
        )
        fixture.dragScrollView.scrollViewWillEndDragging(
            fixture.dragScrollView,
            withVelocity: .zero,
            targetContentOffset: &target
        )

        fixture.dragScrollView.scrollViewDidEndDragging(
            fixture.dragScrollView,
            willDecelerate: false
        )

        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === originalSession)
        XCTAssertGreaterThan(
            fixture.participant.contentOffset.y,
            fixture.participantMaximumOffset
        )

        let fallbackStarted = expectation(description: "fallback scheduled after terminal callback")
        DispatchQueue.main.async { fallbackStarted.fulfill() }
        await fulfillment(of: [fallbackStarted], timeout: 1)

        XCTAssertEqual(fixture.dragScrollView.runtime.transition.driver, .systemAnimation)
        XCTAssertEqual(
            try XCTUnwrap(
                fixture.dragScrollView.runtime.transition.systemAnimationTargetOffsetY
            ),
            fixture.maximumOuterOffset,
            accuracy: 0.001
        )
        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === originalSession)

        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(events.results.last?.outcome, .completed)
        XCTAssertNil(fixture.dragScrollView.runtime.capture.session)
        XCTAssertEqual(
            fixture.participant.contentOffset.y,
            fixture.participantMaximumOffset,
            accuracy: 0.0001
        )
    }

    func testNewTouchCanTakeOverHostOverscrollReturnWithoutRebuildingCapture() async throws {
        let fixture = try makeBottomInnerOverscrollFixture()
        let events = ReentrantDecelerationDelegate()
        fixture.dragScrollView.eventDelegate = events
        defer {
            fixture.dragScrollView.eventDelegate = nil
            if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                fixture.dragScrollView.scrollViewDidEndDragging(
                    fixture.dragScrollView,
                    willDecelerate: false
                )
            }
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
            _ = fixture.provider
        }
        var target = CGPoint(
            x: fixture.dragScrollView.contentOffset.x,
            y: fixture.maximumOuterOffset
        )
        fixture.dragScrollView.scrollViewWillEndDragging(
            fixture.dragScrollView,
            withVelocity: .zero,
            targetContentOffset: &target
        )
        fixture.dragScrollView.scrollViewDidEndDragging(
            fixture.dragScrollView,
            willDecelerate: false
        )
        let fallbackStarted = expectation(description: "host return started")
        DispatchQueue.main.async { fallbackStarted.fulfill() }
        await fulfillment(of: [fallbackStarted], timeout: 1)

        let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let oldGeneration = session.ownershipGeneration
        let hostOffset = fixture.dragScrollView.contentOffset
        let panelFrame = fixture.panelView.frame
        let participantOffset = fixture.participant.contentOffset

        fixture.dragScrollView.beginCapture(from: fixture.leafView)
        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)

        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === session)
        XCTAssertGreaterThan(session.ownershipGeneration, oldGeneration)
        XCTAssertEqual(fixture.dragScrollView.contentOffset, hostOffset)
        XCTAssertEqual(fixture.panelView.frame, panelFrame)
        XCTAssertEqual(fixture.participant.contentOffset, participantOffset)
        XCTAssertNil(fixture.dragScrollView.runtime.transition.activeTransaction)
        XCTAssertNil(fixture.dragScrollView.runtime.transition.driver)
        XCTAssertEqual(events.results.map(\.reason), [.dragRelease])
        XCTAssertEqual(events.results.map(\.outcome), [.interrupted])

        fixture.dragScrollView.scrollViewDidEndScrollingAnimation(fixture.dragScrollView)

        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === session)
        XCTAssertTrue(fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive)
    }

    func testNewTouchDuringParticipantDecelerationRefreshesSameCaptureAndInterruptsOldMovement() throws {
        let fixture = try makeBottomInnerOverscrollFixture()
        let participantLifecycle = ParticipantLifecycleSpy()
        let events = ReentrantDecelerationDelegate()
        fixture.participant.delegate = participantLifecycle
        fixture.dragScrollView.eventDelegate = events
        defer {
            fixture.dragScrollView.eventDelegate = nil
            fixture.participant.delegate = nil
            if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                fixture.dragScrollView.scrollViewDidEndDragging(
                    fixture.dragScrollView,
                    willDecelerate: false
                )
            }
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
            _ = fixture.provider
        }

        fixture.dragScrollView.contentOffset.y = fixture.maximumOuterOffset - 100
        fixture.dragScrollView.scrollViewDidScroll(fixture.dragScrollView)
        let originalSession = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let originalGeneration = originalSession.ownershipGeneration
        let hostOffset = fixture.dragScrollView.contentOffset
        let panelFrame = fixture.panelView.frame
        let participantOffset = fixture.participant.contentOffset
        XCTAssertLessThan(
            fixture.participant.contentOffset.y,
            fixture.participantMaximumOffset
        )

        try beginDragDeceleration(
            on: fixture.dragScrollView,
            targetOffsetY: fixture.maximumOuterOffset
        )
        fixture.dragScrollView.beginCapture(from: fixture.leafView)
        let refreshedSession = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)

        XCTAssertTrue(refreshedSession === originalSession)
        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === originalSession)
        XCTAssertGreaterThan(refreshedSession.ownershipGeneration, originalGeneration)
        XCTAssertEqual(fixture.dragScrollView.contentOffset, hostOffset)
        XCTAssertEqual(fixture.panelView.frame, panelFrame)
        XCTAssertEqual(fixture.participant.contentOffset, participantOffset)
        XCTAssertNil(fixture.dragScrollView.runtime.transition.activeTransaction)
        XCTAssertEqual(events.results.map(\.reason), [.dragRelease])
        XCTAssertEqual(events.results.map(\.outcome), [.interrupted])
        XCTAssertEqual(participantLifecycle.didDecelerate.count, 1)
        XCTAssertEqual(participantLifecycle.began.count, 1)
        XCTAssertFalse(fixture.dragScrollView.runtime.transition.isAwaitingDidEndDecelerating)

        fixture.dragScrollView.scrollViewDidEndDecelerating(fixture.dragScrollView)

        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === originalSession)
        XCTAssertEqual(participantLifecycle.didDecelerate.count, 1)
        XCTAssertEqual(events.didEndDeceleratingCount, 1)
        XCTAssertTrue(fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive)
    }

    func testNewTouchDuringBottomBounceDecelerationPreservesSameCaptureAndIgnoresLateOldEnd() throws {
        let observingPanel = GeometryObservingPanelView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 800)
        )
        let fixture = try makeBottomInnerOverscrollFixture(
            suppliedPanelView: observingPanel
        )
        let participantLifecycle = ParticipantLifecycleSpy()
        let events = ReentrantDecelerationDelegate()
        fixture.participant.delegate = participantLifecycle
        fixture.dragScrollView.eventDelegate = events
        defer {
            fixture.dragScrollView.eventDelegate = nil
            fixture.participant.delegate = nil
            if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                fixture.dragScrollView.contentOffset.y = fixture.maximumOuterOffset
                fixture.dragScrollView.scrollViewDidScroll(fixture.dragScrollView)
                fixture.dragScrollView.scrollViewDidEndDragging(
                    fixture.dragScrollView,
                    willDecelerate: false
                )
            }
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
            _ = fixture.provider
        }

        let originalSession = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let originalGeneration = originalSession.ownershipGeneration
        try beginDragDeceleration(
            on: fixture.dragScrollView,
            targetOffsetY: fixture.maximumOuterOffset
        )
        let hostOffset = fixture.dragScrollView.contentOffset
        let hostInset = fixture.dragScrollView.contentInset
        let hostContentSize = fixture.dragScrollView.contentSize
        let panelFrame = fixture.panelView.frame
        let participantOffset = fixture.participant.contentOffset
        let viewportRelativePanelOrigin = fixture.panelView.frame.minY
            - fixture.dragScrollView.contentOffset.y
        observingPanel.resetCenterChanges()

        fixture.dragScrollView.beginCapture(from: fixture.leafView)
        let refreshedSession = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        XCTAssertTrue(refreshedSession === originalSession)
        XCTAssertGreaterThan(refreshedSession.ownershipGeneration, originalGeneration)

        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)

        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === originalSession)
        XCTAssertEqual(
            fixture.dragScrollView.runtime.capture.session?.ownershipGeneration,
            refreshedSession.ownershipGeneration
        )
        XCTAssertEqual(
            fixture.dragScrollView.runtime.transition.captureCleanupOwnership?.sessionID,
            originalSession.id
        )
        XCTAssertEqual(
            fixture.dragScrollView.runtime.transition.captureCleanupOwnership?
                .sessionOwnershipGeneration,
            refreshedSession.ownershipGeneration
        )
        XCTAssertEqual(fixture.dragScrollView.contentOffset, hostOffset)
        XCTAssertEqual(fixture.dragScrollView.contentInset, hostInset)
        XCTAssertEqual(fixture.dragScrollView.contentSize, hostContentSize)
        XCTAssertEqual(fixture.panelView.frame, panelFrame)
        XCTAssertEqual(fixture.participant.contentOffset, participantOffset)
        XCTAssertNil(fixture.dragScrollView.runtime.transition.activeTransaction)
        XCTAssertEqual(events.results.map(\.reason), [.dragRelease])
        XCTAssertEqual(events.results.map(\.outcome), [.interrupted])
        XCTAssertEqual(participantLifecycle.didDecelerate.count, 1)
        XCTAssertEqual(participantLifecycle.began.count, 1)
        XCTAssertEqual(events.didEndDeceleratingCount, 1)
        XCTAssertEqual(events.willBeginDraggingCount, 1)
        XCTAssertFalse(fixture.dragScrollView.runtime.transition.isAwaitingDidEndDecelerating)
        XCTAssertTrue(fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive)
        XCTAssertTrue(observingPanel.centerChanges.isEmpty)

        // The first sample owned by the new drag continues from the visible bounce instead of
        // normalizing to the participant boundary and later jumping back out.
        let continuedBounceDistance: CGFloat = 24
        deliverHostScroll(
            fixture.dragScrollView,
            to: fixture.maximumOuterOffset + continuedBounceDistance
        )
        XCTAssertEqual(observingPanel.centerChanges.count, 1)
        XCTAssertEqual(
            fixture.panelView.frame.minY - fixture.dragScrollView.contentOffset.y,
            viewportRelativePanelOrigin
        )
        XCTAssertEqual(
            fixture.participant.contentOffset.y,
            fixture.participantMaximumOffset + continuedBounceDistance,
            accuracy: 0.0001
        )
        let continuedHostOffset = fixture.dragScrollView.contentOffset
        let continuedPanelFrame = fixture.panelView.frame
        let continuedParticipantOffset = fixture.participant.contentOffset

        // UIKit may still deliver the callback belonging to the deceleration interrupted above.
        // It has no authority over the tracking lifecycle and refreshed capture generation.
        fixture.dragScrollView.scrollViewDidEndDecelerating(fixture.dragScrollView)

        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === originalSession)
        XCTAssertEqual(
            fixture.dragScrollView.runtime.capture.session?.ownershipGeneration,
            refreshedSession.ownershipGeneration
        )
        XCTAssertEqual(participantLifecycle.didDecelerate.count, 1)
        XCTAssertEqual(events.didEndDeceleratingCount, 1)
        XCTAssertTrue(fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive)
        XCTAssertEqual(fixture.dragScrollView.contentOffset, continuedHostOffset)
        XCTAssertEqual(fixture.panelView.frame, continuedPanelFrame)
        XCTAssertEqual(fixture.participant.contentOffset, continuedParticipantOffset)
    }

    func testAdaptiveFreePanelDirectionReturnRebasesBeforeApplyingCurrentDelta() throws {
        let fixture = try makeAdaptiveFreePanelFixture(initialDisplayHeight: 300)
        let recorder = MovementEventRecorder()
        fixture.dragScrollView.eventDelegate = recorder
        defer {
            fixture.dragScrollView.eventDelegate = nil
            if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                fixture.dragScrollView.scrollViewDidEndDragging(
                    fixture.dragScrollView,
                    willDecelerate: false
                )
            }
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
        }
        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)
        let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        XCTAssertEqual(session.axisPhase?.rebasePolicy, .continuousPanel)

        let oldModel = try XCTUnwrap(session.model)
        let oldBlockEnd = try XCTUnwrap(oldModel.segments.last?.outerEnd)
        deliverHostScroll(fixture.dragScrollView, to: oldBlockEnd)
        XCTAssertEqual(
            fixture.participant.contentOffset.y,
            fixture.participantMaximumOffset,
            accuracy: 0.0001
        )

        let expandedDisplayHeight: CGFloat = 700
        let expandedOuterOffset = oldBlockEnd + expandedDisplayHeight - 300
        deliverHostScroll(fixture.dragScrollView, to: expandedOuterOffset)
        XCTAssertEqual(fixture.dragScrollView.displayHeight, expandedDisplayHeight, accuracy: 0.0001)

        let updatesBeforeReturn = recorder.scrollUpdates.count
        let returningOuterOffset = expandedOuterOffset - 10
        // UIKit advances its own contentOffset before calling the delegate; the panel frame and
        // participant offsets still represent the previously committed pivot at this point.
        setHostOffsetWithoutDeliveringScroll(
            fixture.dragScrollView,
            to: returningOuterOffset
        )
        fixture.dragScrollView.rebaseAdaptiveAxisForReturningDragIfNeeded(
            nativeIsDragging: true
        )
        fixture.dragScrollView.scrollViewDidScroll(fixture.dragScrollView)

        let rebasedModel = try XCTUnwrap(session.model)
        XCTAssertNotEqual(rebasedModel, oldModel)
        XCTAssertEqual(
            try XCTUnwrap(rebasedModel.segments.first?.displayHeight),
            expandedDisplayHeight,
            accuracy: 0.0001
        )
        XCTAssertEqual(fixture.dragScrollView.displayHeight, expandedDisplayHeight, accuracy: 0.0001)
        XCTAssertEqual(
            fixture.participant.contentOffset.y,
            fixture.participantMaximumOffset - 10,
            accuracy: 0.0001
        )
        XCTAssertEqual(recorder.scrollUpdates.count - updatesBeforeReturn, 1)
        if case .participant(let scrollView) = recorder.scrollUpdates.last?.source {
            XCTAssertTrue(scrollView === fixture.participant)
        } else {
            XCTFail("The first returning delta must belong to the participant")
        }

        let newBlockStart = try XCTUnwrap(rebasedModel.segments.first?.outerStart)
        deliverHostScroll(fixture.dragScrollView, to: newBlockStart)
        XCTAssertEqual(fixture.participant.contentOffset.y, 0, accuracy: 0.0001)
        deliverHostScroll(fixture.dragScrollView, to: newBlockStart - 20)
        XCTAssertEqual(fixture.dragScrollView.displayHeight, expandedDisplayHeight - 20, accuracy: 0.0001)
    }

    func testAdaptiveFreePanelLowerReturnRebasesSymmetrically() throws {
        let fixture = try makeAdaptiveFreePanelFixture(initialDisplayHeight: 500)
        defer {
            if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                fixture.dragScrollView.scrollViewDidEndDragging(
                    fixture.dragScrollView,
                    willDecelerate: false
                )
            }
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
        }
        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)
        let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let oldModel = try XCTUnwrap(session.model)
        let oldBlockStart = try XCTUnwrap(oldModel.segments.first?.outerStart)

        let collapsedDisplayHeight: CGFloat = 200
        let collapsedOuterOffset = oldBlockStart - (500 - collapsedDisplayHeight)
        deliverHostScroll(fixture.dragScrollView, to: collapsedOuterOffset)
        XCTAssertEqual(fixture.dragScrollView.displayHeight, collapsedDisplayHeight, accuracy: 0.0001)
        XCTAssertEqual(fixture.participant.contentOffset.y, 0, accuracy: 0.0001)

        setHostOffsetWithoutDeliveringScroll(
            fixture.dragScrollView,
            to: collapsedOuterOffset + 10
        )
        fixture.dragScrollView.rebaseAdaptiveAxisForReturningDragIfNeeded(
            nativeIsDragging: true
        )
        fixture.dragScrollView.scrollViewDidScroll(fixture.dragScrollView)

        let rebasedModel = try XCTUnwrap(session.model)
        XCTAssertNotEqual(rebasedModel, oldModel)
        XCTAssertEqual(
            try XCTUnwrap(rebasedModel.segments.first?.displayHeight),
            collapsedDisplayHeight,
            accuracy: 0.0001
        )
        XCTAssertEqual(fixture.dragScrollView.displayHeight, collapsedDisplayHeight, accuracy: 0.0001)
        XCTAssertEqual(fixture.participant.contentOffset.y, 10, accuracy: 0.0001)
    }

    func testAdaptiveFreePanelCanRebaseAgainAfterMovingInBothDirections() throws {
        let fixture = try makeAdaptiveFreePanelFixture(initialDisplayHeight: 300)
        defer {
            if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                fixture.dragScrollView.scrollViewDidEndDragging(
                    fixture.dragScrollView,
                    willDecelerate: false
                )
            }
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
        }
        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)
        let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let initialModel = try XCTUnwrap(session.model)
        let initialBlockEnd = try XCTUnwrap(initialModel.segments.last?.outerEnd)

        let expandedDisplayHeight: CGFloat = 700
        let expandedOuterOffset = initialBlockEnd + expandedDisplayHeight - 300
        deliverHostScroll(fixture.dragScrollView, to: expandedOuterOffset)
        setHostOffsetWithoutDeliveringScroll(
            fixture.dragScrollView,
            to: expandedOuterOffset - 10
        )
        fixture.dragScrollView.rebaseAdaptiveAxisForReturningDragIfNeeded(
            nativeIsDragging: true
        )
        fixture.dragScrollView.scrollViewDidScroll(fixture.dragScrollView)

        let expandedModel = try XCTUnwrap(session.model)
        XCTAssertNotEqual(expandedModel, initialModel)
        XCTAssertEqual(
            try XCTUnwrap(expandedModel.segments.first?.displayHeight),
            expandedDisplayHeight,
            accuracy: 0.0001
        )

        // Consume the newly positioned inner range downward, then continue moving the panel below
        // it. Reversing upward must create a second phase at this new panel height.
        let expandedBlockStart = try XCTUnwrap(expandedModel.segments.first?.outerStart)
        deliverHostScroll(fixture.dragScrollView, to: expandedBlockStart)
        let collapsedDisplayHeight: CGFloat = 300
        let collapsedOuterOffset = expandedBlockStart
            - (expandedDisplayHeight - collapsedDisplayHeight)
        deliverHostScroll(fixture.dragScrollView, to: collapsedOuterOffset)
        setHostOffsetWithoutDeliveringScroll(
            fixture.dragScrollView,
            to: collapsedOuterOffset + 10
        )
        fixture.dragScrollView.rebaseAdaptiveAxisForReturningDragIfNeeded(
            nativeIsDragging: true
        )
        fixture.dragScrollView.scrollViewDidScroll(fixture.dragScrollView)

        let collapsedModel = try XCTUnwrap(session.model)
        XCTAssertNotEqual(collapsedModel, expandedModel)
        XCTAssertEqual(
            try XCTUnwrap(collapsedModel.segments.first?.displayHeight),
            collapsedDisplayHeight,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            fixture.dragScrollView.displayHeight,
            collapsedDisplayHeight,
            accuracy: 0.0001
        )
        XCTAssertEqual(fixture.participant.contentOffset.y, 10, accuracy: 0.0001)
    }

    func testAdaptiveFreePanelRebasePreservesNestedParticipantAxis() throws {
        let (dragScrollView, panelView) = makeHost()
        _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
        let outer = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 400),
            contentHeight: 1_200
        )
        let outerContent = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 1_200))
        outer.addSubview(outerContent)
        let middle = makeScrollView(
            frame: CGRect(x: 0, y: 100, width: 320, height: 500),
            contentHeight: 900
        )
        let middleContent = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 900))
        middle.addSubview(middleContent)
        outerContent.addSubview(middle)
        let deep = makeScrollView(
            frame: CGRect(x: 0, y: 100, width: 320, height: 200),
            contentHeight: 600
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 10, width: 40, height: 40))
        deep.addSubview(leafView)
        middleContent.addSubview(deep)
        panelView.addSubview(outer)
        dragScrollView.beginCapture(from: leafView)
        defer {
            if dragScrollView.runtime.transition.isUserDragLifecycleActive {
                dragScrollView.scrollViewDidEndDragging(
                    dragScrollView,
                    willDecelerate: false
                )
            }
            dragScrollView.endCapture()
        }

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        let session = try XCTUnwrap(dragScrollView.runtime.capture.session)
        XCTAssertEqual(session.participantChain.count, 3)
        XCTAssertEqual(session.axisPhase?.rebasePolicy, .continuousPanel)
        let originalModel = try XCTUnwrap(session.model)
        XCTAssertEqual(
            originalModel.segments.compactMap(\.participantID),
            [
                session.participantChain[2].id,
                session.participantChain[1].id,
                session.participantChain[0].id,
                session.participantChain[1].id,
                session.participantChain[2].id
            ]
        )
        let originalActivation = try XCTUnwrap(originalModel.segments.first?.displayHeight)
        let originalBlockEnd = try XCTUnwrap(originalModel.segments.last?.outerEnd)
        let expandedDisplayHeight: CGFloat = 700
        let expandedOuterOffset = originalBlockEnd
            + expandedDisplayHeight
            - originalActivation
        deliverHostScroll(dragScrollView, to: expandedOuterOffset)
        let offsetsAtExpandedPivot = session.participantChain.compactMap {
            $0.scrollView?.contentOffset.y
        }

        let returningOuterOffset = expandedOuterOffset - 10
        setHostOffsetWithoutDeliveringScroll(dragScrollView, to: returningOuterOffset)
        let panelFrameAtPivot = panelView.frame
        let offsetsAtPivot = session.participantChain.compactMap {
            $0.scrollView?.contentOffset
        }
        dragScrollView.rebaseAdaptiveAxisForReturningDragIfNeeded(nativeIsDragging: true)

        XCTAssertEqual(panelView.frame, panelFrameAtPivot)
        XCTAssertEqual(
            session.participantChain.compactMap { $0.scrollView?.contentOffset },
            offsetsAtPivot
        )
        dragScrollView.scrollViewDidScroll(dragScrollView)

        let rebasedModel = try XCTUnwrap(session.model)
        XCTAssertNotEqual(rebasedModel, originalModel)
        XCTAssertEqual(
            rebasedModel.segments.map(\.owner),
            originalModel.segments.map(\.owner)
        )
        XCTAssertEqual(
            rebasedModel.segments.map(\.innerStart),
            originalModel.segments.map(\.innerStart)
        )
        XCTAssertEqual(
            rebasedModel.segments.map(\.innerEnd),
            originalModel.segments.map(\.innerEnd)
        )
        XCTAssertTrue(
            rebasedModel.segments.allSatisfy {
                $0.displayHeight == expandedDisplayHeight
            }
        )
        XCTAssertEqual(dragScrollView.displayHeight, expandedDisplayHeight, accuracy: 0.0001)

        let expectedProjection = rebasedModel.projection(at: returningOuterOffset)
        for expected in expectedProjection.participantOffsets {
            let actual = try XCTUnwrap(session.participant(with: expected.participantID)?.scrollView)
            XCTAssertEqual(actual.contentOffset.y, expected.contentOffset, accuracy: 0.0001)
        }
        let offsetsAfterReturn = session.participantChain.compactMap {
            $0.scrollView?.contentOffset.y
        }
        XCTAssertTrue(
            zip(offsetsAtExpandedPivot, offsetsAfterReturn).contains {
                abs($0 - $1) >= 0.0001
            }
        )
    }

    func testAdaptiveFreePanelUsesStrictOnePhysicalPixelDepartureGate() throws {
        func run(previousOuterOffset: (CGFloat, CGFloat) -> CGFloat) throws -> Bool {
            let fixture = try makeAdaptiveFreePanelFixture(initialDisplayHeight: 300)
            defer {
                if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                    fixture.dragScrollView.scrollViewDidEndDragging(
                        fixture.dragScrollView,
                        willDecelerate: false
                    )
                }
                fixture.dragScrollView.endCapture()
                fixture.window.isHidden = true
            }
            fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)
            let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
            let originalModel = try XCTUnwrap(session.model)
            let blockEnd = try XCTUnwrap(originalModel.segments.last?.outerEnd)
            let previous = previousOuterOffset(
                blockEnd,
                originalModel.comparison.boundaryBand
            )
            deliverHostScroll(fixture.dragScrollView, to: previous)
            setHostOffsetWithoutDeliveringScroll(
                fixture.dragScrollView,
                // UIScrollView may align its offset to physical pixels. Use one whole pixel so
                // the returning delta itself is observable; this test varies only the prior
                // departure distance around the strict adaptive-axis threshold.
                to: previous - originalModel.comparison.boundaryBand
            )
            fixture.dragScrollView.rebaseAdaptiveAxisForReturningDragIfNeeded(
                nativeIsDragging: true
            )
            return session.model != originalModel
        }

        // UIScrollView aligns these coordinates to physical pixels, so sub-pixel requests cannot
        // reliably exercise a just-below threshold. Verify the two physically distinct states;
        // the gate itself accepts only one ULP of representation noise around the exact threshold.
        XCTAssertFalse(try run { blockEnd, _ in blockEnd })
        XCTAssertTrue(try run { blockEnd, band in blockEnd + band })
    }

    func testAdaptiveFreePanelReturningDeltaRequiresNativeDragging() throws {
        let fixture = try makeAdaptiveFreePanelFixture(initialDisplayHeight: 300)
        defer {
            if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                fixture.dragScrollView.scrollViewDidEndDragging(
                    fixture.dragScrollView,
                    willDecelerate: false
                )
            }
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
        }
        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)
        let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let originalModel = try XCTUnwrap(session.model)
        let blockEnd = try XCTUnwrap(originalModel.segments.last?.outerEnd)
        let expandedOuterOffset = blockEnd + 200
        deliverHostScroll(fixture.dragScrollView, to: expandedOuterOffset)
        setHostOffsetWithoutDeliveringScroll(
            fixture.dragScrollView,
            to: expandedOuterOffset - 10
        )

        fixture.dragScrollView.rebaseAdaptiveAxisForReturningDragIfNeeded(
            nativeIsDragging: false
        )

        XCTAssertEqual(session.model, originalModel)
    }

    func testAdaptiveFreePanelRebaseFailsClosedForDirtyOrIncoherentState() throws {
        func run(
            mutate: (
                BODragScrollView,
                UIScrollView,
                BODragScrollCaptureSession
            ) -> Void
        ) throws {
            let fixture = try makeAdaptiveFreePanelFixture(initialDisplayHeight: 300)
            defer {
                if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                    fixture.dragScrollView.scrollViewDidEndDragging(
                        fixture.dragScrollView,
                        willDecelerate: false
                    )
                }
                fixture.dragScrollView.endCapture()
                fixture.window.isHidden = true
            }
            fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)
            let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
            let originalModel = try XCTUnwrap(session.model)
            let blockEnd = try XCTUnwrap(originalModel.segments.last?.outerEnd)
            let expandedOuterOffset = blockEnd + 200
            deliverHostScroll(fixture.dragScrollView, to: expandedOuterOffset)
            mutate(fixture.dragScrollView, fixture.participant, session)
            setHostOffsetWithoutDeliveringScroll(
                fixture.dragScrollView,
                to: expandedOuterOffset - 10
            )

            fixture.dragScrollView.rebaseAdaptiveAxisForReturningDragIfNeeded(
                nativeIsDragging: true
            )

            XCTAssertEqual(session.model, originalModel)
        }

        try run { _, _, session in
            session.hasDeferredMetricsChange = true
        }
        try run { dragScrollView, _, _ in
            dragScrollView.runtime.scrolling.mismatchDirection = 1
        }
        try run { _, participant, _ in
            participant.contentOffset.y -= 10
        }
        try run { dragScrollView, _, _ in
            dragScrollView.bounds.size.height -= 1
        }
    }

    func testFixedFreePanelAxisKeepsMaximumEndpointExact() throws {
        let exactMaximumDisplayHeight: CGFloat = 873
        let (dragScrollView, panelView) = makeHost(
            panelHeight: exactMaximumDisplayHeight
        )
        let window = attachToWindow(dragScrollView)
        defer {
            dragScrollView.endCapture()
            window.isHidden = true
        }
        _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
        var configuration = dragScrollView.configuration
        configuration.handoff.innerScrollPlacement = .atDisplayHeight(300)
        dragScrollView.configuration = configuration
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 40, width: 320, height: 300),
            contentHeight: 1_900.3
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 10, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)

        let phase = try XCTUnwrap(dragScrollView.runtime.capture.session?.axisPhase)
        XCTAssertEqual(phase.rebasePolicy, .fixed)
        XCTAssertEqual(
            phase.endpointAuthority.displayHeightRange.upperBound,
            exactMaximumDisplayHeight
        )
        XCTAssertEqual(
            phase.endpointAuthority.outerOffsetRange.upperBound,
            dragScrollView.maximumOuterOffset
        )
        deliverHostScroll(dragScrollView, to: phase.endpointAuthority.outerOffsetRange.upperBound)

        XCTAssertEqual(dragScrollView.displayHeight, exactMaximumDisplayHeight)
        XCTAssertTrue(
            dragScrollView.comparisonPolicy.isValueEqual(
                dragScrollView.displayHeightForCurrentGeometry,
                exactMaximumDisplayHeight
            )
        )
    }

    func testInitialAdaptiveCaptureDoesNotPersistMaximumMachineTail() throws {
        let exactMaximumDisplayHeight: CGFloat = 873
        let (dragScrollView, panelView) = makeHost(
            panelHeight: exactMaximumDisplayHeight
        )
        let window = attachToWindow(dragScrollView)
        defer {
            dragScrollView.endCapture()
            window.isHidden = true
        }
        _ = dragScrollView.move(
            toDisplayHeight: exactMaximumDisplayHeight,
            animated: false
        )
        let noisyDisplayHeight = exactMaximumDisplayHeight.nextUp
        var noisyFrame = panelView.frame
        noisyFrame.origin.y = dragScrollView.bounds.height
            + dragScrollView.contentOffset.y
            - noisyDisplayHeight
        dragScrollView.setPanelFrame(noisyFrame)
        XCTAssertEqual(
            dragScrollView.displayHeightForCurrentGeometry,
            noisyDisplayHeight
        )

        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 40, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 10, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)

        let phase = try XCTUnwrap(dragScrollView.runtime.capture.session?.axisPhase)
        XCTAssertEqual(phase.rebasePolicy, .continuousPanel)
        XCTAssertEqual(
            try XCTUnwrap(phase.model.segments.first?.displayHeight),
            exactMaximumDisplayHeight
        )
        XCTAssertEqual(
            phase.endpointAuthority.displayHeightRange.upperBound,
            exactMaximumDisplayHeight
        )
        XCTAssertEqual(dragScrollView.displayHeight, exactMaximumDisplayHeight)
        XCTAssertTrue(
            dragScrollView.comparisonPolicy.isValueEqual(
                dragScrollView.displayHeightForCurrentGeometry,
                exactMaximumDisplayHeight
            )
        )
    }

    func testFixedProviderMismatchRecoveryPreservesExtendedActivationHeight() throws {
        let panelHeight: CGFloat = 800
        let providerDisplayHeight: CGFloat = 900
        let (dragScrollView, panelView) = makeHost(panelHeight: panelHeight)
        let window = attachToWindow(dragScrollView)
        defer {
            dragScrollView.runtime.scrolling.isForcingMismatchRecovery = false
            dragScrollView.endCapture()
            window.isHidden = true
        }
        _ = dragScrollView.move(
            toDisplayHeight: providerDisplayHeight,
            animated: false
        )
        let provider = SegmentProvider([
            BODragScrollInnerScrollSegment(
                displayHeight: providerDisplayHeight,
                beginOffsetY: 0,
                endOffsetY: 300
            )
        ])
        dragScrollView.behaviorProvider = provider
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 40, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 10, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)

        let session = try XCTUnwrap(dragScrollView.runtime.capture.session)
        XCTAssertEqual(session.axisPhase?.rebasePolicy, .fixed)
        XCTAssertEqual(
            try XCTUnwrap(session.model?.segments.first?.displayHeight),
            providerDisplayHeight
        )
        XCTAssertEqual(
            session.axisPhase?.endpointAuthority.displayHeightRange.upperBound,
            providerDisplayHeight
        )
        XCTAssertEqual(
            session.axisPhase?.endpointAuthority.outerOffsetRange.upperBound,
            dragScrollView.maximumOuterOffset
        )

        dragScrollView.runtime.scrolling.isForcingMismatchRecovery = true
        dragScrollView.rebuildCaptureSessionIfNeeded(reason: .mismatchRecovery)
        dragScrollView.runtime.scrolling.isForcingMismatchRecovery = false

        XCTAssertEqual(session.axisPhase?.rebasePolicy, .fixed)
        XCTAssertEqual(
            try XCTUnwrap(session.model?.segments.first?.displayHeight),
            providerDisplayHeight
        )
        XCTAssertEqual(
            session.axisPhase?.endpointAuthority.displayHeightRange.upperBound,
            providerDisplayHeight
        )
        XCTAssertEqual(
            session.axisPhase?.endpointAuthority.outerOffsetRange.upperBound,
            dragScrollView.maximumOuterOffset
        )
    }

    func testInitialContinuousCapturePreservesCompatibleBottomPanelBounce() throws {
        let exactMaximumDisplayHeight: CGFloat = 873
        let (dragScrollView, panelView) = makeHost(
            panelHeight: exactMaximumDisplayHeight
        )
        let window = attachToWindow(dragScrollView)
        defer {
            dragScrollView.endCapture()
            window.isHidden = true
        }
        _ = dragScrollView.move(
            toDisplayHeight: exactMaximumDisplayHeight,
            animated: false
        )
        let panelMaximumOuterOffset = dragScrollView.maximumOuterOffset
        let bounceDistance: CGFloat = 30
        deliverHostScroll(
            dragScrollView,
            to: panelMaximumOuterOffset + bounceDistance
        )

        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 40, width: 320, height: 300),
            contentHeight: 900
        )
        let participantMaximum = participant.contentSize.height
            - participant.bounds.height
        participant.contentOffset.y = participantMaximum
        let leafView = UIView(frame: CGRect(x: 0, y: 10, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)

        let phase = try XCTUnwrap(dragScrollView.runtime.capture.session?.axisPhase)
        XCTAssertEqual(phase.rebasePolicy, .continuousPanel)
        XCTAssertEqual(
            try XCTUnwrap(phase.model.segments.first?.displayHeight),
            exactMaximumDisplayHeight
        )
        XCTAssertEqual(
            phase.endpointAuthority.displayHeightRange.upperBound,
            exactMaximumDisplayHeight
        )
        XCTAssertEqual(
            dragScrollView.contentOffset.y
                - phase.endpointAuthority.outerOffsetRange.upperBound,
            bounceDistance,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            dragScrollView.displayHeight,
            exactMaximumDisplayHeight + bounceDistance,
            accuracy: 0.0001
        )
        XCTAssertEqual(participant.contentOffset.y, participantMaximum, accuracy: 0.0001)
    }

    func testInitialContinuousCaptureFailsClosedForIncompatiblePanelBounce() throws {
        let exactMaximumDisplayHeight: CGFloat = 873
        let (dragScrollView, panelView) = makeHost(
            panelHeight: exactMaximumDisplayHeight
        )
        let window = attachToWindow(dragScrollView)
        defer {
            dragScrollView.endCapture()
            window.isHidden = true
        }
        _ = dragScrollView.move(
            toDisplayHeight: exactMaximumDisplayHeight,
            animated: false
        )
        let bounceDistance: CGFloat = 30
        deliverHostScroll(
            dragScrollView,
            to: dragScrollView.maximumOuterOffset + bounceDistance
        )
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 40, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 10, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)

        let session = try XCTUnwrap(dragScrollView.runtime.capture.session)
        XCTAssertNil(session.axisPhase)
        XCTAssertFalse(dragScrollView.hasParticipantSegments)
        XCTAssertEqual(participant.contentOffset.y, 0, accuracy: 0.0001)
        XCTAssertEqual(
            dragScrollView.displayHeightForCurrentGeometry,
            exactMaximumDisplayHeight + bounceDistance,
            accuracy: 0.0001
        )
    }

    func testInitialContinuousCapturePreservesCompatibleTopPanelBounce() throws {
        let (dragScrollView, panelView) = makeHost(panelHeight: 873)
        let window = attachToWindow(dragScrollView)
        defer {
            dragScrollView.endCapture()
            window.isHidden = true
        }
        let exactMinimumDisplayHeight = dragScrollView.effectiveMinimumDisplayHeight
        _ = dragScrollView.move(
            toDisplayHeight: exactMinimumDisplayHeight,
            animated: false
        )
        let panelMinimumOuterOffset = dragScrollView.minimumOuterOffset
        let bounceDistance: CGFloat = 30
        deliverHostScroll(
            dragScrollView,
            to: panelMinimumOuterOffset - bounceDistance
        )

        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 40, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 10, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)

        let phase = try XCTUnwrap(dragScrollView.runtime.capture.session?.axisPhase)
        XCTAssertEqual(phase.rebasePolicy, .continuousPanel)
        XCTAssertEqual(
            try XCTUnwrap(phase.model.segments.first?.displayHeight),
            exactMinimumDisplayHeight
        )
        XCTAssertEqual(
            phase.endpointAuthority.displayHeightRange.lowerBound,
            exactMinimumDisplayHeight
        )
        XCTAssertEqual(
            phase.endpointAuthority.outerOffsetRange.lowerBound
                - dragScrollView.contentOffset.y,
            bounceDistance,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            dragScrollView.displayHeight,
            exactMinimumDisplayHeight - bounceDistance,
            accuracy: 0.0001
        )
        XCTAssertEqual(participant.contentOffset.y, 0, accuracy: 0.0001)
    }

    func testInitialContinuousCaptureFailsClosedForIncompatibleTopPanelBounce() throws {
        let (dragScrollView, panelView) = makeHost(panelHeight: 873)
        let window = attachToWindow(dragScrollView)
        defer {
            dragScrollView.endCapture()
            window.isHidden = true
        }
        let exactMinimumDisplayHeight = dragScrollView.effectiveMinimumDisplayHeight
        _ = dragScrollView.move(
            toDisplayHeight: exactMinimumDisplayHeight,
            animated: false
        )
        let bounceDistance: CGFloat = 30
        deliverHostScroll(
            dragScrollView,
            to: dragScrollView.minimumOuterOffset - bounceDistance
        )
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 40, width: 320, height: 300),
            contentHeight: 900
        )
        participant.contentOffset.y = 100
        let leafView = UIView(frame: CGRect(x: 0, y: 10, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)

        let session = try XCTUnwrap(dragScrollView.runtime.capture.session)
        XCTAssertNil(session.axisPhase)
        XCTAssertFalse(dragScrollView.hasParticipantSegments)
        XCTAssertEqual(participant.contentOffset.y, 100, accuracy: 0.0001)
        XCTAssertEqual(
            dragScrollView.displayHeightForCurrentGeometry,
            exactMinimumDisplayHeight - bounceDistance,
            accuracy: 0.0001
        )
    }

    func testAdaptiveFreePanelRebaseKeepsCapturedMaximumHeightExact() throws {
        let exactMaximumDisplayHeight: CGFloat = 873
        let fixture = try makeAdaptiveFreePanelFixture(
            initialDisplayHeight: 300,
            panelHeight: exactMaximumDisplayHeight,
            participantContentHeight: 1_900.3
        )
        defer {
            if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                fixture.dragScrollView.scrollViewDidEndDragging(
                    fixture.dragScrollView,
                    willDecelerate: false
                )
            }
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
        }
        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)
        let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let originalModel = try XCTUnwrap(session.model)
        let displayRange = try XCTUnwrap(
            session.axisPhase?.endpointAuthority.displayHeightRange
        )
        XCTAssertEqual(displayRange.upperBound, exactMaximumDisplayHeight)
        fixture.dragScrollView.minimumDisplayHeight = 120
        XCTAssertEqual(
            session.axisPhase?.endpointAuthority.displayHeightRange,
            displayRange
        )

        deliverHostScroll(
            fixture.dragScrollView,
            to: fixture.dragScrollView.maximumOuterOffset
        )
        XCTAssertEqual(fixture.dragScrollView.displayHeight, exactMaximumDisplayHeight)
        XCTAssertTrue(
            fixture.dragScrollView.comparisonPolicy.isValueEqual(
                fixture.dragScrollView.displayHeightForCurrentGeometry,
                exactMaximumDisplayHeight
            )
        )
        let maximumOuterOffset = fixture.dragScrollView.contentOffset.y
        setHostOffsetWithoutDeliveringScroll(
            fixture.dragScrollView,
            to: maximumOuterOffset - originalModel.comparison.boundaryBand
        )
        fixture.dragScrollView.rebaseAdaptiveAxisForReturningDragIfNeeded(
            nativeIsDragging: true
        )

        let rebasedModel = try XCTUnwrap(session.model)
        XCTAssertNotEqual(rebasedModel, originalModel)
        XCTAssertEqual(
            try XCTUnwrap(rebasedModel.segments.first?.displayHeight),
            exactMaximumDisplayHeight
        )
    }

    func testAdaptiveFreePanelRebaseKeepsCapturedMinimumHeightExact() throws {
        let exactMinimumDisplayHeight: CGFloat = 100
        let fixture = try makeAdaptiveFreePanelFixture(
            initialDisplayHeight: 500,
            panelHeight: 873,
            participantContentHeight: 1_900.3,
            minimumDisplayHeight: exactMinimumDisplayHeight
        )
        defer {
            if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                fixture.dragScrollView.scrollViewDidEndDragging(
                    fixture.dragScrollView,
                    willDecelerate: false
                )
            }
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
        }
        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)
        let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let originalModel = try XCTUnwrap(session.model)
        let displayRange = try XCTUnwrap(
            session.axisPhase?.endpointAuthority.displayHeightRange
        )
        XCTAssertEqual(displayRange.lowerBound, exactMinimumDisplayHeight)

        deliverHostScroll(
            fixture.dragScrollView,
            to: fixture.dragScrollView.minimumOuterOffset
        )
        XCTAssertEqual(fixture.dragScrollView.displayHeight, exactMinimumDisplayHeight)
        XCTAssertEqual(
            fixture.dragScrollView.displayHeightForCurrentGeometry,
            exactMinimumDisplayHeight
        )
        let minimumOuterOffset = fixture.dragScrollView.contentOffset.y
        setHostOffsetWithoutDeliveringScroll(
            fixture.dragScrollView,
            to: minimumOuterOffset + originalModel.comparison.boundaryBand
        )
        fixture.dragScrollView.rebaseAdaptiveAxisForReturningDragIfNeeded(
            nativeIsDragging: true
        )

        let rebasedModel = try XCTUnwrap(session.model)
        XCTAssertNotEqual(rebasedModel, originalModel)
        XCTAssertEqual(
            try XCTUnwrap(rebasedModel.segments.first?.displayHeight),
            exactMinimumDisplayHeight
        )
    }

    func testAdaptiveEndpointCorrectionPreservesBottomBounceOwnership() throws {
        func run(
            owner: BODragScrollBounceOwner
        ) throws -> (
            displayHeight: CGFloat,
            participantOffset: CGFloat,
            participantMaximum: CGFloat,
            hostOverscroll: CGFloat,
            boundaryBand: CGFloat
        ) {
            let fixture = try makeAdaptiveFreePanelFixture(
                initialDisplayHeight: 300,
                panelHeight: 873,
                participantContentHeight: 1_900.3
            )
            defer {
                if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                    fixture.dragScrollView.scrollViewDidEndDragging(
                        fixture.dragScrollView,
                        willDecelerate: false
                    )
                }
                fixture.dragScrollView.endCapture()
                fixture.window.isHidden = true
            }
            var configuration = fixture.dragScrollView.configuration
            configuration.bounce.preferredBottomOwner = owner
            fixture.dragScrollView.configuration = configuration
            fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)
            let maximumOuterOffset = fixture.dragScrollView.maximumOuterOffset
            deliverHostScroll(
                fixture.dragScrollView,
                to: maximumOuterOffset + 30
            )
            return (
                fixture.dragScrollView.displayHeight,
                fixture.participant.contentOffset.y,
                fixture.participantMaximumOffset,
                fixture.dragScrollView.contentOffset.y - maximumOuterOffset,
                fixture.dragScrollView.comparisonPolicy.boundaryBand
            )
        }

        let innerOwned = try run(owner: .innerScrollView)
        XCTAssertEqual(innerOwned.displayHeight, 873, accuracy: 0.0001)
        XCTAssertEqual(
            innerOwned.participantOffset - innerOwned.participantMaximum,
            innerOwned.hostOverscroll,
            accuracy: 0.0001
        )

        let panelOwned = try run(owner: .panel)
        XCTAssertEqual(
            panelOwned.displayHeight,
            873 + panelOwned.hostOverscroll,
            accuracy: 0.0001
        )
        XCTAssertLessThan(
            abs(panelOwned.participantOffset - panelOwned.participantMaximum),
            panelOwned.boundaryBand
        )
    }

    func testOnlyCoordinatedAutomaticNoDetentCaptureIsAdaptive() throws {
        func makeBasis(
            detents: [CGFloat] = [],
            configure: (BODragScrollView) -> Void = { _ in },
            provider: BODragScrollBehaviorProvider? = nil
        ) throws -> BODragScrollAxisRebasePolicy? {
            let (dragScrollView, panelView) = makeHost(detents: detents)
            defer { dragScrollView.endCapture() }
            _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
            configure(dragScrollView)
            dragScrollView.behaviorProvider = provider
            let participant = makeScrollView(
                frame: CGRect(x: 0, y: 40, width: 320, height: 300),
                contentHeight: 900
            )
            let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
            participant.addSubview(leafView)
            panelView.addSubview(participant)
            dragScrollView.beginCapture(from: leafView)
            return try XCTUnwrap(dragScrollView.runtime.capture.session).axisPhase?.rebasePolicy
        }

        XCTAssertEqual(try makeBasis(), .continuousPanel)
        XCTAssertEqual(
            try makeBasis { dragScrollView in
                var configuration = dragScrollView.configuration
                configuration.handoff.innerScrollPlacement = .fromTouchedPosition
                dragScrollView.configuration = configuration
            },
            .continuousPanel
        )
        XCTAssertEqual(try makeBasis(detents: [100, 300, 600]), .fixed)
        XCTAssertEqual(
            try makeBasis { dragScrollView in
                var configuration = dragScrollView.configuration
                configuration.handoff.innerScrollPlacement = .atDisplayHeight(300)
                dragScrollView.configuration = configuration
            },
            .fixed
        )
        XCTAssertEqual(
            try makeBasis { dragScrollView in
                var configuration = dragScrollView.configuration
                configuration.handoff.innerScrollPlacement = .afterPanelFullyDisplayed
                dragScrollView.configuration = configuration
            },
            .fixed
        )
        XCTAssertNil(
            try makeBasis { dragScrollView in
                var configuration = dragScrollView.configuration
                configuration.handoff.mode = .innerFirst
                dragScrollView.configuration = configuration
            }
        )
        XCTAssertEqual(
            try makeBasis { dragScrollView in
                var configuration = dragScrollView.configuration
                configuration.handoff.mode = .innerFirstAtBoundary
                dragScrollView.configuration = configuration
            },
            .fixed
        )
        let explicitProvider = SegmentProvider([
            BODragScrollInnerScrollSegment(
                displayHeight: 300,
                beginOffsetY: 0,
                endOffsetY: 600
            )
        ])
        XCTAssertEqual(try makeBasis(provider: explicitProvider), .fixed)
        _ = explicitProvider
    }

    func testMismatchRecoveryDoesNotPromoteExplicitProviderAxisToAdaptive() throws {
        let (dragScrollView, panelView) = makeHost()
        _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
        let provider = SegmentProvider([
            BODragScrollInnerScrollSegment(
                displayHeight: 300,
                beginOffsetY: 0,
                endOffsetY: 600
            )
        ])
        dragScrollView.behaviorProvider = provider
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 40, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        defer {
            dragScrollView.runtime.scrolling.isForcingMismatchRecovery = false
            dragScrollView.endCapture()
            _ = provider
        }

        let session = try XCTUnwrap(dragScrollView.runtime.capture.session)
        XCTAssertEqual(session.axisPhase?.rebasePolicy, .fixed)
        dragScrollView.runtime.scrolling.isForcingMismatchRecovery = true
        dragScrollView.rebuildCaptureSessionIfNeeded(reason: .mismatchRecovery)
        dragScrollView.runtime.scrolling.isForcingMismatchRecovery = false

        XCTAssertTrue(dragScrollView.runtime.capture.session === session)
        XCTAssertEqual(session.axisPhase?.rebasePolicy, .fixed)
    }

    func testNewDragDuringAdaptiveFreePanelDecelerationRebasesSameCleanCapture() throws {
        let fixture = try makeAdaptiveFreePanelFixture(initialDisplayHeight: 300)
        defer {
            if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                fixture.dragScrollView.scrollViewDidEndDragging(
                    fixture.dragScrollView,
                    willDecelerate: false
                )
            }
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
        }
        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)
        let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let oldModel = try XCTUnwrap(session.model)
        let oldBlockEnd = try XCTUnwrap(oldModel.segments.last?.outerEnd)
        deliverHostScroll(fixture.dragScrollView, to: oldBlockEnd)

        let expandedDisplayHeight: CGFloat = 700
        let expandedOuterOffset = oldBlockEnd + expandedDisplayHeight - 300
        deliverHostScroll(fixture.dragScrollView, to: expandedOuterOffset)
        try beginDragDeceleration(
            on: fixture.dragScrollView,
            targetOffsetY: expandedOuterOffset
        )

        let panelFrame = fixture.panelView.frame
        let participantOffset = fixture.participant.contentOffset
        let hostOffset = fixture.dragScrollView.contentOffset
        fixture.dragScrollView.beginCapture(from: fixture.leafView)
        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)

        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === session)
        XCTAssertNotEqual(session.model, oldModel)
        XCTAssertEqual(
            try XCTUnwrap(session.model?.segments.first?.displayHeight),
            expandedDisplayHeight,
            accuracy: 0.0001
        )
        XCTAssertEqual(fixture.dragScrollView.contentOffset, hostOffset)
        XCTAssertEqual(fixture.panelView.frame, panelFrame)
        XCTAssertEqual(fixture.participant.contentOffset, participantOffset)
        XCTAssertNil(fixture.dragScrollView.runtime.transition.driver)
        XCTAssertFalse(fixture.dragScrollView.runtime.transition.isAwaitingDidEndDecelerating)

        // A late callback from the interrupted driver cannot tear down the new drag or its phase.
        fixture.dragScrollView.scrollViewDidEndDecelerating(fixture.dragScrollView)
        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === session)
        XCTAssertTrue(fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive)
    }

    func testNewDragRebasesAdaptiveInnerBounceFromLegalBoundaryWithoutGeometryWrites() throws {
        let fixture = try makeAdaptiveFreePanelFixture(initialDisplayHeight: 300)
        defer {
            if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                fixture.dragScrollView.contentOffset.y = fixture.maximumOuterOffset
                fixture.dragScrollView.scrollViewDidScroll(fixture.dragScrollView)
                fixture.dragScrollView.scrollViewDidEndDragging(
                    fixture.dragScrollView,
                    willDecelerate: false
                )
            }
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
        }
        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)
        let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let oldModel = try XCTUnwrap(session.model)
        let overscrollDistance: CGFloat = 30
        deliverHostScroll(
            fixture.dragScrollView,
            to: fixture.maximumOuterOffset + overscrollDistance
        )
        try beginDragDeceleration(
            on: fixture.dragScrollView,
            targetOffsetY: fixture.maximumOuterOffset
        )

        let hostOffset = fixture.dragScrollView.contentOffset
        let hostInset = fixture.dragScrollView.contentInset
        let hostContentSize = fixture.dragScrollView.contentSize
        let panelFrame = fixture.panelView.frame
        let participantOffset = fixture.participant.contentOffset
        fixture.dragScrollView.beginCapture(from: fixture.leafView)
        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)

        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === session)
        XCTAssertNotEqual(session.model, oldModel)
        XCTAssertEqual(
            try XCTUnwrap(session.model?.segments.first?.displayHeight),
            800,
            accuracy: 0.0001
        )
        XCTAssertEqual(fixture.dragScrollView.contentOffset, hostOffset)
        XCTAssertEqual(fixture.dragScrollView.contentInset, hostInset)
        XCTAssertEqual(fixture.dragScrollView.contentSize, hostContentSize)
        XCTAssertEqual(fixture.panelView.frame, panelFrame)
        XCTAssertEqual(fixture.participant.contentOffset, participantOffset)
        XCTAssertEqual(
            fixture.participant.contentOffset.y,
            fixture.participantMaximumOffset + overscrollDistance,
            accuracy: 0.0001
        )
    }

    func testNewTouchStopsWhenSyntheticOldDecelerationEndRemovesHost() throws {
        let fixture = try makeBottomInnerOverscrollFixture()
        let participantLifecycle = SyntheticDecelerationMutationDelegate()
        let events = ReentrantDecelerationDelegate()
        fixture.participant.delegate = participantLifecycle
        fixture.dragScrollView.eventDelegate = events
        defer {
            fixture.dragScrollView.eventDelegate = nil
            fixture.participant.delegate = nil
            fixture.window.isHidden = true
            _ = fixture.provider
        }
        try beginDragDeceleration(
            on: fixture.dragScrollView,
            targetOffsetY: fixture.maximumOuterOffset
        )
        fixture.dragScrollView.beginCapture(from: fixture.leafView)
        participantLifecycle.onDidEndDecelerating = {
            fixture.dragScrollView.removeFromSuperview()
        }

        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)

        XCTAssertNil(fixture.dragScrollView.window)
        XCTAssertNil(fixture.dragScrollView.runtime.capture.session)
        XCTAssertNil(fixture.dragScrollView.runtime.transition.captureCleanupOwnership)
        XCTAssertFalse(fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive)
        XCTAssertEqual(participantLifecycle.didEndDeceleratingCount, 1)
        XCTAssertEqual(participantLifecycle.willBeginDraggingCount, 0)
        XCTAssertEqual(events.didEndDeceleratingCount, 1)
        XCTAssertEqual(events.willBeginDraggingCount, 0)
    }

    func testNewTouchStopsWhenSyntheticOldDecelerationEndReplacesPanel() throws {
        let fixture = try makeBottomInnerOverscrollFixture()
        let participantLifecycle = SyntheticDecelerationMutationDelegate()
        let events = ReentrantDecelerationDelegate()
        fixture.participant.delegate = participantLifecycle
        fixture.dragScrollView.eventDelegate = events
        defer {
            fixture.dragScrollView.eventDelegate = nil
            fixture.participant.delegate = nil
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
            _ = fixture.provider
        }
        try beginDragDeceleration(
            on: fixture.dragScrollView,
            targetOffsetY: fixture.maximumOuterOffset
        )
        fixture.dragScrollView.beginCapture(from: fixture.leafView)
        let replacementPanel = UIView(frame: fixture.panelView.frame)
        participantLifecycle.onDidEndDecelerating = {
            fixture.dragScrollView.panelView = replacementPanel
        }

        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)

        XCTAssertTrue(fixture.dragScrollView.panelView === replacementPanel)
        XCTAssertNil(fixture.dragScrollView.runtime.capture.session)
        XCTAssertNil(fixture.dragScrollView.runtime.transition.captureCleanupOwnership)
        XCTAssertFalse(fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive)
        XCTAssertEqual(participantLifecycle.didEndDeceleratingCount, 1)
        XCTAssertEqual(participantLifecycle.willBeginDraggingCount, 0)
        XCTAssertEqual(events.didEndDeceleratingCount, 1)
        XCTAssertEqual(events.willBeginDraggingCount, 0)
    }

    func testNewTouchStopsWhenInterruptedMovementCompletionRemovesHost() throws {
        let fixture = try makeBottomInnerOverscrollFixture()
        let participantLifecycle = ParticipantLifecycleSpy()
        let events = ReentrantDecelerationDelegate()
        fixture.participant.delegate = participantLifecycle
        fixture.dragScrollView.eventDelegate = events
        defer {
            fixture.dragScrollView.eventDelegate = nil
            fixture.participant.delegate = nil
            fixture.window.isHidden = true
            _ = fixture.provider
        }
        try beginDragDeceleration(
            on: fixture.dragScrollView,
            targetOffsetY: fixture.maximumOuterOffset
        )
        fixture.dragScrollView.beginCapture(from: fixture.leafView)
        events.onDidFinishMovement = { result in
            guard result.reason == .dragRelease,
                  result.outcome == .interrupted else { return }
            fixture.dragScrollView.removeFromSuperview()
        }

        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)

        XCTAssertEqual(events.results.map(\.outcome), [.interrupted])
        XCTAssertNil(fixture.dragScrollView.window)
        XCTAssertNil(fixture.dragScrollView.runtime.capture.session)
        XCTAssertNil(fixture.dragScrollView.runtime.transition.captureCleanupOwnership)
        XCTAssertFalse(fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive)
        XCTAssertTrue(participantLifecycle.began.isEmpty)
        XCTAssertEqual(events.willBeginDraggingCount, 0)
    }

    func testQueuedHostOverscrollReturnResumesAfterTrackingOnlyTouchEnds() async throws {
        let fixture = try makeBottomInnerOverscrollFixture()
        let trackingDidBegin = NSSelectorFromString("_trackingDidBegin")
        let trackingDidEnd = NSSelectorFromString("_trackingDidEnd")
        guard fixture.dragScrollView.responds(to: trackingDidBegin),
              fixture.dragScrollView.responds(to: trackingDidEnd) else {
            XCTFail("This UIKit runtime cannot expose a physical tracking-only test state.")
            return
        }
        let events = ReentrantDecelerationDelegate()
        let completed = expectation(description: "host overscroll return completed")
        events.onDidFinishMovement = { result in
            guard result.reason == .dragRelease else { return }
            completed.fulfill()
        }
        fixture.dragScrollView.eventDelegate = events
        defer {
            if fixture.dragScrollView.nativeScrollState.isTracking {
                fixture.dragScrollView.perform(trackingDidEnd)
            }
            fixture.dragScrollView.eventDelegate = nil
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
            _ = fixture.provider
        }
        var target = CGPoint(
            x: fixture.dragScrollView.contentOffset.x,
            y: fixture.maximumOuterOffset
        )
        fixture.dragScrollView.scrollViewWillEndDragging(
            fixture.dragScrollView,
            withVelocity: .zero,
            targetContentOffset: &target
        )

        fixture.dragScrollView.scrollViewDidEndDragging(
            fixture.dragScrollView,
            willDecelerate: false
        )
        // A short touch can put UIScrollView into tracking before the queued return executes,
        // without ever reaching scrollViewWillBeginDragging(_:). It temporarily owns physics.
        fixture.dragScrollView.perform(trackingDidBegin)
        XCTAssertTrue(fixture.dragScrollView.nativeScrollState.isTracking)
        await Task.yield()

        XCTAssertNotEqual(fixture.dragScrollView.runtime.transition.driver, .systemAnimation)
        XCTAssertNotNil(fixture.dragScrollView.runtime.transition.activeTransaction)
        XCTAssertNotNil(fixture.dragScrollView.runtime.capture.session)
        XCTAssertEqual(events.willBeginDraggingCount, 0)

        fixture.dragScrollView.perform(trackingDidEnd)
        XCTAssertFalse(fixture.dragScrollView.nativeScrollState.isTracking)

        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(events.results.map(\.outcome), [.completed])
        XCTAssertNil(fixture.dragScrollView.runtime.transition.activeTransaction)
        XCTAssertNil(fixture.dragScrollView.runtime.transition.driver)
        XCTAssertNil(fixture.dragScrollView.runtime.capture.session)
    }

    func testDecelerationEndDuringTrackingOnlyTouchSettlesAfterTouchEnds() async throws {
        let fixture = try makeBottomInnerOverscrollFixture()
        let trackingDidBegin = NSSelectorFromString("_trackingDidBegin")
        let trackingDidEnd = NSSelectorFromString("_trackingDidEnd")
        guard fixture.dragScrollView.responds(to: trackingDidBegin),
              fixture.dragScrollView.responds(to: trackingDidEnd) else {
            XCTFail("This UIKit runtime cannot expose a physical tracking-only test state.")
            return
        }
        let events = ReentrantDecelerationDelegate()
        let completed = expectation(description: "interrupted deceleration settled")
        events.onDidFinishMovement = { result in
            guard result.reason == .dragRelease else { return }
            completed.fulfill()
        }
        fixture.dragScrollView.eventDelegate = events
        defer {
            if fixture.dragScrollView.nativeScrollState.isTracking {
                fixture.dragScrollView.perform(trackingDidEnd)
            }
            fixture.dragScrollView.eventDelegate = nil
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
            _ = fixture.provider
        }
        try beginDragDeceleration(
            on: fixture.dragScrollView,
            targetOffsetY: fixture.maximumOuterOffset
        )
        let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let transaction = try XCTUnwrap(
            fixture.dragScrollView.runtime.transition.activeTransaction
        )

        fixture.dragScrollView.perform(trackingDidBegin)
        fixture.dragScrollView.beginCapture(from: fixture.leafView)
        fixture.dragScrollView.scrollViewDidEndDecelerating(fixture.dragScrollView)

        XCTAssertTrue(fixture.dragScrollView.nativeScrollState.isTracking)
        XCTAssertFalse(fixture.dragScrollView.runtime.transition.isAwaitingDidEndDecelerating)
        XCTAssertEqual(events.didEndDeceleratingCount, 1)
        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === session)
        XCTAssertTrue(fixture.dragScrollView.runtime.transition.activeTransaction === transaction)
        XCTAssertEqual(fixture.dragScrollView.runtime.transition.driver, .dragDeceleration)

        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(fixture.dragScrollView.runtime.transition.activeTransaction === transaction)
        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === session)

        fixture.dragScrollView.perform(trackingDidEnd)
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(events.didEndDeceleratingCount, 1)
        XCTAssertEqual(events.results.map(\.outcome), [.completed])
        XCTAssertNil(fixture.dragScrollView.runtime.transition.activeTransaction)
        XCTAssertNil(fixture.dragScrollView.runtime.transition.driver)
        XCTAssertNil(fixture.dragScrollView.runtime.capture.session)
    }

    func testDirtyDecelerationTrackingOnlyTouchKeepsOldAxisUntilSettlement() async throws {
        let fixture = try makeAutomaticBottomInnerOverscrollFixture()
        let trackingDidBegin = NSSelectorFromString("_trackingDidBegin")
        let trackingDidEnd = NSSelectorFromString("_trackingDidEnd")
        guard fixture.dragScrollView.responds(to: trackingDidBegin),
              fixture.dragScrollView.responds(to: trackingDidEnd) else {
            XCTFail("This UIKit runtime cannot expose a physical tracking-only test state.")
            return
        }
        let events = ReentrantDecelerationDelegate()
        let completed = expectation(description: "dirty interrupted deceleration settled")
        events.onDidFinishMovement = { result in
            guard result.reason == .dragRelease else { return }
            completed.fulfill()
        }
        fixture.dragScrollView.eventDelegate = events
        defer {
            if fixture.dragScrollView.nativeScrollState.isTracking {
                fixture.dragScrollView.perform(trackingDidEnd)
            }
            fixture.dragScrollView.eventDelegate = nil
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
        }
        try beginDragDeceleration(
            on: fixture.dragScrollView,
            targetOffsetY: fixture.maximumOuterOffset
        )
        let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let model = try XCTUnwrap(session.model)
        let transaction = try XCTUnwrap(
            fixture.dragScrollView.runtime.transition.activeTransaction
        )
        fixture.participant.contentSize = CGSize(width: 320, height: 420)
        let metricsCallbackDrained = expectation(description: "dirty metrics callback drained")
        DispatchQueue.main.async { metricsCallbackDrained.fulfill() }
        await fulfillment(of: [metricsCallbackDrained], timeout: 1)
        XCTAssertTrue(session.hasDeferredMetricsChange)

        fixture.dragScrollView.perform(trackingDidBegin)
        fixture.dragScrollView.beginCapture(from: fixture.leafView)

        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === session)
        XCTAssertEqual(session.model, model)
        XCTAssertTrue(fixture.dragScrollView.runtime.transition.activeTransaction === transaction)
        XCTAssertEqual(fixture.dragScrollView.runtime.transition.driver, .dragDeceleration)

        fixture.dragScrollView.scrollViewDidEndDecelerating(fixture.dragScrollView)
        let ownershipAtTerminal = try XCTUnwrap(
            fixture.dragScrollView.runtime.transition.captureCleanupOwnership
        )
        fixture.dragScrollView.beginCapture(from: fixture.leafView)
        let refreshedOwnership = try XCTUnwrap(
            fixture.dragScrollView.runtime.transition.captureCleanupOwnership
        )

        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === session)
        XCTAssertEqual(session.model, model)
        XCTAssertEqual(refreshedOwnership.sessionID, ownershipAtTerminal.sessionID)
        XCTAssertNotEqual(
            refreshedOwnership.sessionOwnershipGeneration,
            ownershipAtTerminal.sessionOwnershipGeneration
        )
        XCTAssertTrue(fixture.dragScrollView.runtime.transition.activeTransaction === transaction)
        fixture.dragScrollView.perform(trackingDidEnd)
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(events.results.map(\.outcome), [.completed])
        XCTAssertNil(fixture.dragScrollView.runtime.transition.activeTransaction)
        XCTAssertNil(fixture.dragScrollView.runtime.capture.session)
        let finalInset = fixture.participant.effectiveContentInset
        let finalMaximumOffset = max(
            -finalInset.top,
            fixture.participant.contentSize.height
                + finalInset.bottom
                - fixture.participant.bounds.height
        )
        XCTAssertEqual(
            fixture.participant.contentOffset.y,
            finalMaximumOffset,
            accuracy: 0.0001
        )
    }

    func testParticipantWillBeginPanelReplacementPairsOnlyParticipantLifecycle() throws {
        let fixture = try makeCapturedParticipantFixture()
        let participantLifecycle = ParticipantLifecycleSpy()
        let hostLifecycle = ReentrantDragLifecycleEventDelegate()
        fixture.participant.delegate = participantLifecycle
        fixture.dragScrollView.eventDelegate = hostLifecycle
        defer {
            fixture.dragScrollView.eventDelegate = nil
            fixture.participant.delegate = nil
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
        }
        let replacementPanel = UIView(frame: fixture.panelView.frame)
        participantLifecycle.onWillBeginDragging = {
            fixture.dragScrollView.panelView = replacementPanel
        }

        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)

        XCTAssertTrue(fixture.dragScrollView.panelView === replacementPanel)
        XCTAssertEqual(participantLifecycle.began.count, 1)
        XCTAssertEqual(participantLifecycle.didEnd.count, 1)
        XCTAssertTrue(participantLifecycle.didEnd.first === fixture.participant)
        XCTAssertEqual(hostLifecycle.willBeginDraggingCount, 0)
        XCTAssertTrue(hostLifecycle.didEndDraggingValues.isEmpty)
        XCTAssertFalse(fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive)
        XCTAssertNil(fixture.dragScrollView.runtime.transition.captureCleanupOwnership)
    }

    func testHostWillBeginPanelReplacementPairsHostAndParticipantLifecycles() throws {
        let fixture = try makeCapturedParticipantFixture()
        let participantLifecycle = ParticipantLifecycleSpy()
        let hostLifecycle = ReentrantDragLifecycleEventDelegate()
        fixture.participant.delegate = participantLifecycle
        fixture.dragScrollView.eventDelegate = hostLifecycle
        defer {
            fixture.dragScrollView.eventDelegate = nil
            fixture.participant.delegate = nil
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
        }
        let replacementPanel = UIView(frame: fixture.panelView.frame)
        hostLifecycle.onWillBeginDragging = {
            fixture.dragScrollView.panelView = replacementPanel
        }

        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)

        XCTAssertTrue(fixture.dragScrollView.panelView === replacementPanel)
        XCTAssertEqual(participantLifecycle.began.count, 1)
        XCTAssertEqual(participantLifecycle.didEnd.count, 1)
        XCTAssertTrue(participantLifecycle.didEnd.first === fixture.participant)
        XCTAssertEqual(hostLifecycle.willBeginDraggingCount, 1)
        XCTAssertEqual(hostLifecycle.didEndDraggingValues, [false])
        XCTAssertFalse(fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive)
        XCTAssertNil(fixture.dragScrollView.runtime.transition.captureCleanupOwnership)
    }

    func testParticipantShrinkDuringActiveBottomOverscrollDefersModelUntilLifecycleEnds() async throws {
        let fixture = try makeCapturedParticipantFixture()
        defer {
            if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                fixture.dragScrollView.scrollViewDidEndDragging(
                    fixture.dragScrollView,
                    willDecelerate: false
                )
            }
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
        }
        var configuration = fixture.dragScrollView.configuration
        configuration.bounce.preferredBottomOwner = .innerScrollView
        fixture.dragScrollView.configuration = configuration
        fixture.dragScrollView.reloadScrollMetrics()
        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)

        let maximumOuterOffset = fixture.dragScrollView.maximumOuterOffset
        fixture.dragScrollView.contentOffset.y = maximumOuterOffset + 30
        fixture.dragScrollView.scrollViewDidScroll(fixture.dragScrollView)
        let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let model = try XCTUnwrap(session.model)
        let operationEpoch = fixture.dragScrollView.runtime.capture.operationEpoch
        let hostOffset = fixture.dragScrollView.contentOffset
        let hostInset = fixture.dragScrollView.contentInset
        let hostContentSize = fixture.dragScrollView.contentSize
        let panelFrame = fixture.panelView.frame
        let participantOffset = fixture.participant.contentOffset
        XCTAssertGreaterThan(
            participantOffset.y,
            fixture.participant.contentSize.height - fixture.participant.bounds.height
        )

        fixture.participant.contentSize = CGSize(width: 320, height: 420)
        let metricsCallbackDrained = expectation(description: "participant metrics callback drained")
        DispatchQueue.main.async { metricsCallbackDrained.fulfill() }
        await fulfillment(of: [metricsCallbackDrained], timeout: 1)

        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === session)
        XCTAssertEqual(try XCTUnwrap(session.model), model)
        XCTAssertEqual(fixture.dragScrollView.runtime.capture.operationEpoch, operationEpoch)
        XCTAssertTrue(session.hasDeferredMetricsChange)
        XCTAssertEqual(fixture.dragScrollView.contentOffset, hostOffset)
        XCTAssertEqual(fixture.dragScrollView.contentInset, hostInset)
        XCTAssertEqual(fixture.dragScrollView.contentSize, hostContentSize)
        XCTAssertEqual(fixture.panelView.frame, panelFrame)
        XCTAssertEqual(fixture.participant.contentOffset, participantOffset)

        fixture.dragScrollView.scrollViewDidEndDragging(
            fixture.dragScrollView,
            willDecelerate: false
        )

        let inset = fixture.participant.effectiveContentInset
        let newStandaloneMaximum = max(
            -inset.top,
            fixture.participant.contentSize.height
                + inset.bottom
                - fixture.participant.bounds.height
        )
        XCTAssertNil(fixture.dragScrollView.runtime.capture.session)
        XCTAssertEqual(
            fixture.participant.contentOffset.y,
            newStandaloneMaximum,
            accuracy: 0.0001
        )

        fixture.dragScrollView.beginCapture(from: fixture.leafView)
        let freshSession = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let freshModel = try XCTUnwrap(freshSession.model)
        XCTAssertFalse(freshSession === session)
        XCTAssertNotEqual(freshSession.id, session.id)
        XCTAssertFalse(freshSession.hasDeferredMetricsChange)
        XCTAssertNotEqual(freshModel, model)
        let freshParticipantDistance = freshModel.segments.reduce(CGFloat.zero) {
            $0 + ($1.isParticipantSegment ? $1.innerLength : 0)
        }
        XCTAssertEqual(freshParticipantDistance, newStandaloneMaximum + inset.top, accuracy: 0.001)
    }

    func testParticipantShrinkDuringBottomBounceDecelerationRestoresOldProjection() async throws {
        let fixture = try makeAutomaticBottomInnerOverscrollFixture()
        defer {
            if fixture.dragScrollView.runtime.transition.isAwaitingDidEndDecelerating {
                fixture.dragScrollView.scrollViewDidEndDecelerating(fixture.dragScrollView)
            }
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
        }
        try beginDragDeceleration(
            on: fixture.dragScrollView,
            targetOffsetY: fixture.maximumOuterOffset
        )
        let transaction = try XCTUnwrap(
            fixture.dragScrollView.runtime.transition.activeTransaction
        )
        let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let model = try XCTUnwrap(session.model)
        let operationEpoch = fixture.dragScrollView.runtime.capture.operationEpoch
        let hostOffset = fixture.dragScrollView.contentOffset
        let hostInset = fixture.dragScrollView.contentInset
        let hostContentSize = fixture.dragScrollView.contentSize
        let panelFrame = fixture.panelView.frame
        let participantOffset = fixture.participant.contentOffset

        fixture.participant.contentSize = CGSize(width: 320, height: 420)
        let metricsCallbackDrained = expectation(description: "shrink metrics callback drained")
        DispatchQueue.main.async { metricsCallbackDrained.fulfill() }
        await fulfillment(of: [metricsCallbackDrained], timeout: 1)

        XCTAssertTrue(fixture.dragScrollView.runtime.transition.activeTransaction === transaction)
        XCTAssertEqual(fixture.dragScrollView.runtime.transition.driver, .dragDeceleration)
        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === session)
        XCTAssertEqual(try XCTUnwrap(session.model), model)
        XCTAssertEqual(fixture.dragScrollView.runtime.capture.operationEpoch, operationEpoch)
        XCTAssertTrue(session.hasDeferredMetricsChange)
        XCTAssertEqual(fixture.dragScrollView.contentOffset, hostOffset)
        XCTAssertEqual(fixture.dragScrollView.contentInset, hostInset)
        XCTAssertEqual(fixture.dragScrollView.contentSize, hostContentSize)
        XCTAssertEqual(fixture.panelView.frame, panelFrame)
        XCTAssertEqual(fixture.participant.contentOffset, participantOffset)
    }

    func testParticipantGrowthDuringBottomBounceDecelerationPreservesBounceDistance() async throws {
        let fixture = try makeAutomaticBottomInnerOverscrollFixture()
        defer {
            if fixture.dragScrollView.runtime.transition.isAwaitingDidEndDecelerating {
                fixture.dragScrollView.scrollViewDidEndDecelerating(fixture.dragScrollView)
            }
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
        }
        try beginDragDeceleration(
            on: fixture.dragScrollView,
            targetOffsetY: fixture.maximumOuterOffset
        )
        let transaction = try XCTUnwrap(
            fixture.dragScrollView.runtime.transition.activeTransaction
        )
        let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let model = try XCTUnwrap(session.model)
        let operationEpoch = fixture.dragScrollView.runtime.capture.operationEpoch
        let hostOffset = fixture.dragScrollView.contentOffset
        let hostInset = fixture.dragScrollView.contentInset
        let hostContentSize = fixture.dragScrollView.contentSize
        let panelFrame = fixture.panelView.frame
        let participantOffset = fixture.participant.contentOffset

        fixture.participant.contentSize = CGSize(width: 320, height: 1_200)
        let metricsCallbackDrained = expectation(description: "growth metrics callback drained")
        DispatchQueue.main.async { metricsCallbackDrained.fulfill() }
        await fulfillment(of: [metricsCallbackDrained], timeout: 1)

        XCTAssertTrue(fixture.dragScrollView.runtime.transition.activeTransaction === transaction)
        XCTAssertEqual(fixture.dragScrollView.runtime.transition.driver, .dragDeceleration)
        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === session)
        XCTAssertEqual(try XCTUnwrap(session.model), model)
        XCTAssertEqual(fixture.dragScrollView.runtime.capture.operationEpoch, operationEpoch)
        XCTAssertTrue(session.hasDeferredMetricsChange)
        XCTAssertEqual(fixture.dragScrollView.contentOffset, hostOffset)
        XCTAssertEqual(fixture.dragScrollView.contentInset, hostInset)
        XCTAssertEqual(fixture.dragScrollView.contentSize, hostContentSize)
        XCTAssertEqual(fixture.panelView.frame, panelFrame)
        XCTAssertEqual(fixture.participant.contentOffset, participantOffset)

        let inset = fixture.participant.effectiveContentInset
        let grownStandaloneMaximum = max(
            -inset.top,
            fixture.participant.contentSize.height
                + inset.bottom
                - fixture.participant.bounds.height
        )
        XCTAssertLessThan(fixture.participant.contentOffset.y, grownStandaloneMaximum)
        let overscroll = try XCTUnwrap(fixture.dragScrollView.hostOverscrollState())
        XCTAssertEqual(overscroll.edge, .bottom)
        XCTAssertEqual(overscroll.distance, 30, accuracy: 0.001)
        XCTAssertEqual(
            overscroll.owner,
            session.primaryParticipant.map { .participant($0.id) }
        )
    }

    func testConfigurationAndProviderLayoutWaitForActiveBounceLifecycle() async throws {
        let fixture = try makeBottomInnerOverscrollFixture()
        let replacementProvider = CallbackPanelSizeProvider(
            size: CGSize(width: 320, height: 900)
        )
        let events = ReentrantDecelerationDelegate()
        let completed = expectation(description: "active bounce settled before provider layout")
        events.onDidFinishMovement = { result in
            guard result.reason == .dragRelease else { return }
            completed.fulfill()
        }
        fixture.dragScrollView.eventDelegate = events
        defer {
            fixture.dragScrollView.eventDelegate = nil
            fixture.dragScrollView.interruptActiveMovement(outcome: .interrupted)
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
            _ = fixture.provider
            _ = replacementProvider
        }
        try beginDragDeceleration(
            on: fixture.dragScrollView,
            targetOffsetY: fixture.maximumOuterOffset
        )
        let session = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let model = try XCTUnwrap(session.model)
        let transaction = try XCTUnwrap(
            fixture.dragScrollView.runtime.transition.activeTransaction
        )
        let operationEpoch = fixture.dragScrollView.runtime.capture.operationEpoch
        let hostOffset = fixture.dragScrollView.contentOffset
        let hostInset = fixture.dragScrollView.contentInset
        let hostContentSize = fixture.dragScrollView.contentSize
        let panelFrame = fixture.panelView.frame
        let participantOffset = fixture.participant.contentOffset

        var configuration = fixture.dragScrollView.configuration
        configuration.bounce.preferredBottomOwner = .panel
        fixture.dragScrollView.configuration = configuration
        fixture.dragScrollView.behaviorProvider = replacementProvider
        layout(fixture.dragScrollView)

        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === session)
        XCTAssertEqual(session.model, model)
        XCTAssertTrue(fixture.dragScrollView.runtime.transition.activeTransaction === transaction)
        XCTAssertEqual(fixture.dragScrollView.runtime.transition.driver, .dragDeceleration)
        XCTAssertEqual(fixture.dragScrollView.runtime.capture.operationEpoch, operationEpoch)
        XCTAssertEqual(fixture.dragScrollView.contentOffset, hostOffset)
        XCTAssertEqual(fixture.dragScrollView.contentInset, hostInset)
        XCTAssertEqual(fixture.dragScrollView.contentSize, hostContentSize)
        XCTAssertEqual(fixture.panelView.frame, panelFrame)
        XCTAssertEqual(fixture.participant.contentOffset, participantOffset)
        XCTAssertTrue(
            fixture.dragScrollView.runtime.panel.defersConfigurationLayoutUntilCaptureEnds
        )

        fixture.dragScrollView.scrollViewDidEndDecelerating(fixture.dragScrollView)
        await fulfillment(of: [completed], timeout: 2)
        layout(fixture.dragScrollView)

        XCTAssertNil(fixture.dragScrollView.runtime.capture.session)
        XCTAssertFalse(
            fixture.dragScrollView.runtime.panel.defersConfigurationLayoutUntilCaptureEnds
        )
        XCTAssertEqual(fixture.panelView.frame.height, 900, accuracy: 0.001)
    }

    func testNewTouchDuringDirtyBottomBounceDecelerationBuildsFreshCapture() async throws {
        let fixture = try makeAutomaticBottomInnerOverscrollFixture()
        let events = ReentrantDecelerationDelegate()
        defer {
            fixture.dragScrollView.eventDelegate = nil
            if fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive {
                fixture.dragScrollView.scrollViewDidEndDragging(
                    fixture.dragScrollView,
                    willDecelerate: false
                )
            }
            fixture.dragScrollView.endCapture()
            fixture.window.isHidden = true
        }
        try beginDragDeceleration(
            on: fixture.dragScrollView,
            targetOffsetY: fixture.maximumOuterOffset
        )
        let oldTransaction = try XCTUnwrap(
            fixture.dragScrollView.runtime.transition.activeTransaction
        )
        let oldSession = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let oldModel = try XCTUnwrap(oldSession.model)
        let oldOperationEpoch = fixture.dragScrollView.runtime.capture.operationEpoch

        fixture.participant.contentSize = CGSize(width: 320, height: 420)
        let metricsCallbackDrained = expectation(description: "dirty metrics callback drained")
        DispatchQueue.main.async { metricsCallbackDrained.fulfill() }
        await fulfillment(of: [metricsCallbackDrained], timeout: 1)
        XCTAssertTrue(oldSession.hasDeferredMetricsChange)
        fixture.dragScrollView.eventDelegate = events

        fixture.dragScrollView.beginCapture(from: fixture.leafView)

        // Touch-down alone must not install a fresh axis under the old deceleration driver. The
        // old model remains authoritative until this touch becomes an actual drag.
        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === oldSession)
        XCTAssertTrue(oldSession.model == oldModel)
        XCTAssertTrue(oldSession.hasDeferredMetricsChange)
        XCTAssertTrue(
            fixture.dragScrollView.runtime.transition.activeTransaction === oldTransaction
        )
        XCTAssertEqual(fixture.dragScrollView.runtime.transition.driver, .dragDeceleration)

        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)

        let freshSession = try XCTUnwrap(fixture.dragScrollView.runtime.capture.session)
        let freshModel = try XCTUnwrap(freshSession.model)
        XCTAssertFalse(freshSession === oldSession)
        XCTAssertNotEqual(freshSession.id, oldSession.id)
        XCTAssertFalse(freshSession.hasDeferredMetricsChange)
        XCTAssertNotEqual(freshModel, oldModel)
        XCTAssertGreaterThan(
            fixture.dragScrollView.runtime.capture.operationEpoch,
            oldOperationEpoch
        )
        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === freshSession)
        XCTAssertNil(fixture.dragScrollView.runtime.transition.activeTransaction)
        XCTAssertNil(fixture.dragScrollView.runtime.transition.driver)
        XCTAssertFalse(fixture.dragScrollView.runtime.transition.isAwaitingDidEndDecelerating)
        XCTAssertTrue(fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive)
        XCTAssertEqual(events.results.map(\.reason), [.dragRelease])
        XCTAssertEqual(events.results.map(\.outcome), [.interrupted])
        XCTAssertEqual(events.didEndDeceleratingCount, 1)

        fixture.dragScrollView.scrollViewDidEndDecelerating(fixture.dragScrollView)

        XCTAssertTrue(fixture.dragScrollView.runtime.capture.session === freshSession)
        XCTAssertTrue(fixture.dragScrollView.runtime.transition.isUserDragLifecycleActive)
        XCTAssertEqual(events.didEndDeceleratingCount, 1)
    }

    func testDisabledParticipantBounceClampsOuterOffsetAtBothBoundaries() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        participant.bounces = false
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)

        var configuration = dragScrollView.configuration
        configuration.bounce.allowsPanelTopBounce = false
        configuration.bounce.allowsPanelBottomBounce = false
        configuration.bounce.forcesInnerTopBounce = true
        configuration.bounce.preferredBottomOwner = .innerScrollView
        dragScrollView.configuration = configuration
        dragScrollView.beginCapture(from: leafView)
        _ = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
        defer { dragScrollView.endCapture() }

        let minimum = dragScrollView.minimumOuterOffset
        dragScrollView.contentOffset.y = minimum - 30
        dragScrollView.scrollViewDidScroll(dragScrollView)
        XCTAssertEqual(dragScrollView.contentOffset.y, minimum, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(
            participant.contentOffset.y,
            -participant.effectiveContentInset.top
        )

        let maximum = dragScrollView.maximumOuterOffset
        dragScrollView.contentOffset.y = maximum + 30
        dragScrollView.scrollViewDidScroll(dragScrollView)
        XCTAssertEqual(dragScrollView.contentOffset.y, maximum, accuracy: 0.001)
        XCTAssertLessThanOrEqual(
            participant.contentOffset.y,
            participant.contentSize.height
                + participant.effectiveContentInset.bottom
                - participant.bounds.height
        )
    }

    func testPanelOwnedBounceDoesNotApplyInnerFixedHeightCorrectionAtEitherBoundary() throws {
        func driveScrollGeometry(_ dragScrollView: BODragScrollView, to offsetY: CGFloat) {
            // `contentOffset` is pixel-quantized by UIScrollView, so it cannot inject the half-pixel
            // residue this regression test needs. The scroll view's real geometry is its bounds;
            // setting that origin preserves the requested sub-pixel value and does not synthesize a
            // delegate callback, allowing this test to deliver exactly one deterministic sample.
            var bounds = dragScrollView.bounds
            bounds.origin.y = offsetY
            dragScrollView.bounds = bounds
            XCTAssertEqual(dragScrollView.contentOffset.y, offsetY, accuracy: 0.000_000_001)
            dragScrollView.scrollViewDidScroll(dragScrollView)
        }

        func exerciseTopBoundary() throws {
            let (dragScrollView, panelView) = makeHost(detents: [100, 300])
            let provider = SegmentProvider([
                .init(displayHeight: 100, beginOffsetY: 0, endOffsetY: 600)
            ])
            dragScrollView.behaviorProvider = provider
            layout(dragScrollView)
            let participant = makeScrollView(
                frame: CGRect(x: 0, y: 0, width: 320, height: 300),
                contentHeight: 900
            )
            let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
            participant.addSubview(leafView)
            panelView.addSubview(participant)
            dragScrollView.beginCapture(from: leafView)
            defer { dragScrollView.endCapture() }

            let model = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
            let boundaryOffset = dragScrollView.minimumOuterOffset
            XCTAssertNotNil(model.projection(at: boundaryOffset).authoritativeDisplayHeight)
            driveScrollGeometry(dragScrollView, to: boundaryOffset)
            let boundaryHeight = dragScrollView.displayHeight
            let boundaryPanelOrigin = panelView.frame.minY
            let pixel = dragScrollView.comparisonPolicy.boundaryBand

            for distance in [pixel * 0.5, pixel, pixel * 1.5] {
                driveScrollGeometry(dragScrollView, to: boundaryOffset - distance)
                XCTAssertEqual(panelView.frame.minY, boundaryPanelOrigin, accuracy: 0.000_001)
                XCTAssertEqual(
                    dragScrollView.displayHeight,
                    boundaryHeight - distance,
                    accuracy: 0.000_001
                )
            }
        }

        func exerciseBottomBoundary() throws {
            let (dragScrollView, panelView) = makeHost(detents: [100, 300])
            var configuration = dragScrollView.configuration
            configuration.bounce.preferredBottomOwner = .panel
            dragScrollView.configuration = configuration
            let provider = SegmentProvider([
                .init(displayHeight: 300, beginOffsetY: 0, endOffsetY: 600)
            ])
            dragScrollView.behaviorProvider = provider
            layout(dragScrollView)
            let participant = makeScrollView(
                frame: CGRect(x: 0, y: 0, width: 320, height: 300),
                contentHeight: 900
            )
            let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
            participant.addSubview(leafView)
            panelView.addSubview(participant)
            dragScrollView.beginCapture(from: leafView)
            defer { dragScrollView.endCapture() }

            let model = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
            let boundaryOffset = dragScrollView.maximumOuterOffset
            XCTAssertNotNil(model.projection(at: boundaryOffset).authoritativeDisplayHeight)
            driveScrollGeometry(dragScrollView, to: boundaryOffset)
            let boundaryHeight = dragScrollView.displayHeight
            let boundaryPanelOrigin = panelView.frame.minY
            let pixel = dragScrollView.comparisonPolicy.boundaryBand

            for distance in [pixel * 0.5, pixel, pixel * 1.5] {
                driveScrollGeometry(dragScrollView, to: boundaryOffset + distance)
                XCTAssertEqual(panelView.frame.minY, boundaryPanelOrigin, accuracy: 0.000_001)
                XCTAssertEqual(
                    dragScrollView.displayHeight,
                    boundaryHeight + distance,
                    accuracy: 0.000_001
                )
            }
        }

        try exerciseTopBoundary()
        try exerciseBottomBoundary()
    }

    func testForcedInnerTopBounceUsesCurrentExactDetentAsCaptureMinimum() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300, 500])
        _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
        XCTAssertEqual(dragScrollView.displayHeight, 300, accuracy: 0.001)

        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)

        var configuration = dragScrollView.configuration
        configuration.bounce.forcesInnerTopBounce = true
        configuration.bounce.preferredTopOwner = .innerScrollView
        dragScrollView.configuration = configuration
        dragScrollView.beginCapture(from: leafView)

        let model = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
        XCTAssertEqual(model.detentDisplayHeights, [300, 500])
        XCTAssertEqual(
            dragScrollView.minimumOuterOffset,
            300 - dragScrollView.bounds.height,
            accuracy: 0.001
        )

        let minimum = dragScrollView.minimumOuterOffset
        dragScrollView.contentOffset.y = minimum - 30
        dragScrollView.scrollViewDidScroll(dragScrollView)

        XCTAssertEqual(dragScrollView.displayHeight, 300, accuracy: 0.001)
        XCTAssertEqual(participant.contentOffset.y, -30, accuracy: 0.001)
        XCTAssertEqual(panelView.frame.minY, -30, accuracy: 0.001)
    }

    func testForcedInnerTopBounceKeepsSuffixForEverySmartPlacement() throws {
        let placements: [BODragScrollInnerScrollPlacement] = [
            .automatic,
            .fromTouchedPosition,
            .afterPanelFullyDisplayed
        ]

        for placement in placements {
            let (dragScrollView, panelView) = makeHost(detents: [100, 300, 500])
            _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
            let participant = makeScrollView(
                frame: CGRect(x: 0, y: 0, width: 320, height: 300),
                contentHeight: 900
            )
            let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
            participant.addSubview(leafView)
            panelView.addSubview(participant)

            var configuration = dragScrollView.configuration
            configuration.bounce.forcesInnerTopBounce = true
            configuration.handoff.innerScrollPlacement = placement
            dragScrollView.configuration = configuration
            dragScrollView.beginCapture(from: leafView)

            let model = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
            XCTAssertEqual(model.detentDisplayHeights, [300, 500], "\(placement)")
            XCTAssertEqual(
                dragScrollView.minimumOuterOffset,
                300 - dragScrollView.bounds.height,
                accuracy: 0.001,
                "\(placement)"
            )
            dragScrollView.endCapture()
        }
    }

    func testForcedInnerTopBounceDoesNotTrimFixedPlacementDetents() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300, 500])
        _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)

        var configuration = dragScrollView.configuration
        configuration.bounce.forcesInnerTopBounce = true
        configuration.handoff.innerScrollPlacement = .atDisplayHeight(300)
        dragScrollView.configuration = configuration
        dragScrollView.beginCapture(from: leafView)

        let model = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
        XCTAssertEqual(model.detentDisplayHeights, [100, 300, 500])
        XCTAssertEqual(
            dragScrollView.minimumOuterOffset,
            100 - dragScrollView.bounds.height,
            accuracy: 0.001
        )

        dragScrollView.contentOffset.y -= 30
        dragScrollView.scrollViewDidScroll(dragScrollView)
        XCTAssertEqual(dragScrollView.displayHeight, 270, accuracy: 0.001)
        XCTAssertEqual(participant.contentOffset.y, 0, accuracy: 0.001)
        XCTAssertEqual(panelView.frame.minY, 0, accuracy: 0.001)
    }

    func testForcedInnerTopBounceDoesNotTrimProviderSpecifiedDetents() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300, 500])
        _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
        let provider = SegmentProvider([
            BODragScrollInnerScrollSegment(
                displayHeight: 300,
                beginOffsetY: 0,
                endOffsetY: 200
            ),
            BODragScrollInnerScrollSegment(
                displayHeight: 500,
                beginOffsetY: 200,
                endOffsetY: 600
            )
        ])
        dragScrollView.behaviorProvider = provider
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)

        var configuration = dragScrollView.configuration
        configuration.bounce.forcesInnerTopBounce = true
        dragScrollView.configuration = configuration
        dragScrollView.beginCapture(from: leafView)

        let model = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
        XCTAssertEqual(model.detentDisplayHeights, [100, 300, 500])
        XCTAssertEqual(
            model.segments.filter(\.isParticipantSegment).map(\.displayHeight),
            [300, 500]
        )
        XCTAssertEqual(
            dragScrollView.minimumOuterOffset,
            100 - dragScrollView.bounds.height,
            accuracy: 0.001
        )
    }

    func testForcedInnerTopBounceKeepsSingleSpecifiedSegmentAcrossNestedChain() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300, 500])
        _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
        let provider = SegmentProvider([
            BODragScrollInnerScrollSegment(
                displayHeight: 300,
                beginOffsetY: 0,
                endOffsetY: 600
            )
        ])
        dragScrollView.behaviorProvider = provider

        let outer = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 500),
            contentHeight: 1_200
        )
        let outerContent = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 1_200))
        outer.addSubview(outerContent)
        let primary = makeScrollView(
            frame: CGRect(x: 0, y: 100, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        primary.addSubview(leafView)
        outerContent.addSubview(primary)
        panelView.addSubview(outer)

        var configuration = dragScrollView.configuration
        configuration.bounce.forcesInnerTopBounce = true
        dragScrollView.configuration = configuration
        dragScrollView.beginCapture(from: leafView)

        let session = try XCTUnwrap(dragScrollView.runtime.capture.session)
        let model = try XCTUnwrap(session.model)
        XCTAssertEqual(session.participantChain.count, 2)
        XCTAssertEqual(model.detentDisplayHeights, [100, 300, 500])
        let owners = Set(model.segments.compactMap(\.participantID))
        XCTAssertEqual(owners, Set(session.participantChain.map(\.id)))
        XCTAssertLessThanOrEqual(
            dragScrollView.minimumOuterOffset,
            100 - dragScrollView.bounds.height + 0.001
        )
    }

    func testForcedInnerTopBounceFallsBackToSmartSuffixForInvalidSpecifiedSegments() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300, 500])
        _ = dragScrollView.move(toDisplayHeight: 300, animated: false)
        let provider = SegmentProvider([
            BODragScrollInnerScrollSegment(
                displayHeight: .nan,
                beginOffsetY: .infinity,
                endOffsetY: -.infinity
            )
        ])
        dragScrollView.behaviorProvider = provider
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)

        var configuration = dragScrollView.configuration
        configuration.bounce.forcesInnerTopBounce = true
        dragScrollView.configuration = configuration
        dragScrollView.beginCapture(from: leafView)

        let model = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
        XCTAssertEqual(model.detentDisplayHeights, [300, 500])
        XCTAssertEqual(
            dragScrollView.minimumOuterOffset,
            300 - dragScrollView.bounds.height,
            accuracy: 0.001
        )
    }

    func testPrimaryParticipantReceivesAConsistentDragLifecycle() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let lifecycle = ParticipantLifecycleSpy()
        participant.delegate = lifecycle
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        _ = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
        defer { dragScrollView.endCapture() }

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        var target = dragScrollView.contentOffset
        withUnsafeMutablePointer(to: &target) { pointer in
            dragScrollView.scrollViewWillEndDragging(
                dragScrollView,
                withVelocity: .zero,
                targetContentOffset: pointer
            )
        }
        dragScrollView.scrollViewDidEndDragging(dragScrollView, willDecelerate: false)

        XCTAssertEqual(lifecycle.began.count, 1)
        XCTAssertEqual(lifecycle.willEnd.count, 1)
        XCTAssertEqual(lifecycle.didEnd.count, 1)
        XCTAssertTrue(lifecycle.began.first === participant)
        XCTAssertTrue(lifecycle.willEnd.first === participant)
        XCTAssertTrue(lifecycle.didEnd.first === participant)
    }

    func testOldDragCleanupDoesNotEndReentrantSameChainCapture() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let lifecycle = ReentrantParticipantLifecycleDelegate()
        participant.delegate = lifecycle
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        let originalSession = try XCTUnwrap(dragScrollView.runtime.capture.session)
        let originalGeneration = originalSession.ownershipGeneration
        lifecycle.onDidEndDragging = {
            dragScrollView.beginCapture(from: leafView)
        }

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        dragScrollView.scrollViewDidEndDragging(dragScrollView, willDecelerate: false)

        let refreshedSession = try XCTUnwrap(dragScrollView.runtime.capture.session)
        XCTAssertEqual(refreshedSession.id, originalSession.id)
        XCTAssertGreaterThan(refreshedSession.ownershipGeneration, originalGeneration)
        dragScrollView.endCapture()
    }

    func testSameChainRefreshDuringTrackingRemainsOwnedByDrag() throws {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        _ = try XCTUnwrap(dragScrollView.runtime.capture.session)

        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        dragScrollView.beginCapture(from: leafView)
        dragScrollView.scrollViewDidEndDragging(dragScrollView, willDecelerate: false)

        XCTAssertNil(dragScrollView.runtime.capture.session)
    }

    func testCaptureRebuildDoesNotRebindSessionEndedByProvider() {
        let (dragScrollView, panelView) = makeHost()
        let provider = EndingCaptureProvider()
        dragScrollView.behaviorProvider = provider
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)

        dragScrollView.beginCapture(from: leafView)

        XCTAssertNil(dragScrollView.runtime.capture.session)
        XCTAssertFalse(
            BODragScrollUIScrollViewBridge.unbind(
                primaryParticipant: participant,
                from: dragScrollView,
                captureSessionID: 1
            )
        )
    }

    func testSingleWKWebViewCandidateAlwaysReachesCaptureProposalProvider() {
        let (dragScrollView, panelView) = makeHost()
        let provider = CaptureProposalSpy()
        dragScrollView.behaviorProvider = provider

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
        panelView.addSubview(webView)
        webView.layoutIfNeeded()
        webView.scrollView.contentSize = CGSize(width: 320, height: 900)

        let containingWebView = dragScrollView.beginCapture(from: webView.scrollView)
        defer { dragScrollView.endCapture() }

        XCTAssertTrue(containingWebView === webView)
        XCTAssertEqual(provider.adjustmentCallCount, 1)
        XCTAssertEqual(provider.candidateCount, 1)
        XCTAssertTrue(provider.hadPrimaryCandidate)
        XCTAssertTrue(provider.containedWebView)
    }

    func testHostDeinitRestoresParticipantScrollsToTopLease() {
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        participant.scrollsToTop = true
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        weak var weakHost: BODragScrollView?

        autoreleasepool {
            let (host, panelView) = makeHost()
            weakHost = host
            panelView.addSubview(participant)
            host.beginCapture(from: leafView)
            XCTAssertNotNil(host.runtime.capture.session)
            XCTAssertFalse(participant.scrollsToTop)
        }

        XCTAssertNil(weakHost)
        XCTAssertTrue(participant.scrollsToTop)
    }

    func testHostDeinitFallbackNormalizesExternallyRetainedParticipant() {
        let retainedPanel = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 800))
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        participant.scrollsToTop = true
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        retainedPanel.addSubview(participant)
        weak var weakHost: BODragScrollView?

        autoreleasepool {
            let host = BODragScrollView(frame: viewport)
            host.runtime.capture.allowsOffWindowCaptureForTesting = true
            weakHost = host
            host.panelView = retainedPanel
            layout(host)
            host.beginCapture(from: leafView)
            XCTAssertNotNil(host.runtime.capture.session)
            participant.contentOffset.y = -80
            XCTAssertLessThan(participant.contentOffset.y, -participant.adjustedContentInset.top)
        }

        XCTAssertNil(weakHost)
        XCTAssertEqual(
            participant.contentOffset.y,
            -participant.adjustedContentInset.top,
            accuracy: 0.001
        )
        XCTAssertTrue(participant.scrollsToTop)
    }

    // MARK: - Accessibility and touch-completion timing

    func testAccessibilityReturnsTrueWhenItExecutesWithoutDetents() {
        let (dragScrollView, _) = makeHost()
        let originalOffset = dragScrollView.contentOffset

        let handled = dragScrollView.accessibilityScroll(.down)

        XCTAssertTrue(handled)
        XCTAssertNotEqual(dragScrollView.contentOffset, originalOffset)
    }

    func testAccessibilityDetentMovementUsesPublicDisplayHeight() {
        let (dragScrollView, _) = makeHost(detents: [100, 300])

        XCTAssertTrue(dragScrollView.accessibilityScroll(.down))
        XCTAssertEqual(dragScrollView.displayHeight, 300, accuracy: 0.001)
    }

    func testAccessibilityPanelMovementTakesOwnershipFromParticipantDeceleration() throws {
        let (dragScrollView, panelView) = makeHost()
        let provider = AccessibilityPanelOnlyProvider()
        dragScrollView.behaviorProvider = provider
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let lifecycle = ParticipantLifecycleSpy()
        participant.delegate = lifecycle
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        _ = try XCTUnwrap(dragScrollView.runtime.capture.session)
        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        dragScrollView.scrollViewDidEndDragging(dragScrollView, willDecelerate: true)

        XCTAssertTrue(dragScrollView.accessibilityScroll(.down))

        XCTAssertEqual(lifecycle.didDecelerate.count, 1)
        XCTAssertFalse(dragScrollView.runtime.transition.isAwaitingDidEndDecelerating)
        XCTAssertNil(dragScrollView.runtime.capture.session)
        XCTAssertEqual(dragScrollView.displayHeight, 800, accuracy: 0.001)
    }

    func testAccessibilityBoundaryResolvesAfterDecelerationCallbacks() throws {
        let (dragScrollView, panelView) = makeHost()
        let provider = AccessibilityPanelOnlyProvider()
        let events = ReentrantDecelerationDelegate()
        dragScrollView.behaviorProvider = provider
        dragScrollView.eventDelegate = events
        _ = dragScrollView.move(toDisplayHeight: 500, animated: false)
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        _ = try XCTUnwrap(dragScrollView.runtime.capture.session)
        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        dragScrollView.scrollViewDidEndDragging(dragScrollView, willDecelerate: true)
        events.onDidEndDecelerating = {
            dragScrollView.minimumDisplayHeight = 120
        }

        XCTAssertTrue(dragScrollView.accessibilityScroll(.up))

        XCTAssertEqual(dragScrollView.displayHeight, 120, accuracy: 0.001)
    }

    func testAccessibilityMovementInterruptsActiveViewAnimation() {
        let (dragScrollView, _) = makeHost()
        let window = attachToWindow(dragScrollView)
        defer { window.isHidden = true }
        var previousResults: [BODragScrollMovementResult] = []
        dragScrollView.move(
            toDisplayHeight: 500,
            animated: true,
            options: BODragScrollMovementOptions(style: .viewAnimation, duration: 0.5)
        ) { previousResults.append($0) }

        XCTAssertTrue(dragScrollView.accessibilityScroll(.down))

        XCTAssertEqual(previousResults.map(\.outcome), [.interrupted])
        XCTAssertEqual(dragScrollView.runtime.transition.activeTransaction?.reason, .accessibility)
        dragScrollView.interruptActiveMovement(outcome: .interrupted)
    }

    func testTouchCompletionRecognizerInstallationAndPendingCancellation() throws {
        let dragScrollView = BODragScrollView(frame: viewport)
        let recognizer = try XCTUnwrap(
            dragScrollView.gestureRecognizers?.compactMap {
                $0 as? TouchCompletionGestureRecognizer
            }.first
        )

        XCTAssertFalse(recognizer.cancelsTouchesInView)
        XCTAssertFalse(recognizer.delaysTouchesEnded)
        XCTAssertTrue(recognizer.delegate === dragScrollView)

        dragScrollView.installInteractionSupport()
        XCTAssertEqual(
            dragScrollView.gestureRecognizers?.compactMap {
                $0 as? TouchCompletionGestureRecognizer
            }.count,
            1
        )

        dragScrollView.lastSystemAnimationEndTimestamp = Date().timeIntervalSince1970
        XCTAssertTrue(dragScrollView.gestureRecognizerShouldBegin(recognizer))
        XCTAssertEqual(dragScrollView.lastSystemAnimationEndTimestamp, 0)

        // UIKit only commits a recognizer state transition while dispatching a touch sequence, so
        // outside event delivery the testable contract is that cancellation is safe and clears the
        // host's pending settlement, not a synthetic `.failed` state value.
        dragScrollView.cancelPendingTouchCompletionSettlement()

        let standalone = TouchCompletionGestureRecognizer(target: nil, action: nil)
        XCTAssertEqual(standalone.state, .possible)
        standalone.finishRecognition()
    }

    func testStaleSystemAnimationEndDoesNotArmTouchCompletion() throws {
        let dragScrollView = BODragScrollView(frame: viewport)
        let recognizer = try XCTUnwrap(
            dragScrollView.gestureRecognizers?.compactMap {
                $0 as? TouchCompletionGestureRecognizer
            }.first
        )
        XCTAssertNil(dragScrollView.runtime.transition.driver)
        XCTAssertEqual(dragScrollView.lastSystemAnimationEndTimestamp, 0)

        dragScrollView.scrollViewDidEndScrollingAnimation(dragScrollView)

        XCTAssertEqual(dragScrollView.lastSystemAnimationEndTimestamp, 0)
        XCTAssertFalse(dragScrollView.gestureRecognizerShouldBegin(recognizer))
    }

    func testReplacingSystemAnimationDriverClearsTouchCompletionTimestamp() {
        let dragScrollView = BODragScrollView(frame: viewport)
        dragScrollView.runtime.transition.driver = .systemAnimation
        dragScrollView.lastSystemAnimationEndTimestamp = Date().timeIntervalSince1970

        // A valid callback from the old animation may have armed touch completion immediately
        // before another movement replaces that driver. Once ownership changes, the timestamp no
        // longer describes the current interaction and must be invalidated with the driver.
        dragScrollView.interruptActiveMovement(outcome: .interrupted)

        XCTAssertNil(dragScrollView.runtime.transition.driver)
        XCTAssertEqual(dragScrollView.lastSystemAnimationEndTimestamp, 0)
    }

    // MARK: - Fixtures

    private func makeHost(
        detents: [CGFloat] = [],
        layout shouldLayout: Bool = true,
        panelHeight: CGFloat = 800,
        suppliedPanelView: UIView? = nil
    ) -> (BODragScrollView, UIView) {
        let dragScrollView = BODragScrollView(frame: viewport)
        dragScrollView.runtime.capture.allowsOffWindowCaptureForTesting = true
        dragScrollView.detentHeights = detents
        let panelView = suppliedPanelView
            ?? UIView(frame: CGRect(x: 0, y: 0, width: 320, height: panelHeight))
        dragScrollView.panelView = panelView
        if shouldLayout {
            layout(dragScrollView)
        }
        return (dragScrollView, panelView)
    }

    private func layout(_ dragScrollView: BODragScrollView) {
        dragScrollView.setNeedsLayout()
        dragScrollView.layoutIfNeeded()
    }

    private func attachToWindow(_ dragScrollView: BODragScrollView) -> UIWindow {
        let window = UIWindow(frame: viewport)
        let rootViewController = UIViewController()
        window.rootViewController = rootViewController
        rootViewController.view.frame = viewport
        rootViewController.view.addSubview(dragScrollView)
        window.makeKeyAndVisible()
        layout(dragScrollView)
        return window
    }

    private func beginDragDeceleration(
        on dragScrollView: BODragScrollView,
        targetOffsetY: CGFloat
    ) throws {
        var target = CGPoint(x: dragScrollView.contentOffset.x, y: targetOffsetY)
        dragScrollView.scrollViewWillEndDragging(
            dragScrollView,
            withVelocity: .zero,
            targetContentOffset: &target
        )
        _ = try XCTUnwrap(
            dragScrollView.runtime.transition.activeTransaction?.id
        )
        dragScrollView.scrollViewDidEndDragging(dragScrollView, willDecelerate: true)
        XCTAssertTrue(dragScrollView.runtime.transition.isAwaitingDidEndDecelerating)
        XCTAssertEqual(dragScrollView.runtime.transition.driver, .dragDeceleration)
    }

    private func makeCapturedParticipantFixture() throws -> (
        dragScrollView: BODragScrollView,
        panelView: UIView,
        participant: UIScrollView,
        leafView: UIView,
        window: UIWindow
    ) {
        let (dragScrollView, panelView) = makeHost(detents: [100, 300])
        let window = attachToWindow(dragScrollView)
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300),
            contentHeight: 900
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        _ = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
        XCTAssertTrue(dragScrollView.hasParticipantSegments)
        return (dragScrollView, panelView, participant, leafView, window)
    }

    private func makeAdaptiveFreePanelFixture(
        initialDisplayHeight: CGFloat,
        panelHeight: CGFloat = 800,
        participantContentHeight: CGFloat = 900,
        minimumDisplayHeight: CGFloat? = nil
    ) throws -> (
        dragScrollView: BODragScrollView,
        panelView: UIView,
        participant: UIScrollView,
        leafView: UIView,
        window: UIWindow,
        maximumOuterOffset: CGFloat,
        participantMaximumOffset: CGFloat
    ) {
        let (dragScrollView, panelView) = makeHost(panelHeight: panelHeight)
        if let minimumDisplayHeight {
            dragScrollView.minimumDisplayHeight = minimumDisplayHeight
        }
        let window = attachToWindow(dragScrollView)
        XCTAssertEqual(
            dragScrollView.move(
                toDisplayHeight: initialDisplayHeight,
                animated: false
            ),
            initialDisplayHeight,
            accuracy: 0.0001
        )
        let participant = makeScrollView(
            frame: CGRect(x: 0, y: 40, width: 320, height: 300),
            contentHeight: participantContentHeight
        )
        let leafView = UIView(frame: CGRect(x: 0, y: 10, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)

        let session = try XCTUnwrap(dragScrollView.runtime.capture.session)
        _ = try XCTUnwrap(session.model)
        XCTAssertEqual(session.axisPhase?.rebasePolicy, .continuousPanel)
        let participantMinimumOffset = -participant.effectiveContentInset.top
        let participantMaximumOffset = max(
            participantMinimumOffset,
            participant.contentSize.height
                + participant.effectiveContentInset.bottom
                - participant.bounds.height
        )
        return (
            dragScrollView,
            panelView,
            participant,
            leafView,
            window,
            dragScrollView.maximumOuterOffset,
            participantMaximumOffset
        )
    }

    private func setHostOffsetWithoutDeliveringScroll(
        _ dragScrollView: BODragScrollView,
        to outerOffsetY: CGFloat
    ) {
        dragScrollView.withInternalMutation {
            dragScrollView.contentOffset = CGPoint(
                x: dragScrollView.contentOffset.x,
                y: outerOffsetY
            )
        }
    }

    private func deliverHostScroll(
        _ dragScrollView: BODragScrollView,
        to outerOffsetY: CGFloat
    ) {
        setHostOffsetWithoutDeliveringScroll(dragScrollView, to: outerOffsetY)
        dragScrollView.scrollViewDidScroll(dragScrollView)
    }

    private func makeAutomaticBottomInnerOverscrollFixture() throws -> (
        dragScrollView: BODragScrollView,
        panelView: UIView,
        participant: UIScrollView,
        leafView: UIView,
        window: UIWindow,
        maximumOuterOffset: CGFloat,
        participantMaximumOffset: CGFloat
    ) {
        let fixture = try makeCapturedParticipantFixture()
        var configuration = fixture.dragScrollView.configuration
        configuration.bounce.preferredBottomOwner = .innerScrollView
        fixture.dragScrollView.configuration = configuration
        fixture.dragScrollView.reloadScrollMetrics()
        fixture.dragScrollView.scrollViewWillBeginDragging(fixture.dragScrollView)

        let maximumOuterOffset = fixture.dragScrollView.maximumOuterOffset
        let inset = fixture.participant.effectiveContentInset
        let participantMaximumOffset = max(
            -inset.top,
            fixture.participant.contentSize.height
                + inset.bottom
                - fixture.participant.bounds.height
        )
        fixture.dragScrollView.contentOffset.y = maximumOuterOffset + 30
        fixture.dragScrollView.scrollViewDidScroll(fixture.dragScrollView)

        XCTAssertEqual(
            fixture.dragScrollView.contentOffset.y,
            maximumOuterOffset + 30,
            accuracy: 0.001
        )
        XCTAssertEqual(
            fixture.participant.contentOffset.y,
            participantMaximumOffset + 30,
            accuracy: 0.001
        )
        return (
            fixture.dragScrollView,
            fixture.panelView,
            fixture.participant,
            fixture.leafView,
            fixture.window,
            maximumOuterOffset,
            participantMaximumOffset
        )
    }

    private func makeBottomInnerOverscrollFixture(
        nativeTracking: Bool = false,
        suppliedPanelView: UIView? = nil
    ) throws -> (
        dragScrollView: BODragScrollView,
        panelView: UIView,
        participant: ContentOffsetRequestRecordingScrollView,
        leafView: UIView,
        provider: SegmentProvider,
        window: UIWindow,
        maximumOuterOffset: CGFloat,
        participantMaximumOffset: CGFloat
    ) {
        let (dragScrollView, panelView) = makeHost(
            detents: [100, 300],
            suppliedPanelView: suppliedPanelView
        )
        let window = attachToWindow(dragScrollView)
        let participant = ContentOffsetRequestRecordingScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300)
        )
        participant.contentSize = CGSize(width: 320, height: 900)
        let provider = SegmentProvider([
            BODragScrollInnerScrollSegment(
                displayHeight: 300,
                beginOffsetY: 0,
                endOffsetY: 600
            )
        ])
        dragScrollView.behaviorProvider = provider
        layout(dragScrollView)

        var configuration = dragScrollView.configuration
        configuration.bounce.preferredBottomOwner = .innerScrollView
        dragScrollView.configuration = configuration

        let leafView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        participant.addSubview(leafView)
        panelView.addSubview(participant)
        dragScrollView.beginCapture(from: leafView)
        _ = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)
        if nativeTracking {
            let trackingDidBegin = NSSelectorFromString("_trackingDidBegin")
            guard dragScrollView.responds(to: trackingDidBegin) else {
                throw XCTSkip("This UIKit runtime cannot expose a physical tracking test state.")
            }
            dragScrollView.perform(trackingDidBegin)
            guard dragScrollView.nativeScrollState.isTracking else {
                throw XCTSkip("UIKit did not enter the requested physical tracking state.")
            }
        }
        dragScrollView.scrollViewWillBeginDragging(dragScrollView)
        _ = try XCTUnwrap(dragScrollView.runtime.capture.session?.model)

        let maximumOuterOffset = dragScrollView.maximumOuterOffset
        let participantMaximumOffset = max(
            -participant.effectiveContentInset.top,
            participant.contentSize.height
                + participant.effectiveContentInset.bottom
                - participant.bounds.height
        )
        let overscrollDistance: CGFloat = 30
        dragScrollView.contentOffset.y = maximumOuterOffset + overscrollDistance
        dragScrollView.scrollViewDidScroll(dragScrollView)

        XCTAssertEqual(
            dragScrollView.contentOffset.y,
            maximumOuterOffset + overscrollDistance,
            accuracy: 0.001
        )
        XCTAssertEqual(
            participant.contentOffset.y,
            participantMaximumOffset + overscrollDistance,
            accuracy: 0.001
        )
        XCTAssertEqual(dragScrollView.displayHeight, 300, accuracy: 0.001)

        return (
            dragScrollView,
            panelView,
            participant,
            leafView,
            provider,
            window,
            maximumOuterOffset,
            participantMaximumOffset
        )
    }

    private func makeScrollView(frame: CGRect, contentHeight: CGFloat) -> UIScrollView {
        let scrollView = UIScrollView(frame: frame)
        scrollView.contentSize = CGSize(width: frame.width, height: contentHeight)
        return scrollView
    }
}
#endif
