# BODragScroll Swift 实现文档

本目录解释 Swift 重写版的结构、数学原理、UIKit 运行时机和维护边界。阅读顺序从业务能力出发，再逐步进入内部实现，不要求先理解原 Objective-C 单文件代码。

## 推荐阅读顺序

1. [ARCHITECTURE.md](ARCHITECTURE.md)：整体分层、功能模块、状态所有权和源码文件边界。
2. [SCROLL_MODEL.md](SCROLL_MODEL.md)：组合滚动轴、参与段、嵌套拆段、投影和松手目标求解。
3. [INTERACTION_LIFECYCLE.md](INTERACTION_LIFECYCLE.md)：布局、手指按下、滑动、抬手、减速、手势和辅助功能的完整时序。

根目录 [README.md](../README.md) 面向组件使用者，包含安装、公开 API、迁移表和 Demo；本目录面向维护组件实现的开发者。

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
- 改变捕获候选、嵌套参与者或 WebView 规则；
- 改变 `ScrollSegment` 的构建、顺序或投影公式；
- 改变拖拽、减速、动画、scroll-to-top 的生命周期所有权；
- 新增生产源码文件或重新划分模块职责。
