import UIKit

final class FreePanelViewController: DemoScenarioViewController, UIScrollViewDelegate {
    private enum ContentAmount: Int, Equatable {
        case smaller
        case equal
        case larger

        var code: String {
            switch self {
            case .smaller: return "A"
            case .equal: return "B"
            case .larger: return "C"
            }
        }
    }

    private struct ContentGeometry: Equatable {
        let amount: ContentAmount
        let boundsHeight: CGFloat
        let insetTop: CGFloat
        let insetBottom: CGFloat
    }

    private let contentScrollView = UIScrollView()
    private let contentAmountControl = UISegmentedControl(items: ["A 少于", "B 等于", "C 大于"])
    private let contentMetricsLabel = UILabel()
    private let contentDocumentView = UIView()
    private var contentHeightConstraint: NSLayoutConstraint?
    private var selectedContentAmount: ContentAmount = .larger
    private var appliedContentGeometry: ContentGeometry?
    private var shouldResetContentOffset = true

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

    override func transferComparisonSettings(to counterpart: DemoScenarioViewController) {
        guard let counterpart = counterpart as? FreePanelViewController else { return }
        counterpart.setContentAmount(selectedContentAmount, announcesChange: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        panelView.layoutIfNeeded()
        applyContentGeometry(resetOffset: false)
    }

    override func detentHeights(for viewportSize: CGSize) -> [CGFloat] { [] }

    override func minimumDisplayHeight(for viewportSize: CGSize) -> CGFloat? { 104 }

    override func initialDisplayHeight(for viewportSize: CGSize) -> CGFloat { 190 }

    override func comparisonScrollViews() -> [(name: String, scrollView: UIScrollView)] {
        [("freePanelContentScroll", contentScrollView)]
    }

    override func configureContent(in contentView: UIView) {
        let controlSurface = UIView()
        controlSurface.backgroundColor = DemoPalette.elevatedSurface
        controlSurface.layer.cornerRadius = 16
        controlSurface.translatesAutoresizingMaskIntoConstraints = false

        let amountTitle = UILabel()
        amountTitle.text = "内部有效内容高（contentSize + 上下 inset）"
        amountTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        amountTitle.textColor = DemoPalette.secondaryInk
        amountTitle.translatesAutoresizingMaskIntoConstraints = false

        let collapseButton = UIButton(type: .system)
        collapseButton.setTitle("收起", for: .normal)
        collapseButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        collapseButton.setTitleColor(DemoPalette.orange, for: .normal)
        collapseButton.backgroundColor = DemoPalette.orange.withAlphaComponent(0.12)
        collapseButton.layer.cornerRadius = 10
        collapseButton.accessibilityIdentifier = "free.collapse"
        collapseButton.addTarget(self, action: #selector(collapsePanel), for: .touchUpInside)
        collapseButton.translatesAutoresizingMaskIntoConstraints = false

        contentAmountControl.selectedSegmentIndex = selectedContentAmount.rawValue
        contentAmountControl.accessibilityIdentifier = "free.contentAmount"
        contentAmountControl.accessibilityLabel = "内部 ScrollView 内容高度"
        contentAmountControl.addTarget(self, action: #selector(contentAmountChanged(_:)), for: .valueChanged)
        contentAmountControl.translatesAutoresizingMaskIntoConstraints = false

        contentMetricsLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        contentMetricsLabel.textColor = DemoPalette.ink
        contentMetricsLabel.numberOfLines = 2
        contentMetricsLabel.isAccessibilityElement = true
        contentMetricsLabel.accessibilityIdentifier = "free.contentGeometry"
        contentMetricsLabel.accessibilityLabel = "内部 ScrollView 内容几何"
        contentMetricsLabel.translatesAutoresizingMaskIntoConstraints = false

        controlSurface.addSubview(amountTitle)
        controlSurface.addSubview(collapseButton)
        controlSurface.addSubview(contentAmountControl)
        controlSurface.addSubview(contentMetricsLabel)

        let markerTexts = [
            "功能：连续拖动自由面板，不配置中间吸附点",
            "操作：切换 A / B / C，再在此内容区向上滑动",
            "A / B 的内部滚动距离为 0，C 提供 600pt 以上滚动范围",
            "顶部 HUD 可观察 OC / Swift 的回调与运动来源"
        ]
        let markers = (1...18).map { index -> UIView in
            let marker = UIView()
            marker.backgroundColor = index.isMultiple(of: 2)
                ? DemoPalette.orange.withAlphaComponent(0.11)
                : DemoPalette.purple.withAlphaComponent(0.09)
            marker.layer.cornerRadius = 13
            marker.heightAnchor.constraint(equalToConstant: 46).isActive = true

            let label = UILabel()
            label.text = index <= markerTexts.count
                ? markerTexts[index - 1]
                : String(format: "内部内容区块 %02d", index)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = DemoPalette.secondaryInk
            label.numberOfLines = 2
            label.isAccessibilityElement = index <= markerTexts.count
            if index <= markerTexts.count {
                label.accessibilityIdentifier = "free.instructions.\(index)"
            }
            label.translatesAutoresizingMaskIntoConstraints = false
            marker.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: marker.leadingAnchor, constant: 14),
                label.trailingAnchor.constraint(lessThanOrEqualTo: marker.trailingAnchor, constant: -14),
                label.centerYAnchor.constraint(equalTo: marker.centerYAnchor)
            ])
            return marker
        }
        let stack = UIStackView(arrangedSubviews: markers)
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentDocumentView.backgroundColor = DemoPalette.surface
        contentDocumentView.layer.cornerRadius = 18
        contentDocumentView.clipsToBounds = true
        contentDocumentView.translatesAutoresizingMaskIntoConstraints = false
        contentDocumentView.addSubview(stack)

        contentScrollView.alwaysBounceVertical = false
        contentScrollView.scrollsToTop = false
        contentScrollView.delegate = self
        contentScrollView.contentInsetAdjustmentBehavior = .never
        contentScrollView.contentInset = UIEdgeInsets(top: 12, left: 0, bottom: 16, right: 0)
        contentScrollView.verticalScrollIndicatorInsets = contentScrollView.contentInset
        contentScrollView.accessibilityIdentifier = "freePanelContentScroll"
        contentScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(controlSurface)
        contentView.addSubview(contentScrollView)
        contentScrollView.addSubview(contentDocumentView)

        let contentHeightConstraint = contentDocumentView.heightAnchor.constraint(equalToConstant: 1)
        self.contentHeightConstraint = contentHeightConstraint

        NSLayoutConstraint.activate([
            controlSurface.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            controlSurface.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            controlSurface.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            controlSurface.heightAnchor.constraint(equalToConstant: 112),

            amountTitle.leadingAnchor.constraint(equalTo: controlSurface.leadingAnchor, constant: 12),
            amountTitle.topAnchor.constraint(equalTo: controlSurface.topAnchor, constant: 9),
            amountTitle.trailingAnchor.constraint(lessThanOrEqualTo: collapseButton.leadingAnchor, constant: -8),

            collapseButton.trailingAnchor.constraint(equalTo: controlSurface.trailingAnchor, constant: -10),
            collapseButton.centerYAnchor.constraint(equalTo: amountTitle.centerYAnchor),
            collapseButton.widthAnchor.constraint(equalToConstant: 52),
            collapseButton.heightAnchor.constraint(equalToConstant: 26),

            contentAmountControl.leadingAnchor.constraint(equalTo: controlSurface.leadingAnchor, constant: 10),
            contentAmountControl.trailingAnchor.constraint(equalTo: controlSurface.trailingAnchor, constant: -10),
            contentAmountControl.topAnchor.constraint(equalTo: amountTitle.bottomAnchor, constant: 6),
            contentAmountControl.heightAnchor.constraint(equalToConstant: 32),

            contentMetricsLabel.leadingAnchor.constraint(equalTo: controlSurface.leadingAnchor, constant: 12),
            contentMetricsLabel.trailingAnchor.constraint(equalTo: controlSurface.trailingAnchor, constant: -12),
            contentMetricsLabel.topAnchor.constraint(equalTo: contentAmountControl.bottomAnchor, constant: 5),
            contentMetricsLabel.bottomAnchor.constraint(lessThanOrEqualTo: controlSurface.bottomAnchor, constant: -6),

            contentScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentScrollView.topAnchor.constraint(equalTo: controlSurface.bottomAnchor, constant: 10),
            contentScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            contentDocumentView.leadingAnchor.constraint(
                equalTo: contentScrollView.contentLayoutGuide.leadingAnchor,
                constant: 18
            ),
            contentDocumentView.trailingAnchor.constraint(
                equalTo: contentScrollView.contentLayoutGuide.trailingAnchor,
                constant: -18
            ),
            contentDocumentView.topAnchor.constraint(equalTo: contentScrollView.contentLayoutGuide.topAnchor),
            contentDocumentView.bottomAnchor.constraint(equalTo: contentScrollView.contentLayoutGuide.bottomAnchor),
            contentDocumentView.widthAnchor.constraint(
                equalTo: contentScrollView.frameLayoutGuide.widthAnchor,
                constant: -36
            ),
            contentHeightConstraint,

            stack.leadingAnchor.constraint(equalTo: contentDocumentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: contentDocumentView.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: contentDocumentView.topAnchor, constant: 12)
        ])
    }

