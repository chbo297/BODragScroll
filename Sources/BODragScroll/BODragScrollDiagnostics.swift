//
//  BODragScrollDiagnostics.swift
//  BODragScroll
//
//  DEBUG-only observability used by the comparison Demo. It deliberately reports
//  decisions after they have been made and never participates in those decisions.
//

#if canImport(UIKit) && DEBUG
import UIKit

/// A DEBUG-only diagnostic emitted by the engine for the bundled comparison Demo.
///
/// This is SPI instead of public product API: applications do not need to depend on
/// implementation-detail event names or fields.
@_spi(BODragScrollDemoDiagnostics)
public struct BODragScrollDebugEvent {
    public let category: String
    public let fields: [String: String]

    public init(category: String, fields: [String: String]) {
        self.category = category
        self.fields = fields
    }
}

@MainActor
final class BODragScrollDebugState {
    var sink: (@MainActor (BODragScrollDebugEvent) -> Void)?
    var touchSequence: UInt64 = 0
}

@MainActor
extension BODragScrollView {
    /// Installs the comparison Demo's DEBUG logger. Setting this to `nil` restores a
    /// completely silent engine.
    @_spi(BODragScrollDemoDiagnostics)
    public var _demoDiagnosticsSink: (@MainActor (BODragScrollDebugEvent) -> Void)? {
        get { runtime.debug.sink }
        set { runtime.debug.sink = newValue }
    }

    func debugBeginTouch(from touchedView: UIView) {
        guard runtime.debug.sink != nil else { return }
        runtime.debug.touchSequence &+= 1
        debugEmit(
            "Touch",
            fields: [
                "phase": "begin",
                "touch": String(runtime.debug.touchSequence),
                "view": debugDescribe(view: touchedView)
            ]
        )
    }

    func debugCaptureDidFinish(from touchedView: UIView) {
        guard runtime.debug.sink != nil else { return }
        let touch = String(runtime.debug.touchSequence)
        guard let session = runtime.capture.session else {
            debugEmit(
                "Capture",
                fields: [
                    "capturedCount": "0",
                    "primary": "none",
                    "session": "none",
                    "touch": touch,
                    "touchedView": debugDescribe(view: touchedView)
                ]
            )
            debugEmit(
                "Coordination",
                fields: [
                    "established": "NO",
                    "reason": "no-capture-session",
                    "selectedDriverPendingShouldBegin": "panel-self-or-web-blocked",
                    "touch": touch
                ]
            )
            return
        }

        let captured = session.participantChain.compactMap(\.scrollView)
        debugEmit(
            "Capture",
            fields: [
                "capturedCount": String(captured.count),
                "primary": captured.first.map(debugDescribe(scrollView:)) ?? "none",
                "session": String(session.id),
                "touch": touch,
                "touchedView": debugDescribe(view: touchedView)
            ]
        )
        for (index, scrollView) in captured.enumerated() {
            debugEmit(
                "CapturedScrollView",
                fields: [
                    "chainIndex": String(index),
                    "role": index == 0 ? "primary" : "participating-ancestor",
                    "scrollView": debugDescribe(scrollView: scrollView),
                    "touch": touch
                ]
            )
        }

        let model = session.model
        let participantSegmentCount = model?.segments.filter(\.isParticipantSegment).count ?? 0
        let establishesCoordination = participantSegmentCount > 0
        debugEmit(
            "Coordination",
            fields: [
                "established": establishesCoordination ? "YES" : "NO",
                "detentHeights": model?.detentDisplayHeights.map(debugNumber).joined(separator: "->") ?? "none",
                "handoffMode": debugHandoffMode,
                "modelSegmentCount": String(model?.segments.count ?? 0),
                "participantSegmentCount": String(participantSegmentCount),
                "reason": establishesCoordination ? "active-composite-model" : debugNoModelReason,
                "touch": touch
            ]
        )

        guard let model else { return }
        for (index, segment) in model.segments.enumerated() {
            let owner: String
            switch segment.owner {
            case .panel:
                owner = "panel"
            case let .participant(participantID):
                if let scrollView = session.participant(with: participantID)?.scrollView {
                    owner = debugDescribe(scrollView: scrollView)
                } else {
                    owner = participantID.description
                }
            }
            debugEmit(
                "ModelSegment",
                fields: [
                    "index": String(index),
                    "innerOffset": "\(debugNumber(segment.innerStart))->\(debugNumber(segment.innerEnd))",
                    "kind": segment.isParticipantSegment ? "participant-scroll" : "panel-anchor",
                    "outerOffset": "\(debugNumber(segment.outerStart))->\(debugNumber(segment.outerEnd))",
                    "owner": owner,
                    "panelDisplayHeight": debugNumber(segment.displayHeight),
                    "touch": touch
                ]
            )
        }
    }

