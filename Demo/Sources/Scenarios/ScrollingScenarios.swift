import UIKit

final class TableHandoffViewController: DemoScenarioViewController {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let dataSource = DemoTableDataSource(rowCount: 54, prefix: "连续列表")
    private let placementControl = UISegmentedControl(items: ["自动", "全展开", "固定", "触点"])
    private let forceInnerTopBounceSwitch = UISwitch()
    private let rowCountLabel = DemoControlFactory.valueLabel("")

    init(implementation: DemoImplementation = .swift) {
        super.init(
            title: "列表连续交接",
            subtitle: "真实触摸自动捕获 UITableView，不调用 internal API",
            accent: DemoPalette.blue,
            implementation: implementation
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeScene(implementation: DemoImplementation) -> DemoScenarioViewController {
        TableHandoffViewController(implementation: implementation)
    }

    override func transferComparisonSettings(to counterpart: DemoScenarioViewController) {
        guard let counterpart = counterpart as? TableHandoffViewController else { return }
        counterpart.placementControl.selectedSegmentIndex = placementControl.selectedSegmentIndex
        counterpart.forceInnerTopBounceSwitch.isOn = forceInnerTopBounceSwitch.isOn
        counterpart.dataSource.rowCount = dataSource.rowCount
        counterpart.tableView.reloadData()
        counterpart.updateRowCountLabel()
        counterpart.applyPlacement()
    }

    override func initialDisplayHeight(for viewportSize: CGSize) -> CGFloat { 250 }

    override func comparisonScrollViews() -> [(name: String, scrollView: UIScrollView)] {
        [("innerTable", tableView)]
    }

    override func applyInitialConfiguration() {
        var configuration = dragEngine.configuration
        configuration.handoff.mode = .coordinated
        configuration.handoff.innerScrollPlacement = .automatic
        dragEngine.configuration = configuration
        dragScrollView.scrollsToTop = true
    }

    override func configureContent(in contentView: UIView) {
        tableView.backgroundColor = DemoPalette.surface
        tableView.separatorColor = DemoPalette.tertiaryInk.withAlphaComponent(0.2)
        tableView.rowHeight = 62
        tableView.dataSource = dataSource
        tableView.scrollsToTop = false
        tableView.accessibilityIdentifier = "innerTable"
        tableView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: contentView.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        tableView.tableHeaderView = makeTableHeader()
        updateRowCountLabel()
    }

    override func viewportDidChange(to viewportSize: CGSize) {
        guard placementControl.selectedSegmentIndex == 2 else { return }
        applyPlacement()
    }

    override func adjustCaptureProposal(_ proposal: inout DemoCaptureProposal) {
        let primary = proposal.primaryCandidate?.scrollView.accessibilityIdentifier ?? "none"
        recordEvent("capture · \(proposal.candidates.count) candidate(s) · primary \(primary)")
    }

    private func makeTableHeader() -> UIView {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 350))
        header.backgroundColor = DemoPalette.elevatedSurface

        let title = UILabel()
        title.text = "功能与操作"
        title.font = .systemFont(ofSize: 17, weight: .bold)
        title.textColor = DemoPalette.ink

        let detail = DemoControlFactory.caption(
            "功能：演示面板与 UITableView 在同一条组合滚动轴上连续交接，并比较四种内部区间放置方式。\n操作：从列表内向上滑，观察面板先展开、随后列表接管；列表回到顶部后继续向下滑，观察运动交还面板。切换放置方式后请抬手并重新触摸；增减行数可验证内容刷新。\n对齐说明：OC 临时适配层调用原 .m 的内部刷新入口；它不是旧版公开 API。"
        )
        placementControl.selectedSegmentIndex = 0
        placementControl.accessibilityIdentifier = "handoff.placement"
        forceInnerTopBounceSwitch.accessibilityIdentifier = "handoff.forceInnerTopBounce"
        rowCountLabel.accessibilityIdentifier = "handoff.rowCount"
        placementControl.addTarget(self, action: #selector(placementChanged), for: .valueChanged)
        forceInnerTopBounceSwitch.addTarget(
            self,
            action: #selector(placementChanged),
            for: .valueChanged
        )

        let add = DemoControlFactory.button(title: "+ 10 行", tint: DemoPalette.blue)
        let remove = DemoControlFactory.button(title: "− 10 行", tint: DemoPalette.orange)
        add.accessibilityIdentifier = "handoff.add"
        remove.accessibilityIdentifier = "handoff.remove"
        add.addTarget(self, action: #selector(addRows), for: .touchUpInside)
        remove.addTarget(self, action: #selector(removeRows), for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [add, remove])
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 10

        let row = UIStackView(arrangedSubviews: [rowCountLabel, buttons])
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .fillProportionally
        row.spacing = 12

        let forceBounceRow = DemoControlFactory.row(
            label: "强制列表顶部回弹",
            control: forceInnerTopBounceSwitch
        )
        let stack = UIStackView(
            arrangedSubviews: [title, detail, placementControl, forceBounceRow, row]
        )
        stack.axis = .vertical
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 16)
        ])
        return header
    }

