# BODragScroll 使用指南

本文只说明公开 API 的常用接入方式。组件内部结构、数学模型和 UIKit 时序分别见 [ARCHITECTURE.md](ARCHITECTURE.md)、[SCROLL_MODEL.md](SCROLL_MODEL.md) 和 [INTERACTION_LIFECYCLE.md](INTERACTION_LIFECYCLE.md)。

## 1. 基本心智模型

- `BODragScrollView` 是负责接收手势和承载组合滚动轴的 host。
- `panelView` 是固定尺寸的业务面板；运动改变的是它的可见高度，不会在每一帧修改它的尺寸。
- `displayHeight` 是面板当前实际展示高度，也是业务观察面板状态的主坐标。
- `detentHeights` 是松手时允许吸附的高度。
- 被触摸的内部 `UIScrollView` 会沿 responder chain 自动捕获，通常不需要注册。

`behaviorProvider` 只提供同步决策，`eventDelegate` 只接收事件。二者都是弱引用；控制器自身实现协议最简单，独立对象则需要由业务方强持有。

## 2. 三态面板与默认自动联动

[首页推荐示例](../README.md#推荐接入三态面板与默认内部联动) 给出了可直接运行的 `UIViewController`。接入顺序是：

1. 把 `BODragScrollView` 放入业务界面；
2. 在 `panelView` 内完成列表等业务布局；
3. 设置配置和 `behaviorProvider`；
4. 最后设置 `panelView`，触发首次面板布局。

### 2.1 在 sizing 回调中统一配置

```swift
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
        proposedDisplayHeight = lowHeight
    } else {
        proposedDisplayHeight = min(
            maximumHeight,
            max(lowHeight, proposedDisplayHeight)
        )
    }

    return CGSize(
        width: dragScrollView.bounds.width,
        height: maximumHeight
    )
}
```

这个回调对应 Objective-C 的 `layoutEmbedView`：返回值决定固定面板尺寸，`proposedDisplayHeight` 决定本次布局希望保持或展示的高度。

示例把 host 全高作为业务的最大面板高度。这只是一种布局选择；业务可以返回其他固定尺寸，组件不替业务决定视觉上限。

首次展示高度应直接写入 `proposedDisplayHeight`，不要在回调中调用 `move(...)`。后续布局一般保留传入值，只在新的业务尺寸范围内做约束。`detentHeights` 应按变化设置，避免每次布局重复触发配置刷新。

### 2.2 默认交接策略

```swift
var configuration = dragScrollView.configuration
configuration.handoff.mode = .coordinated
configuration.handoff.innerScrollPlacement = .automatic
configuration.handoff.minimumInnerVisibilityRatio = 0.7
dragScrollView.configuration = configuration
```

- `.coordinated` 把面板移动与内部 offset 合并成一条连续滚动轴。
- `.automatic` 从当前高度向更高的 detent 搜索内部滚动区间的放置高度。
- `minimumInnerVisibilityRatio` 是自动搜索时要求内部 ScrollView 已显示的最小比例，默认是 `0.7`。

例如内部列表从 `panelView.y = 40` 延伸到底部，而中间态只展示面板高度的 52%，那么中间态达不到 70% 可见比例，默认区间会放在最高态。

这些值本身就是默认配置。示例显式设置是为了让行为一目了然；如果使用默认行为，可以完全不写这段配置。

## 3. 程序化移动

### 3.1 移动到指定展示高度

```swift
dragScrollView.move(
    toDisplayHeight: targetHeight,
    animated: true,
    options: .init(style: .automatic)
) { result in
    switch result.outcome {
    case .completed:
        print("完成：", result.finalDisplayHeight)
    case .cancelled:
        print("请求未执行")
    case .interrupted:
        print("被新的交互或移动替代")
    }
}
```

同步返回值表示当前调用已经解析或接受的高度。请求若在布局、拖拽等 UIKit 原子阶段被延后，最终结果应以 completion 中的 `finalDisplayHeight` 为准。

### 3.2 吸附到最近 detent

```swift
dragScrollView.settleToNearestDetent(animated: true)
```

当 `detentHeights` 为空时，这个方法是 no-op。

## 4. 事件监听

```swift
extension DemoViewController: BODragScrollEventDelegate {
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didChangeDisplayHeight displayHeight: CGFloat
    ) {
        print("展示高度：", displayHeight)
    }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didScroll update: BODragScrollUpdate
    ) {
        switch update.source {
        case .panel:
            print("本次由面板区间消费")
        case .participant(let scrollView):
            print("本次由内部 ScrollView 消费：", scrollView)
        }
    }

    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didFinishMovement result: BODragScrollMovementResult
    ) {
        print(result.reason, result.outcome)
    }
}
```

在初始化时设置：

```swift
dragScrollView.eventDelegate = self
```

- `didChangeDisplayHeight` 具有值变化语义，只在展示高度确实变化时发布。
- `didScroll` 具有滚动事件语义，不会因为展示高度相同而过滤。
- `didFinishMovement` 与对应 `move` completion 对同一移动事务都最多调用一次。

不要设置继承自 `UIScrollView` 的 `delegate`；它由组件内部持有。

## 5. 无吸附点的自由面板

```swift
dragScrollView.detentHeights = []
dragScrollView.minimumDisplayHeight = 120
```

无 detent 时，面板在 `minimumDisplayHeight` 与面板固定高度之间连续移动，松手保持系统解析的位置。默认自动捕获仍然有效，面板和内部 ScrollView 仍可联动。

如果未设置 `minimumDisplayHeight`，组件使用自身的默认有效最小高度。

## 6. 显式内部滚动区间

显式区间适合以下情况：

- 必须在某一个业务高度才允许滑内部；
- 内部 offset 只有一部分需要参与联动；
- 同一个内部 ScrollView 需要在多个面板高度承接不同 offset 段。

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

边界规则：

- 第一段 `beginOffsetY = nil`：从该 ScrollView 的有效顶部 offset 开始；
- 最后一段 `endOffsetY = nil`：一直到有效底部 offset；
- 多段需要按 `displayHeight` 和内部 offset 单调排列；
- 非法条目会被忽略；没有有效条目时回退到自动建段；
- 返回 `nil` 或空数组表示不接管，继续使用默认自动策略。

显式区间只覆盖传入的那个 ScrollView，不会要求业务手动维护捕获生命周期。

## 7. 多层嵌套 ScrollView

当触摸路径类似：

```text
panelView
└── outerScrollView
    └── contentView
        └── innerTableView   ← 手指按下的位置
```

组件会从最内层命中视图沿 responder chain 向外扫描：

1. 默认选择最内层可纵向滚动视图作为主参与者；
2. 默认标记为 participant 的纵向可滚祖先按 `primary → ancestors` 加入参与链；
3. 纯横向 ScrollView 默认保留给 UIKit，不自动加入纵向联动；
4. 一次手势期间使用稳定的捕获快照，业务无需随着滚动逐帧注册或切换对象。

普通嵌套结构不需要额外代码。如需排除某个业务列表：

```swift
func dragScrollView(
    _ dragScrollView: BODragScrollView,
    canCapture scrollView: UIScrollView
) -> Bool {
    scrollView !== independentlyScrollingView
}
```

如需改选主参与者或改变某一层优先级，实现：

```swift
func dragScrollView(
    _ dragScrollView: BODragScrollView,
    adjustCaptureProposal proposal: inout BODragScrollCaptureProposal
) {
    // 默认提案已经满足常见嵌套列表；这里只处理明确的业务例外。
}
```

provider 回调是同步决策点。不要在回调中重排正在参与捕获的视图层级。

## 8. WKWebView

```swift
import WebKit

let webView = WKWebView(frame: .zero)
webView.translatesAutoresizingMaskIntoConstraints = false
panelView.addSubview(webView)
```

默认情况下，`WKWebView.scrollView` 会作为普通纵向参与者被捕获，网页按钮、链接和输入控件仍由 WebKit 正常处理。

### 8.1 Web 区域独立交互

```swift
var configuration = dragScrollView.configuration
configuration.capture.disablesPanelInteractionInWebView = true
dragScrollView.configuration = configuration
```

开启后，触摸位于 Web 内容中时不启动面板联动。

### 8.2 Web 内多层滚动交回 WebKit

```swift
var configuration = dragScrollView.configuration
configuration.capture.ignoresMultipleNestedWebScrollViews = true
dragScrollView.configuration = configuration
```

开启后，如果 Web 容器内检测到多层纵向 ScrollView，组件放弃本次捕获，让 WebKit/UIKit 自己处理。默认值为 `false`，即允许按普通嵌套链参与。

## 9. 其它能力速查

- 内部内容量、inset 或业务滚动范围更新后，可调用 `reloadScrollMetrics()` 立即按新数据重建。
- panel 的外部尺寸输入变化而 host bounds 不变时，可调用 `invalidatePanelLayout()` 重新询问 sizing provider。
- `nonSnappingRanges` 指定松手时不执行 detent 吸附的高度区间。
- `configuration.bounce` 控制顶部、底部回弹是否允许以及由面板还是内部 ScrollView 承担。
- `.innerFirst` 和 `.innerFirstAtBoundary` 用于内部独立或内部边界优先的非默认交接方式。
- 手势冲突、scroll-to-top 和辅助功能均有对应的类型化 provider 回调；无明确业务要求时使用默认值。

## 10. 常见边界

- 在 `panelView` 赋值前设置需要参与首次布局的配置和 `behaviorProvider`。
- sizing 回调负责尺寸和布局提案，不要从其中启动新的程序化移动。
- `behaviorProvider` 与 `eventDelegate` 都是弱引用；独立对象需要由业务方强持有。
- 不要覆盖 `BODragScrollView.delegate`，使用 `behaviorProvider` 和 `eventDelegate`。
- UI API 应在主线程调用；公开接口通过 `@MainActor` 表达这一约束。