    func debugGestureShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer,
        result: Bool
    ) {
        guard runtime.debug.sink != nil,
              gestureRecognizer === panGestureRecognizer else { return }

        let provisionalDriver: String
        if !result,
           configuration.capture.disablesPanelInteractionInWebView,
           didTouchWebView {
            provisionalDriver = "web/native-scroll"
        } else if result, activeScrollModel?.segments.contains(where: \.isParticipantSegment) == true {
            provisionalDriver = "coordinated-axis"
        } else if !result, primaryParticipantScrollView != nil {
            provisionalDriver = "native-inner-scroll-view"
        } else if result {
            provisionalDriver = "panel-self"
        } else {
            provisionalDriver = "none/current-pan-rejected"
        }

        debugEmit(
            "Gesture.shouldBegin",
            fields: [
                "currentPan": result ? "allowed" : "rejected",
                "geometryDisplayHeight": debugNumber(displayHeightForCurrentGeometry),
                "handoffMode": debugHandoffMode,
                "result": result ? "YES" : "NO",
                "reportedDisplayHeight": debugNumber(displayHeight),
                "provisionalDriver": provisionalDriver,
                "touch": String(runtime.debug.touchSequence),
                "velocityY": debugNumber(panGestureRecognizer.velocity(in: window).y)
            ]
        )
    }

    func debugGestureArbitration(
        callback: String,
        gestureRecognizer: UIGestureRecognizer,
        otherGestureRecognizer: UIGestureRecognizer,
        result: Bool
    ) {
        guard runtime.debug.sink != nil,
              gestureRecognizer === panGestureRecognizer,
              let otherScrollView = otherGestureRecognizer.view as? UIScrollView,
              otherScrollView !== self,
              otherGestureRecognizer === otherScrollView.panGestureRecognizer else {
            return
        }

        let semantic: String
        switch callback {
        case "shouldRequireFailureOf":
            semantic = result
                ? "other-first/current-waits"
                : "no-other-first-requirement;check-companion-callbacks-or-UIKit"
        case "shouldBeRequiredToFailBy":
            semantic = result
                ? "current-first/other-waits"
                : "no-current-first-requirement;check-companion-callbacks-or-UIKit"
        case "shouldRecognizeSimultaneouslyWith":
            semantic = result
                ? "simultaneous"
                : "exclusive;winner-resolved-by-failure-rules-or-UIKit"
        default:
            semantic = "unknown"
        }

        debugEmit(
            "Gesture.\(callback)",
            fields: [
                "storedCapturePriority": debugCapturePriorityDescription(for: otherScrollView),
                "otherIsPrimary": otherScrollView === primaryParticipantScrollView ? "YES" : "NO",
                "otherScrollView": debugDescribe(scrollView: otherScrollView),
                "result": result ? "YES" : "NO",
                "semantic": semantic,
                "touch": String(runtime.debug.touchSequence)
            ]
        )
    }

    func debugModelBuildFailed(_ error: Error) {
        guard runtime.debug.sink != nil else { return }
        debugEmit(
            "ModelBuild",
            fields: [
                "error": String(describing: error),
                "result": "no-composite-model",
                "touch": String(runtime.debug.touchSequence)
            ]
        )
    }

    private var debugHandoffMode: String {
        switch configuration.handoff.mode {
        case .coordinated: return "coordinated"
        case .innerFirst: return "inner-first"
        case .innerFirstAtBoundary: return "inner-first-at-boundary"
        }
    }

    private var debugNoModelReason: String {
        switch configuration.handoff.mode {
        case .innerFirst:
            return "native-inner-priority"
        case .innerFirstAtBoundary:
            return "native-inner-can-consume-or-no-valid-segment"
        case .coordinated:
            return "no-valid-participant-segment"
        }
    }

    private func debugCapturePriorityDescription(for scrollView: UIScrollView) -> String {
        switch capturePriority(for: scrollView) {
        case .panelFirst: return "panel-first"
        case .simultaneous: return "simultaneous"
        case .otherFirst: return "other-first"
        case .systemDefault: return "system-default"
        case .participant: return "coordinated-participant"
        case nil: return "not-captured"
        }
    }

    private func debugEmit(_ category: String, fields: [String: String]) {
        runtime.debug.sink?(.init(category: category, fields: fields))
    }

    private func debugDescribe(view: UIView) -> String {
        if let scrollView = view as? UIScrollView {
            return debugDescribe(scrollView: scrollView)
        }
        let identifier = view.accessibilityIdentifier ?? "-"
        return "\(String(describing: type(of: view)))@\(debugPointer(view))#\(identifier)"
    }

    private func debugDescribe(scrollView: UIScrollView) -> String {
        let inset = scrollView.adjustedContentInset
        let minimum = -inset.top
        let maximum = max(
            scrollView.contentSize.height + inset.bottom - scrollView.bounds.height,
            minimum
        )
        let identifier = scrollView.accessibilityIdentifier ?? "-"
        return [
            "\(String(describing: type(of: scrollView)))@\(debugPointer(scrollView))#\(identifier)",
            "offset=\(debugNumber(scrollView.contentOffset.y))",
            "range=\(debugNumber(minimum))->\(debugNumber(maximum))",
            "contentH=\(debugNumber(scrollView.contentSize.height))",
            "boundsH=\(debugNumber(scrollView.bounds.height))"
        ].joined(separator: ",")
    }

    private func debugPointer(_ object: AnyObject) -> String {
        let pointer = Unmanaged.passUnretained(object).toOpaque()
        return "0x" + String(UInt(bitPattern: pointer), radix: 16)
    }

    private func debugNumber(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }
}
#endif
