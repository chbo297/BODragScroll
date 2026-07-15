import UIKit
import WebKit

final class WebContentViewController: DemoScenarioViewController, WKNavigationDelegate {
    private let webView = WKWebView(frame: .zero)
    private let captureControl = UISegmentedControl(items: ["面板联动", "Web 独占"])
    private var disablesPanelInteraction = false
    private var lastProposalDescription = ""

    init(implementation: DemoImplementation = .swift) {
        super.init(
            title: "离线 Web 内容",
            subtitle: "WKWebView 的内部 scroll view 通过公开捕获策略参与",
            accent: DemoPalette.indigo,
            implementation: implementation
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeScene(implementation: DemoImplementation) -> DemoScenarioViewController {
        WebContentViewController(implementation: implementation)
    }

    override func transferComparisonSettings(to counterpart: DemoScenarioViewController) {
        guard let counterpart = counterpart as? WebContentViewController else { return }
        counterpart.captureControl.selectedSegmentIndex = captureControl.selectedSegmentIndex
        counterpart.webCaptureChanged()
    }

    override func initialDisplayHeight(for viewportSize: CGSize) -> CGFloat { 260 }

    override var defersReadyUntilContentLoaded: Bool { true }

    override func comparisonScrollViews() -> [(name: String, scrollView: UIScrollView)] {
        [("webScroll", webView.scrollView)]
    }

    override func configureContent(in contentView: UIView) {
        let guideCard = DemoCardView(
            title: "功能 / 操作见网页顶部 · \(implementation.displayName)",
            tint: DemoPalette.indigo
        )
        captureControl.selectedSegmentIndex = 0
        captureControl.accessibilityIdentifier = "web.mode"
        captureControl.addTarget(self, action: #selector(webCaptureChanged), for: .valueChanged)
        guideCard.stackView.addArrangedSubview(captureControl)
        guideCard.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(guideCard)

        webView.navigationDelegate = self
        webView.accessibilityIdentifier = "web.ready"
        webView.accessibilityValue = "false"
        webView.scrollView.accessibilityIdentifier = "webScroll"
        webView.scrollView.scrollsToTop = false
        webView.isOpaque = false
        webView.backgroundColor = DemoPalette.surface
        webView.scrollView.backgroundColor = DemoPalette.surface
        webView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(webView)
        NSLayoutConstraint.activate([
            guideCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            guideCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            guideCard.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),

            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            webView.topAnchor.constraint(equalTo: guideCard.bottomAnchor, constant: 8),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        webView.loadHTMLString(Self.offlineHTML, baseURL: nil)
    }

    override func adjustCaptureProposal(_ proposal: inout DemoCaptureProposal) {
        let primary = proposal.primaryCandidate?.scrollView.accessibilityIdentifier ?? "none"
        let description = "Web \(proposal.containsWebView ? "YES" : "NO") · \(proposal.candidates.count) candidate(s) · \(primary)"
        guard description != lastProposalDescription else { return }
        lastProposalDescription = description
        recordEvent(description)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.accessibilityValue = "true"
        recordEvent("离线 HTML 已就绪，可以在正文内拖动")
        markScenarioReady("webLoaded")
    }

    @objc private func webCaptureChanged() {
        disablesPanelInteraction = captureControl.selectedSegmentIndex == 1
        var configuration = dragEngine.configuration
        configuration.capture.disablesPanelInteractionInWebView = disablesPanelInteraction
        dragEngine.configuration = configuration
        recordEvent(
            disablesPanelInteraction
                ? "Web 区域禁止面板手势；仍可拖动 panel header"
                : "Web 与 panel 恢复联动"
        )
    }

    private static let offlineHTML = """
    <!doctype html>
    <html lang="zh-CN">
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
      <style>
        * { box-sizing: border-box; }
        body { margin: 0; padding: 22px 18px 80px; font-family: -apple-system, sans-serif;
               color: #182039; background: #f6f7fc; }
        .badge { display: inline-block; padding: 6px 10px; border-radius: 999px;
                 color: #5148d8; background: #e8e6ff; font-size: 12px; font-weight: 700; }
        h1 { font-size: 28px; line-height: 1.1; margin: 16px 0 8px; }
        .lead { color: #65708a; line-height: 1.55; margin-bottom: 22px; }
        .card { min-height: 150px; padding: 18px; margin: 14px 0; border-radius: 22px;
                color: white; box-shadow: 0 10px 24px rgba(30,40,80,.12); }
        .card h2 { margin: 0 0 8px; font-size: 21px; }
        .card p { margin: 0; line-height: 1.5; opacity: .86; }
        .c1 { background: linear-gradient(135deg,#645cff,#8b5cf6); }
        .c2 { background: linear-gradient(135deg,#087f8c,#26b6a4); }
        .c3 { background: linear-gradient(135deg,#ef6c3e,#f4a23c); }
        .c4 { background: linear-gradient(135deg,#df3f77,#9238c7); }
        button { width: 100%; border: 0; border-radius: 16px; padding: 15px; font-size: 16px;
                 font-weight: 700; color: #5148d8; background: white; }
      </style>
    </head>
    <body>
      <span class="badge">LOCAL WKWEBVIEW</span>
      <h1>Web 也是滚动参与者</h1>
      <p class="lead"><b>功能：</b>验证 WKWebView 内部纵向滚动与面板的连续交接，并比较 Web 联动/独占策略。<br><br><b>操作：</b>先展开面板，再在正文内持续上下拖动；切换上方策略后先抬手，再重新触摸正文。网页按钮仍应正常响应。<br><br><b>对齐说明：</b>“Web 独占”映射到原 OC 的 inhibitPanelForWebView。OC 的捕获诊断粒度与 Swift 不同，应比较实际联动行为，而不是要求候选数量相同。</p>
      <div class="card c1"><h2>自动捕获</h2><p>引擎只使用公开 UIKit/WebKit 层级，从真实触摸的 responder chain 建立候选。</p></div>
      <div class="card c2"><h2>连续交接</h2><p>面板运动和网页 contentOffset 被投影到同一条组合滚动轴。</p></div>
      <div class="card c3"><h2>策略切换</h2><p>使用网页上方的“面板联动 / Web 独占”切换。切换后抬手，再重新触摸正文。</p></div>
      <div class="card c4"><h2>系统行为</h2><p>输入、按钮和链接仍然由 WKWebView 正常处理，不需要私有 API。</p></div>
      <button onclick="this.textContent='网页按钮已触发 ✓'">点击网页按钮</button>
      <div class="card c1"><h2>继续滚动</h2><p>额外内容确保网页高度明显大于可视区域。</p></div>
      <div class="card c2"><h2>返回边界</h2><p>向下滚回网页顶部后，运动再交还给 panel。</p></div>
    </body>
    </html>
    """
}

final class ControlsAndGesturesViewController: DemoScenarioViewController,
    UICollectionViewDataSource {

    private let resultLabel = DemoControlFactory.valueLabel("等待控件事件")
    private let gestureControl = UISegmentedControl(items: ["同时", "面板", "横滑", "系统"])
    private let accessibilityControl = UISegmentedControl(items: ["自动", "Panel", "接管"])
    private let pageScrollView = UIScrollView()
    private let carousel: UICollectionView
    private var buttonTapCount = 0
    private let carouselColors: [UIColor] = [
        DemoPalette.pink, DemoPalette.purple, DemoPalette.indigo,
        DemoPalette.blue, DemoPalette.teal, DemoPalette.orange
    ]

    init(implementation: DemoImplementation = .swift) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 118, height: 118)
        layout.minimumLineSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        carousel = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(
            title: "控件与横向手势",
            subtitle: "UIControl 保持点击语义，横向滚动不被纵向面板吞掉",
            accent: DemoPalette.pink,
            implementation: implementation
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeScene(implementation: DemoImplementation) -> DemoScenarioViewController {
        ControlsAndGesturesViewController(implementation: implementation)
    }

    override func transferComparisonSettings(to counterpart: DemoScenarioViewController) {
        guard let counterpart = counterpart as? ControlsAndGesturesViewController else { return }
        counterpart.gestureControl.selectedSegmentIndex = gestureControl.selectedSegmentIndex
        counterpart.accessibilityControl.selectedSegmentIndex = accessibilityControl.selectedSegmentIndex
    }

    override func initialDisplayHeight(for viewportSize: CGSize) -> CGFloat { 310 }

    override func comparisonScrollViews() -> [(name: String, scrollView: UIScrollView)] {
        [
            ("controlsPageScroll", pageScrollView),
            ("controls.carousel", carousel)
        ]
    }

    override func configureContent(in contentView: UIView) {
        let controlsCard = DemoCardView(
            title: "功能与操作 · 原生 UIControl",
            detail: "功能：验证按钮、Switch、Slider 的原生触摸语义不会被纵向面板误吞。\n操作：依次点击、切换、拖动 Slider，再从控件之间的空白处纵向拖动面板。\n对齐说明：OC 含针对减速期 UIControl 的历史补偿逻辑；Swift 版采用新的触摸完成机制，因此极端时序的事件过程可能不同，最终控件动作应一致。当前：\(implementation.displayName)。",
            tint: DemoPalette.pink
        )
        let button = DemoControlFactory.button(title: "点击 Button", tint: DemoPalette.pink)
        button.accessibilityIdentifier = "controls.button"
        button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
        let toggle = UISwitch()
        toggle.accessibilityIdentifier = "controls.switch"
        toggle.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
        let slider = UISlider()
        slider.accessibilityIdentifier = "controls.slider"
        slider.minimumValue = 0
        slider.maximumValue = 100
        slider.value = 35
        slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
        controlsCard.stackView.addArrangedSubview(button)
        controlsCard.stackView.addArrangedSubview(DemoControlFactory.row(label: "Switch", control: toggle))
        controlsCard.stackView.addArrangedSubview(slider)
        resultLabel.accessibilityIdentifier = "controls.result"
        controlsCard.stackView.addArrangedSubview(resultLabel)

        let carouselCard = DemoCardView(
            title: "功能与操作 · 横向 Carousel",
            detail: "功能：对比纵向面板与横向 UICollectionView 的手势冲突策略。\n操作：选择策略后横向甩动色块，再斜向或纵向拖动，观察由哪一方取得手势。OC 使用原代理的整数策略，Swift 使用类型化策略；中立层表达一致，但系统仲裁时序可能不同。",
            tint: DemoPalette.indigo
        )
        gestureControl.selectedSegmentIndex = 0
        gestureControl.accessibilityIdentifier = "controls.gesture"
        gestureControl.addTarget(self, action: #selector(gesturePolicyChanged), for: .valueChanged)
        carouselCard.stackView.addArrangedSubview(gestureControl)
        carousel.backgroundColor = .clear
        carousel.showsHorizontalScrollIndicator = false
        carousel.alwaysBounceHorizontal = true
        carousel.accessibilityIdentifier = "controls.carousel"
        carousel.dataSource = self
        carousel.register(DemoCarouselCell.self, forCellWithReuseIdentifier: DemoCarouselCell.reuseIdentifier)
        carousel.heightAnchor.constraint(equalToConstant: 122).isActive = true
        carouselCard.stackView.addArrangedSubview(carousel)

        let accessibilityCard = DemoCardView(
            title: "功能与操作 · Accessibility scroll",
            detail: "功能：比较默认无障碍滚动、仅移动面板、业务完全接管三种处理。\n操作：先选模式，再点『收起/展开』；也可开启 VoiceOver 后执行三指滚动。『接管』会由页面程序化移动一个吸附点。OC 的 nil/NO/YES 三态分别映射为自动/Panel/接管。",
            tint: DemoPalette.teal
        )
        accessibilityControl.selectedSegmentIndex = 0
        accessibilityControl.accessibilityIdentifier = "controls.accessibility"
        accessibilityCard.stackView.addArrangedSubview(accessibilityControl)
        let previous = DemoControlFactory.button(title: "收起", tint: DemoPalette.orange)
        let next = DemoControlFactory.button(title: "展开", tint: DemoPalette.teal)
        previous.accessibilityIdentifier = "controls.accessibility.collapse"
        next.accessibilityIdentifier = "controls.accessibility.expand"
        previous.tag = -1
        next.tag = 1
        previous.addTarget(self, action: #selector(accessibilityButtonTapped(_:)), for: .touchUpInside)
        next.addTarget(self, action: #selector(accessibilityButtonTapped(_:)), for: .touchUpInside)
        let accessibilityButtons = UIStackView(arrangedSubviews: [previous, next])
        accessibilityButtons.axis = .horizontal
        accessibilityButtons.spacing = 10
        accessibilityButtons.distribution = .fillEqually
        accessibilityCard.stackView.addArrangedSubview(accessibilityButtons)

        let stack = UIStackView(arrangedSubviews: [controlsCard, carouselCard, accessibilityCard])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        pageScrollView.alwaysBounceVertical = true
        pageScrollView.scrollsToTop = false
        pageScrollView.accessibilityIdentifier = "controlsPageScroll"
        pageScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pageScrollView)
        pageScrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            pageScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pageScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            pageScrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            pageScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            pageScrollView.contentLayoutGuide.widthAnchor.constraint(
                equalTo: pageScrollView.frameLayoutGuide.widthAnchor
            ),
            stack.leadingAnchor.constraint(
                equalTo: pageScrollView.contentLayoutGuide.leadingAnchor,
                constant: 18
            ),
            stack.trailingAnchor.constraint(
                equalTo: pageScrollView.contentLayoutGuide.trailingAnchor,
                constant: -18
            ),
            stack.topAnchor.constraint(equalTo: pageScrollView.contentLayoutGuide.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: pageScrollView.contentLayoutGuide.bottomAnchor, constant: -18)
        ])
    }

    override func gestureStrategy(
        for gesture: UIGestureRecognizer,
        otherGesture: UIGestureRecognizer
    ) -> DemoGestureStrategy? {
        guard let gestureView = otherGesture.view,
              gestureView === carousel || gestureView.isDescendant(of: carousel) else {
            return nil
        }
        switch gestureControl.selectedSegmentIndex {
        case 1: return .panelFirst
        case 2: return .otherFirst
        case 3: return .systemDefault
        default: return .simultaneous
        }
    }

    override func accessibilityDisposition(
        for direction: UIAccessibilityScrollDirection
    ) -> DemoAccessibilityDisposition {
        switch accessibilityControl.selectedSegmentIndex {
        case 1:
            return .panelOnly
        case 2:
            moveOneDetent(direction: direction)
            return .handled
        default:
            return .automatic
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        12
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: DemoCarouselCell.reuseIdentifier,
            for: indexPath
        ) as! DemoCarouselCell
        cell.configure(index: indexPath.item, color: carouselColors[indexPath.item % carouselColors.count])
        return cell
    }

    @objc private func buttonTapped() {
        buttonTapCount += 1
        resultLabel.text = "Button touchUpInside · count \(buttonTapCount)"
    }

    @objc private func switchChanged(_ sender: UISwitch) {
        resultLabel.text = "Switch · \(sender.isOn ? "ON" : "OFF")"
    }

    @objc private func sliderChanged(_ sender: UISlider) {
        resultLabel.text = String(format: "Slider · %.0f", sender.value)
    }

    @objc private func gesturePolicyChanged() {
        recordEvent("横向手势策略已切换")
    }

    @objc private func accessibilityButtonTapped(_ sender: UIButton) {
        // UIKit/VoiceOver semantics: .down advances to a larger display height, while .up
        // returns to a smaller one. Keep the buttons and the custom provider on that same axis.
        let direction: UIAccessibilityScrollDirection = sender.tag > 0 ? .down : .up
        let handled = dragEngine.performAccessibilityScroll(direction)
        resultLabel.text = "accessibilityScroll · \(handled ? "handled" : "ignored")"
    }

    private func moveOneDetent(direction: UIAccessibilityScrollDirection) {
        let detents = detentHeights(for: dragScrollView.bounds.size)
        guard !detents.isEmpty else { return }
        let current = dragEngine.displayHeight
        let target: CGFloat
        if direction == .down {
            target = detents.first(where: { $0 > current + 1 }) ?? detents.last!
        } else {
            target = detents.reversed().first(where: { $0 < current - 1 }) ?? detents.first!
        }
        dragEngine.move(
            toDisplayHeight: target,
            animated: true,
            options: .init(),
            completion: nil
        )
    }

}