    @objc private func placementChanged() {
        applyPlacement()
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
        dragEngine.reloadScrollMetrics()
        recordEvent("placement 已切换，抬手后重新触摸生效")
    }

    private func applyPlacement() {
        var configuration = dragEngine.configuration
        switch placementControl.selectedSegmentIndex {
        case 1:
            configuration.handoff.innerScrollPlacement = .afterPanelFullyDisplayed
        case 2:
            let detents = detentHeights(for: dragScrollView.bounds.size)
            configuration.handoff.innerScrollPlacement = .atDisplayHeight(
                displayHeightForEngine(detents[1], viewportSize: dragScrollView.bounds.size)
            )
        case 3:
            configuration.handoff.innerScrollPlacement = .fromTouchedPosition
        default:
            configuration.handoff.innerScrollPlacement = .automatic
        }
        configuration.bounce.forcesInnerTopBounce = forceInnerTopBounceSwitch.isOn
        configuration.bounce.preferredTopOwner = forceInnerTopBounceSwitch.isOn
            ? .innerScrollView
            : .panel
        dragEngine.configuration = configuration
    }

    @objc private func addRows() {
        dataSource.rowCount += 10
        reloadDynamicRows()
    }

    @objc private func removeRows() {
        dataSource.rowCount = max(14, dataSource.rowCount - 10)
        reloadDynamicRows()
    }

    private func reloadDynamicRows() {
        tableView.reloadData()
        tableView.layoutIfNeeded()
        updateRowCountLabel()
        dragEngine.reloadScrollMetrics()
        recordEvent("内容已刷新 · \(dataSource.rowCount) 行")
    }

    private func updateRowCountLabel() {
        rowCountLabel.text = "\(dataSource.rowCount) 行"
    }
}

/// A deliberately minimal reproduction of the original component's default smart-placement rule.
/// The participant starts exactly 40pt below the panel top, extends to the panel bottom, and owns a
/// 2000pt effective scroll range. No handoff setting is changed: coordinated composition, automatic placement,
/// and the 0.7 minimum-visible ratio all come from the engine defaults.
final class AutomaticSmartHandoffViewController: DemoScenarioViewController {
    private let innerScrollView = UIScrollView()
    private let documentView = UIView()
    private let geometryMarker = UIView()
    private let scrollableDistance: CGFloat = 2_000
    private var documentHeightConstraint: NSLayoutConstraint!

