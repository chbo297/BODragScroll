import UIKit

final class DemoPanelView: UIView {
    let contentView = UIView()

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    init(title: String, subtitle: String, accent: UIColor) {
        super.init(frame: .zero)
        backgroundColor = DemoPalette.surface
        layer.cornerRadius = 28
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        clipsToBounds = true
        isAccessibilityElement = false
        accessibilityIdentifier = "demo.panel"

        // A non-interactive, comfortably sized accessibility target gives UI tests a stable
        // coordinate in the real panel header without changing UIKit hit testing.
        let grabberAccessibilityTarget = UIView()
        grabberAccessibilityTarget.isUserInteractionEnabled = false
        grabberAccessibilityTarget.isAccessibilityElement = true
        grabberAccessibilityTarget.accessibilityIdentifier = "demo.panelGrabber"
        grabberAccessibilityTarget.accessibilityLabel = "拖动面板"
        grabberAccessibilityTarget.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grabberAccessibilityTarget)

        let grabber = UIView()
        grabber.backgroundColor = DemoPalette.tertiaryInk.withAlphaComponent(0.55)
        grabber.layer.cornerRadius = 2.5
        grabber.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grabber)

        let eyebrow = UILabel()
        eyebrow.text = "BODRAGSCROLL"
        eyebrow.font = .systemFont(ofSize: 10, weight: .heavy)
        eyebrow.textColor = accent

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = DemoPalette.ink

        subtitleLabel.text = subtitle
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = DemoPalette.secondaryInk
        subtitleLabel.numberOfLines = 2

        let labels = UIStackView(arrangedSubviews: [eyebrow, titleLabel, subtitleLabel])
        labels.axis = .vertical
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        NSLayoutConstraint.activate([
            grabberAccessibilityTarget.topAnchor.constraint(equalTo: topAnchor),
            grabberAccessibilityTarget.centerXAnchor.constraint(equalTo: centerXAnchor),
            grabberAccessibilityTarget.widthAnchor.constraint(equalToConstant: 112),
            grabberAccessibilityTarget.heightAnchor.constraint(equalToConstant: 44),

            grabber.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            grabber.centerXAnchor.constraint(equalTo: centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 42),
            grabber.heightAnchor.constraint(equalToConstant: 5),

            // Leave room for the floating back and implementation-switch buttons at full height.
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 72),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -72),
            labels.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: 9),

            contentView.topAnchor.constraint(equalTo: topAnchor, constant: 152),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class DemoEventHUD: UIView {
    private let heightLabel = UILabel()
    private let eventLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.74)
        layer.cornerRadius = 14
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "demo.eventHUD"

        heightLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        heightLabel.textColor = .white
        eventLabel.font = .systemFont(ofSize: 11, weight: .medium)
        eventLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        eventLabel.lineBreakMode = .byTruncatingMiddle

        let stack = UIStackView(arrangedSubviews: [heightLabel, eventLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            widthAnchor.constraint(lessThanOrEqualToConstant: 330)
        ])
        update(displayHeight: 0, source: "panel", event: "等待交互", trace: "[]")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(displayHeight: CGFloat, source: String, event: String, trace: String) {
        let heightText = String(format: "displayHeight  %6.1f   ·   %@", displayHeight, source)
        if heightLabel.text != heightText {
            heightLabel.text = heightText
        }
        if eventLabel.text != event {
            eventLabel.text = event
        }
        let accessibilityLabel = String(
            format: "展示高度 %.6f，运动来源 %@，%@",
            displayHeight,
            source,
            event
        )
        if self.accessibilityLabel != accessibilityLabel {
            self.accessibilityLabel = accessibilityLabel
        }
        if accessibilityValue != trace {
            accessibilityValue = trace
        }
    }
}
