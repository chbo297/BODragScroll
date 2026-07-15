import UIKit

final class DemoCatalogViewController: UITableViewController {
    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "BODragScroll"
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = DemoPalette.canvas
        tableView.separatorStyle = .none
        tableView.register(DemoScenarioCell.self, forCellReuseIdentifier: DemoScenarioCell.reuseIdentifier)
        tableView.tableHeaderView = makeHeaderView()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
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
        guard frame.height != height else { return }
        frame.size.height = height
        header.frame = frame
        tableView.tableHeaderView = header
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        DemoCatalog.sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        DemoCatalog.sections[section].scenarios.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        DemoCatalog.sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        DemoCatalog.sections[section].footer
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: DemoScenarioCell.reuseIdentifier,
            for: indexPath
        ) as! DemoScenarioCell
        cell.configure(with: DemoCatalog.sections[indexPath.section].scenarios[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        84
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let scenario = DemoCatalog.sections[indexPath.section].scenarios[indexPath.row]
        navigationController?.pushViewController(scenario.makeViewController(.swift), animated: true)
    }

    private func makeHeaderView() -> UIView {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 220))

        let title = UILabel()
        title.text = "BODragScroll"
        title.font = .systemFont(ofSize: 34, weight: .black)
        title.textColor = DemoPalette.ink

        let badge = DemoBadgeLabel(text: "SWIFT ↔ OC · UIKit · iOS 13+")
        let summary = UILabel()
        summary.text = "选择场景后，可用右上角 OC / Swift 分段标签在重写版和原实现之间重建切换；业务选项会保留，位置与捕获会话会重置。\n\n测试边界：原 OC 的 +load swizzle 在进程内全局生效，因此这里用于行为 A/B，不是两个完全隔离进程的性能对照。"
        summary.font = .preferredFont(forTextStyle: .body)
        summary.textColor = DemoPalette.secondaryInk
        summary.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [title, badge, summary])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -18)
        ])
        return header
    }
}

private final class DemoScenarioCell: UITableViewCell {
    static let reuseIdentifier = "DemoScenarioCell"

    private let iconContainer = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        let card = UIView()
        card.backgroundColor = DemoPalette.surface
        card.layer.cornerRadius = 18
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        iconContainer.layer.cornerRadius = 14
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(iconContainer)

        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconView)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = DemoPalette.ink
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = DemoPalette.secondaryInk
        subtitleLabel.numberOfLines = 2

        let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        labels.axis = .vertical
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(labels)

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = DemoPalette.tertiaryInk
        chevron.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(chevron)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            iconContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            iconContainer.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 48),
            iconContainer.heightAnchor.constraint(equalToConstant: 48),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 23),
            iconView.heightAnchor.constraint(equalToConstant: 23),

            labels.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 13),
            labels.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -10),

            chevron.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: card.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with scenario: DemoScenario) {
        titleLabel.text = scenario.title
        subtitleLabel.text = scenario.subtitle
        iconView.image = UIImage(systemName: scenario.symbolName)
        iconView.tintColor = scenario.tint
        iconContainer.backgroundColor = scenario.tint.withAlphaComponent(0.13)
        accessibilityTraits = .button
        accessibilityLabel = "\(scenario.title)，\(scenario.subtitle)"
    }
}
