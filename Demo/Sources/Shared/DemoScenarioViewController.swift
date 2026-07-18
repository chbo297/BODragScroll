import UIKit

@MainActor
class DemoScenarioViewController: UIViewController, DemoDragEngineDelegate {
    let implementation: DemoImplementation
    let dragEngine: DemoDragEngine
    let panelView: DemoPanelView

    var dragScrollView: UIScrollView { dragEngine.scrollView }

    private let eventHUD = DemoEventHUD()
    private let backButton = UIButton(type: .system)
    private let implementationTabs = UISegmentedControl(items: ["OC", "Swift"])
    private let heroLabel = UILabel()
    private let readyMarker = UIView()
    private var didApplyInitialHeight = false
    private var didMarkScenarioReady = false
    private var pendingReadyReason: String?
    private var didInvalidateEngine = false
    private var isPendingNavigationRemoval = false
    private var lastViewportSize = CGSize.zero
    private var lastMaximumPanelHeight: CGFloat = -1
    private var latestSource: String
    private var latestEvent: String
    private var lastHUDPublication: CFTimeInterval = 0
    private lazy var traceRecorder = DemoTraceRecorder(
        scene: String(describing: type(of: self)),
        implementation: implementation
    )

    init(
        title: String,
        subtitle: String,
        accent: UIColor,
        implementation: DemoImplementation = .swift
    ) {
        self.implementation = implementation
        dragEngine = DemoDragEngineFactory.make(implementation: implementation)
        panelView = DemoPanelView(title: title, subtitle: subtitle, accent: accent)
        latestSource = "\(implementation.displayName)/panel"
        latestEvent = "\(implementation.displayName) 实现 · 等待交互"
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = DemoPalette.canvas
        view.accessibilityIdentifier = "demo.scenario"

        let backdrop = DemoBackdropView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)

        heroLabel.text = "向上拖动面板\n再在内容区域继续滑动"
        heroLabel.font = .systemFont(ofSize: 23, weight: .bold)
        heroLabel.textColor = DemoPalette.ink.withAlphaComponent(0.70)
        heroLabel.numberOfLines = 0
        heroLabel.textAlignment = .center
        heroLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(heroLabel)

        dragEngine.delegate = self
        dragScrollView.backgroundColor = .clear
        dragScrollView.translatesAutoresizingMaskIntoConstraints = false
        dragScrollView.accessibilityIdentifier = "demo.dragHost"
        dragScrollView.accessibilityLabel = "可拖动面板，当前为\(implementation.displayName)实现"
        view.addSubview(dragScrollView)

        eventHUD.translatesAutoresizingMaskIntoConstraints = false
        panelView.addSubview(eventHUD)

