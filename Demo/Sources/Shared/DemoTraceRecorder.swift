import Foundation
import UIKit

private struct DemoTraceScrollSnapshot: Codable, Sendable {
    let name: String
    let identifier: String
    let offsetX: Double
    let offsetY: Double
    let contentWidth: Double
    let contentHeight: Double
    let boundsWidth: Double
    let boundsHeight: Double
    let presentationOffsetY: Double
    let isTracking: Bool
    let isDragging: Bool
    let isDecelerating: Bool

    init(name: String, scrollView: UIScrollView) {
        self.name = name
        identifier = scrollView.accessibilityIdentifier ?? String(describing: type(of: scrollView))
        offsetX = Self.finite(scrollView.contentOffset.x)
        offsetY = Self.finite(scrollView.contentOffset.y)
        contentWidth = Self.finite(scrollView.contentSize.width)
        contentHeight = Self.finite(scrollView.contentSize.height)
        boundsWidth = Self.finite(scrollView.bounds.width)
        boundsHeight = Self.finite(scrollView.bounds.height)
        presentationOffsetY = Self.finite(
            (scrollView.layer.presentation() ?? scrollView.layer).bounds.origin.y
        )
        isTracking = scrollView.isTracking
        isDragging = scrollView.isDragging
        isDecelerating = scrollView.isDecelerating
    }

    private static func finite(_ value: CGFloat) -> Double {
        value.isFinite ? Double(value) : 0
    }
}

private struct DemoTracePanelSnapshot: Codable, Sendable {
    let frameMinY: Double
    let centerY: Double
    let layerPositionY: Double
    let presentationFrameMinY: Double
    let presentationVisualMinY: Double

    init(panelView: UIView, host: UIScrollView) {
        let panelLayer = panelView.layer.presentation() ?? panelView.layer
        let hostLayer = host.layer.presentation() ?? host.layer
        frameMinY = Self.finite(panelView.frame.minY)
        centerY = Self.finite(panelView.center.y)
        layerPositionY = Self.finite(panelView.layer.position.y)
        presentationFrameMinY = Self.finite(panelLayer.frame.minY)
        presentationVisualMinY = Self.finite(
            panelLayer.frame.minY - hostLayer.bounds.origin.y
        )
    }

    private static func finite(_ value: CGFloat) -> Double {
        value.isFinite ? Double(value) : 0
    }
}

private struct DemoTraceEvent: Codable, Sendable {
    let sequence: Int
    let elapsed: Double
    let scene: String
    let implementation: String
    let callback: String
    let displayHeight: Double
    let isAnimatingDisplayHeight: Bool
    let host: DemoTraceScrollSnapshot
    let panel: DemoTracePanelSnapshot?
    let participants: [DemoTraceScrollSnapshot]
    let details: [String: String]
}

private struct DemoTraceBatch: Codable, Sendable {
    let reason: String
    let scene: String
    let implementation: String
    let part: Int
    let partCount: Int
    let events: [DemoTraceEvent]
}

/// Demo-only observation. It deliberately owns no UIKit object and never feeds data back into
/// either drag engine, so enabling trace collection cannot change capture or movement decisions.
@MainActor
final class DemoTraceRecorder {
    private let scene: String
    private let implementation: String
    /// UI tests read the complete textual trace through accessibility. Manual comparison runs use
    /// the console batches instead, so building and republishing an ever-growing accessibility
    /// string on every scroll sample would only perturb the interaction being diagnosed.
    private let exposesLiveAccessibilityTrace: Bool
    private let startTime = CACurrentMediaTime()
    private let outputQueue = DispatchQueue(label: "com.chbo297.BODragScrollDemo.trace-output")
    private var events: [DemoTraceEvent] = []
    private var pendingStartIndex = 0
    private var encodedAccessibilityTrace = ""

    init(scene: String, implementation: DemoImplementation) {
        self.scene = scene
        self.implementation = implementation.displayName
        exposesLiveAccessibilityTrace = ProcessInfo.processInfo.environment[
            "BODRAGSCROLL_UI_TESTING"
        ] == "1"
    }

