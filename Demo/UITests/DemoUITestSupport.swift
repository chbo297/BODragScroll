import Foundation
import XCTest

enum DemoScenarioUnderTest: Int, CaseIterable {
    case freePanel = 0
    case movement
    case tableHandoff
    case automaticSmartHandoff
    case nestedScrollChain
    case explicitSegments
    case policyLab
    case webContent
    case controlsAndGestures

    var name: String {
        switch self {
        case .freePanel: return "free-panel"
        case .movement: return "movement"
        case .tableHandoff: return "table-handoff"
        case .automaticSmartHandoff: return "automatic-smart-handoff"
        case .nestedScrollChain: return "nested-scroll-chain"
        case .explicitSegments: return "explicit-segments"
        case .policyLab: return "policy-lab"
        case .webContent: return "web-content"
        case .controlsAndGestures: return "controls-and-gestures"
        }
    }

    var expectedInitialDisplayHeight: CGFloat {
        switch self {
        case .freePanel: return 190
        case .movement: return 390
        case .tableHandoff: return 250
        case .automaticSmartHandoff: return 150
        case .nestedScrollChain: return 300
        case .explicitSegments: return 230
        case .policyLab: return 330
        case .webContent: return 260
        case .controlsAndGestures: return 310
        }
    }
}

enum DemoImplementationUnderTest: String {
    case swift = "Swift"
    case objectiveC = "OC"
}

enum DemoAccessibilityID {
    static let dragHost = "demo.dragHost"
    static let panel = "demo.panel"
    static let panelGrabber = "demo.panelGrabber"
    static let eventHUD = "demo.eventHUD"
    static let ready = "demo.ready"
    static let switchImplementation = "demo.switchImplementation"
}

struct DemoHUDSnapshot {
    let displayHeight: CGFloat?
    let rawText: String
    let traceLines: [String]
}

struct DemoTraceSample {
    let sequence: Int
    let displayHeight: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    let line: String
}

