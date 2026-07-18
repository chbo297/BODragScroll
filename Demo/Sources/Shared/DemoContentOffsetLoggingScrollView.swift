import UIKit

/// Demo-only probe for determining who writes an inner scroll view's offset.
///
/// The overrides deliberately forward the requested value to UIKit without clamping, coalescing,
/// or changing animation behavior. Logging happens after the corresponding `super` call so each
/// line contains both the requested value and the value UIKit actually retained.
@MainActor
final class DemoContentOffsetLoggingScrollView: UIScrollView {
    private let diagnosticImplementation: DemoImplementation
    weak var diagnosticHostScrollView: UIScrollView?
#if DEBUG
    private var mutationSequence: UInt64 = 0
    private var animatedAPIDepth = 0
    private var nestedAnimatedSetterCount = 0
    private var layoutDepth = 0
    private var adjustedInsetCallbackDepth = 0
    private var didLogUnexpectedBoundaryRecoveryStack = false
#endif

    init(implementation: DemoImplementation) {
        diagnosticImplementation = implementation
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set {
#if DEBUG
            let before = super.contentOffset
            let unexpectedRecovery = unexpectedBoundaryRecovery(
                before: before,
                requested: newValue
            )
            let recoveryStack = unexpectedRecovery && !didLogUnexpectedBoundaryRecoveryStack
                ? Thread.callStackSymbols.dropFirst(2).joined(separator: "\n")
                : nil
            super.contentOffset = newValue
            if animatedAPIDepth > 0 {
                // The public animated API is the one top-level request. Merge any synchronous
                // internal setter traversal into its return log instead of making it look like a
                // second independent writer.
                nestedAnimatedSetterCount += 1
            } else {
                logOffsetWrite(
                    api: "contentOffset-setter",
                    requested: newValue,
                    before: before,
                    after: super.contentOffset,
                    animated: nil,
                    nestedSetterCount: 0,
                    recoveryStack: recoveryStack
                )
            }
#else
            super.contentOffset = newValue
#endif
        }
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
#if DEBUG
        let before = super.contentOffset
        let nestedSetterCountBeforeCall = nestedAnimatedSetterCount
        animatedAPIDepth += 1
        super.setContentOffset(contentOffset, animated: animated)
        animatedAPIDepth -= 1
        logOffsetWrite(
            api: "setContentOffset:animated:return",
            requested: contentOffset,
            before: before,
            after: super.contentOffset,
            animated: animated,
            nestedSetterCount: nestedAnimatedSetterCount - nestedSetterCountBeforeCall,
            recoveryStack: nil
        )
#else
        super.setContentOffset(contentOffset, animated: animated)
#endif
    }

#if DEBUG
    override func layoutSubviews() {
        let before = super.contentOffset
        layoutDepth += 1
        super.layoutSubviews()
        layoutDepth -= 1
        let after = super.contentOffset
        logLayoutIfRelevant(before: before, after: after)
    }

    override func adjustedContentInsetDidChange() {
        let before = super.contentOffset
        adjustedInsetCallbackDepth += 1
        super.adjustedContentInsetDidChange()
        adjustedInsetCallbackDepth -= 1
        let after = super.contentOffset
        guard isOutsideLegalRange(before.y) || before != after else { return }
        DemoDebugLogger.log(
            diagnosticImplementation,
            "InnerScroll.adjustedContentInsetDidChange",
            fields: diagnosticFields(before: before, after: after)
        )
    }

    override func flashScrollIndicators() {
        DemoDebugLogger.log(
            diagnosticImplementation,
            "InnerScroll.flashScrollIndicators",
            fields: [
                "identifier": accessibilityIdentifier ?? "-",
                "stack": Thread.callStackSymbols.dropFirst(2).joined(separator: "\n")
            ]
        )
        super.flashScrollIndicators()
    }
#endif
}