    var accessibilityValue: String {
        encodedAccessibilityTrace.isEmpty ? "[]" : encodedAccessibilityTrace
    }

    func record(
        callback: String,
        displayHeight: CGFloat,
        isAnimatingDisplayHeight: Bool,
        host: UIScrollView,
        panel: UIView?,
        participants: [(name: String, scrollView: UIScrollView)],
        details: [String: String] = [:]
    ) {
        let event = DemoTraceEvent(
            sequence: events.count + 1,
            elapsed: CACurrentMediaTime() - startTime,
            scene: scene,
            implementation: implementation,
            callback: callback,
            displayHeight: displayHeight.isFinite ? Double(displayHeight) : 0,
            isAnimatingDisplayHeight: isAnimatingDisplayHeight,
            host: DemoTraceScrollSnapshot(name: "host", scrollView: host),
            panel: panel.map { DemoTracePanelSnapshot(panelView: $0, host: host) },
            participants: participants.map {
                DemoTraceScrollSnapshot(name: $0.name, scrollView: $0.scrollView)
            },
            details: details
        )
        events.append(event)
        guard exposesLiveAccessibilityTrace else { return }
        if !encodedAccessibilityTrace.isEmpty {
            encodedAccessibilityTrace.append("\n")
        }
        encodedAccessibilityTrace.append(accessibilityLine(for: event))
    }

    /// Emits only events not included in an earlier batch. Flushing is restricted to lifecycle
    /// boundaries so console I/O never occurs for every display-link or scroll callback.
    func flush(reason: String) {
        guard pendingStartIndex < events.count else { return }
        let pendingEvents = Array(events[pendingStartIndex...])
        pendingStartIndex = events.count
        let chunkSize = 16
        let partCount = (pendingEvents.count + chunkSize - 1) / chunkSize
        for partIndex in 0..<partCount {
            let lowerBound = partIndex * chunkSize
            let upperBound = min(lowerBound + chunkSize, pendingEvents.count)
            let batch = DemoTraceBatch(
                reason: reason,
                scene: scene,
                implementation: implementation,
                part: partIndex + 1,
                partCount: partCount,
                events: Array(pendingEvents[lowerBound..<upperBound])
            )
            outputQueue.async {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard let data = try? encoder.encode(batch),
                      let payload = String(data: data, encoding: .utf8) else { return }
                print("BODRAG_TRACE_BATCH \(payload)")
            }
        }
    }

    private func accessibilityLine(for event: DemoTraceEvent) -> String {
        let participantText = event.participants.map(snapshotText).joined(separator: ";")
        let detailText = event.details.keys.sorted().map {
            "\($0)=\(event.details[$0] ?? "")"
        }.joined(separator: ",")
        return String(
            format: "#%d t=%.6f %@/%@ %@ h=%.6f anim=%@ host={%@} participants=[%@] details={%@}",
            event.sequence,
            event.elapsed,
            event.scene,
            event.implementation,
            event.callback,
            event.displayHeight,
            event.isAnimatingDisplayHeight ? "true" : "false",
            snapshotText(event.host),
            participantText,
            detailText
        )
    }

    private func snapshotText(_ snapshot: DemoTraceScrollSnapshot) -> String {
        String(
            format: "%@/%@ offset=(%.6f,%.6f) content=(%.6f,%.6f) bounds=(%.6f,%.6f) tracking=%@ dragging=%@ decelerating=%@",
            snapshot.name,
            snapshot.identifier,
            snapshot.offsetX,
            snapshot.offsetY,
            snapshot.contentWidth,
            snapshot.contentHeight,
            snapshot.boundsWidth,
            snapshot.boundsHeight,
            snapshot.isTracking ? "true" : "false",
            snapshot.isDragging ? "true" : "false",
            snapshot.isDecelerating ? "true" : "false"
        )
    }
}
