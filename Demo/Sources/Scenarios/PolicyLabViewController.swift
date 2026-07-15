import UIKit

final class PolicyLabViewController: DemoScenarioViewController {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let dataSource = DemoTableDataSource(rowCount: 44, prefix: "策略列表")
    private let handoffControl = UISegmentedControl(items: ["协调", "列表优先", "到边界"])
    private let bounceControl = UISegmentedControl(items: ["面板顶", "列表", "关闭"])
    private let resistanceSwitch = UISwitch()
    private let indicatorSwitch = UISwitch()

    init(implementation: DemoImplementation = .swift) {
        super.init(
            title: "Handoff 与回弹实验室",
            subtitle: "修改值类型 configuration，观察同一列表的不同行为",
            accent: DemoPalette.green,
            implementation: implementation
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeScene(implementation: DemoImplementation) -> DemoScenarioViewController {
        PolicyLabViewController(implementation: implementation)
    }

    override func transferComparisonSettings(to counterpart: DemoScenarioViewController) {
        guard let counterpart = counterpart as? PolicyLabViewController else { return }
        counterpart.handoffControl.selectedSegmentIndex = handoffControl.selectedSegmentIndex
        counterpart.bounceControl.selectedSegmentIndex = bounceControl.selectedSegmentIndex
        counterpart.resistanceSwitch.isOn = resistanceSwitch.isOn
        counterpart.indicatorSwitch.isOn = indicatorSwitch.isOn
        counterpart.applyPolicies(announce: false)
    }

    override func initialDisplayHeight(for viewportSize: CGSize) -> CGFloat { 330 }

    override func comparisonScrollViews() -> [(name: String, scrollView: UIScrollView)] {
        [("policyTable", tableView)]
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView, tableView.bounds.width > 0 else { return }
        var frame = header.frame
        frame.size.width = tableView.bounds.width
        header.frame = frame
        let height = header.systemLayoutSizeFitting(
            CGSize(width: tableView.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        guard abs(frame.height - height) > 0.5 else { return }
        frame.size.height = height
        header.frame = frame
        tableView.tableHeaderView = header
    }

    override func applyInitialConfiguration() {
        handoffControl.selectedSegmentIndex = 0
        bounceControl.selectedSegmentIndex = 0
        indicatorSwitch.isOn = true
        applyPolicies(announce: false)
    }

    override func configureContent(in contentView: UIView) {
        tableView.dataSource = dataSource
        tableView.rowHeight = 58
        tableView.layer.cornerRadius = 18
        tableView.scrollsToTop = false
        tableView.accessibilityIdentifier = "policyTable"
        tableView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: contentView.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        tableView.tableHeaderView = makePolicyHeader()
    }

    private func makePolicyHeader() -> UIView {
        // Keep the controls in the table header so every control and every row remains reachable
        // even on compact-height devices; a clipped, oversized table frame would hide its last rows.
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 480))
        header.backgroundColor = DemoPalette.surface

        let policyCard = DemoCardView(
            title: "功能与操作 · 运行时策略",
            detail: "功能：对比面板与内部列表的交接顺序、越界回弹归属、收起阻力和滚动指示器提示。\n操作：从下方列表开始上下拖动并越过顶部或底部；每次切换后先抬手，再重新触摸。\n边界：为保证面板永不越过顶部安全区，面板向上的 bottom bounce 始终关闭；『面板顶』只演示向下拉时由面板回弹，列表底部仍由列表回弹。\n对齐说明：OC 的交接选项对应原实现的布尔策略组合，边界手感可能不完全相同。当前：\(implementation.displayName)。",
            tint: DemoPalette.green
        )

        handoffControl.accessibilityIdentifier = "policy.handoff"
        bounceControl.accessibilityIdentifier = "policy.bounce"
        resistanceSwitch.accessibilityIdentifier = "policy.resistance"
        indicatorSwitch.accessibilityIdentifier = "policy.indicator"
        handoffControl.addTarget(self, action: #selector(policyChanged), for: .valueChanged)
        bounceControl.addTarget(self, action: #selector(policyChanged), for: .valueChanged)
        resistanceSwitch.addTarget(self, action: #selector(policyChanged), for: .valueChanged)
        indicatorSwitch.addTarget(self, action: #selector(policyChanged), for: .valueChanged)
        policyCard.stackView.addArrangedSubview(DemoControlFactory.caption("HANDOFF MODE"))
        policyCard.stackView.addArrangedSubview(handoffControl)
        policyCard.stackView.addArrangedSubview(DemoControlFactory.caption("TOP / BOTTOM BOUNCE OWNER"))
        policyCard.stackView.addArrangedSubview(bounceControl)
        policyCard.stackView.addArrangedSubview(
            DemoControlFactory.row(label: "收起时增加阻力", control: resistanceSwitch)
        )
        policyCard.stackView.addArrangedSubview(
            DemoControlFactory.row(label: "自动提示列表指示器", control: indicatorSwitch)
        )
        policyCard.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(policyCard)

        let listTitle = UILabel()
        listTitle.text = "从这里开始上下甩动，越过两端观察回弹归属"
        listTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        listTitle.textColor = DemoPalette.secondaryInk
        listTitle.numberOfLines = 0
        listTitle.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(listTitle)

        NSLayoutConstraint.activate([
            policyCard.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
            policyCard.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -18),
            policyCard.topAnchor.constraint(equalTo: header.topAnchor, constant: 18),

            listTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 22),
            listTitle.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -22),
            listTitle.topAnchor.constraint(equalTo: policyCard.bottomAnchor, constant: 18),
            listTitle.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -18)
        ])
        return header
    }

    @objc private func policyChanged() {
        applyPolicies(announce: true)
    }

    private func applyPolicies(announce: Bool) {
        var configuration = dragEngine.configuration

        switch handoffControl.selectedSegmentIndex {
        case 1:
            configuration.handoff.mode = .innerFirst
        case 2:
            configuration.handoff.mode = .innerFirstAtBoundary
        default:
            configuration.handoff.mode = .coordinated
        }

        configuration.handoff.resistsCollapse = resistanceSwitch.isOn
        configuration.indicator.automaticallyShowsInnerIndicator = indicatorSwitch.isOn

        switch bounceControl.selectedSegmentIndex {
        case 1:
            configuration.bounce.allowsPanelTopBounce = true
            configuration.bounce.allowsPanelBottomBounce = false
            configuration.bounce.preferredTopOwner = .innerScrollView
            configuration.bounce.preferredBottomOwner = .innerScrollView
            configuration.bounce.forcesInnerTopBounce = true
            tableView.bounces = true
        case 2:
            configuration.bounce.allowsPanelTopBounce = false
            configuration.bounce.allowsPanelBottomBounce = false
            configuration.bounce.forcesInnerTopBounce = false
            tableView.bounces = false
        default:
            configuration.bounce.allowsPanelTopBounce = true
            configuration.bounce.allowsPanelBottomBounce = false
            configuration.bounce.preferredTopOwner = .panel
            configuration.bounce.preferredBottomOwner = .innerScrollView
            configuration.bounce.forcesInnerTopBounce = false
            tableView.bounces = true
        }

        dragEngine.configuration = configuration
        dragEngine.reloadScrollMetrics()
        if announce {
            recordEvent("策略已更新，抬手后重新触摸生效")
        }
    }
}