    @objc private func contentAmountChanged(_ sender: UISegmentedControl) {
        guard let amount = ContentAmount(rawValue: sender.selectedSegmentIndex) else { return }
        setContentAmount(amount, announcesChange: true)
    }

    private func setContentAmount(_ amount: ContentAmount, announcesChange: Bool) {
        selectedContentAmount = amount
        contentAmountControl.selectedSegmentIndex = amount.rawValue
        appliedContentGeometry = nil
        shouldResetContentOffset = true
        applyContentGeometry(resetOffset: true)
        if announcesChange {
            recordEvent("内部内容切换为 \(amount.code) · \(displayRelation(for: amount))")
        }
    }

    private func applyContentGeometry(resetOffset: Bool) {
        let boundsHeight = contentScrollView.bounds.height
        let inset = contentScrollView.adjustedContentInset
        guard boundsHeight > 0,
              let contentHeightConstraint else { return }

        let geometry = ContentGeometry(
            amount: selectedContentAmount,
            boundsHeight: boundsHeight,
            insetTop: inset.top,
            insetBottom: inset.bottom
        )
        let geometryChanged = geometry != appliedContentGeometry
        let needsOffsetReset = resetOffset || shouldResetContentOffset
        guard geometryChanged || needsOffsetReset else {
            updateContentMetrics()
            return
        }

        let equalContentHeight = max(0, boundsHeight - inset.top - inset.bottom)
        let targetContentHeight: CGFloat
        switch selectedContentAmount {
        case .smaller:
            let underflow = min(80, equalContentHeight * 0.5)
            targetContentHeight = max(0, equalContentHeight - underflow)
        case .equal:
            targetContentHeight = equalContentHeight
        case .larger:
            targetContentHeight = equalContentHeight + max(600, boundsHeight)
        }

        contentHeightConstraint.constant = targetContentHeight
        contentScrollView.layoutIfNeeded()
        appliedContentGeometry = geometry

        let minimumOffsetY = -contentScrollView.adjustedContentInset.top
        let maximumOffsetY = max(
            targetContentHeight + contentScrollView.adjustedContentInset.bottom - boundsHeight,
            minimumOffsetY
        )
        if needsOffsetReset || selectedContentAmount != .larger {
            contentScrollView.setContentOffset(
                CGPoint(x: 0, y: minimumOffsetY),
                animated: false
            )
            shouldResetContentOffset = false
        } else {
            let clampedOffsetY = min(maximumOffsetY, max(minimumOffsetY, contentScrollView.contentOffset.y))
            if clampedOffsetY != contentScrollView.contentOffset.y {
                contentScrollView.setContentOffset(
                    CGPoint(x: contentScrollView.contentOffset.x, y: clampedOffsetY),
                    animated: false
                )
            }
        }
        updateContentMetrics()
        dragEngine.reloadScrollMetrics()
    }

