import UIKit

final class FreePanelViewController: DemoScenarioViewController {
    private let contentScrollView = UIScrollView()

    init(implementation: DemoImplementation = .swift) {
        super.init(
            title: "自由面板",
            subtitle: "没有中间 detent，释放后保留系统预测位置",
            accent: DemoPalette.orange,
            implementation: implementation
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeScene(implementation: DemoImplementation) -> DemoScenarioViewController {
        FreePanelViewController(implementation: implementation)
    }

    override func detentHeights(for viewportSize: CGSize) -> [CGFloat] { [] }

    override func minimumDisplayHeight(for viewportSize: CGSize) -> CGFloat? { 104 }

    override func initialDisplayHeight(for viewportSize: CGSize) -> CGFloat { 190 }

    override func comparisonScrollViews() -> [(name: String, scrollView: UIScrollView)] {
        [("freePanelContentScroll", contentScrollView)]
    }

    override func configureContent(in contentView: UIView) {
        let first = DemoCardView(
            title: "功能与操作",
            detail: "功能：演示没有吸附点时，固定尺寸面板在最小与最大展示高度之间连续移动。\n操作：在面板头部上下拖动并快速甩动，观察面板停在连续位置；内容区可独立滚动，点击底部按钮验证程序化收起。",
            tint: DemoPalette.orange
        )
        let second = DemoCardView(
            title: "连续停止",
            detail: "这里不配置 detentHeights。慢拖或快速甩动后，面板可以停在最小与最大边界之间的连续位置。",
            tint: DemoPalette.purple
        )
        let third = DemoCardView(
            title: "实时事件",
            detail: "顶部黑色 HUD 显示展示高度、当前运动来源以及最新生命周期事件。",
            tint: DemoPalette.teal
        )

        let collapseButton = DemoControlFactory.button(title: "回到最小展示高度", tint: DemoPalette.orange)
        collapseButton.accessibilityIdentifier = "free.collapse"
        collapseButton.addTarget(self, action: #selector(collapsePanel), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [first, second, third, collapseButton])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentScrollView.alwaysBounceVertical = true
        contentScrollView.scrollsToTop = false
        contentScrollView.accessibilityIdentifier = "freePanelContentScroll"
        contentScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentScrollView)
        contentScrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            contentScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentScrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            contentScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            contentScrollView.contentLayoutGuide.widthAnchor.constraint(
                equalTo: contentScrollView.frameLayoutGuide.widthAnchor
            ),
            stack.leadingAnchor.constraint(
                equalTo: contentScrollView.contentLayoutGuide.leadingAnchor,
                constant: 18
            ),
            stack.trailingAnchor.constraint(
                equalTo: contentScrollView.contentLayoutGuide.trailingAnchor,
                constant: -18
            ),
            stack.topAnchor.constraint(equalTo: contentScrollView.contentLayoutGuide.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: contentScrollView.contentLayoutGuide.bottomAnchor, constant: -18)
        ])
    }

    override func canCapture(_ scrollView: UIScrollView) -> Bool {
        scrollView !== contentScrollView
    }

    override func gestureStrategy(
        for gesture: UIGestureRecognizer,
        otherGesture: UIGestureRecognizer
    ) -> DemoGestureStrategy? {
        otherGesture === contentScrollView.panGestureRecognizer ? .otherFirst : nil
    }

    @objc private func collapsePanel() {
        dragEngine.move(
            toDisplayHeight: 104,
            animated: true,
            options: .init(),
            completion: nil
        )
    }
}

final class MovementLabViewController: DemoScenarioViewController {
    private let styleControl = UISegmentedControl(items: ["自动", "系统", "View"])
    private let nonSnappingSwitch = UISwitch()
    private let resultLabel = DemoControlFactory.valueLabel("尚未发起程序化移动")
    private let controlsScrollView = UIScrollView()
    private var latestViewportSize = CGSize.zero

