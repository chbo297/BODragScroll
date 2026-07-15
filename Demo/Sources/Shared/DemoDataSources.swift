import UIKit

final class DemoTableDataSource: NSObject, UITableViewDataSource {
    var rowCount: Int
    var prefix: String

    init(rowCount: Int, prefix: String) {
        self.rowCount = rowCount
        self.prefix = prefix
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rowCount
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "DemoRow"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        cell.backgroundColor = indexPath.row.isMultiple(of: 2)
            ? DemoPalette.surface
            : DemoPalette.elevatedSurface
        cell.textLabel?.text = "\(prefix) \(String(format: "%02d", indexPath.row + 1))"
        cell.textLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        cell.textLabel?.textColor = DemoPalette.ink
        cell.detailTextLabel?.text = indexPath.row.isMultiple(of: 5)
            ? "继续纵向滑动，观察运动来源切换"
            : "BODragScroll participant"
        cell.detailTextLabel?.textColor = DemoPalette.secondaryInk
        cell.selectionStyle = .none
        cell.imageView?.image = UIImage(systemName: indexPath.row.isMultiple(of: 3) ? "circle.fill" : "circle")
        cell.imageView?.tintColor = DemoPalette.accent.withAlphaComponent(0.72)
        return cell
    }
}

final class DemoCarouselCell: UICollectionViewCell {
    static let reuseIdentifier = "DemoCarouselCell"
    private let numberLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 18
        numberLabel.font = .systemFont(ofSize: 28, weight: .black)
        numberLabel.textColor = .white
        numberLabel.textAlignment = .center
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(numberLabel)
        NSLayoutConstraint.activate([
            numberLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(index: Int, color: UIColor) {
        numberLabel.text = "\(index + 1)"
        backgroundColor = color
    }
}