    init(implementation: DemoImplementation = .swift) {
        super.init(
            title: "默认智能交接边界",
            subtitle: "默认 coordinated + automatic · 可滑动视图 y = 40",
            accent: DemoPalette.indigo,
            implementation: implementation
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeScene(implementation: DemoImplementation) -> DemoScenarioViewController {
        AutomaticSmartHandoffViewController(implementation: implementation)
    }

    override func initialDisplayHeight(for viewportSize: CGSize) -> CGFloat {
        detentHeights(for: viewportSize)[0]
    }

    override func comparisonScrollViews() -> [(name: String, scrollView: UIScrollView)] {
        [("smartHandoffScroll", innerScrollView)]
    }

    override func configureContent(in contentView: UIView) {
        // This case intentionally does not use DemoPanelView.contentView, whose top is 152pt. The
        // participant geometry under test must begin at panel y=40 and continue to its bottom.
        // Keep the scroll view itself transparent so the shared fixed panel header remains crisp;
        // only document cards draw backgrounds as they move underneath it.
        innerScrollView.backgroundColor = .clear
        innerScrollView.contentInsetAdjustmentBehavior = .never
        innerScrollView.alwaysBounceVertical = true
        innerScrollView.accessibilityIdentifier = "smartHandoffScroll"
        innerScrollView.accessibilityLabel = "默认智能交接的内部可滑动区域"
        innerScrollView.translatesAutoresizingMaskIntoConstraints = false
        panelView.addSubview(innerScrollView)

        documentView.backgroundColor = .clear
        documentView.translatesAutoresizingMaskIntoConstraints = false
        innerScrollView.addSubview(documentView)

        documentHeightConstraint = documentView.heightAnchor.constraint(
            equalToConstant: scrollableDistance
        )
        NSLayoutConstraint.activate([
            innerScrollView.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 40),
            innerScrollView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            innerScrollView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            innerScrollView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor),

            documentView.topAnchor.constraint(equalTo: innerScrollView.contentLayoutGuide.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: innerScrollView.contentLayoutGuide.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: innerScrollView.contentLayoutGuide.trailingAnchor),
            documentView.bottomAnchor.constraint(equalTo: innerScrollView.contentLayoutGuide.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: innerScrollView.frameLayoutGuide.widthAnchor),
            documentHeightConstraint
        ])

        installDocumentContent()

        geometryMarker.isUserInteractionEnabled = false
        geometryMarker.isAccessibilityElement = true
        geometryMarker.accessibilityIdentifier = "smartHandoff.geometry"
        geometryMarker.accessibilityLabel = "默认智能交接几何"
        geometryMarker.translatesAutoresizingMaskIntoConstraints = false
        panelView.addSubview(geometryMarker)
        NSLayoutConstraint.activate([
            geometryMarker.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            geometryMarker.topAnchor.constraint(equalTo: panelView.topAnchor),
            geometryMarker.widthAnchor.constraint(equalToConstant: 1),
            geometryMarker.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // "2000pt 可滑动区域" means effective offset range, not a 2000pt contentSize whose
        // usable distance shrinks with the viewport. Keep maxOffset - minOffset exactly 2000pt.
        let requiredDocumentHeight = innerScrollView.bounds.height + scrollableDistance
        if abs(documentHeightConstraint.constant - requiredDocumentHeight) > 0.01 {
            documentHeightConstraint.constant = requiredDocumentHeight
        }
        innerScrollView.layoutIfNeeded()
        let frameInPanel = panelView.convert(innerScrollView.frame, from: innerScrollView.superview)
        let effectiveScrollableDistance = max(
            0,
            innerScrollView.contentSize.height - innerScrollView.bounds.height
        )
        let detents = dragEngine.detentHeights
            .map { String(format: "%.6f", $0) }
            .joined(separator: ",")
        let handoff = dragEngine.configuration.handoff
        let handoffMode: String
        switch handoff.mode {
        case .coordinated:
            handoffMode = "coordinated"
        case .innerFirst:
            handoffMode = "innerFirst"
        case .innerFirstAtBoundary:
            handoffMode = "innerFirstAtBoundary"
        }
        let innerPlacement: String
        switch handoff.innerScrollPlacement {
        case .automatic:
            innerPlacement = "automatic"
        case .afterPanelFullyDisplayed:
            innerPlacement = "afterPanelFullyDisplayed"
        case .atDisplayHeight:
            innerPlacement = "atDisplayHeight"
        case .fromTouchedPosition:
            innerPlacement = "fromTouchedPosition"
        }
        geometryMarker.accessibilityValue = String(
            format: "frameY=%.6f,frameMaxY=%.6f,panelBottomY=%.6f,contentHeight=%.6f,boundsHeight=%.6f,scrollableDistance=%.6f,displayScale=%.6f,handoffMode=%@,innerPlacement=%@,minimumInnerVisibilityRatio=%.6f,detents=%@",
            frameInPanel.minY,
            frameInPanel.maxY,
            panelView.bounds.maxY,
            innerScrollView.contentSize.height,
            innerScrollView.bounds.height,
            effectiveScrollableDistance,
            UIScreen.main.scale,
            handoffMode,
            innerPlacement,
            handoff.minimumInnerVisibilityRatio,
            detents
        )
    }

    private func installDocumentContent() {
        let instruction = DemoControlFactory.caption(
            "功能：验证默认 automatic 智能放置如何在面板和内部 UIScrollView 之间分配同一次手势。\n操作：保持默认设置，从最低吸附点按住本区域向上拖到底；观察 HUD 先显示 panel，达到自动激活高度后切换为 inner。\n几何：内部视图从 panel y=40 延伸到底部，有效可滑动距离为 2000pt，使用低 / 中 / 完整 viewport 三态吸附。"
        )
        instruction.backgroundColor = DemoPalette.surface.withAlphaComponent(0.94)
        instruction.layer.cornerRadius = 14
        instruction.layer.masksToBounds = true
        instruction.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(instruction)

        NSLayoutConstraint.activate([
            // Leave the shared title and trace HUD unobscured during the short first inner segment.
            instruction.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 230),
            instruction.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 18),
            instruction.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -18)
        ])

