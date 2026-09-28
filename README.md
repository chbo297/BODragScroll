# BODragScroll

`BODragScroll` 是 [BODragScrollView](https://github.com/chbo297/BODragScrollView) 的纯 Swift 重写。它通过一个统一的纵向滚动轴，协调固定尺寸的 `panelView` 与触摸路径上的一个或多个 `UIScrollView`，支持面板吸附、内部列表交接、嵌套滚动和 Web 内容。

- iOS 13+
- Swift 5.7+
- UIKit
- 无第三方运行时依赖

## 安装

Swift Package Manager：

```swift
.package(
    url: "https://github.com/chbo297/BODragScroll.git",
    from: "2.2.0"
)
```

CocoaPods：

```ruby
pod "BODragScroll", "~> 2.1"
```

### 从 1.x 升级

2.0 将程序化面板移动 API 从 `move(toDisplayHeight:animated:options:completion:)`
重命名为 `scroll(toDisplayHeight:animated:options:completion:)`。旧名称不再保留，升级时需要同步更新调用点。

2.0 还新增 `isMovementActive` 与
`dragScrollView(_:didBecomeIdleAtDisplayHeight:)`，用于观察拖拽、减速、动画、回弹和延迟移动形成的整批运动何时完全结束。

## 推荐接入：三态面板与默认内部联动

下面是最常用的完整接入方式：面板具有低、中、高三个吸附状态，内部 `UITableView` 从面板的 `y = 40` 延伸到底部。使用默认自动策略时，中间态不足以展示内部列表的 70%，因此面板会先展开到最高态，再滚动内部列表。

```swift
import UIKit
import BODragScroll

@MainActor
final class DemoViewController: UIViewController,
                                BODragScrollBehaviorProvider,
                                UITableViewDataSource {

    private let dragScrollView = BODragScrollView()
    private let panelView = UIView()
    private let tableView = UITableView()
    private let rows = (1...60).map { "第 \($0) 行" }

    // 避免同一次尺寸下反复设置 detent，引起无意义的布局刷新。
    private var configuredDetents: [CGFloat] = []

    override func viewDidLoad() {
        super.viewDidLoad()

        dragScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dragScrollView)

        NSLayoutConstraint.activate([
            dragScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dragScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dragScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            dragScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        panelView.backgroundColor = .systemBackground
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        panelView.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 40),
            tableView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor)
        ])

        // 这些也是默认值；显式写出是为了说明默认交接行为。
        var configuration = dragScrollView.configuration
        configuration.handoff.mode = .coordinated
        configuration.handoff.innerScrollPlacement = .automatic
        configuration.handoff.minimumInnerVisibilityRatio = 0.7
        dragScrollView.configuration = configuration

        // provider 必须在 panelView 首次布局前设置。
        dragScrollView.behaviorProvider = self
        dragScrollView.panelView = panelView
    }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        sizeFor panelView: UIView,
        firstLayout: Bool,
        proposedDisplayHeight: inout CGFloat
    ) -> CGSize? {
        let maximumHeight = dragScrollView.bounds.height
        guard maximumHeight > 0 else { return panelView.bounds.size }

        let lowHeight = maximumHeight * 0.22
        let middleHeight = maximumHeight * 0.52
        let detents = [lowHeight, middleHeight, maximumHeight]

        if configuredDetents != detents {
            configuredDetents = detents
            dragScrollView.detentHeights = detents
        }

        if firstLayout {
            // 等价于 OC layoutEmbedView 回调中的 *willShowHeight。
            proposedDisplayHeight = lowHeight
        } else {
            proposedDisplayHeight = min(
                maximumHeight,
                max(lowHeight, proposedDisplayHeight)
            )
        }

        // 同一个回调同时决定 panelView 的固定尺寸。
        return CGSize(
            width: dragScrollView.bounds.width,
            height: maximumHeight
        )
    }

    func tableView(
        _ tableView: UITableView,
        numberOfRowsInSection section: Int
    ) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let identifier = "row"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .default, reuseIdentifier: identifier)
        cell.textLabel?.text = rows[indexPath.row]
        return cell
    }
}
```

`sizeFor:panelView:firstLayout:proposedDisplayHeight:` 可以像 Objective-C 的 `layoutEmbedView` 回调一样，在一个位置配置：

- 返回 `panelView` 的固定尺寸；
- 设置或更新三态 `detentHeights`；
- 在 `firstLayout == true` 时修改 `proposedDisplayHeight`，决定首次展示高度。

示例把 host 全高作为业务的最大面板高度；也可以按自己的容器布局返回其他尺寸。组件只协调面板和内部滚动，不替业务决定面板的视觉上限。

不要在 sizing 回调中调用 `scroll(...)`。后续布局通常应保留传入的 `proposedDisplayHeight`，只在业务尺寸范围发生变化时做必要约束。

### 默认交接配置

```swift
var configuration = dragScrollView.configuration
configuration.handoff.mode = .coordinated
configuration.handoff.innerScrollPlacement = .automatic
configuration.handoff.minimumInnerVisibilityRatio = 0.7
dragScrollView.configuration = configuration
```

- `.coordinated`：面板和内部 ScrollView 由同一条组合滚动轴协调。
- `.automatic`：从当前面板高度向更高的 detent 查找，把内部滚动区间放在第一个达到可见比例要求的位置。
- `0.7`：自动选择位置时，内部 ScrollView 至少应显示自身高度的 70%。

`==` 表示比较；修改配置要使用上面示例中的 `=`，并把整个 `configuration` 写回控件。

## 常用能力

### 程序化展开、收起和吸附

```swift
dragScrollView.scroll(
    toDisplayHeight: dragScrollView.detentHeights.last ?? 0,
    animated: true
) { result in
    print(result.finalDisplayHeight, result.outcome)
}

dragScrollView.settleToNearestDetent(animated: true)
```

每个被接受的移动请求只结束一次；结果为 `.completed`、`.cancelled` 或 `.interrupted`。布局或拖拽原子阶段内接受的请求可能延后执行，最终值以 completion 为准。

### 监听高度和滚动来源

```swift
extension DemoViewController: BODragScrollEventDelegate {
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didChangeDisplayHeight displayHeight: CGFloat
    ) {
        print("displayHeight:", displayHeight)
    }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didBecomeIdleAtDisplayHeight displayHeight: CGFloat
    ) {
        print("all movement is idle at:", displayHeight)
    }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didScroll update: BODragScrollUpdate
    ) {
        switch update.source {
        case .panel:
            print("panel scrolling")
        case .participant(let scrollView):
            print("inner scrolling:", scrollView)
        }
    }
}

// 在 viewDidLoad 中设置。eventDelegate 是弱引用，控制器自身实现时无需额外持有。
dragScrollView.eventDelegate = self
```

`didChangeDisplayHeight` 是高度值变化通知；`didScroll` 是滚动事件通知，即使某次滚动没有改变面板高度也会如实回调。`didBecomeIdleAtDisplayHeight` 在最新一批拖拽、减速、动画、bounce 回位和延迟移动全部停止后只回调一次，适合提交最终业务状态；即使最终高度与上次相同也会回调。

### 无吸附点的自由面板

```swift
dragScrollView.detentHeights = []
dragScrollView.minimumDisplayHeight = 120
```

面板会在最小高度与自身固定高度之间连续移动，松手时不吸附；内部 ScrollView 仍可参与默认联动。

### 显式指定内部滚动区间

自动策略无法表达业务区间时，可在同一个 `behaviorProvider` 中返回显式配置：

```swift
func dragScrollView(
    _ dragScrollView: BODragScrollView,
    segmentsFor scrollView: UIScrollView
) -> [BODragScrollInnerScrollSegment]? {
    guard scrollView === tableView,
          let maximumHeight = dragScrollView.detentHeights.last else {
        return nil
    }

    return [
        .init(
            displayHeight: maximumHeight,
            beginOffsetY: nil,
            endOffsetY: nil
        )
    ]
}
```

首段的 `beginOffsetY = nil` 使用有效顶部边界，末段的 `endOffsetY = nil` 使用有效底部边界。返回 `nil` 或空数组会继续使用自动策略。

### 多层嵌套 ScrollView

无需手动逐层注册。触摸开始时，组件从最内层命中视图沿 responder chain 向外捕获纵向可滚的 ScrollView：最内层作为主参与者，可滚祖先按层级加入同一条组合滚动轴。

如需排除某一层，可实现 `canCapture`；如需改变主参与者或每层优先级，可实现 `adjustCaptureProposal`。普通嵌套列表不需要实现这两个回调。

### WKWebView

`WKWebView.scrollView` 默认会像普通内部 ScrollView 一样被自动捕获，不需要私有 API：

```swift
import WebKit

let webView = WKWebView(frame: .zero)
panelView.addSubview(webView)
```

需要让 Web 区域完全自行处理交互时：

```swift
var configuration = dragScrollView.configuration
configuration.capture.disablesPanelInteractionInWebView = true
dragScrollView.configuration = configuration
```

Web 内容中存在多层纵向 ScrollView，且希望放弃组件联动、交回 Web/UIKit 处理时，可设置 `ignoresMultipleNestedWebScrollViews = true`。

更多完整示例和边界说明见 [使用指南](docs/USAGE.md)。

## 其它配置速览

- `innerScrollPlacement` 还支持 `.afterPanelFullyDisplayed`、`.atDisplayHeight(...)` 和 `.fromTouchedPosition`。
- `handoff.mode` 还支持内部独立滚动和到达边界后再交给面板；`bounce` 配置控制顶部、底部回弹的 owner。
- `nonSnappingRanges` 可让指定高度区间跳过 detent 吸附。
- 内部列表的滚动范围发生业务性变化时可调用 `reloadScrollMetrics()`；panel 的外部尺寸输入变化时可调用 `invalidatePanelLayout()`。
- 手势优先级、scroll-to-top 和辅助功能均可通过类型化配置或 `behaviorProvider` 定制。

`behaviorProvider` 与 `eventDelegate` 都是弱引用。控制器自身实现协议最简单；若使用独立 provider/delegate 对象，业务方必须强持有它。继承自 `UIScrollView` 的 `delegate` 由组件内部使用，请不要覆盖。

## Demo 与文档

用 Xcode 打开 `Demo/BODragScrollDemo.xcodeproj`。Demo 提供自由面板、吸附与程序化移动、默认交接、多层滚动链、显式区间、WebKit、UIControl、手势和辅助功能等场景，并可在 Swift 与原 Objective-C 实现之间切换对比。

- [完整使用指南](docs/USAGE.md)
- [Swift 实现文档入口](docs/README.md)
- [整体架构](docs/ARCHITECTURE.md)
- [组合滚动模型](docs/SCROLL_MODEL.md)
- [交互生命周期](docs/INTERACTION_LIFECYCLE.md)

## 从 Objective-C 迁移

| Objective-C | Swift |
| --- | --- |
| `embedView` | `panelView` |
| `currDisplayH` | `displayHeight` |
| `attachDisplayHAr` | `detentHeights` |
| `misAttachRanges` | `nonSnappingRanges` |
| `minDisplayH` | `minimumDisplayHeight` |
| `scrollToDisplayH` | `scroll(toDisplayHeight:animated:options:completion:)` |
| `forceReloadCurrInnerScrollView` | `reloadScrollMetrics()` |
| `dragScrollDelegate` | `behaviorProvider` + `eventDelegate` |

所有公开 UIKit 操作都应在主线程执行，Swift 并发下由 `@MainActor` 约束。

## 验证

```sh
swift test
sh build_sim.sh
xcodebuild -scheme BODragScroll \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

测试持续覆盖纯 Swift 数学模型和 iOS UIKit 集成行为；不在首页硬编码用例数量，避免新增测试后说明失真。

## License

MIT © bo（[chbo297](https://github.com/chbo297)）