    private func updateContentMetrics() {
        let boundsHeight = contentScrollView.bounds.height
        guard boundsHeight > 0 else { return }
        let inset = contentScrollView.adjustedContentInset
        let contentHeight = contentScrollView.contentSize.height
        let effectiveHeight = contentHeight + inset.top + inset.bottom
        let scrollableDistance = max(0, effectiveHeight - boundsHeight)
        let minimumOffsetY = -inset.top
        let maximumOffsetY = max(contentHeight + inset.bottom - boundsHeight, minimumOffsetY)
        let difference = effectiveHeight - boundsHeight
        let pixel = 1 / max(view.window?.screen.scale ?? traitCollection.displayScale, 1)
        let relation: String
        let symbol: String
        if difference < -pixel {
            relation = "less"
            symbol = "<"
        } else if difference > pixel {
            relation = "greater"
            symbol = ">"
        } else {
            relation = "equal"
            symbol = "="
        }

        contentMetricsLabel.text = String(
            format: "有效 %.1f %@ 可视 %.1f\ncontent %.1f + inset %.1f/%.1f",
            effectiveHeight,
            symbol,
            boundsHeight,
            contentHeight,
            inset.top,
            inset.bottom
        )
        let marker = String(
            format: "mode=%@;content=%.6f;bounds=%.6f;insetTop=%.6f;insetBottom=%.6f;effective=%.6f;scrollable=%.6f;offsetY=%.6f;minimumOffsetY=%.6f;maximumOffsetY=%.6f;relation=%@",
            selectedContentAmount.code,
            contentHeight,
            boundsHeight,
            inset.top,
            inset.bottom,
            effectiveHeight,
            scrollableDistance,
            contentScrollView.contentOffset.y,
            minimumOffsetY,
            maximumOffsetY,
            relation
        )
        contentMetricsLabel.accessibilityValue = marker
        contentScrollView.accessibilityValue = marker
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === contentScrollView else { return }
        updateContentMetrics()
    }

