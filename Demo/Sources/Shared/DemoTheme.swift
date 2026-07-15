import UIKit

enum DemoPalette {
    static let canvas = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.045, green: 0.055, blue: 0.08, alpha: 1)
            : UIColor(red: 0.955, green: 0.965, blue: 0.985, alpha: 1)
    }
    static let surface = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.105, green: 0.12, blue: 0.165, alpha: 1)
            : .white
    }
    static let elevatedSurface = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.15, green: 0.17, blue: 0.22, alpha: 1)
            : UIColor(red: 0.975, green: 0.98, blue: 0.995, alpha: 1)
    }
    static let ink = UIColor.label
    static let secondaryInk = UIColor.secondaryLabel
    static let tertiaryInk = UIColor.tertiaryLabel
    static let accent = UIColor(red: 0.27, green: 0.39, blue: 0.96, alpha: 1)
    static let blue = UIColor(red: 0.20, green: 0.50, blue: 0.96, alpha: 1)
    static let indigo = UIColor(red: 0.36, green: 0.31, blue: 0.91, alpha: 1)
    static let purple = UIColor(red: 0.58, green: 0.29, blue: 0.91, alpha: 1)
    static let pink = UIColor(red: 0.93, green: 0.27, blue: 0.56, alpha: 1)
    static let red = UIColor(red: 0.93, green: 0.29, blue: 0.31, alpha: 1)
    static let orange = UIColor(red: 0.96, green: 0.50, blue: 0.16, alpha: 1)
    static let green = UIColor(red: 0.16, green: 0.66, blue: 0.43, alpha: 1)
    static let teal = UIColor(red: 0.10, green: 0.66, blue: 0.68, alpha: 1)
}

final class DemoBackdropView: UIView {
    private let gradient = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.colors = [
            DemoPalette.accent.withAlphaComponent(0.30).cgColor,
            DemoPalette.teal.withAlphaComponent(0.18).cgColor,
            DemoPalette.canvas.cgColor
        ]
        gradient.startPoint = CGPoint(x: 0.1, y: 0)
        gradient.endPoint = CGPoint(x: 0.9, y: 1)
        layer.addSublayer(gradient)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        gradient.colors = [
            DemoPalette.accent.withAlphaComponent(0.30).cgColor,
            DemoPalette.teal.withAlphaComponent(0.18).cgColor,
            DemoPalette.canvas.cgColor
        ]
    }
}

final class DemoBadgeLabel: UILabel {
    init(text: String) {
        super.init(frame: .zero)
        self.text = text
        font = .systemFont(ofSize: 11, weight: .bold)
        textColor = DemoPalette.accent
        backgroundColor = DemoPalette.accent.withAlphaComponent(0.12)
        layer.cornerRadius = 10
        clipsToBounds = true
        textAlignment = .center
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: intrinsicContentSize.width + 18).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: 9, dy: 0))
    }
}

final class DemoCardView: UIView {
    let stackView = UIStackView()

    init(title: String? = nil, detail: String? = nil, tint: UIColor = DemoPalette.accent) {
        super.init(frame: .zero)
        backgroundColor = DemoPalette.elevatedSurface
        layer.cornerRadius = 18
        translatesAutoresizingMaskIntoConstraints = false

        stackView.axis = .vertical
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        ])

        if let title {
            let label = UILabel()
            label.text = title
            label.font = .systemFont(ofSize: 17, weight: .semibold)
            label.textColor = tint
            stackView.addArrangedSubview(label)
        }
        if let detail {
            let label = UILabel()
            label.text = detail
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = DemoPalette.secondaryInk
            label.numberOfLines = 0
            stackView.addArrangedSubview(label)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

enum DemoControlFactory {
    static func button(title: String, tint: UIColor = DemoPalette.accent) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.setTitleColor(tint, for: .normal)
        button.backgroundColor = tint.withAlphaComponent(0.12)
        button.layer.cornerRadius = 12
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        return button
    }

    static func caption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = DemoPalette.secondaryInk
        label.numberOfLines = 0
        return label
    }

    static func valueLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        label.textColor = DemoPalette.ink
        label.numberOfLines = 0
        return label
    }

    static func row(label text: String, control: UIView) -> UIStackView {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = DemoPalette.ink
        let stack = UIStackView(arrangedSubviews: [label, control])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .equalSpacing
        stack.spacing = 12
        return stack
    }
}
