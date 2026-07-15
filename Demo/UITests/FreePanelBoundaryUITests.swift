import XCTest

final class FreePanelBoundaryUITests: DemoUITestCase {
    func testFreePanelBoundariesAndImplementationSwitch() {
        _ = launch(scenario: .freePanel, implementation: .swift)

        let swiftMinimum = dragPanel(toNormalizedScreenY: 0.995)
        XCTAssertEqual(swiftMinimum, 104, accuracy: 0.75)

        let swiftMaximum = dragPanel(toNormalizedScreenY: 0.005)
        XCTAssertGreaterThan(swiftMaximum, 190)
        XCTAssertLessThanOrEqual(swiftMaximum, app.frame.height - 1)
        attachHUDTrace("free-panel-Swift-maximum")
        attachScreenshot("free-panel-Swift-maximum")

        switchImplementation(to: .objectiveC)
        XCTAssertEqual(waitForStableDisplayHeight(), 190, accuracy: 0.75)

        let objectiveCMinimum = dragPanel(toNormalizedScreenY: 0.995)
        XCTAssertEqual(objectiveCMinimum, 104, accuracy: 0.75)

        let objectiveCMaximum = dragPanel(toNormalizedScreenY: 0.005)
        XCTAssertGreaterThan(objectiveCMaximum, 190)
        XCTAssertLessThanOrEqual(objectiveCMaximum, app.frame.height - 1)
        XCTAssertEqual(objectiveCMaximum, swiftMaximum, accuracy: 0.75)
        attachHUDTrace("free-panel-OC-maximum")
        attachScreenshot("free-panel-OC-maximum")

        switchImplementation(to: .swift)
        XCTAssertEqual(waitForStableDisplayHeight(), 190, accuracy: 0.75)
    }
}
