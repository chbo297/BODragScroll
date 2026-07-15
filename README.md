# BODragScroll

`BODragScroll` 是 [BODragScrollView](https://github.com/chbo297/BODragScrollView) 的纯 Swift 重写：一个固定尺寸的卡片面板，通过“展示高度”控制可见区域，并把面板运动与触摸路径上的多层纵向 `UIScrollView` 组合成一条连续滚动轴。

实现目标不是逐行翻译 Objective-C，而是保留原项目的运行时行为、手感参数和系统时机修复，同时用类型化 API、纯数学模型和明确的职责边界消除原单文件实现中的隐式状态。

## 环境与安装

- iOS 13+
- Swift 5.7+
- UIKit
- 无第三方运行时依赖

Swift Package Manager：

```swift
.package(url: "https://github.com/chbo297/BODragScroll.git", from: "1.0.0")
```

CocoaPods：

```ruby
pod "BODragScroll"
```

## Demo 与新旧实现对比

用 Xcode 打开 `Demo/BODragScrollDemo.xcodeproj`。目录提供 9 个场景，覆盖自由面板、吸附与程序化移动、默认智能交接边界、列表交接、多层滚动链、显式内部区间、策略与回弹、WebKit、UIControl、横向手势和辅助功能。

每个功能页右上角都可通过 OC / Swift 分段标签在 Swift 重写版与原 Objective-C 实现之间重建切换；业务选项会保留，展示高度、内容 offset、捕获会话和运行中的动画会重置，便于从同一初始状态重复 A/B。Demo 中的 OC `.h/.m` 以源仓库实现为逻辑基线，并额外加入以 `~~~` 开头的诊断日志；功能修复会按语义同步，但不会用源文件整体覆盖这些日志。原实现的 `+load` swizzle 仍是进程级行为，因此这里用于功能对齐，不代表两个完全隔离进程的性能对照。

Swift 内部实现的推荐阅读顺序、组合滚动数学模型和 UIKit 生命周期见 [docs/README.md](docs/README.md)。

## 基本使用

```swift
import BODragScroll

let dragScrollView = BODragScrollView(frame: view.bounds)
view.addSubview(dragScrollView)

let panelView = YourPanelView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 800))
dragScrollView.panelView = panelView

// 所有高度均表示 panelView 当前可见的高度。
dragScrollView.detentHeights = [100, 400, 700]

dragScrollView.move(toDisplayHeight: 400, animated: false)
```

`panelView` 的尺寸在运动过程中保持不变。面板通过外层滚动偏移改变可见高度，内部 table view、collection view、普通 scroll view 或 Web 内容可在被触摸时自动加入联动。

## 三个核心命名

| 名称 | 含义 |
| --- | --- |
| `panelView` | 固定尺寸、被展示和拖动的业务面板 |
| `displayHeight` | `panelView` 当前实际可见高度 |
| `primaryParticipantScrollView`（内部） | 本次触摸从响应链捕获的最内层主参与者 |

捕获不是只找一个 scroll view。引擎从命中的最内层视图沿 responder chain 向外扫描，先形成候选集合，再确定主参与者，并把被配置为 `.participant` 的可滚动祖先按“主参与者 → 祖先”保存为 `participantChain`。纯模型会按真实层级和当前位置把祖先拆成 child 之前/之后的区间，因此同一个祖先可能在组合滚动轴上拥有多个不连续片段。

## 公开配置

```swift
var configuration = dragScrollView.configuration

configuration.handoff.mode = .coordinated
configuration.handoff.innerScrollPlacement = .automatic
configuration.handoff.offsetMismatch = .waitForValidSegment

configuration.bounce.preferredTopOwner = .panel
configuration.bounce.preferredBottomOwner = .innerScrollView

configuration.capture.ignoresMultipleNestedWebScrollViews = false
configuration.gesture.recognizesSimultaneouslyWithOtherGestures = true

configuration.movement.defaultStyle = .systemScroll
dragScrollView.configuration = configuration
```

主要行为分组：

- `handoff`：面板与内部滚动的交接方式、内部区间放置和错位恢复。
- `bounce`：顶部/底部回弹是否允许，以及回弹优先归属面板还是内部参与者。
- `capture`：响应链和 Web 内容的捕获策略。
- `gesture`：与其它手势的失败关系和同时识别策略。
- `movement`：系统滚动或视图动画、原项目手感阈值、时长和延迟发布策略。
- `indicator`：进入内部滚动时是否使用公开 UIKit API提示滚动指示器。

当默认自动区间不能表达业务需求时，可由 `BODragScrollBehaviorProvider` 返回类型化的内部区间：

```swift
@MainActor
final class PanelBehavior: BODragScrollBehaviorProvider {
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        segmentsFor scrollView: UIScrollView
    ) -> [BODragScrollInnerScrollSegment]? {
        [
            .init(displayHeight: 700, beginOffsetY: nil, endOffsetY: nil)
        ]
    }
}

let behavior = PanelBehavior()
dragScrollView.behaviorProvider = behavior
```

协议具有默认实现，只需实现需要接管的决策。`behaviorProvider` 只负责同步决策；`eventDelegate` 只负责事件通知，避免一个 delegate 同时承担输入和输出。

如果 panel 尺寸依赖安全区或其它外部状态，而 `BODragScrollView.bounds` 本身没有变化，在该状态变化后调用 `invalidatePanelLayout()`；组件会按 presentation 状态保存当前可见高度、中断旧移动并重新执行 sizing provider。

## 移动与完成语义

```swift
dragScrollView.move(
    toDisplayHeight: 700,
    animated: true,
    options: .init(style: .automatic)
) { result in
    print(result.finalDisplayHeight, result.outcome)
}

dragScrollView.settleToNearestDetent(animated: true)
dragScrollView.reloadScrollMetrics()
```

- 每个被接受的移动请求拥有独立 transaction。
- completion 和 `didFinishMovement` 对同一 transaction 最多调用一次。
- 请求可立即执行时，`move` 同步返回本次解析后的高度；若 UIKit 正处于布局/拖拽原子阶段，请求会延迟，
  此时同步值表示已接受的请求高度，最终解析值与结果以 completion 为准。
- 新请求、移除窗口或替换 `panelView` 会以 `.interrupted` 结束旧请求。
- 非法非有限高度以 `.cancelled` 结束，不进入动画。
- 布局前调用会保存意图，并在首次有效布局后执行。

## 运行机制

一次交互按以下阶段运行：

1. 命中测试兼容 presentation layer、触摸穿透、`UIControl`、Web 内容和独立减速中的嵌套 scroll view。
2. 从最内层命中视图沿响应链建立捕获候选；provider 可选择主参与者及调整每个候选的优先级。
3. 捕获会创建稳定的 `ParticipantID`，快照面板、主参与者和祖先的几何数据。
4. 纯 Swift 模型把 detent、面板区间和多个参与者区间合成为单一滚动轴。
5. `scrollViewDidScroll` 只对缓存模型做投影，再按固定顺序更新 `panelView.frame` 和各参与者 `contentOffset`。
6. 松手时纯求解器结合当前位置、系统预测、速度、非吸附区间和配置决定目标。
7. Transition 层通过系统滚动或视图动画执行目标，并补齐拖拽、减速、scroll-to-top、辅助功能和触摸结束时机。

## 数值语义

公开 detent 和显式内部区间保留 Objective-C `NSNumber.floatValue` 的 Float32 输入语义。

实现中有两种不同的数值带：

- 一个物理像素：用于“是否进入区间、是否位于边界”等运行时分支判定。
- 极小 jitter band：用于抑制同一次 UIKit 更新中的浮点抖动和重复回调。

它们都不是允许业务结果偏差的测试容差。模型的排序、有限性和区间单调性仍使用严格结构校验。

原项目的默认手感参数保持为：低速阈值 `0.2`、高速阈值 `2.2`、相邻边界距离 `86pt`、面板进入内部区间的捕获距离 `140pt`。

## UIScrollView 状态桥接

Objective-C 原实现通过 method swizzling，使被捕获内部 scroll view 的 `isDragging`、`isTracking`、`isDecelerating` 在联动期间反映外层驱动状态。Swift 版保留这一兼容语义，但缩小了边界：

- 进程内只安装一次公开 getter 的交换实现。
- 只有当前 capture session 的主参与者会建立弱关联；祖先参与者不伪装状态。
- session 结束立即解绑，关联不持有面板。
- 同时兼容 Objective-C `BOOL` 在不同架构上的 `B`/`c` ABI。
- 不保留 `BODragScrollLegacy`，也不提供运行期关闭后再恢复 IMP 的不安全开关。

## 文件结构与边界

生产实现由九个运行文件和一个仅在 DEBUG 编译的诊断文件组成：

| 文件 | 职责 |
| --- | --- |
| `BODragScrollTypes.swift` | 公开类型、配置、behavior provider 与 event delegate |
| `BODragScrollView.swift` | 公开入口、共享状态、panel 布局和几何不变量 |
| `BODragScrollUIScrollViewBridge.swift` | 主参与者滚动状态桥接和跨架构 ABI 处理 |
| `BODragScrollCapture.swift` | 响应链候选、capture session、参与者链、KVO 和模型快照 |
| `Core/BODragScrollModel.swift` | 无 UIKit 的组合滚动轴、嵌套片段构建和投影 |
| `Core/BODragScrollTargetSolver.swift` | 无 UIKit 的松手目标和吸附求解 |
| `BODragScrollScrolling.swift` | 高频 didScroll 投影、回弹分配、错位恢复和指示器 |
| `BODragScrollTransition.swift` | 移动 transaction、动画、拖拽/减速生命周期和 scroll-to-top |
| `BODragScrollInteraction.swift` | 命中测试、手势优先级、系统触摸补完和 accessibility |
| `BODragScrollDiagnostics.swift` | DEBUG Demo 观察事件；不参与捕获、手势或滚动决策 |

划分以“状态所有权 + 系统回调阶段”为边界，不再把一个 Objective-C `.m` 文件机械拆成大量微型 helper 文件；纯计算仅有两个 Core 文件，UIKit 生命周期仍围绕一个 `BODragScrollView` 聚合。

## 从 Objective-C API 迁移

| Objective-C 名称 | Swift 名称 |
| --- | --- |
| `embedView` | `panelView` |
| `currDisplayH` | `displayHeight` |
| `currentScrollView` | 内部 `primaryParticipantScrollView` |
| `attachDisplayHAr` | `detentHeights` |
| `misAttachRanges` | `nonSnappingRanges` |
| `minDisplayH` | `minimumDisplayHeight` |
| `scrollToDisplayH` | `move(toDisplayHeight:animated:options:completion:)` |
| `animationSetting` | `isAnimatingDisplayHeight`（只读） |
| `forceReloadCurrInnerScrollView` | `reloadScrollMetrics()` |
| `dragScrollDelegate` | `behaviorProvider` + `eventDelegate` |

继承自 `UIScrollView` 的 `delegate` 由组件内部持有：外部清空会被忽略，设置为其它对象会在 Debug 下报告错误；请使用 `behaviorProvider` 和 `eventDelegate`。所有公开 UIKit 操作均应在主线程执行，Swift 并发下由 `@MainActor` 约束。

## 验证

```sh
swift test
sh build_sim.sh
xcodebuild -scheme BODragScroll \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

当前验证包含 41 条纯 Swift 数学/模型/求解器测试和 70 条 iOS UIKit 集成测试，覆盖 Float32 与原生 CGFloat 来源语义、物理像素判定带、无吸附点联动、嵌套三层片段顺序、同一祖先的非连续区间、目标求解阈值、完成回调一次性、首次布局移动、响应链捕获与跨容器接管、Web 单候选 provider 回调、投影写入顺序、状态恢复、重入/析构生命周期和 accessibility。

## License

MIT © bo（[chbo297](https://github.com/chbo297)）