class DemoUITestCase: XCTestCase {
    private(set) var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning {
            app.terminate()
        }
        app = nil
        try super.tearDownWithError()
    }

    @discardableResult
    func launch(
        scenario: DemoScenarioUnderTest,
        implementation: DemoImplementationUnderTest,
        launchEnvironment: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGFloat {
        if let app, app.state != .notRunning {
            app.terminate()
        }

        let application = XCUIApplication()
        application.launchArguments = [
            "-DemoScenario", String(scenario.rawValue),
            "-DemoImplementation", implementation == .swift ? "swift" : "oc"
        ]
        application.launchEnvironment["BODRAGSCROLL_UI_TESTING"] = "1"
        for (key, value) in launchEnvironment {
            application.launchEnvironment[key] = value
        }
        application.launch()
        app = application

        waitForReady(expectedImplementation: implementation, file: file, line: line)
        assertCurrentImplementation(implementation, file: file, line: line)

        let height = waitForStableDisplayHeight(file: file, line: line)
        XCTAssertEqual(
            height,
            scenario.expectedInitialDisplayHeight,
            accuracy: 0.75,
            "Unexpected initial display height for \(scenario.name)/\(implementation.rawValue)",
            file: file,
            line: line
        )
        return height
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    func requireElement(
        _ identifier: String,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let result = element(identifier)
        if !result.exists {
            XCTAssertTrue(
                result.waitForExistence(timeout: timeout),
                "Missing accessibility element \(identifier). Hierarchy:\n\(app.debugDescription)",
                file: file,
                line: line
            )
        }
        return result
    }

    func waitForReady(
        expectedImplementation: DemoImplementationUnderTest? = nil,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ready = requireElement(DemoAccessibilityID.ready, timeout: timeout, file: file, line: line)
        XCTAssertTrue(
            waitUntil(timeout: timeout) {
                guard let value = ready.value as? String else { return false }
                guard !value.isEmpty && value != "false" else { return false }
                guard let expectedImplementation else { return true }
                return value.hasPrefix(expectedImplementation.rawValue + "|")
            },
            "Scenario marker exists but did not become ready. Value: \(String(describing: ready.value))",
            file: file,
            line: line
        )
        requireElement(DemoAccessibilityID.dragHost, timeout: timeout, file: file, line: line)
        requireElement(DemoAccessibilityID.panel, timeout: timeout, file: file, line: line)
        requireElement(DemoAccessibilityID.panelGrabber, timeout: timeout, file: file, line: line)
        requireElement(DemoAccessibilityID.eventHUD, timeout: timeout, file: file, line: line)
        requireElement(DemoAccessibilityID.switchImplementation, timeout: timeout, file: file, line: line)
    }

    func switchImplementation(
        to implementation: DemoImplementationUnderTest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if currentImplementationMatches(implementation) { return }

        let tabs = requireElement(
            DemoAccessibilityID.switchImplementation,
            file: file,
            line: line
        )
        XCTAssertTrue(tabs.isHittable, "Implementation tabs are not hittable", file: file, line: line)

        let targetTab = tabs.buttons[implementation.rawValue].firstMatch
        if targetTab.exists && targetTab.isHittable {
            targetTab.tap()
        } else {
            // UISegmentedControl exposes its child buttons differently across iOS versions.
            // Keep a coordinate fallback while still selecting the requested tab explicitly.
            tabs.coordinate(
                withNormalizedOffset: CGVector(
                    dx: implementation == .objectiveC ? 0.25 : 0.75,
                    dy: 0.5
                )
            ).tap()
        }

        XCTAssertTrue(
            waitUntil(timeout: 8) { [weak self] in
                self?.currentImplementationMatches(implementation) == true
            },
            "Implementation did not switch to \(implementation.rawValue). Marker: \(implementationMarkerText())",
            file: file,
            line: line
        )
        waitForReady(expectedImplementation: implementation, file: file, line: line)
        assertImplementationTabSelection(implementation, file: file, line: line)
        _ = waitForStableDisplayHeight(file: file, line: line)
    }

    func assertCurrentImplementation(
        _ implementation: DemoImplementationUnderTest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            currentImplementationMatches(implementation),
            "Expected \(implementation.rawValue), marker was: \(implementationMarkerText())",
            file: file,
            line: line
        )
        assertImplementationTabSelection(implementation, file: file, line: line)
    }

    private func assertImplementationTabSelection(
        _ implementation: DemoImplementationUnderTest,
        file: StaticString,
        line: UInt
    ) {
        let tabs = requireElement(DemoAccessibilityID.switchImplementation, file: file, line: line)
        let marker = accessibilityStrings(from: tabs).joined(separator: " | ")
        XCTAssertTrue(
            marker.contains("当前为\(implementation.rawValue)实现"),
            "Implementation tab does not announce its current selection: \(marker)",
            file: file,
            line: line
        )

        // The iOS runtime used by UI parity tests exposes UISegmentedControl children as buttons.
        // Keep the value assertion above as the cross-version contract, then verify the visual
        // selected trait whenever those children are present.
        let selectedTab = tabs.buttons[implementation.rawValue].firstMatch
        if selectedTab.exists {
            XCTAssertTrue(
                selectedTab.isSelected,
                "The \(implementation.rawValue) segment is visible but not selected",
                file: file,
                line: line
            )
        }
        let otherLabel = implementation == .swift ? "OC" : "Swift"
        let otherTab = tabs.buttons[otherLabel].firstMatch
        if otherTab.exists {
            XCTAssertFalse(
                otherTab.isSelected,
                "Both implementation segments appear selected",
                file: file,
                line: line
            )
        }
    }

    func readHUDSnapshot() -> DemoHUDSnapshot {
        let hud = element(DemoAccessibilityID.eventHUD)
        guard hud.exists else {
            return DemoHUDSnapshot(displayHeight: nil, rawText: "<missing demo.eventHUD>", traceLines: [])
        }

        let strings = orderedUnique(accessibilityStrings(from: hud).filter { !$0.isEmpty })
        let raw = strings.joined(separator: "\n")
        let displayHeight = displayHeight(in: raw)
        let traceLines = traceLines(from: strings)
        return DemoHUDSnapshot(displayHeight: displayHeight, rawText: raw, traceLines: traceLines)
    }

    func waitForStableDisplayHeight(
        timeout: TimeInterval = 7,
        accuracy: CGFloat = 0.2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        var last: CGFloat?
        var stableSamples = 0
        var mostRecentSnapshot = readHUDSnapshot()

        while Date() < deadline {
            mostRecentSnapshot = readHUDSnapshot()
            if let value = mostRecentSnapshot.displayHeight {
                if let last, abs(last - value) <= accuracy {
                    stableSamples += 1
                } else {
                    stableSamples = 0
                }
                last = value
                if stableSamples >= 2 { return value }
            }
            Thread.sleep(forTimeInterval: 0.15)
        }

        XCTFail(
            "Display height did not become readable and stable. HUD:\n\(mostRecentSnapshot.rawText)",
            file: file,
            line: line
        )
        return last ?? .nan
    }

    @discardableResult
    func dragPanel(
        deltaY: CGFloat,
        velocity: XCUIGestureVelocity = .slow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGFloat {
        _ = requireElement(DemoAccessibilityID.panelGrabber, file: file, line: line)
        let before = waitForStableDisplayHeight(file: file, line: line)
        let appFrame = app.frame
        // AX reports descendants of a scrolled UIScrollView in content coordinates on some
        // runtimes. Derive the real visible header point from the observed display height instead.
        let startPoint = CGPoint(
            x: appFrame.midX,
            y: min(appFrame.maxY - 2, max(appFrame.minY + 2, appFrame.maxY - before + 22))
        )
        let targetY = min(appFrame.maxY - 2, max(appFrame.minY + 2, startPoint.y + deltaY))
        let normalizedX = (startPoint.x - appFrame.minX) / max(appFrame.width, 1)
        let normalizedY = (targetY - appFrame.minY) / max(appFrame.height, 1)
        let start = app.coordinate(
            withNormalizedOffset: CGVector(
                dx: (startPoint.x - appFrame.minX) / max(appFrame.width, 1),
                dy: (startPoint.y - appFrame.minY) / max(appFrame.height, 1)
            )
        )
        let destination = app.coordinate(
            withNormalizedOffset: CGVector(dx: normalizedX, dy: normalizedY)
        )
        start.press(
            forDuration: 0.20,
            thenDragTo: destination,
            withVelocity: velocity,
            thenHoldForDuration: 0.05
        )
        _ = waitUntil(timeout: 2) { [weak self] in
            guard let height = self?.readHUDSnapshot().displayHeight else { return false }
            return abs(height - before) > 0.5
        }
        return waitForStableDisplayHeight(file: file, line: line)
    }

    @discardableResult
    func dragPanel(
        toNormalizedScreenY normalizedY: CGFloat,
        velocity: XCUIGestureVelocity = .slow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGFloat {
        _ = requireElement(DemoAccessibilityID.panelGrabber, file: file, line: line)
        let before = waitForStableDisplayHeight(file: file, line: line)
        let appFrame = app.frame
        let startPoint = CGPoint(
            x: appFrame.midX,
            y: min(appFrame.maxY - 2, max(appFrame.minY + 2, appFrame.maxY - before + 22))
        )
        let clampedY = min(0.995, max(0.005, normalizedY))
        let normalizedX = (startPoint.x - appFrame.minX) / max(appFrame.width, 1)
        let start = app.coordinate(
            withNormalizedOffset: CGVector(
                dx: normalizedX,
                dy: (startPoint.y - appFrame.minY) / max(appFrame.height, 1)
            )
        )
        let destination = app.coordinate(
            withNormalizedOffset: CGVector(dx: normalizedX, dy: clampedY)
        )
        start.press(
            forDuration: 0.20,
            thenDragTo: destination,
            withVelocity: velocity,
            thenHoldForDuration: 0.05
        )
        _ = waitUntil(timeout: 2) { [weak self] in
            guard let height = self?.readHUDSnapshot().displayHeight else { return false }
            return abs(height - before) > 0.5
        }
        return waitForStableDisplayHeight(file: file, line: line)
    }

    func swipe(
        _ element: XCUIElement,
        from start: CGVector,
        to end: CGVector,
        velocity: XCUIGestureVelocity = .fast
    ) {
        element.coordinate(withNormalizedOffset: start).press(
            forDuration: 0.08,
            thenDragTo: element.coordinate(withNormalizedOffset: end),
            withVelocity: velocity,
            thenHoldForDuration: 0
        )
    }

    /// Starts inside the currently visible panel content rather than trusting AX frames reported
    /// for descendants of the host UIScrollView. This is the repeatable gesture used by the nested
    /// participant, WebKit and policy parity cases.
    func dragVisiblePanelContent(
        deltaY: CGFloat,
        visibleOffsetFromPanelTop: CGFloat = 210,
        normalizedX: CGFloat = 0.5,
        velocity: XCUIGestureVelocity = .slow
    ) {
        let height = waitForStableDisplayHeight()
        let frame = app.frame
        let panelTop = frame.maxY - height
        let availableInsidePanel = max(24, height - 24)
        let startY = min(
            frame.maxY - 24,
            max(frame.minY + 24, panelTop + min(visibleOffsetFromPanelTop, availableInsidePanel))
        )
        let destinationY = min(frame.maxY - 4, max(frame.minY + 4, startY + deltaY))
        let start = app.coordinate(
            withNormalizedOffset: CGVector(
                dx: min(0.95, max(0.05, normalizedX)),
                dy: (startY - frame.minY) / max(frame.height, 1)
            )
        )
        let destination = app.coordinate(
            withNormalizedOffset: CGVector(
                dx: min(0.95, max(0.05, normalizedX)),
                dy: (destinationY - frame.minY) / max(frame.height, 1)
            )
        )
        start.press(
            forDuration: 0.18,
            thenDragTo: destination,
            withVelocity: velocity,
            thenHoldForDuration: 0.05
        )
    }

    @discardableResult
    func scrollToElement(
        _ identifier: String,
        in scrollIdentifier: String,
        direction: XCUISwipeDirection = .up,
        maximumSwipes: Int = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let target = requireElement(identifier, file: file, line: line)
        let scrollView = requireElement(scrollIdentifier, file: file, line: line)
        for _ in 0..<maximumSwipes where !target.isHittable {
            switch direction {
            case .down: scrollView.swipeDown()
            case .left: scrollView.swipeLeft()
            case .right: scrollView.swipeRight()
            default: scrollView.swipeUp()
            }
        }
        XCTAssertTrue(
            target.isHittable,
            "Element \(identifier) did not become hittable in \(scrollIdentifier)",
            file: file,
            line: line
        )
        return target
    }

    @discardableResult
    func selectSegment(
        control identifier: String,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let control = requireElement(identifier, file: file, line: line)
        let button = control.buttons[label]
        XCTAssertTrue(
            button.waitForExistence(timeout: 3),
            "Missing segment \(label) in \(identifier)",
            file: file,
            line: line
        )
        XCTAssertTrue(button.isHittable, "Segment \(label) is not hittable", file: file, line: line)
        button.tap()
        XCTAssertTrue(
            waitUntil(timeout: 2) { button.isSelected },
            "Segment \(label) in \(identifier) did not become selected",
            file: file,
            line: line
        )
        return button
    }

    func elementText(_ identifier: String) -> String {
        accessibilityStrings(from: element(identifier)).joined(separator: " | ")
    }

    var latestTraceSequence: Int {
        readHUDSnapshot().traceLines.compactMap(Self.traceSequence).max() ?? 0
    }

    func traceLines(after sequence: Int = 0) -> [String] {
        readHUDSnapshot().traceLines.filter { (Self.traceSequence($0) ?? 0) > sequence }
    }

    func traceCount(callback: String, after sequence: Int = 0) -> Int {
        traceLines(after: sequence).filter { $0.contains(" \(callback) h=") }.count
    }

    func traceSamples(for identifier: String, after sequence: Int = 0) -> [DemoTraceSample] {
        let escapedIdentifier = NSRegularExpression.escapedPattern(for: identifier)
        let number = #"([+-]?(?:\d+(?:\.\d+)?|\.\d+))"#
        guard let heightExpression = try? NSRegularExpression(pattern: #" h="# + number),
              let offsetExpression = try? NSRegularExpression(
                pattern: escapedIdentifier + #" offset=\("# + number + #","# + number + #"\)"#
              ) else { return [] }

        return traceLines(after: sequence).compactMap { line in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let heightMatch = heightExpression.firstMatch(in: line, range: range),
                  let offsetMatch = offsetExpression.firstMatch(in: line, range: range),
                  let heightRange = Range(heightMatch.range(at: 1), in: line),
                  let xRange = Range(offsetMatch.range(at: 1), in: line),
                  let yRange = Range(offsetMatch.range(at: 2), in: line),
                  let height = Double(line[heightRange]),
                  let offsetX = Double(line[xRange]),
                  let offsetY = Double(line[yRange]) else { return nil }
            return DemoTraceSample(
                sequence: Self.traceSequence(line) ?? 0,
                displayHeight: CGFloat(height),
                offsetX: CGFloat(offsetX),
                offsetY: CGFloat(offsetY),
                line: line
            )
        }
    }

    func attachScreenshot(_ name: String, keepAlways: Bool = false) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = keepAlways ? .keepAlways : .deleteOnSuccess
        add(attachment)
    }

    func attachHUDTrace(_ name: String, keepAlways: Bool = false) {
        let snapshot = readHUDSnapshot()
        let text = [
            "displayHeight=\(snapshot.displayHeight.map(String.init(describing:)) ?? "nil")",
            snapshot.rawText,
            "TRACE",
            snapshot.traceLines.joined(separator: "\n")
        ].joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = keepAlways ? .keepAlways : .deleteOnSuccess
        add(attachment)
    }

    private func implementationMarkerText() -> String {
        let host = element(DemoAccessibilityID.dragHost)
        let hud = element(DemoAccessibilityID.eventHUD)
        let switchButton = element(DemoAccessibilityID.switchImplementation)
        return orderedUnique(
            accessibilityStrings(from: host)
                + accessibilityStrings(from: hud)
                + accessibilityStrings(from: switchButton)
        ).joined(separator: " | ")
    }

    private func currentImplementationMatches(_ implementation: DemoImplementationUnderTest) -> Bool {
        let hostMarker = accessibilityStrings(from: element(DemoAccessibilityID.dragHost))
            .joined(separator: " | ")
        let hudLabel = element(DemoAccessibilityID.eventHUD).label
        switch implementation {
        case .swift:
            return hostMarker.contains("当前为Swift实现") || hudLabel.contains("Swift/")
        case .objectiveC:
            return hostMarker.contains("当前为OC实现") || hudLabel.contains("OC/")
        }
    }

    private func accessibilityStrings(from element: XCUIElement) -> [String] {
        guard element.exists else { return [] }
        var values: [String] = []
        if !element.label.isEmpty { values.append(element.label) }
        if !element.title.isEmpty { values.append(element.title) }
        if let value = element.value as? String, !value.isEmpty { values.append(value) }
        if let value = element.value as? NSNumber { values.append(value.stringValue) }
        return values
    }

    private func displayHeight(in text: String) -> CGFloat? {
        let patterns = [
            #"\"displayHeight\"\s*:\s*([+-]?\d+(?:\.\d+)?)"#,
            #"displayHeight\s*[:=]?\s*([+-]?\d+(?:\.\d+)?)"#,
            #"展示高度\s*[:=]?\s*([+-]?\d+(?:\.\d+)?)"#,
            #"^\s*([+-]?\d+(?:\.\d+)?)\s*(?:$|[|,;])"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.anchorsMatchLines]
            ) else { continue }
            let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = expression.firstMatch(in: text, range: searchRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text),
                  let value = Double(text[range]) else { continue }
            return CGFloat(value)
        }
        return nil
    }

    private func traceLines(from strings: [String]) -> [String] {
        var lines: [String] = []
        for value in strings {
            if let data = value.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                if let array = object as? [String] {
                    lines.append(contentsOf: array)
                    continue
                }
                if let dictionary = object as? [String: Any],
                   let trace = dictionary["trace"] as? [String] {
                    lines.append(contentsOf: trace)
                    continue
                }
            }

            lines.append(contentsOf: value.components(separatedBy: CharacterSet(charactersIn: "\n\u{001e}")))
        }
        return orderedUnique(lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    @discardableResult
    func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return condition()
    }

    private static func traceSequence(_ line: String) -> Int? {
        guard line.first == "#" else { return nil }
        let digits = line.dropFirst().prefix { $0.isNumber }
        return Int(digits)
    }
}

enum XCUISwipeDirection {
    case up
    case down
    case left
    case right
}
