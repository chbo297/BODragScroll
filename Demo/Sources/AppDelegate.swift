import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let navigationController = UINavigationController(rootViewController: makeInitialViewController())
        configureAppearance(for: navigationController)

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = navigationController
        window.tintColor = DemoPalette.accent
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    private func configureAppearance(for navigationController: UINavigationController) {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = DemoPalette.canvas
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: DemoPalette.ink]
        appearance.largeTitleTextAttributes = [.foregroundColor: DemoPalette.ink]

        navigationController.navigationBar.standardAppearance = appearance
        navigationController.navigationBar.compactAppearance = appearance
        navigationController.navigationBar.scrollEdgeAppearance = appearance
        navigationController.navigationBar.prefersLargeTitles = false
    }

    private func makeInitialViewController() -> UIViewController {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "-DemoScenario"),
              arguments.indices.contains(flagIndex + 1),
              let scenarioIndex = Int(arguments[flagIndex + 1]) else {
            return DemoCatalogViewController()
        }
        let scenarios = DemoCatalog.sections.flatMap(\.scenarios)
        guard scenarios.indices.contains(scenarioIndex) else {
            return DemoCatalogViewController()
        }
        let implementation = launchImplementation(from: arguments)
        return scenarios[scenarioIndex].makeViewController(implementation)
    }

    private func launchImplementation(from arguments: [String]) -> DemoImplementation {
        guard let flagIndex = arguments.firstIndex(of: "-DemoImplementation"),
              arguments.indices.contains(flagIndex + 1) else {
            return .swift
        }
        switch arguments[flagIndex + 1].lowercased() {
        case "oc", "objc", "objective-c", "objectivec":
            return .objectiveC
        default:
            return .swift
        }
    }
}