    private func displayRelation(for amount: ContentAmount) -> String {
        switch amount {
        case .smaller: return "有效内容小于可视区"
        case .equal: return "有效内容等于可视区"
        case .larger: return "有效内容大于可视区"
        }
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
            detail: "功能：比较三档吸附、非吸附区、系统滚动动画、View 动画和程序化移动。\n操作：先拖动面板头部并释放观察吸附；再切换动画方式并点击目标高度；开启非吸附区后在低档与中档之间释放；最后运行中断演示。控件列表由组件按默认规则捕获，在面板展开后可继续滚动访问。",
            tint: DemoPalette.purple
        )

        let styleCard = DemoCardView(
            title: "移动实现",
            detail: "automatic 先询问 behavior provider，再使用 configuration 默认值。",
            tint: DemoPalette.purple
        )

        let buttonsCard = DemoCardView(
            title: "目标高度",
            detail: "completion 与 event delegate 对同一次 transaction 各自只完成一次。",
            tint: DemoPalette.blue
        )
        let low = movementButton(title: "最低", tag: 0)
        let middle = movementButton(title: "中间", tag: 1)
        let high = movementButton(title: "最高", tag: 2)
        let nearest = DemoControlFactory.button(title: "最近吸附", tint: DemoPalette.teal)
        nearest.accessibilityIdentifier = "movement.nearest"
        nearest.addTarget(self, action: #selector(settleNearest), for: .touchUpInside)
        let interruptButton = DemoControlFactory.button(title: "中断演示", tint: DemoPalette.red)
        interruptButton.accessibilityIdentifier = "movement.interrupt"
        interruptButton.addTarget(self, action: #selector(runInterruptionDemo), for: .touchUpInside)

        let rangeCard = DemoCardView(
            title: "释放目标",
            detail: "开启后，中低档之间会出现一段橙色语义的非吸附区；手指释放可保留系统预测位置。",
            tint: DemoPalette.orange
        )
        nonSnappingSwitch.addTarget(self, action: #selector(nonSnappingChanged), for: .valueChanged)

        // Keep every movement control outside the scrollable documentation. This preserves a
        // stable operation surface while the document itself participates in the component's
        // default panel/inner-scroll handoff.
        let quickActions = UIView()
        quickActions.backgroundColor = DemoPalette.elevatedSurface
        quickActions.layer.cornerRadius = 16
        quickActions.translatesAutoresizingMaskIntoConstraints = false
        let targetRow = UIStackView(arrangedSubviews: [low, middle, high])
        targetRow.axis = .horizontal
        targetRow.distribution = .fillEqually
        targetRow.spacing = 8
        let optionRow = UIStackView(arrangedSubviews: [
            DemoControlFactory.caption("非吸附"),
            nonSnappingSwitch,
            nearest,
            interruptButton
        ])
        optionRow.axis = .horizontal
        optionRow.alignment = .center
        optionRow.spacing = 8
        let quickStack = UIStackView(arrangedSubviews: [styleControl, targetRow, optionRow])
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
            arrangedSubviews: [instructionsCard, styleCard, buttonsCard, rangeCard, transactionCard]
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
            quickActions.heightAnchor.constraint(equalToConstant: 160),

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