        configureBackButton()
        view.addSubview(backButton)
        configureImplementationTabs()
        view.addSubview(implementationTabs)
        configureReadyMarker()
        view.addSubview(readyMarker)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            heroLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            heroLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -90),
            heroLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            heroLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),

            // The drag host intentionally owns the complete screen. Only its panel size and
            // display-height inputs are restricted to the area below the top safe inset.
            dragScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dragScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dragScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            dragScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            eventHUD.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 100),
            eventHUD.centerXAnchor.constraint(equalTo: panelView.centerXAnchor),
            eventHUD.leadingAnchor.constraint(greaterThanOrEqualTo: panelView.leadingAnchor, constant: 72),
            eventHUD.trailingAnchor.constraint(lessThanOrEqualTo: panelView.trailingAnchor, constant: -72),

            backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            backButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            backButton.widthAnchor.constraint(equalToConstant: 46),
            backButton.heightAnchor.constraint(equalToConstant: 46),

            implementationTabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            implementationTabs.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 13),
            implementationTabs.widthAnchor.constraint(equalToConstant: 124),
            implementationTabs.heightAnchor.constraint(equalToConstant: 40),

            readyMarker.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            readyMarker.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            readyMarker.widthAnchor.constraint(equalToConstant: 1),
            readyMarker.heightAnchor.constraint(equalToConstant: 1)
        ])

        configureContent(in: panelView.contentView)
        dragEngine.panelView = panelView
        applyInitialConfiguration()
        publishHUD(force: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        backButton.isHidden = navigationController?.viewControllers.first === self
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isMovingFromParent || navigationController?.isBeingDismissed == true else { return }
        isPendingNavigationRemoval = true
        navigationController?.setNavigationBarHidden(false, animated: animated)
        transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] context in
            guard let self else { return }
            if context.isCancelled {
                self.isPendingNavigationRemoval = false
                self.navigationController?.setNavigationBarHidden(true, animated: false)
            } else {
                self.invalidateEngineIfNeeded()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isPendingNavigationRemoval else { return }
        let remainsInStack = navigationController?.viewControllers.contains(where: { $0 === self }) == true
        if !remainsInStack {
            invalidateEngineIfNeeded()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeightSafetyForCurrentViewport()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // Apply a reduced safe-area ceiling synchronously when bounds are already valid. The next
        // regular layout pass remains a fallback for early callbacks that arrive before sizing.
        updateHeightSafetyForCurrentViewport()
        view.setNeedsLayout()
    }

    private func updateHeightSafetyForCurrentViewport() {
        let viewportSize = dragScrollView.bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        let maximumPanelHeight = availablePanelHeight(for: viewportSize)
        let viewportChanged = viewportSize != lastViewportSize
        let maximumHeightChanged = maximumPanelHeight != lastMaximumPanelHeight
        let hadPreviousViewport = lastViewportSize != .zero
        if viewportChanged || maximumHeightChanged {
            lastViewportSize = viewportSize
            lastMaximumPanelHeight = maximumPanelHeight
            dragEngine.detentHeights = clampedDetentHeights(
                detentHeights(for: viewportSize),
                maximum: maximumPanelHeight
            )
            dragEngine.nonSnappingRanges = clampedNonSnappingRanges(
                nonSnappingRanges(for: viewportSize),
                maximum: maximumPanelHeight
            )
            dragEngine.minimumDisplayHeight = minimumDisplayHeight(for: viewportSize).map {
                engineSafeHeight($0, maximum: maximumPanelHeight)
            }
            viewportDidChange(to: viewportSize)
            dragEngine.reloadScrollMetrics()
            if hadPreviousViewport {
                // Reconcile presentation-state animations as well as geometry. This explicit path
                // is required for safe-area-only changes and also hardens rotation during motion.
                recordTrace(
                    "viewportInvalidation",
                    details: [
                        "viewport": String(format: "%.6f,%.6f", viewportSize.width, viewportSize.height),
                        "safeMaximum": String(format: "%.6f", maximumPanelHeight),
                        "visiblePanelHeight": String(
                            format: "%.6f",
                            presentationDisplayHeight()
                        )
                    ]
                )
                publishHUD(force: true)
                dragEngine.invalidatePanelLayout()
            } else {
                dragScrollView.setNeedsLayout()
            }
        }

        dragScrollView.layoutIfNeeded()
        guard panelView.bounds.height > 0 else { return }

        if !didApplyInitialHeight {
            didApplyInitialHeight = true
            dragEngine.move(
                toDisplayHeight: min(maximumPanelHeight, max(0, initialDisplayHeight(for: viewportSize))),
                animated: false,
                options: .init(),
                completion: nil
            )
            if !defersReadyUntilContentLoaded {
                markScenarioReady("initialLayout")
            } else if let pendingReadyReason {
                self.pendingReadyReason = nil
                markScenarioReady(pendingReadyReason)
            }
        } else if allowsPostInitializationHeightCorrection,
                  dragEngine.displayHeight > maximumPanelHeight {
            dragEngine.move(
                toDisplayHeight: maximumPanelHeight,
                animated: false,
                options: .init(),
                completion: nil
            )
        }
    }

    // MARK: - Scene hooks

    func makeScene(implementation: DemoImplementation) -> DemoScenarioViewController {
        preconditionFailure("Every concrete demo scene must rebuild itself for implementation switching")
    }

    /// Copy user-selected policy values to a freshly built counterpart. Scroll offsets, active
    /// capture sessions, animations and display height intentionally remain reset for repeatable A/B.
    func transferComparisonSettings(to counterpart: DemoScenarioViewController) {}

    /// Scroll views whose independent state is relevant to Swift/OC comparison. The host scroll
    /// view is always captured separately and must not be repeated here.
    func comparisonScrollViews() -> [(name: String, scrollView: UIScrollView)] { [] }

    /// Scenarios that exercise unassisted natural scrolling can disable the defensive runtime
    /// correction so an ordinary layout pass never authors a programmatic movement.
    var allowsPostInitializationHeightCorrection: Bool { true }

    /// Web-like scenes can defer the ready marker until their asynchronous content is usable.
    var defersReadyUntilContentLoaded: Bool { false }

    final func markScenarioReady(_ reason: String) {
        guard !didMarkScenarioReady else { return }
        guard didApplyInitialHeight else {
            pendingReadyReason = reason
            return
        }
        didMarkScenarioReady = true
        readyMarker.accessibilityValue = String(
            format: "%@|%@|%.6f",
            implementation.displayName,
            reason,
            dragEngine.displayHeight
        )
        recordTrace("ready", details: ["reason": reason])
        traceRecorder.flush(reason: "ready")
        publishHUD(force: true)
    }

    func configureContent(in contentView: UIView) {}

    func applyInitialConfiguration() {}

    func panelSize(for viewportSize: CGSize) -> CGSize {
        CGSize(width: viewportSize.width, height: availablePanelHeight(for: viewportSize))
    }

    func detentHeights(for viewportSize: CGSize) -> [CGFloat] {
        let maximum = availablePanelHeight(for: viewportSize)
        let low = min(150, maximum)
        let middle = min(maximum, max(low, min(390, maximum - 80)))
        return [low, middle, maximum]
    }

    func nonSnappingRanges(for viewportSize: CGSize) -> [ClosedRange<CGFloat>] { [] }

    func minimumDisplayHeight(for viewportSize: CGSize) -> CGFloat? { nil }

    func initialDisplayHeight(for viewportSize: CGSize) -> CGFloat { 210 }

    /// Convert a scene-authored height to the exact Float32 value both kernels will consume,
    /// choosing the lower representable value whenever rounding upward could cross the safe cap.
    func safeDisplayHeightForEngine(_ height: CGFloat, viewportSize: CGSize) -> CGFloat {
        engineSafeHeight(height, maximum: availablePanelHeight(for: viewportSize))
    }

    func viewportDidChange(to viewportSize: CGSize) {}

    func segments(for scrollView: UIScrollView) -> [DemoInnerScrollSegment]? { nil }

    func canCapture(_ scrollView: UIScrollView) -> Bool { true }

    func adjustCaptureProposal(_ proposal: inout DemoCaptureProposal) {}

    func shouldBypassDetents(at displayHeight: CGFloat) -> Bool? { nil }

    func movementStyle(
        from fromDisplayHeight: CGFloat,
        to toDisplayHeight: CGFloat,
        reason: DemoMovementReason
    ) -> DemoMovementStyle { .automatic }

    func adjustTargetContentOffset(_ targetContentOffset: inout CGPoint, velocity: CGPoint) {}

    func shouldScrollToTop() -> Bool { true }

    func accessibilityDisposition(
        for direction: UIAccessibilityScrollDirection
    ) -> DemoAccessibilityDisposition { .automatic }

    func didRecordEvent(_ event: String) {}

    func recordEvent(_ event: String) {
        recordTrace("sceneEvent", details: ["message": event])
        presentEvent(event)
    }

    final func recordMovementCompletion(_ result: DemoMovementResult, label: String) {
        recordTrace(
            "movementCompletion",
            details: [
                "label": label,
                "requested": String(format: "%.6f", result.requestedDisplayHeight),
                "final": String(format: "%.6f", result.finalDisplayHeight),
                "reason": result.reason.description,
                "outcome": result.outcome.rawValue
            ]
        )
        publishHUD(force: true)
        traceRecorder.flush(reason: "movementCompletion")
    }

    private func presentEvent(_ event: String) {
        latestEvent = event
        publishHUD(force: true)
        didRecordEvent(event)
    }

    private func recordTrace(_ callback: String, details: [String: String] = [:]) {
        traceRecorder.record(
            callback: callback,
            displayHeight: dragEngine.displayHeight,
            isAnimatingDisplayHeight: dragEngine.isAnimatingDisplayHeight,
            host: dragScrollView,
            participants: comparisonScrollViews(),
            details: details
        )
    }

    private func traceName(for scrollView: UIScrollView) -> String {
        scrollView.accessibilityIdentifier ?? String(describing: type(of: scrollView))
    }

    private func tracePoint(_ point: CGPoint) -> String {
        String(format: "%.6f,%.6f", point.x, point.y)
    }

    // MARK: - Demo engine delegate

    func dragEngine(
        _ engine: DemoDragEngine,
        sizeFor panelView: UIView,
        firstLayout: Bool,
        proposedDisplayHeight: inout CGFloat
    ) -> CGSize {
        let viewportSize = engine.scrollView.bounds.size
        let maximumHeight = availablePanelHeight(for: viewportSize)
        let requestedSize = panelSize(for: viewportSize)
        let originalProposedDisplayHeight = proposedDisplayHeight
        proposedDisplayHeight = min(maximumHeight, max(0, proposedDisplayHeight))
        let size = CGSize(
            width: min(max(0, requestedSize.width), viewportSize.width),
            height: min(maximumHeight, max(0, requestedSize.height))
        )
        recordTrace(
            "sizeForPanel",
            details: [
                "firstLayout": String(firstLayout),
                "proposedBefore": String(format: "%.6f", originalProposedDisplayHeight),
                "proposedAfter": String(format: "%.6f", proposedDisplayHeight),
                "result": String(format: "%.6f,%.6f", size.width, size.height)
            ]
        )
        return size
    }

    func dragEngine(
        _ engine: DemoDragEngine,
        segmentsFor scrollView: UIScrollView
    ) -> [DemoInnerScrollSegment]? {
        let viewportSize = engine.scrollView.bounds.size
        let result = segments(for: scrollView)?.map { segment in
            var segment = segment
            segment.displayHeight = safeDisplayHeightForEngine(
                segment.displayHeight,
                viewportSize: viewportSize
            )
            return segment
        }
        let description = result?.map {
            String(
                format: "h=%.6f,begin=%@,end=%@",
                $0.displayHeight,
                $0.beginOffsetY.map { String(format: "%.6f", $0) } ?? "nil",
                $0.endOffsetY.map { String(format: "%.6f", $0) } ?? "nil"
            )
        }.joined(separator: "|") ?? "nil"
        recordTrace(
            "segmentsForScrollView",
            details: ["scrollView": traceName(for: scrollView), "segments": description]
        )
        return result
    }

    func dragEngine(_ engine: DemoDragEngine, canCapture scrollView: UIScrollView) -> Bool {
        let result = canCapture(scrollView)
        recordTrace(
            "canCaptureScrollView",
            details: ["scrollView": traceName(for: scrollView), "result": String(result)]
        )
        return result
    }

    func dragEngine(
        _ engine: DemoDragEngine,
        adjustCaptureProposal proposal: inout DemoCaptureProposal
    ) {
        let primaryBefore = proposal.primaryCandidate.map { traceName(for: $0.scrollView) } ?? "nil"
        let candidatesBefore = proposal.candidates.map { traceName(for: $0.scrollView) }.joined(separator: ",")
        adjustCaptureProposal(&proposal)
        recordTrace(
            "adjustCaptureProposal",
            details: [
                "containsWebView": String(proposal.containsWebView),
                "primaryBefore": primaryBefore,
                "primaryAfter": proposal.primaryCandidate.map { traceName(for: $0.scrollView) } ?? "nil",
                "candidatesBefore": candidatesBefore,
                "candidatesAfter": proposal.candidates.map {
                    "\(traceName(for: $0.scrollView)):\($0.priority.rawValue)"
                }.joined(separator: ",")
            ]
        )
    }

    func dragEngine(_ engine: DemoDragEngine, shouldBypassDetentsAt displayHeight: CGFloat) -> Bool? {
        let result = shouldBypassDetents(at: displayHeight)
        recordTrace(
            "shouldBypassDetents",
            details: [
                "height": String(format: "%.6f", displayHeight),
                "result": result.map(String.init) ?? "nil"
            ]
        )
        return result
    }

    func dragEngine(
        _ engine: DemoDragEngine,
        movementStyleFrom fromDisplayHeight: CGFloat,
        to toDisplayHeight: CGFloat,
        reason: DemoMovementReason
    ) -> DemoMovementStyle {
        let result = movementStyle(from: fromDisplayHeight, to: toDisplayHeight, reason: reason)
        recordTrace(
            "movementStyle",
            details: [
                "from": String(format: "%.6f", fromDisplayHeight),
                "to": String(format: "%.6f", toDisplayHeight),
                "reason": reason.description,
                "result": String(describing: result)
            ]
        )
        return result
    }

    func dragEngine(
        _ engine: DemoDragEngine,
        adjustTargetContentOffset targetContentOffset: inout CGPoint,
        velocity: CGPoint
    ) {
        let targetBefore = targetContentOffset
        adjustTargetContentOffset(&targetContentOffset, velocity: velocity)
        recordTrace(
            "adjustTargetContentOffset",
            details: [
                "targetBefore": tracePoint(targetBefore),
                "targetAfter": tracePoint(targetContentOffset),
                "velocity": tracePoint(velocity)
            ]
        )
    }

    func dragEngineShouldScrollToTop(_ engine: DemoDragEngine) -> Bool {
        let result = shouldScrollToTop()
        recordTrace("shouldScrollToTop", details: ["result": String(result)])
        return result
    }

    func dragEngine(
        _ engine: DemoDragEngine,
        accessibilityDispositionFor direction: UIAccessibilityScrollDirection
    ) -> DemoAccessibilityDisposition {
        let result = accessibilityDisposition(for: direction)
        recordTrace(
            "accessibilityDisposition",
            details: [
                "direction": String(direction.rawValue),
                "result": String(describing: result)
            ]
        )
        return result
    }

    func dragEngine(_ engine: DemoDragEngine, didChangeDisplayHeight displayHeight: CGFloat) {
        recordTrace(
            "didChangeDisplayHeight",
            details: ["callbackHeight": String(format: "%.6f", displayHeight)]
        )
        publishHUD()
    }

    func dragEngine(_ engine: DemoDragEngine, didScrollFrom source: DemoMotionSource) {
        latestSource = "\(implementation.displayName)/\(source.displayName)"
        recordTrace("didScroll", details: ["source": source.displayName])
        publishHUD()
    }

    func dragEngine(
        _ engine: DemoDragEngine,
        willMoveToDisplayHeight displayHeight: CGFloat,
        reason: DemoMovementReason
    ) {
        recordTrace(
            "willMoveToDisplayHeight",
            details: [
                "target": String(format: "%.6f", displayHeight),
                "reason": reason.description
            ]
        )
        presentEvent("willMove → \(Int(displayHeight)) · \(reason)")
    }

    func dragEngine(_ engine: DemoDragEngine, didFinishMovement result: DemoMovementResult) {
        recordTrace(
            "didFinishMovement",
            details: [
                "requested": String(format: "%.6f", result.requestedDisplayHeight),
                "final": String(format: "%.6f", result.finalDisplayHeight),
                "reason": result.reason.description,
                "outcome": result.outcome.rawValue
            ]
        )
        presentEvent("didFinish · \(result.outcome.rawValue) @ \(Int(result.finalDisplayHeight))")
        traceRecorder.flush(reason: "didFinishMovement")
    }

    func dragEngineWillBeginDragging(_ engine: DemoDragEngine) {
        recordTrace("willBeginDragging")
        presentEvent("willBeginDragging")
    }

    func dragEngine(
        _ engine: DemoDragEngine,
        willEndDraggingWithVelocity velocity: CGPoint,
        resolvedTargetContentOffset: CGPoint
    ) {
        recordTrace(
            "willEndDragging",
            details: [
                "velocity": tracePoint(velocity),
                "resolvedTargetContentOffset": tracePoint(resolvedTargetContentOffset)
            ]
        )
        presentEvent(String(format: "willEnd · velocity %.2f", velocity.y))
    }

    func dragEngine(_ engine: DemoDragEngine, didEndDraggingWillDecelerate: Bool) {
        recordTrace(
            "didEndDragging",
            details: ["willDecelerate": String(didEndDraggingWillDecelerate)]
        )
        presentEvent("didEndDragging · decelerate \(didEndDraggingWillDecelerate ? "YES" : "NO")")
        if !didEndDraggingWillDecelerate {
            traceRecorder.flush(reason: "didEndDragging")
        }
    }

    func dragEngineDidEndDecelerating(_ engine: DemoDragEngine) {
        recordTrace("didEndDecelerating")
        presentEvent("didEndDecelerating")
        traceRecorder.flush(reason: "didEndDecelerating")
    }

    func dragEngineDidEndScrollingAnimation(_ engine: DemoDragEngine) {
        recordTrace("didEndScrollingAnimation")
        presentEvent("didEndScrollingAnimation")
        traceRecorder.flush(reason: "didEndScrollingAnimation")
    }

    func dragEngineDidScrollToTop(_ engine: DemoDragEngine) {
        recordTrace("didScrollToTop")
        presentEvent("didScrollToTop")
        traceRecorder.flush(reason: "didScrollToTop")
    }

    // MARK: - Floating controls

    private func configureBackButton() {
        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = DemoPalette.ink
        styleFloatingControl(backButton, cornerRadius: 23)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.accessibilityIdentifier = "demo.back"
        backButton.accessibilityLabel = "返回功能列表"
        backButton.addTarget(self, action: #selector(popScene), for: .touchUpInside)
    }

    private func configureImplementationTabs() {
        implementationTabs.selectedSegmentIndex = implementation == .objectiveC ? 0 : 1
        implementationTabs.selectedSegmentTintColor = implementation == .swift
            ? DemoPalette.indigo
            : DemoPalette.orange
        implementationTabs.setTitleTextAttributes(
            [
                .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: DemoPalette.secondaryInk
            ],
            for: .normal
        )
        implementationTabs.setTitleTextAttributes(
            [
                .font: UIFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: UIColor.white
            ],
            for: .selected
        )
        styleFloatingControl(implementationTabs, cornerRadius: 20)
        implementationTabs.translatesAutoresizingMaskIntoConstraints = false
        implementationTabs.accessibilityIdentifier = "demo.switchImplementation"
        implementationTabs.accessibilityLabel = "Demo 实现版本"
        implementationTabs.accessibilityValue = "当前为\(implementation.displayName)实现"
        implementationTabs.addTarget(self, action: #selector(selectImplementation(_:)), for: .valueChanged)
    }

    private func configureReadyMarker() {
        readyMarker.backgroundColor = .clear
        readyMarker.isUserInteractionEnabled = false
        readyMarker.isAccessibilityElement = true
        readyMarker.accessibilityIdentifier = "demo.ready"
        readyMarker.accessibilityLabel = "Demo ready"
        readyMarker.accessibilityValue = "false"
        readyMarker.translatesAutoresizingMaskIntoConstraints = false
    }

    private func styleFloatingControl(_ control: UIControl, cornerRadius: CGFloat) {
        control.backgroundColor = DemoPalette.surface.withAlphaComponent(0.96)
        control.layer.cornerRadius = cornerRadius
        control.layer.shadowColor = UIColor.black.cgColor
        control.layer.shadowOpacity = 0.14
        control.layer.shadowRadius = 12
        control.layer.shadowOffset = CGSize(width: 0, height: 5)
    }

    @objc private func popScene() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func selectImplementation(_ sender: UISegmentedControl) {
        let selectedImplementation: DemoImplementation = sender.selectedSegmentIndex == 0
            ? .objectiveC
            : .swift
        guard selectedImplementation != implementation else { return }
        guard let navigationController,
              let index = navigationController.viewControllers.firstIndex(where: { $0 === self }) else {
            sender.selectedSegmentIndex = implementation == .objectiveC ? 0 : 1
            return
        }
        let replacement = makeScene(implementation: selectedImplementation)
        replacement.loadViewIfNeeded()
        transferComparisonSettings(to: replacement)
        invalidateEngineIfNeeded()
        var controllers = navigationController.viewControllers
        controllers[index] = replacement
        navigationController.setViewControllers(controllers, animated: false)
    }

    // MARK: - Height safety

    private func availablePanelHeight(for viewportSize: CGSize) -> CGFloat {
        max(0, viewportSize.height - view.safeAreaInsets.top)
    }

    private func clampedDetentHeights(_ heights: [CGFloat], maximum: CGFloat) -> [CGFloat] {
        heights
            .map { engineSafeHeight($0, maximum: maximum) }
            .sorted()
            .reduce(into: [CGFloat]()) { result, value in
                guard result.last != value else { return }
                result.append(value)
            }
    }

    /// Both kernels intentionally interpret OC numeric inputs with Float32 semantics. Quantize
    /// before crossing the engine boundary, but always choose the representable value at or below
    /// the safe-area ceiling so conversion can never turn rounding into a real visual overflow.
    private func engineSafeHeight(_ height: CGFloat, maximum: CGFloat) -> CGFloat {
        let clamped = min(maximum, max(0, height))
        let floatValue = Float(clamped)
        guard floatValue.isFinite else { return 0 }
        if CGFloat(floatValue) <= maximum {
            return CGFloat(floatValue)
        }
        return CGFloat(floatValue.nextDown)
    }

    private func clampedNonSnappingRanges(
        _ ranges: [ClosedRange<CGFloat>],
        maximum: CGFloat
    ) -> [ClosedRange<CGFloat>] {
        ranges.compactMap { range in
            let lower = min(maximum, max(0, range.lowerBound))
            let upper = min(maximum, max(0, range.upperBound))
            return lower <= upper ? lower...upper : nil
        }
    }

    private func invalidateEngineIfNeeded() {
        guard !didInvalidateEngine else { return }
        didInvalidateEngine = true
        recordTrace("invalidateEngine")
        traceRecorder.flush(reason: "invalidateEngine")
        dragEngine.delegate = nil
        dragEngine.invalidate()
    }

    private func publishHUD(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastHUDPublication >= 0.08 else { return }
        lastHUDPublication = now
        eventHUD.update(
            displayHeight: dragEngine.displayHeight,
            source: latestSource,
            event: latestEvent,
            trace: traceRecorder.accessibilityValue
        )
    }

    private func presentationDisplayHeight() -> CGFloat {
        let hostLayer = dragScrollView.layer.presentation() ?? dragScrollView.layer
        let panelLayer = panelView.layer.presentation() ?? panelView.layer
        let height = hostLayer.bounds.height
            - (panelLayer.frame.minY - hostLayer.bounds.minY)
        return height.isFinite ? height : dragEngine.displayHeight
    }
}