        for (index, y) in [420, 760, 1_100, 1_440, 1_780].enumerated() {
            let marker = UILabel()
            marker.text = "内部内容 \(index + 1) · y = \(y)pt"
            marker.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            marker.textColor = DemoPalette.indigo
            marker.backgroundColor = DemoPalette.surface.withAlphaComponent(0.88)
            marker.layer.cornerRadius = 12
            marker.layer.masksToBounds = true
            marker.textAlignment = .center
            marker.translatesAutoresizingMaskIntoConstraints = false
            documentView.addSubview(marker)
            NSLayoutConstraint.activate([
                marker.topAnchor.constraint(equalTo: documentView.topAnchor, constant: CGFloat(y)),
                marker.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
                marker.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
                marker.heightAnchor.constraint(equalToConstant: 58)
            ])
        }
    }
}

final class NestedScrollChainViewController: DemoScenarioViewController {
    private let outerScrollView = UIScrollView()
    private let middleScrollView = UIScrollView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let dataSource = DemoTableDataSource(rowCount: 38, prefix: "最内层")
    private var lastProposalSignature = ""

    init(implementation: DemoImplementation = .swift) {
        super.init(
            title: "三层滚动链",
            subtitle: "触摸最内层后，从 responder chain 捕获真实祖先",
            accent: DemoPalette.teal,
            implementation: implementation
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeScene(implementation: DemoImplementation) -> DemoScenarioViewController {
        NestedScrollChainViewController(implementation: implementation)
    }

    override func initialDisplayHeight(for viewportSize: CGSize) -> CGFloat { 300 }

    override func comparisonScrollViews() -> [(name: String, scrollView: UIScrollView)] {
        [
            ("deepTable", tableView),
            ("middleScroll", middleScrollView),
            ("outerScroll", outerScrollView)
        ]
    }

    override func configureContent(in contentView: UIView) {
        outerScrollView.backgroundColor = DemoPalette.surface
        outerScrollView.accessibilityIdentifier = "outerScroll"
        outerScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(outerScrollView)

        let outerDocument = UIView()
        outerDocument.backgroundColor = DemoPalette.surface
        outerDocument.translatesAutoresizingMaskIntoConstraints = false
        outerScrollView.addSubview(outerDocument)

        middleScrollView.backgroundColor = DemoPalette.teal.withAlphaComponent(0.08)
        middleScrollView.layer.cornerRadius = 20
        middleScrollView.accessibilityIdentifier = "middleScroll"
        middleScrollView.translatesAutoresizingMaskIntoConstraints = false
        outerDocument.addSubview(middleScrollView)

        let middleDocument = UIView()
        middleDocument.translatesAutoresizingMaskIntoConstraints = false
        middleScrollView.addSubview(middleDocument)

        tableView.rowHeight = 58
        tableView.dataSource = dataSource
        tableView.scrollsToTop = false
        tableView.layer.cornerRadius = 16
        tableView.accessibilityIdentifier = "deepTable"
        tableView.translatesAutoresizingMaskIntoConstraints = false
        middleDocument.addSubview(tableView)

        let outerIntro = makeLayerCard(
            title: "功能与操作 · ① outerScroll",
            detail: "功能：验证触摸最内层列表时，组件沿响应链捕获 middleScroll 与 outerScroll 两层真实滚动祖先。\n操作：从最内层列表持续向上滑，再反向向下滑，观察各层连续接力且没有 offset 跳变；也可从中层或外层空白区域起手比较捕获链。",
            color: DemoPalette.blue
        )
        outerDocument.addSubview(outerIntro)

        let middleIntro = makeLayerCard(
            title: "② middleScroll",
            detail: "内部还有 1450pt 文档，因此它也是真正可滚动的 participant。",
            color: DemoPalette.teal
        )
        middleDocument.addSubview(middleIntro)

        let middleOutro = makeLayerCard(
            title: "中层尾部",
            detail: "祖先区间会按最内层视图的真实位置拆分，并不只是简单串联一次。",
            color: DemoPalette.purple
        )
        middleDocument.addSubview(middleOutro)

        let outerOutro = makeLayerCard(
            title: "外层尾部",
            detail: "全过程应连续且没有 offset 跳变。Swift HUD 会显示具体消费层级；原 OC 回调只能区分 panel / inner，请用各层 offset 与实际交接手感对比。",
            color: DemoPalette.orange
        )
        outerDocument.addSubview(outerOutro)

        NSLayoutConstraint.activate([
            outerScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            outerScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            outerScrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            outerScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            outerDocument.leadingAnchor.constraint(equalTo: outerScrollView.contentLayoutGuide.leadingAnchor),
            outerDocument.trailingAnchor.constraint(equalTo: outerScrollView.contentLayoutGuide.trailingAnchor),
            outerDocument.topAnchor.constraint(equalTo: outerScrollView.contentLayoutGuide.topAnchor),
            outerDocument.bottomAnchor.constraint(equalTo: outerScrollView.contentLayoutGuide.bottomAnchor),
            outerDocument.widthAnchor.constraint(equalTo: outerScrollView.frameLayoutGuide.widthAnchor),
            outerDocument.heightAnchor.constraint(equalToConstant: 2100),

            outerIntro.leadingAnchor.constraint(equalTo: outerDocument.leadingAnchor, constant: 18),
            outerIntro.trailingAnchor.constraint(equalTo: outerDocument.trailingAnchor, constant: -18),
            outerIntro.topAnchor.constraint(equalTo: outerDocument.topAnchor, constant: 22),
            outerIntro.heightAnchor.constraint(equalToConstant: 220),

            middleScrollView.leadingAnchor.constraint(equalTo: outerDocument.leadingAnchor, constant: 18),
            middleScrollView.trailingAnchor.constraint(equalTo: outerDocument.trailingAnchor, constant: -18),
            middleScrollView.topAnchor.constraint(equalTo: outerIntro.bottomAnchor, constant: 34),
            middleScrollView.heightAnchor.constraint(equalToConstant: 760),

            middleDocument.leadingAnchor.constraint(equalTo: middleScrollView.contentLayoutGuide.leadingAnchor),
            middleDocument.trailingAnchor.constraint(equalTo: middleScrollView.contentLayoutGuide.trailingAnchor),
            middleDocument.topAnchor.constraint(equalTo: middleScrollView.contentLayoutGuide.topAnchor),
            middleDocument.bottomAnchor.constraint(equalTo: middleScrollView.contentLayoutGuide.bottomAnchor),
            middleDocument.widthAnchor.constraint(equalTo: middleScrollView.frameLayoutGuide.widthAnchor),
            middleDocument.heightAnchor.constraint(equalToConstant: 1450),

            middleIntro.leadingAnchor.constraint(equalTo: middleDocument.leadingAnchor, constant: 14),
            middleIntro.trailingAnchor.constraint(equalTo: middleDocument.trailingAnchor, constant: -14),
            middleIntro.topAnchor.constraint(equalTo: middleDocument.topAnchor, constant: 18),
            middleIntro.heightAnchor.constraint(equalToConstant: 122),

            tableView.leadingAnchor.constraint(equalTo: middleDocument.leadingAnchor, constant: 14),
            tableView.trailingAnchor.constraint(equalTo: middleDocument.trailingAnchor, constant: -14),
            tableView.topAnchor.constraint(equalTo: middleIntro.bottomAnchor, constant: 82),
            tableView.heightAnchor.constraint(equalToConstant: 520),

            middleOutro.leadingAnchor.constraint(equalTo: middleDocument.leadingAnchor, constant: 14),
            middleOutro.trailingAnchor.constraint(equalTo: middleDocument.trailingAnchor, constant: -14),
            middleOutro.topAnchor.constraint(equalTo: tableView.bottomAnchor, constant: 190),
            middleOutro.heightAnchor.constraint(equalToConstant: 130),

            outerOutro.leadingAnchor.constraint(equalTo: outerDocument.leadingAnchor, constant: 18),
            outerOutro.trailingAnchor.constraint(equalTo: outerDocument.trailingAnchor, constant: -18),
            outerOutro.topAnchor.constraint(equalTo: middleScrollView.bottomAnchor, constant: 320),
            outerOutro.heightAnchor.constraint(equalToConstant: 140)
        ])
    }

    override func adjustCaptureProposal(_ proposal: inout DemoCaptureProposal) {
        let names = proposal.candidates.map {
            $0.scrollView.accessibilityIdentifier ?? String(describing: type(of: $0.scrollView))
        }
        let signature = names.joined(separator: " → ")
        guard signature != lastProposalSignature else { return }
        lastProposalSignature = signature
        recordEvent("capture chain · \(signature)")
    }

    private func makeLayerCard(title: String, detail: String, color: UIColor) -> UIView {
        let card = DemoCardView(title: title, detail: detail, tint: color)
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }
}

final class ExplicitSegmentsViewController: DemoScenarioViewController {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let dataSource = DemoTableDataSource(rowCount: 72, prefix: "分段内容")
    private let segmentBoundary: CGFloat = 620

    init(implementation: DemoImplementation = .swift) {
        super.init(
            title: "显式内部区间",
            subtitle: "业务精确指定每段 inner offset 对应的 displayHeight",
            accent: DemoPalette.red,
            implementation: implementation
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeScene(implementation: DemoImplementation) -> DemoScenarioViewController {
        ExplicitSegmentsViewController(implementation: implementation)
    }

    override func initialDisplayHeight(for viewportSize: CGSize) -> CGFloat { 230 }

    override func comparisonScrollViews() -> [(name: String, scrollView: UIScrollView)] {
        [("segmentedTable", tableView)]
    }

    override func configureContent(in contentView: UIView) {
        tableView.rowHeight = 60
        tableView.dataSource = dataSource
        tableView.scrollsToTop = false
        tableView.accessibilityIdentifier = "segmentedTable"
        tableView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: contentView.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        tableView.tableHeaderView = makeHeader()
    }

    override func segments(for scrollView: UIScrollView) -> [DemoInnerScrollSegment]? {
        guard scrollView === tableView else { return nil }
        let detents = detentHeights(for: dragScrollView.bounds.size)
        guard detents.count == 3 else { return nil }
        return [
            .init(displayHeight: detents[1], beginOffsetY: nil, endOffsetY: segmentBoundary),
            .init(displayHeight: detents[2], beginOffsetY: segmentBoundary, endOffsetY: nil)
        ]
    }

    private func makeHeader() -> UIView {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 244))
        header.backgroundColor = DemoPalette.red.withAlphaComponent(0.09)

        let badge = DemoBadgeLabel(text: "EXPLICIT SEGMENTS")
        let title = UILabel()
        title.text = "功能与操作 · 组合轴三段"
        title.font = .systemFont(ofSize: 19, weight: .bold)
        title.textColor = DemoPalette.ink
        let detail = DemoControlFactory.caption(
            "功能：业务显式规定列表的两个 offset 区间分别在中档和最高档展示高度滚动。\n操作：连续向上滑，观察 panel 到中档、table 滚到 620、panel 再到最高档、table 继续到底；随后反向滑动，检查路径是否对称且没有 offset 跳变。"
        )

        let stack = UIStackView(arrangedSubviews: [badge, title, detail])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 18)
        ])
        return header
    }
}
