//
//  BODragScrollJitterLog.swift
//  BODragScroll
//
//  临时排查用（不要提交）：把手势仲裁结果、模型快照、内部 scrollView 的每次 offset 写入
//  打到控制台，用来定位「拖动时内部 scrollView 抖动」。
//  排查结束后请删除本文件，并移除各调用点的 bodragJitterLog(...)。
//

#if canImport(UIKit)
import UIKit

@MainActor
enum BODragScrollJitterLog {
    /// 置为 false 即完全静音。
    static var isEnabled = true

    static func number(_ value: CGFloat) -> String {
        value.isFinite ? String(format: "%.1f", value) : "nan"
    }

    static func describe(_ scrollView: UIScrollView) -> String {
        "off=\(number(scrollView.contentOffset.y))"
            + " size=\(number(scrollView.contentSize.height))"
            + " bounds=\(number(scrollView.bounds.height))"
            + " insetB=\(number(scrollView.adjustedContentInset.bottom))"
            + " drag=\(scrollView.isDragging ? 1 : 0)"
            + " dec=\(scrollView.isDecelerating ? 1 : 0)"
            + " track=\(scrollView.isTracking ? 1 : 0)"
    }
}

@MainActor
func bodragJitterLog(_ tag: String, _ message: @autoclosure () -> String) {
#if DEBUG
    guard BODragScrollJitterLog.isEnabled else { return }
    print("[BODRAG \(String(format: "%.3f", CACurrentMediaTime()))] \(tag) \(message())")
#endif
}

#endif