    init(implementation: DemoImplementation = .swift) {
        super.init(
            title: "吸附与程序化移动",
            subtitle: "detent、nonSnappingRanges 与 movement transaction",
            accent: DemoPalette.purple,
            implementation: implementation
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeScene(implementation: DemoImplementation) -> DemoScenarioViewController {
        MovementLabViewController(implementation: implementation)
    }

    override func transferComparisonSettings(to counterpart: DemoScenarioViewController) {
        guard let counterpart = counterpart as? MovementLabViewController else { return }
        counterpart.styleControl.selectedSegmentIndex = styleControl.selectedSegmentIndex
        counterpart.nonSnappingSwitch.isOn = nonSnappingSwitch.isOn
        counterpart.updateNonSnappingRange()
    }

    override func initialDisplayHeight(for viewportSize: CGSize) -> CGFloat {
        detentHeights(for: viewportSize)[1]
    }

    override func viewportDidChange(to viewportSize: CGSize) {
        latestViewportSize = viewportSize
        updateNonSnappingRange()
    }

    override func applyInitialConfiguration() {
        var configuration = dragEngine.configuration
        configuration.movement.usesSpring = true
        configuration.movement.speed = 350
        // Keep View-driven settling observable long enough for the rotation comparison to
        // interrupt it after UIKit has actually started relaying the new viewport.
        configuration.movement.maximumDuration = 0.9
        dragEngine.configuration = configuration
    }

    override func comparisonScrollViews() -> [(name: String, scrollView: UIScrollView)] {
        [("movementControlsScroll", controlsScrollView)]
    }

    override func configureContent(in contentView: UIView) {
        styleControl.selectedSegmentIndex = 0
        styleControl.accessibilityIdentifier = "movement.style"
        nonSnappingSwitch.accessibilityIdentifier = "movement.range"
        resultLabel.accessibilityIdentifier = "movement.result"

        let instructionsCard = DemoCardView(
            title: "功能与操作",
            detail: "功能：比较三档吸附、非吸附区、系统滚动动画、View 动画和程序化移动。\n操作：先拖动面板头部并释放观察吸附；再切换动画方式并点击目标高度；开启非吸附区后在低档与中档之间释放；最后运行中断演示。内容区可独立滚动以访问全部控件。",
            tint: DemoPalette.purple
        )

        let styleCard = DemoCardView(
            title: "移动实现",
            detail: "automatic 先询问 behavior provider，再使用 configuration 默认值。",
            tint: DemoPalette.purple
        )
        styleCard.stackView.addArrangedSubview(styleControl)

        let buttonsCard = DemoCardView(
            title: "目标高度",
            detail: "completion 与 event delegate 对同一次 transaction 各自只完成一次。",
            tint: DemoPalette.blue
        )
        let low = movementButton(title: "最低", tag: 0)
        let middle = movementButton(title: "中间", tag: 1)
        let high = movementButton(title: "最高", tag: 2)
        let nearest = DemoControlFactory.button(title: "吸附到最近点", tint: DemoPalette.teal)
        nearest.accessibilityIdentifier = "movement.nearest"
        nearest.addTarget(self, action: #selector(settleNearest), for: .touchUpInside)
        let interruptButton = DemoControlFactory.button(title: "运行中断演示", tint: DemoPalette.red)
        interruptButton.accessibilityIdentifier = "movement.interrupt"
        interruptButton.addTarget(self, action: #selector(runInterruptionDemo), for: .touchUpInside)
        buttonsCard.stackView.addArrangedSubview(buttonGrid([low, middle]))

        let rangeCard = DemoCardView(
            title: "释放目标",
            detail: "开启后，中低档之间会出现一段橙色语义的非吸附区；手指释放可保留系统预测位置。",
            tint: DemoPalette.orange
        )
        nonSnappingSwitch.addTarget(self, action: #selector(nonSnappingChanged), for: .valueChanged)

        // These two actions must remain reachable while the panel itself is between detents. If
        // they lived inside the long controls document, scrolling to them could move the host and
        // turn nearest into an accidental no-op at an existing detent.
        let quickActions = UIView()
        quickActions.backgroundColor = DemoPalette.elevatedSurface
        quickActions.layer.cornerRadius = 16
        quickActions.translatesAutoresizingMaskIntoConstraints = false
        let quickRow = UIStackView(arrangedSubviews: [
            DemoControlFactory.caption("非吸附"),
            nonSnappingSwitch,
            high,
            nearest
        ])
        quickRow.axis = .horizontal
        quickRow.alignment = .center
        quickRow.spacing = 10
        quickRow.translatesAutoresizingMaskIntoConstraints = false
        let quickStack = UIStackView(arrangedSubviews: [quickRow, interruptButton])
        quickStack.axis = .vertical
        quickStack.spacing = 8
        quickStack.translatesAutoresizingMaskIntoConstraints = false
        quickActions.addSubview(quickStack)
        NSLayoutConstraint.activate([
            quickStack.leadingAnchor.constraint(equalTo: quickActions.leadingAnchor, constant: 14),
            quickStack.trailingAnchor.constraint(equalTo: quickActions.trailingAnchor, constant: -14),
            quickStack.topAnchor.constraint(equalTo: quickActions.topAnchor, constant: 10),
            quickStack.bottomAnchor.constraint(equalTo: quickActions.bottomAnchor, constant: -10)
        ])

        let transactionCard = DemoCardView(
            title: "Transaction 中断",
            detail: "点击后短暂倒计时，再发起 0.9 秒 View 动画，并在 180ms 后用新目标打断。Swift 会给出 completed / interrupted 等 typed outcome；原 OC completion 没有 outcome，适配层只能显示 legacyCompletion，不能严格对齐中断语义。",
            tint: DemoPalette.red
        )
        transactionCard.stackView.addArrangedSubview(resultLabel)

        let stack = UIStackView(
            // Keep transaction and target controls near the visible top. Besides making the demo
            // easier to operate, this guarantees that starting either action does not first scroll
            // the independent controls view far enough to move the host to its maximum detent.
            arrangedSubviews: [transactionCard, buttonsCard, rangeCard, styleCard, instructionsCard]
        )
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        controlsScrollView.alwaysBounceVertical = true
        controlsScrollView.scrollsToTop = false
        controlsScrollView.accessibilityIdentifier = "movementControlsScroll"
        controlsScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(quickActions)
        contentView.addSubview(controlsScrollView)
        controlsScrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            quickActions.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            quickActions.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            quickActions.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            quickActions.heightAnchor.constraint(equalToConstant: 120),

            controlsScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            controlsScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            controlsScrollView.topAnchor.constraint(equalTo: quickActions.bottomAnchor, constant: 8),
            controlsScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            controlsScrollView.contentLayoutGuide.widthAnchor.constraint(
                equalTo: controlsScrollView.frameLayoutGuide.widthAnchor
            ),
            stack.leadingAnchor.constraint(
                equalTo: controlsScrollView.contentLayoutGuide.leadingAnchor,
                constant: 18
            ),
            stack.trailingAnchor.constraint(
                equalTo: controlsScrollView.contentLayoutGuide.trailingAnchor,
                constant: -18
            ),
            stack.topAnchor.constraint(equalTo: controlsScrollView.contentLayoutGuide.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: controlsScrollView.contentLayoutGuide.bottomAnchor, constant: -18)
        ])
    }

    override func canCapture(_ scrollView: UIScrollView) -> Bool {
        // This scroll view exists only to keep all controls reachable on compact screens. It is
        // deliberately independent so it does not become part of the panel-handoff experiment.
        scrollView !== controlsScrollView
    }

    override func gestureStrategy(
        for gesture: UIGestureRecognizer,
        otherGesture: UIGestureRecognizer
    ) -> DemoGestureStrategy? {
        otherGesture === controlsScrollView.panGestureRecognizer ? .otherFirst : nil
    }

    private func movementButton(title: String, tag: Int) -> UIButton {
        let button = DemoControlFactory.button(title: title, tint: DemoPalette.purple)
        button.tag = tag
        switch tag {
        case 0: button.accessibilityIdentifier = "movement.low"
        case 1: button.accessibilityIdentifier = "movement.middle"
        case 2: button.accessibilityIdentifier = "movement.high"
        default: break
        }
        button.addTarget(self, action: #selector(moveToDetent(_:)), for: .touchUpInside)
        return button
    }

    private func buttonGrid(_ buttons: [UIButton]) -> UIStackView {
        let rows = stride(from: 0, to: buttons.count, by: 2).map { index -> UIStackView in
            let end = min(index + 2, buttons.count)
            return UIStackView(arrangedSubviews: Array(buttons[index..<end]))
        }
        rows.forEach {
            $0.axis = .horizontal
            $0.distribution = .fillEqually
            $0.spacing = 9
        }
        let grid = UIStackView(arrangedSubviews: rows)
        grid.axis = .vertical
        grid.spacing = 9
        return grid
    }

    private var selectedStyle: DemoMovementStyle {
        switch styleControl.selectedSegmentIndex {
        case 1: return .systemScroll
        case 2: return .viewAnimation
        default: return .automatic
        }
    }

    @objc private func moveToDetent(_ sender: UIButton) {
        let detents = detentHeights(for: dragScrollView.bounds.size)
        guard detents.indices.contains(sender.tag) else { return }
        performMove(to: detents[sender.tag], style: selectedStyle, label: sender.currentTitle ?? "移动")
    }

    @objc private func settleNearest() {
        dragEngine.settleToNearestDetent(
            animated: true,
            options: .init(style: selectedStyle)
        ) { [weak self] result in
            self?.showResult(prefix: "最近点", result: result)
        }
    }

    @objc private func nonSnappingChanged() {
        updateNonSnappingRange()
        recordEvent(nonSnappingSwitch.isOn ? "非吸附区已开启" : "非吸附区已关闭")
    }

    private func updateNonSnappingRange() {
        guard latestViewportSize.height > 0, nonSnappingSwitch.isOn else {
            dragEngine.nonSnappingRanges = []
            return
        }
        let detents = detentHeights(for: latestViewportSize)
        let lower = detents[0] + 45
        let upper = detents[1] - 35
        dragEngine.nonSnappingRanges = lower < upper ? [lower...upper] : []
    }

    @objc private func runInterruptionDemo() {
        let detents = detentHeights(for: dragScrollView.bounds.size)
        guard detents.count == 3 else { return }
        resultLabel.text = "0.8 秒后开始中断演示…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.resultLabel.text = "第一段动画已开始…"
            self.dragEngine.move(
                toDisplayHeight: detents[2],
                animated: true,
                options: .init(style: .viewAnimation, duration: 0.9)
            ) { [weak self] result in
                self?.appendResult(prefix: "第一段", result: result)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self else { return }
                self.dragEngine.move(
                    toDisplayHeight: detents[1],
                    animated: true,
                    options: .init(style: .viewAnimation, duration: 0.9)
                ) { [weak self] result in
                    self?.appendResult(prefix: "第二段", result: result)
                }
                if ProcessInfo.processInfo.environment[
                    "BODRAGSCROLL_AUTO_ROTATE_DURING_INTERRUPTION"
                ] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.requestLandscapeDuringInterruptionUITest()
                    }
                }
            }
        }
    }

    private func requestLandscapeDuringInterruptionUITest() {
        guard #available(iOS 16.0, *), let windowScene = view.window?.windowScene else { return }
        recordEvent("UI 测试：动画中请求横屏")
        let preferences = UIWindowScene.GeometryPreferences.iOS(
            interfaceOrientations: .landscapeLeft
        )
        windowScene.requestGeometryUpdate(preferences) { [weak self] error in
            self?.recordEvent("UI 测试横屏失败：\(error.localizedDescription)")
        }
    }

    private func performMove(to height: CGFloat, style: DemoMovementStyle, label: String) {
        dragEngine.move(
            toDisplayHeight: height,
            animated: true,
            options: .init(style: style)
        ) { [weak self] result in
            self?.showResult(prefix: label, result: result)
        }
    }

    private func showResult(prefix: String, result: DemoMovementResult) {
        recordMovementCompletion(result, label: prefix)
        resultLabel.text = "\(prefix)：\(outcomeName(result.outcome)) @ \(Int(result.finalDisplayHeight))"
    }

    private func appendResult(prefix: String, result: DemoMovementResult) {
        recordMovementCompletion(result, label: prefix)
        let line = "\(prefix)：\(outcomeName(result.outcome)) @ \(Int(result.finalDisplayHeight))"
        if resultLabel.text == "第一段动画已开始…" {
            resultLabel.text = line
        } else {
            resultLabel.text = [resultLabel.text, line].compactMap { $0 }.joined(separator: "\n")
        }
    }

    private func outcomeName(_ outcome: DemoMovementOutcome) -> String {
        switch outcome {
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .interrupted: return "interrupted"
        case .legacyCompletion: return "legacyCompletion"
        }
    }
}
