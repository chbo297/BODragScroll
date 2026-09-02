import UIKit

struct DemoScenario {
    let title: String
    let subtitle: String
    let symbolName: String
    let tint: UIColor
    let makeViewController: @MainActor (DemoImplementation) -> UIViewController
}

struct DemoScenarioSection {
    let title: String
    let footer: String?
    let scenarios: [DemoScenario]
}

enum DemoCatalog {
    static let sections: [DemoScenarioSection] = [
        DemoScenarioSection(
            title: "基础能力",
            footer: "先体验面板本身，再观察吸附和程序化移动。",
            scenarios: [
                DemoScenario(
                    title: "自由面板",
                    subtitle: "固定尺寸 panel、连续拖动、最小与最大边界",
                    symbolName: "hand.draw.fill",
                    tint: DemoPalette.orange,
                    makeViewController: { FreePanelViewController(implementation: $0) }
                ),
                DemoScenario(
                    title: "吸附与程序化移动",
                    subtitle: "三档 detent、非吸附区、两种动画与 completion",
                    symbolName: "circle.grid.2x2.fill",
                    tint: DemoPalette.purple,
                    makeViewController: { MovementLabViewController(implementation: $0) }
                )
            ]
        ),
        DemoScenarioSection(
            title: "嵌套滚动",
            footer: "参与者只会通过真实触摸自动捕获，Demo 不访问任何 internal session。",
            scenarios: [
                DemoScenario(
                    title: "列表连续交接",
                    subtitle: "面板展开后 UITableView 接管，向下滚动时反向交还",
                    symbolName: "list.bullet",
                    tint: DemoPalette.blue,
                    makeViewController: { TableHandoffViewController(implementation: $0) }
                ),
                DemoScenario(
                    title: "默认智能交接边界",
                    subtitle: "y=40、2000pt 内容、三档吸附，从最低档验证自动接管高度",
                    symbolName: "arrow.up.and.down.and.arrow.left.and.right",
                    tint: DemoPalette.indigo,
                    makeViewController: { AutomaticSmartHandoffViewController(implementation: $0) }
                ),
                DemoScenario(
                    title: "三层滚动链",
                    subtitle: "外层 ScrollView → 中层 ScrollView → 最内层 TableView",
                    symbolName: "square.stack.3d.up.fill",
                    tint: DemoPalette.teal,
                    makeViewController: { NestedScrollChainViewController(implementation: $0) }
                ),
                DemoScenario(
                    title: "显式内部区间",
                    subtitle: "在两个 displayHeight 上开放不同的列表 offset 区间",
                    symbolName: "point.3.connected.trianglepath.dotted",
                    tint: DemoPalette.red,
                    makeViewController: { ExplicitSegmentsViewController(implementation: $0) }
                )
            ]
        ),
        DemoScenarioSection(
            title: "行为策略",
            footer: "页面内修改配置后，下一次真实触摸会使用新策略。",
            scenarios: [
                DemoScenario(
                    title: "Handoff 与回弹实验室",
                    subtitle: "交接模式、回弹归属和 collapse resistance 实时切换",
                    symbolName: "slider.horizontal.3",
                    tint: DemoPalette.green,
                    makeViewController: { PolicyLabViewController(implementation: $0) }
                )
            ]
        ),
        DemoScenarioSection(
            title: "系统集成",
            footer: "覆盖 WebKit、UIControl、横向手势及系统辅助功能边界。",
            scenarios: [
                DemoScenario(
                    title: "离线 Web 内容",
                    subtitle: "WKWebView 自动捕获与 Web 区域内禁用面板交互",
                    symbolName: "globe",
                    tint: DemoPalette.indigo,
                    makeViewController: { WebContentViewController(implementation: $0) }
                ),
                DemoScenario(
                    title: "控件与横向手势",
                    subtitle: "Button、Switch、Slider 与横向 carousel 保持原生交互",
                    symbolName: "hand.tap.fill",
                    tint: DemoPalette.pink,
                    makeViewController: { ControlsAndGesturesViewController(implementation: $0) }
                ),
                DemoScenario(
                    title: "惯性中的 UIControl",
                    subtitle: "固定、悬浮和列表内 UIButton/UIControl 的点击与取消语义",
                    symbolName: "hand.raised.fill",
                    tint: DemoPalette.orange,
                    makeViewController: { DecelerationControlLabViewController(implementation: $0) }
                )
            ]
        )
    ]
}
