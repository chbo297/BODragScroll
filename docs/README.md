# BODragScroll 文档

本目录同时提供面向使用者的接入指南，以及面向维护者的 Swift 实现说明。先从公开 API 建立业务心智模型，再按需要进入数学模型和 UIKit 生命周期。

## 推荐阅读顺序

1. [根目录 README](../README.md)：安装和三态面板的完整推荐接入示例。
2. [USAGE.md](USAGE.md)：程序化移动、事件、自由面板、显式区间、多层嵌套和 Web 内容。
3. [ARCHITECTURE.md](ARCHITECTURE.md)：整体分层、功能模块、状态所有权和源码文件边界。
4. [SCROLL_MODEL.md](SCROLL_MODEL.md)：组合滚动轴、参与段、嵌套拆段、投影和松手目标求解。
5. [INTERACTION_LIFECYCLE.md](INTERACTION_LIFECYCLE.md)：布局、手指按下、滑动、抬手、减速、手势和辅助功能的完整时序。

只接入组件时，阅读前两项即可；后三项用于理解或修改组件内部实现。

## 快速心智模型

- `panelView` 是固定尺寸的业务面板；组件改变的是它的可见高度，而不是反复修改它的高度。
- `displayHeight` 是面板当前实际可见高度，是外部理解所有状态与回调的主坐标。
- 一次触摸会从最内层命中视图沿响应链捕获可参与的 `UIScrollView`，形成 `primary → ancestors` 的参与链。
- detent、面板移动区间和所有参与者的内部滚动区间会被合成为一条连续的外部滚动轴。
- 高频 `didScroll` 只投影已缓存的纯数学模型；抬手时由纯求解器决定是否吸附，再由 Transition 层执行目标。
- `didScroll` 表达滚动事件并如实发布；`didChangeDisplayHeight` 表达高度值变化，二者不共用去重策略。
- 回弹 owner 决定参与者固定高度是否继续有效；布局重建使用 transaction epoch 防止旧 layout 覆盖回调中新建的 movement，同时在新事务已结束时仍发布真实几何。

## 文档与代码一致性

修改以下内容时应同步更新文档：

- 新增或改变公开配置、provider、delegate 回调；
- 改变首页推荐接入方式或常用业务配方；
- 改变捕获候选、嵌套参与者或 WebView 规则；
- 改变 `ScrollSegment` 的构建、顺序或投影公式；
- 改变拖拽、减速、动画、scroll-to-top 的生命周期所有权；
- 新增生产源码文件或重新划分模块职责。
