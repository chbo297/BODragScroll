import UIKit

/// Exercises UIControl delivery while the drag host is decelerating on behalf of a participant.
/// The three regions deliberately separate view hierarchy from visual overlap.
final class DecelerationControlLabViewController: DemoScenarioViewController,
    UITableViewDataSource,
    UITableViewDelegate {

    private struct EventCounts {
        var touchDown = 0
        var touchUpInside = 0
        var touchUpOutside = 0
        var touchCancel = 0
        var movingTouchDown = 0

        var accessibilityValue: String {
            "down=\(touchDown);upInside=\(touchUpInside);upOutside=\(touchUpOutside);cancel=\(touchCancel);movingDown=\(movingTouchDown)"
        }
    }

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let resultLabel = DemoControlFactory.valueLabel("等待控件事件")
    private lazy var innerRegion = makeRegion(
        title: "列表内部 · 系统默认",
        detail: "惯性中按下只停止滚动，不触发控件",
        tint: DemoPalette.teal,
        identifierPrefix: "deceleration.inner"
    )
    private var eventCounts: [String: EventCounts] = [:]

    init(implementation: DemoImplementation = .swift) {
        super.init(
            title: "惯性中的 UIControl",
            subtitle: "甩动内部列表，再测试外层、悬浮层和列表内控件",
            accent: DemoPalette.orange,
            implementation: implementation
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeScene(implementation: DemoImplementation) -> DemoScenarioViewController {
        DecelerationControlLabViewController(implementation: implementation)
    }

    /// Start fully expanded so the first fling reaches the participant immediately. A setup drag
    /// would itself leave UIKit in a short settlement window and contaminate the control exercise.
    override func initialDisplayHeight(for viewportSize: CGSize) -> CGFloat {
        viewportSize.height
    }

    override func comparisonScrollViews() -> [(name: String, scrollView: UIScrollView)] {
        [("deceleration.inner.scroll", tableView)]
    }

    override func configureContent(in contentView: UIView) {
        let fixedCard = DemoCardView(
            title: "固定区 · 不覆盖内部 ScrollView",
            detail: "惯性中直接抬起应 upInside；开始拖拽应 touchCancel",
            tint: DemoPalette.orange
        )
        fixedCard.accessibilityIdentifier = "deceleration.fixed.region"
        fixedCard.stackView.addArrangedSubview(
            makeControlRow(
                tint: DemoPalette.orange,
                identifierPrefix: "deceleration.fixed"
            )
        )
        resultLabel.text = "快速甩动列表后立即按控件\ndown/upInside/upOutside/cancel/movingDown"
        resultLabel.accessibilityIdentifier = "deceleration.result"
        resultLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        resultLabel.numberOfLines = 2
        resultLabel.lineBreakMode = .byTruncatingTail
        resultLabel.heightAnchor.constraint(equalToConstant: 34).isActive = true
        fixedCard.stackView.addArrangedSubview(resultLabel)
        contentView.addSubview(fixedCard)

        tableView.backgroundColor = DemoPalette.canvas
        tableView.separatorStyle = .none
        tableView.rowHeight = 62
        tableView.sectionHeaderHeight = 164
        tableView.estimatedSectionHeaderHeight = 0
        tableView.alwaysBounceVertical = true
        tableView.scrollsToTop = false
        tableView.contentInset.bottom = 180
        tableView.verticalScrollIndicatorInsets = UIEdgeInsets(
            top: 0,
            left: 0,
            bottom: 180,
            right: 0
        )
        tableView.accessibilityIdentifier = "deceleration.inner.scroll"
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tableView)
        if #available(iOS 15.0, *) {
            tableView.sectionHeaderTopPadding = 0
        }

        let overlayCard = DemoCardView(
            title: "悬浮区 · 覆盖列表但不属于列表",
            detail: "几何上覆盖列表，层级仍是外层 sibling；事件期望与固定区一致",
            tint: DemoPalette.purple
        )
        overlayCard.accessibilityIdentifier = "deceleration.overlay.region"
        overlayCard.stackView.addArrangedSubview(
            makeControlRow(
                tint: DemoPalette.purple,
                identifierPrefix: "deceleration.overlay"
            )
        )
        contentView.addSubview(overlayCard)

        NSLayoutConstraint.activate([
            fixedCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            fixedCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            fixedCard.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),

            tableView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: fixedCard.bottomAnchor, constant: 8),
            tableView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // This card is intentionally added after the table and constrained over its viewport.
            // It is visually overlapping but remains hierarchy-depth 1 for BODragScroll.
            overlayCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            overlayCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            overlayCard.bottomAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.bottomAnchor, constant: -10)
        ])
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        48
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let reuseIdentifier = "deceleration-row"
        let cell = tableView.dequeueReusableCell(withIdentifier: reuseIdentifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: reuseIdentifier)
        cell.selectionStyle = .none
        cell.backgroundColor = indexPath.row.isMultiple(of: 2)
            ? DemoPalette.elevatedSurface
            : DemoPalette.surface
        cell.textLabel?.text = String(format: "惯性样本 %02d", indexPath.row + 1)
        cell.textLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        cell.textLabel?.textColor = DemoPalette.ink
        cell.detailTextLabel?.text = "快速上下甩动，让 participant 持续减速"
        cell.detailTextLabel?.textColor = DemoPalette.secondaryInk
        return cell
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        innerRegion
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        164
    }

    private func makeRegion(
        title: String,
        detail: String,
        tint: UIColor,
        identifierPrefix: String
    ) -> UIView {
        let container = UIView()
        container.backgroundColor = DemoPalette.canvas

        let card = DemoCardView(title: title, detail: detail, tint: tint)
        card.stackView.addArrangedSubview(
            makeControlRow(tint: tint, identifierPrefix: identifierPrefix)
        )
        container.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            card.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            card.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5)
        ])
        return container
    }

    private func makeControlRow(
        tint: UIColor,
        identifierPrefix: String
    ) -> UIStackView {
        let button = DemoControlFactory.button(title: "UIButton", tint: tint)
        configure(
            button,
            identifier: "\(identifierPrefix).button",
            accessibilityLabel: "\(identifierPrefix) UIButton"
        )

        let customControl = DecelerationLabControl(title: "UIControl", tint: tint)
        configure(
            customControl,
            identifier: "\(identifierPrefix).control",
            accessibilityLabel: "\(identifierPrefix) custom UIControl"
        )

        let row = UIStackView(arrangedSubviews: [button, customControl])
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 10
        row.heightAnchor.constraint(equalToConstant: 60).isActive = true
        return row
    }

    private func configure(
        _ control: UIControl,
        identifier: String,
        accessibilityLabel: String
    ) {
        control.accessibilityIdentifier = identifier
        control.accessibilityLabel = accessibilityLabel
        control.accessibilityValue = EventCounts().accessibilityValue
        control.addTarget(self, action: #selector(controlTouchDown(_:)), for: .touchDown)
        control.addTarget(self, action: #selector(controlTouchUpInside(_:)), for: .touchUpInside)
        control.addTarget(self, action: #selector(controlTouchUpOutside(_:)), for: .touchUpOutside)
        control.addTarget(self, action: #selector(controlTouchCancelled(_:)), for: .touchCancel)
        eventCounts[identifier] = EventCounts()
    }

    @objc private func controlTouchDown(_ control: UIControl) {
        update(control, event: "touchDown") { counts in
            counts.touchDown += 1
            if dragScrollView.isDecelerating
                || tableView.isDecelerating
                || dragEngine.isAnimatingDisplayHeight {
                counts.movingTouchDown += 1
            }
        }
    }

    @objc private func controlTouchUpInside(_ control: UIControl) {
        update(control, event: "touchUpInside") { $0.touchUpInside += 1 }
    }

    @objc private func controlTouchUpOutside(_ control: UIControl) {
        update(control, event: "touchUpOutside") { $0.touchUpOutside += 1 }
    }

    @objc private func controlTouchCancelled(_ control: UIControl) {
        update(control, event: "touchCancel") { $0.touchCancel += 1 }
    }

    private func update(
        _ control: UIControl,
        event: String,
        mutation: (inout EventCounts) -> Void
    ) {
        guard let identifier = control.accessibilityIdentifier else { return }
        var counts = eventCounts[identifier, default: EventCounts()]
        mutation(&counts)
        eventCounts[identifier] = counts
        control.accessibilityValue = counts.accessibilityValue

        let shortName = identifier.replacingOccurrences(of: "deceleration.", with: "")
        resultLabel.text = "\(shortName) · \(event)\n\(counts.accessibilityValue)"
        resultLabel.accessibilityValue = "\(identifier);event=\(event);\(counts.accessibilityValue)"
        recordEvent("\(shortName) · \(event) · \(counts.accessibilityValue)")
    }
}

/// A deliberately plain UIControl so the lab covers more than UIButton's private tracking class.
private final class DecelerationLabControl: UIControl {
    private let titleLabel = UILabel()
    private let tint: UIColor

    init(title: String, tint: UIColor) {
        self.tint = tint
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        backgroundColor = tint.withAlphaComponent(0.12)
        layer.cornerRadius = 12

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = tint
        titleLabel.textAlignment = .center
        titleLabel.isUserInteractionEnabled = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 56)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = tint.withAlphaComponent(isHighlighted ? 0.28 : 0.12)
            transform = isHighlighted ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity
        }
    }
}
