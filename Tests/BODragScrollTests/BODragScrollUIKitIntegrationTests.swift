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
private final class GeometryObservingPanelView: UIView {
    var onFirstCenterChange: (() -> Void)?
    private var hasFired = false

    override var center: CGPoint {
        didSet {
            guard center != oldValue,
                  !hasFired,
                  let onFirstCenterChange else { return }
            hasFired = true
            onFirstCenterChange()
        }
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
    private(set) var began: [UIScrollView] = []
    private(set) var willEnd: [UIScrollView] = []
    private(set) var didEnd: [UIScrollView] = []
    private(set) var didDecelerate: [UIScrollView] = []

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        began.append(scrollView)
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
private final class ReentrantParticipantLifecycleDelegate: NSObject, UIScrollViewDelegate {
    var onDidEndDragging: (() -> Void)?

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        onDidEndDragging?()
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
    private(set) var didEndDeceleratingCount = 0
    private(set) var results: [BODragScrollMovementResult] = []

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

    func testStaleSystemAnimationEndCallbackCannotFinishReplacement() {
        let (dragScrollView, _) = makeHost(detents: [100, 200, 300])
        let window = attachToWindow(dragScrollView)
        defer { window.isHidden = true }
        var firstResults: [BODragScrollMovementResult] = []
        var secondResults: [BODragScrollMovementResult] = []

        dragScrollView.move(
            toDisplayHeight: 300,
            animated: true,
            options: BODragScrollMovementOptions(style: .systemScroll)
        ) { firstResults.append($0) }
        dragScrollView.move(
            toDisplayHeight: 200,
            animated: true,
            options: BODragScrollMovementOptions(style: .systemScroll)
        ) { secondResults.append($0) }

        XCTAssertEqual(firstResults.map(\.outcome), [.interrupted])
        let replacementID = dragScrollView.runtime.transition.activeTransaction?.id

        // Simulate animation A's identifier-less UIKit callback arriving after B owns the driver.
        dragScrollView.scrollViewDidEndScrollingAnimation(dragScrollView)

        XCTAssertEqual(dragScrollView.runtime.transition.activeTransaction?.id, replacementID)
        XCTAssertTrue(secondResults.isEmpty)

        dragScrollView.move(toDisplayHeight: 250, animated: false)
        XCTAssertEqual(secondResults.map(\.outcome), [.interrupted])
        XCTAssertEqual(dragScrollView.displayHeight, 250, accuracy: 0.001)
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
        XCTAssertEqual(panelView.frame.minY, expected.panelTranslation, accuracy: 0.001)
        let observedPanelOrigin = try XCTUnwrap(panelOriginsObservedDuringOffsetWrite.last)
        XCTAssertEqual(
            observedPanelOrigin,
            expected.panelTranslation,
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

    // MARK: - Fixtures

    private func makeHost(
        detents: [CGFloat] = [],
        layout shouldLayout: Bool = true
    ) -> (BODragScrollView, UIView) {
        let dragScrollView = BODragScrollView(frame: viewport)
        dragScrollView.runtime.capture.allowsOffWindowCaptureForTesting = true
        dragScrollView.detentHeights = detents
        let panelView = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 800))
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

    private func makeScrollView(frame: CGRect, contentHeight: CGFloat) -> UIScrollView {
        let scrollView = UIScrollView(frame: frame)
        scrollView.contentSize = CGSize(width: frame.width, height: contentHeight)
        return scrollView
    }
}
#endif