#if DEBUG
@MainActor
private extension DemoContentOffsetLoggingScrollView {
    func logOffsetWrite(
        api: String,
        requested: CGPoint,
        before: CGPoint,
        after: CGPoint,
        animated: Bool?,
        nestedSetterCount: Int,
        recoveryStack: String?
    ) {
        if recoveryStack != nil {
            didLogUnexpectedBoundaryRecoveryStack = true
        }
        mutationSequence &+= 1
        let inset = adjustedContentInset
        let minimumOffsetY = -inset.top
        let maximumOffsetY = max(
            contentSize.height + inset.bottom - bounds.height,
            minimumOffsetY
        )
        let region: String
        if after.y < minimumOffsetY {
            region = "top-bounce"
        } else if after.y > maximumOffsetY {
            region = "bottom-bounce"
        } else {
            region = "legal-range"
        }
        let presentationOffsetY = (layer.presentation() ?? layer).bounds.origin.y
        let host = diagnosticHostScrollView
        let hostPresentationOffsetY = host.map {
            ($0.layer.presentation() ?? $0.layer).bounds.origin.y
        }

        DemoDebugLogger.log(
            diagnosticImplementation,
            "InnerScroll.setContentOffset",
            fields: [
                "after": point(after),
                "animated": animated.map { $0 ? "YES" : "NO" } ?? "property-setter",
                "api": api,
                "before": point(before),
                "decelerating": isDecelerating ? "YES" : "NO",
                "deltaY": number(after.y - before.y),
                "dragging": isDragging ? "YES" : "NO",
                "hostDecelerating": host.map { $0.isDecelerating ? "YES" : "NO" } ?? "nil",
                "hostDragging": host.map { $0.isDragging ? "YES" : "NO" } ?? "nil",
                "hostOffsetY": host.map { number($0.contentOffset.y) } ?? "nil",
                "hostPresentationY": hostPresentationOffsetY.map(number) ?? "nil",
                "hostTracking": host.map { $0.isTracking ? "YES" : "NO" } ?? "nil",
                "identifier": accessibilityIdentifier ?? "-",
                "adjustedInsetDepth": String(adjustedInsetCallbackDepth),
                "layoutDepth": String(layoutDepth),
                "nestedSetterCount": String(nestedSetterCount),
                "panState": String(panGestureRecognizer.state.rawValue),
                "presentationY": number(presentationOffsetY),
                "range": "\(number(minimumOffsetY))->\(number(maximumOffsetY))",
                "region": region,
                "requested": point(requested),
                "seq": String(mutationSequence),
                "time": String(format: "%.6f", CACurrentMediaTime()),
                "tracking": isTracking ? "YES" : "NO",
                "unexpectedRecovery": recoveryStack == nil ? "NO" : "YES",
                "unexpectedRecoveryStack": recoveryStack ?? "-"
            ]
        )
    }

    func unexpectedBoundaryRecovery(before: CGPoint, requested: CGPoint) -> Bool {
        let range = legalOffsetRange()
        guard before.y > range.maximum,
              abs(requested.y - range.maximum) < 0.0001,
              let host = diagnosticHostScrollView else { return false }
        let hostInset = host.adjustedContentInset
        let hostMaximum = max(
            host.contentSize.height + hostInset.bottom - host.bounds.height,
            -hostInset.top
        )
        return host.contentOffset.y > hostMaximum
    }

    func logLayoutIfRelevant(before: CGPoint, after: CGPoint) {
        guard isOutsideLegalRange(before.y) || before != after else { return }
        DemoDebugLogger.log(
            diagnosticImplementation,
            "InnerScroll.layoutSubviews",
            fields: diagnosticFields(before: before, after: after)
        )
    }

    func diagnosticFields(before: CGPoint, after: CGPoint) -> [String: String] {
        let range = legalOffsetRange()
        let host = diagnosticHostScrollView
        return [
            "after": point(after),
            "before": point(before),
            "hostOffsetY": host.map { number($0.contentOffset.y) } ?? "nil",
            "identifier": accessibilityIdentifier ?? "-",
            "range": "\(number(range.minimum))->\(number(range.maximum))"
        ]
    }

    func isOutsideLegalRange(_ value: CGFloat) -> Bool {
        let range = legalOffsetRange()
        return value < range.minimum || value > range.maximum
    }

    func legalOffsetRange() -> (minimum: CGFloat, maximum: CGFloat) {
        let inset = adjustedContentInset
        let minimum = -inset.top
        let maximum = max(contentSize.height + inset.bottom - bounds.height, minimum)
        return (minimum, maximum)
    }

    func point(_ point: CGPoint) -> String {
        "\(number(point.x)),\(number(point.y))"
    }

    func number(_ value: CGFloat) -> String {
        String(format: "%.6f", Double(value))
    }
}
#endif
