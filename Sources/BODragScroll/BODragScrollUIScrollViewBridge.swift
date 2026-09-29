//
//  BODragScrollUIScrollViewBridge.swift
//  BODragScroll
//
//  The narrow UIKit/runtime boundary used by BODragScroll.
//

#if canImport(UIKit)
import UIKit
import ObjectiveC.runtime
import Darwin

// MARK: - Capture hierarchy identity

private final class BODragScrollWeakViewReference {
    weak var view: UIView?

    init(_ view: UIView) {
        self.view = view
    }
}

/// Immutable weak identity snapshot of the physical primary-view -> panel path captured for one
/// session. Exact superview edges are retained, not merely descendant membership, so inserting a
/// new scroll ancestor or wrapper invalidates the old composite model as well as outright reparenting.
///
/// 整个类型标 `@MainActor`：它记的就是 UIView 层级，建快照和每次校验都要走 `superview` 链，
/// 这些全是主 actor 状态。隔离写在类型上，而不是靠函数体里手写 `Thread.isMainThread` —— 后者
/// 编译器看不穿，Swift 6 下每个读点都会报隔离告警。两个 nonisolated 入口（被 swizzle 的 getter、
/// 宿主析构时的 lease 清理）各自用 `MainActor.assumeIsolated` 承接自己的主线程前提。
@MainActor
final class BODragScrollCaptureHierarchySnapshot {
    weak var host: BODragScrollView?
    weak var panelView: UIView?
    let hostID: ObjectIdentifier
    private let participantReferences: [BODragScrollWeakViewReference]
    private let pathReferences: [BODragScrollWeakViewReference]

    // 建快照要走 `superview` 链，那是主 actor 状态；唯一的建快照入口（capture 安装路径、测试）
    // 本来就在主 actor 上，隔离由类型上的 `@MainActor` 统一表达。
    init(
        host: BODragScrollView,
        panelView: UIView,
        participantChain: [UIScrollView]
    ) {
        self.host = host
        self.panelView = panelView
        hostID = ObjectIdentifier(host)
        participantReferences = participantChain.map(BODragScrollWeakViewReference.init)

        var path: [UIView] = []
        var current: UIView? = participantChain.first
        while let view = current, path.count < 512 {
            path.append(view)
            if view === panelView { break }
            current = view.superview
        }
        pathReferences = path.map(BODragScrollWeakViewReference.init)
    }

    func isValid(expectedPrimary: UIScrollView? = nil) -> Bool {
        // 原来这里有一道 `Thread.isMainThread` 守卫，作用是「被 swizzle 的 getter 从别的线程调进来
        // 就别碰 UIKit，直接判无效」。现在隔离由类型上的 `@MainActor` 表达，这个前提由调用方保证：
        // 那个 nonisolated 入口在 `resolve` 里用 `MainActor.assumeIsolated` 承接，走错线程就地 trap，
        // 不再是静默 UB。主线程上的行为与之前逐字一致。
        guard let host,
              let panelView,
              panelView.superview === host else { return false }

        let participants = participantReferences.compactMap(\.view)
        let path = pathReferences.compactMap(\.view)
        guard !participants.isEmpty,
              participants.count == participantReferences.count,
              path.count == pathReferences.count,
              path.first === participants.first,
              path.last === panelView else { return false }
        if let expectedPrimary, participants.first !== expectedPrimary {
            return false
        }

        guard zip(path, path.dropFirst()).allSatisfy({ pair in
            pair.0.superview === pair.1
        }) else { return false }

        var previousPathIndex = -1
        for participant in participants {
            guard let index = path.firstIndex(where: { $0 === participant }),
                  index > previousPathIndex else { return false }
            previousPathIndex = index
        }
        return true
    }

    /// During host deinitialization its weak reference may already be zeroed. Immutable identity
    /// plus the still-live panel edge lets the cleanup token distinguish an intact old hierarchy
    /// from a participant that has been transferred elsewhere.
    func isValidForDeinitializingHost(_ expectedHostID: ObjectIdentifier) -> Bool {
        // 同 `isValid`：原先那道 `Thread.isMainThread` 守卫改由唯一调用方
        // `releaseCaptureLeaseForDeinitializingHost` 负责——它在析构点仍然先判线程再
        // `MainActor.assumeIsolated`，非主线程时根本不会调到这里（老行为：留着孤儿 lease）。
        guard hostID == expectedHostID,
              let panelView else { return false }
        if let panelSuperview = panelView.superview,
           ObjectIdentifier(panelSuperview) != expectedHostID {
            // A non-nil different superview means the whole panel has already acquired a new
            // structural owner. Nil is expected once UIKit's dying superview detaches its children.
            return false
        }

        let participants = participantReferences.compactMap(\.view)
        let path = pathReferences.compactMap(\.view)
        guard !participants.isEmpty,
              participants.count == participantReferences.count,
              path.count == pathReferences.count,
              path.first === participants.first,
              path.last === panelView,
              zip(path, path.dropFirst()).allSatisfy({ $0.0.superview === $0.1 }) else {
            return false
        }
        return true
    }

    func hasSameIdentity(as other: BODragScrollCaptureHierarchySnapshot) -> Bool {
        guard hostID == other.hostID,
              host === other.host,
              panelView === other.panelView else { return false }
        let participants = participantReferences.compactMap(\.view)
        let otherParticipants = other.participantReferences.compactMap(\.view)
        let path = pathReferences.compactMap(\.view)
        let otherPath = other.pathReferences.compactMap(\.view)
        guard participants.count == participantReferences.count,
              otherParticipants.count == other.participantReferences.count,
              path.count == pathReferences.count,
              otherPath.count == other.pathReferences.count,
              participants.count == otherParticipants.count,
              path.count == otherPath.count else { return false }
        return zip(participants, otherParticipants).allSatisfy { $0.0 === $0.1 }
            && zip(path, otherPath).allSatisfy { $0.0 === $0.1 }
    }
}

// MARK: - UIScrollView compatibility and guarded writes

@MainActor
extension UIScrollView {
    /// The inset used by all BODragScroll geometry. The package supports iOS 13 and later, so the
    /// legacy pre-iOS-11 branch from the OC implementation is intentionally unnecessary.
    var effectiveContentInset: UIEdgeInsets {
        adjustedContentInset
    }

    /// Preserve the OC implementation's exact equality guard before mutating UIKit state.
    @inline(__always)
    func setContentOffsetIfNeeded(_ newValue: CGPoint) {
        guard !CGPointEqualToPoint(contentOffset, newValue) else { return }
        contentOffset = newValue
    }

    /// Preserve the OC implementation's exact equality guard before mutating UIKit state.
    @inline(__always)
    func setContentSizeIfNeeded(_ newValue: CGSize) {
        guard !CGSizeEqualToSize(contentSize, newValue) else { return }
        contentSize = newValue
    }

    /// Preserve the OC implementation's exact equality guard before mutating UIKit state.
    @inline(__always)
    func setContentInsetIfNeeded(_ newValue: UIEdgeInsets) {
        guard contentInset != newValue else { return }
        contentInset = newValue
    }
}

// MARK: - Weak primary-participant association

private final class BODragScrollWeakHostLink: NSObject {
    weak var host: BODragScrollView?
    let hostID: ObjectIdentifier
    let captureSessionID: UInt64
    let hierarchy: BODragScrollCaptureHierarchySnapshot

    init(
        host: BODragScrollView,
        captureSessionID: UInt64,
        hierarchy: BODragScrollCaptureHierarchySnapshot
    ) {
        self.host = host
        self.hostID = ObjectIdentifier(host)
        self.captureSessionID = captureSessionID
        self.hierarchy = hierarchy
    }
}

private final class BODragScrollScrollsToTopLease: NSObject {
    weak var host: BODragScrollView?
    let hostID: ObjectIdentifier
    let captureSessionID: UInt64
    let originalValue: Bool
    let hierarchy: BODragScrollCaptureHierarchySnapshot

    init(
        host: BODragScrollView,
        captureSessionID: UInt64,
        originalValue: Bool,
        hierarchy: BODragScrollCaptureHierarchySnapshot
    ) {
        self.host = host
        self.hostID = ObjectIdentifier(host)
        self.captureSessionID = captureSessionID
        self.originalValue = originalValue
        self.hierarchy = hierarchy
    }
}

/// A non-actor cleanup token owned by capture runtime. Its destructor can run after the host's
/// main-actor isolation is no longer accessible, while immutable host/session identity still lets
/// the bridge release only leases that have not been transferred to a newer owner.
final class BODragScrollHostLeaseCleanup {
    private final class Entry {
        weak var scrollView: UIScrollView?
        let hostID: ObjectIdentifier
        let captureSessionID: UInt64

        init(scrollView: UIScrollView, hostID: ObjectIdentifier, captureSessionID: UInt64) {
            self.scrollView = scrollView
            self.hostID = hostID
            self.captureSessionID = captureSessionID
        }
    }

    private var entries: [Entry] = []

    @MainActor
    func register(
        scrollViews: [UIScrollView],
        host: BODragScrollView,
        captureSessionID: UInt64
    ) {
        entries.removeAll { $0.captureSessionID == captureSessionID }
        let hostID = ObjectIdentifier(host)
        entries.append(contentsOf: scrollViews.map {
            Entry(
                scrollView: $0,
                hostID: hostID,
                captureSessionID: captureSessionID
            )
        })
    }

    @MainActor
    func clear(captureSessionID: UInt64) {
        entries.removeAll { $0.captureSessionID == captureSessionID }
    }

    deinit {
        for entry in entries {
            guard let scrollView = entry.scrollView else { continue }
            BODragScrollUIScrollViewBridge.releaseCaptureLeaseForDeinitializingHost(
                for: scrollView,
                hostID: entry.hostID,
                captureSessionID: entry.captureSessionID
            )
        }
    }
}

// Associated-object keys: only the *address* is ever used, the value is never read or written.
// `nonisolated(unsafe)` is the accurate description of that — there is no shared mutable state here
// to protect, just a stable address. Matches the same pattern in BOUIKit.
nonisolated(unsafe) private var bodragScrollHostLinkKey: UInt8 = 0
nonisolated(unsafe) private var bodragScrollScrollsToTopLeaseKey: UInt8 = 0

private extension UIScrollView {
    var bodragScrollHostLink: BODragScrollWeakHostLink? {
        get {
            objc_getAssociatedObject(self, &bodragScrollHostLinkKey) as? BODragScrollWeakHostLink
        }
        set {
            objc_setAssociatedObject(
                self,
                &bodragScrollHostLinkKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN
            )
        }
    }

    var bodragScrollScrollsToTopLease: BODragScrollScrollsToTopLease? {
        get {
            objc_getAssociatedObject(self, &bodragScrollScrollsToTopLeaseKey)
                as? BODragScrollScrollsToTopLease
        }
        set {
            objc_setAssociatedObject(
                self,
                &bodragScrollScrollsToTopLeaseKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN
            )
        }
    }
}

// MARK: - Native state snapshot

/// The physical state of one `UIScrollView`, bypassing BODragScroll's primary-participant mapping.
struct BODragScrollNativeScrollState {
    let isDragging: Bool
    let isTracking: Bool
    let isDecelerating: Bool
}

// MARK: - Getter hook storage

/// Modern Objective-C `BOOL` (`B`) and legacy signed-char `BOOL` (`c`) are distinct C ABIs.
/// Intel Mac Catalyst still exposes the latter for UIKit getters, so replacement and next-IMP calls
/// must use the exact return representation advertised by the method encoding.
private typealias BODragScrollBoolGetter = @convention(c) (AnyObject, Selector) -> Bool
private typealias BODragScrollCCharGetter = @convention(c) (AnyObject, Selector) -> CChar

private enum BODragScrollBooleanABI {
    case bool
    case cChar
}

private struct BODragScrollGetterHook {
    let nextImplementation: IMP
    let abi: BODragScrollBooleanABI
}

private enum BODragScrollStateGetter: CaseIterable {
    case isDragging
    case isTracking
    case isDecelerating

    var selector: Selector {
        switch self {
        case .isDragging:
            return #selector(getter: UIScrollView.isDragging)
        case .isTracking:
            return #selector(getter: UIScrollView.isTracking)
        case .isDecelerating:
            return #selector(getter: UIScrollView.isDecelerating)
        }
    }
}

private let bodragScrollIsDraggingBoolGetter: BODragScrollBoolGetter = { object, selector in
    BODragScrollUIScrollViewBridge.resolve(.isDragging, object: object, selector: selector)
}

private let bodragScrollIsTrackingBoolGetter: BODragScrollBoolGetter = { object, selector in
    BODragScrollUIScrollViewBridge.resolve(.isTracking, object: object, selector: selector)
}

private let bodragScrollIsDeceleratingBoolGetter: BODragScrollBoolGetter = { object, selector in
    BODragScrollUIScrollViewBridge.resolve(.isDecelerating, object: object, selector: selector)
}

private let bodragScrollIsDraggingCCharGetter: BODragScrollCCharGetter = { object, selector in
    BODragScrollUIScrollViewBridge.resolve(.isDragging, object: object, selector: selector) ? 1 : 0
}

private let bodragScrollIsTrackingCCharGetter: BODragScrollCCharGetter = { object, selector in
    BODragScrollUIScrollViewBridge.resolve(.isTracking, object: object, selector: selector) ? 1 : 0
}

private let bodragScrollIsDeceleratingCCharGetter: BODragScrollCCharGetter = { object, selector in
    BODragScrollUIScrollViewBridge.resolve(.isDecelerating, object: object, selector: selector) ? 1 : 0
}

/// Installs and owns the process-wide bridge for the three interaction-state getters used by the OC
/// implementation. Installation is permanent for the life of the process; there is intentionally no
/// runtime enable switch and no uninstall operation.
enum BODragScrollUIScrollViewBridge {
    // Written exactly once, from `install(_:boolReplacement:cCharReplacement:)` during the
    // `installation` initializer, which is main-thread asserted and runs at most once; read-only for
    // the rest of the process lifetime (see the type comment: installation is permanent, there is no
    // uninstall). Reads happen from the swizzled getters, which are plain C function pointers and
    // therefore nonisolated — so `@MainActor` is not an option here, and write-once-then-immutable is
    // precisely what `nonisolated(unsafe)` is for.
    nonisolated(unsafe) private static var isDraggingHook: BODragScrollGetterHook?
    nonisolated(unsafe) private static var isTrackingHook: BODragScrollGetterHook?
    nonisolated(unsafe) private static var isDeceleratingHook: BODragScrollGetterHook?

    private static let installation: Void = {
        precondition(Thread.isMainThread, "BODragScroll state bridging must be installed on the main thread")

        install(
            .isDragging,
            boolReplacement: unsafeBitCast(bodragScrollIsDraggingBoolGetter, to: IMP.self),
            cCharReplacement: unsafeBitCast(bodragScrollIsDraggingCCharGetter, to: IMP.self)
        )
        install(
            .isTracking,
            boolReplacement: unsafeBitCast(bodragScrollIsTrackingBoolGetter, to: IMP.self),
            cCharReplacement: unsafeBitCast(bodragScrollIsTrackingCCharGetter, to: IMP.self)
        )
        install(
            .isDecelerating,
            boolReplacement: unsafeBitCast(bodragScrollIsDeceleratingBoolGetter, to: IMP.self),
            cCharReplacement: unsafeBitCast(bodragScrollIsDeceleratingCCharGetter, to: IMP.self)
        )
    }()

    /// Idempotently installs the permanent getter bridge. Call during the first main-actor
    /// `BODragScrollView` initialization. Binding a primary participant also installs it.
    @MainActor
    static func installIfNeeded() {
        _ = installation
    }

    /// Associate the capture session's primary participant with its physical outer driver.
    ///
    /// Only the primary participant is bridged. Ancestor participants retain their own native state,
    /// matching the OC implementation's association with `_currentScrollView` rather than every nested
    /// scroll view. A live physical scroll view has one exclusive capture lease; stale weak-owner leases
    /// are recovered without overwriting a lease installed synchronously by restoration callbacks.
    @MainActor
    static func acquireCaptureLease(
        for scrollView: UIScrollView,
        host: BODragScrollView,
        captureSessionID: UInt64,
        hierarchy: BODragScrollCaptureHierarchySnapshot
    ) -> Bool {
        guard hierarchy.host === host, hierarchy.isValid() else { return false }
        if let existing = scrollView.bodragScrollScrollsToTopLease {
            if existing.host === host,
               existing.captureSessionID == captureSessionID,
               existing.hierarchy.isValid() {
                if scrollView.scrollsToTop {
                    scrollView.scrollsToTop = false
                }
                return scrollView.bodragScrollScrollsToTopLease === existing
                    && !scrollView.scrollsToTop
                    && hierarchy.isValid()
            }
            guard !existing.hierarchy.isValid() else {
                // A physical scroll view can belong to only one composite-axis session at a time.
                return false
            }

            // Recover an orphaned or structurally stale lease even when its old host is still alive.
            // Detach before invoking callbacks; a re-entrant acquisition becomes authoritative and
            // is never overwritten by this older operation.
            let staleHost = existing.host
            if let link = scrollView.bodragScrollHostLink,
               link.hostID == existing.hostID,
               link.captureSessionID == existing.captureSessionID {
                scrollView.bodragScrollHostLink = nil
            }
            scrollView.bodragScrollScrollsToTopLease = nil
            if scrollView.scrollsToTop != existing.originalValue {
                scrollView.scrollsToTop = existing.originalValue
            }
            staleHost?.endCaptureSessionIfOwned(
                expectedSessionID: existing.captureSessionID,
                hierarchy: existing.hierarchy
            )
            if let replacement = scrollView.bodragScrollScrollsToTopLease {
                return replacement.host === host
                    && replacement.captureSessionID == captureSessionID
                    && !scrollView.scrollsToTop
            }
            guard hierarchy.isValid() else { return false }
        }

        let originalValue = scrollView.scrollsToTop
        let lease = BODragScrollScrollsToTopLease(
            host: host,
            captureSessionID: captureSessionID,
            originalValue: originalValue,
            hierarchy: hierarchy
        )
        scrollView.bodragScrollScrollsToTopLease = lease
        if scrollView.scrollsToTop {
            scrollView.scrollsToTop = false
        }
        guard scrollView.bodragScrollScrollsToTopLease === lease,
              !scrollView.scrollsToTop,
              hierarchy.isValid() else {
            // Roll back only if this operation still owns the association. Detach before restoring
            // so a re-entrant acquisition cannot be hidden or overwritten.
            if scrollView.bodragScrollScrollsToTopLease === lease {
                scrollView.bodragScrollScrollsToTopLease = nil
                if scrollView.scrollsToTop != originalValue {
                    scrollView.scrollsToTop = originalValue
                }
            }
            return false
        }
        return true
    }

    @MainActor
    static func ownsCaptureLease(
        for scrollView: UIScrollView,
        host: BODragScrollView,
        captureSessionID: UInt64
    ) -> Bool {
        guard let lease = scrollView.bodragScrollScrollsToTopLease else { return false }
        return lease.host === host && lease.captureSessionID == captureSessionID
    }

    @MainActor
    @discardableResult
    static func releaseCaptureLease(
        for scrollView: UIScrollView,
        host: BODragScrollView,
        captureSessionID: UInt64
    ) -> Bool {
        guard let lease = scrollView.bodragScrollScrollsToTopLease,
              lease.host === host,
              lease.captureSessionID == captureSessionID else {
            return false
        }
        scrollView.bodragScrollScrollsToTopLease = nil
        if scrollView.scrollsToTop != lease.originalValue {
            scrollView.scrollsToTop = lease.originalValue
        }
        // Restoration is an overridable setter. Report whether the view remained unleased so the
        // old owner does not normalize offsets after a callback gave the view to a new session.
        return scrollView.bodragScrollScrollsToTopLease == nil
    }

    @MainActor
    static func bind(
        primaryParticipant: UIScrollView,
        to host: BODragScrollView,
        captureSessionID: UInt64
    ) -> Bool {
        installIfNeeded()

        guard let lease = primaryParticipant.bodragScrollScrollsToTopLease,
              lease.host === host,
              lease.captureSessionID == captureSessionID,
              lease.hierarchy.isValid(expectedPrimary: primaryParticipant) else { return false }
        if let currentLink = primaryParticipant.bodragScrollHostLink,
           let currentHost = currentLink.host,
           currentHost !== host {
            return false
        }

        primaryParticipant.bodragScrollHostLink = BODragScrollWeakHostLink(
            host: host,
            captureSessionID: captureSessionID,
            hierarchy: lease.hierarchy
        )
        return true
    }

    /// Remove a primary-participant binding only when it still belongs to the supplied session.
    @MainActor
    @discardableResult
    static func unbind(
        primaryParticipant: UIScrollView,
        from host: BODragScrollView,
        captureSessionID: UInt64
    ) -> Bool {
        guard let link = primaryParticipant.bodragScrollHostLink,
              link.host === host,
              link.captureSessionID == captureSessionID else {
            return false
        }

        primaryParticipant.bodragScrollHostLink = nil
        return true
    }

    /// Last-resort cleanup for the uncommon path where UIKit destroys a host hierarchy without
    /// first sending `willMove(toWindow: nil)`. Weak host references may already be nil during
    /// deinitialization, so identity is verified with the immutable object identifier captured when
    /// the lease was created. The association is detached before restoring the overridable setter.
    static func releaseCaptureLeaseForDeinitializingHost(
        for scrollView: UIScrollView,
        hostID: ObjectIdentifier,
        captureSessionID: UInt64
    ) {
        // UIKit views are main-thread objects. If a client violates that contract, leave the weak
        // orphan in place; the next acquisition has a safe recovery path rather than touching UI
        // from the wrong thread during deinit.
        guard Thread.isMainThread else { return }

        // 入口必须保持 nonisolated：它是从 `BODragScrollHostLeaseCleanup.deinit` 调进来的，
        // 析构点没有 actor 上下文可用。上面那行判断已经确认了「现在在主线程」，
        // `MainActor.assumeIsolated` 把这个结论交给编译器，运行时行为不变；
        // 判断走错的情况从原来的静默跨线程读写 UIKit 变成立刻 trap。
        MainActor.assumeIsolated {
            if let link = scrollView.bodragScrollHostLink,
               link.hostID == hostID,
               link.captureSessionID == captureSessionID {
                scrollView.bodragScrollHostLink = nil
            }

            guard let lease = scrollView.bodragScrollScrollsToTopLease,
                  lease.hostID == hostID,
                  lease.captureSessionID == captureSessionID else { return }

            if lease.hierarchy.isValidForDeinitializingHost(hostID),
               let targetOffset = normalizedOffsetForLeaseCleanup(of: scrollView),
               !CGPointEqualToPoint(scrollView.contentOffset, targetOffset) {
                scrollView.setContentOffset(targetOffset, animated: false)
                // The setter is overridable and may synchronously transfer the participant. Never
                // clear or restore state belonging to that newer owner.
                guard scrollView.bodragScrollScrollsToTopLease === lease else { return }
            }
            scrollView.bodragScrollScrollsToTopLease = nil
            if scrollView.scrollsToTop != lease.originalValue {
                scrollView.scrollsToTop = lease.originalValue
            }
        }
    }

    // 唯一调用方是上面那段已经确认在主 actor 上的清理逻辑，所以这里直接标 `@MainActor`，
    // 不用再套一层 `assumeIsolated`：读 inset / contentSize / bounds / contentOffset 全是主 actor 状态。
    @MainActor
    private static func normalizedOffsetForLeaseCleanup(of scrollView: UIScrollView) -> CGPoint? {
        let inset = scrollView.adjustedContentInset
        guard inset.top.isFinite,
              inset.bottom.isFinite,
              scrollView.contentSize.height.isFinite,
              scrollView.bounds.height.isFinite,
              scrollView.contentOffset.x.isFinite,
              scrollView.contentOffset.y.isFinite else { return nil }
        let minimum = -inset.top
        let maximum = max(
            scrollView.contentSize.height + inset.bottom - scrollView.bounds.height,
            minimum
        )
        guard minimum.isFinite, maximum.isFinite else { return nil }
        var target = scrollView.contentOffset
        target.y = min(maximum, max(minimum, target.y))
        return target
    }

    /// Read physical getter values without following this bridge's primary-participant association.
    @MainActor
    static func nativeState(of scrollView: UIScrollView) -> BODragScrollNativeScrollState {
        BODragScrollNativeScrollState(
            isDragging: callNext(.isDragging, on: scrollView),
            isTracking: callNext(.isTracking, on: scrollView),
            isDecelerating: callNext(.isDecelerating, on: scrollView)
        )
    }

    fileprivate static func resolve(
        _ getter: BODragScrollStateGetter,
        object: AnyObject,
        selector: Selector
    ) -> Bool {
        guard let scrollView = object as? UIScrollView else { return false }

        // 这里是被 swizzle 进 UIScrollView 的 C 函数入口，经 objc_msgSend 调进来，签名上必然
        // nonisolated；而 `isDragging`/`isTracking`/`isDecelerating` 这三个 getter 按 UIKit 的调用
        // 约定只在主线程被读，关联对象与 host 状态也都是主 actor 状态。整段用一次
        // `MainActor.assumeIsolated` 承接这个约定：运行时行为不变，真有客户端从别的线程读就地
        // trap，比原来跨线程摸 UIKit 状态（静默 UB）更容易发现。
        return MainActor.assumeIsolated {
            // Calling the installation-time next IMP directly is deliberate. It gives a primary participant
            // its host's physical state without recursively following a second BODragScroll association, and
            // it preserves any hook that was installed before this bridge.
            let stateOwner: UIScrollView
            if let link = scrollView.bodragScrollHostLink,
               link.hierarchy.isValid(expectedPrimary: scrollView),
               let host = link.host {
                stateOwner = host
            } else {
                // 原来这里还要自己判一次 `Thread.isMainThread` 才敢读关联对象、才敢派发失效检查；
                // 这个前置条件已经由入口的 `assumeIsolated` 一次性保证（不在主线程根本走不到这里），
                // 所以只剩「链接是否还在」这一个条件。
                if let staleLink = scrollView.bodragScrollHostLink {
                    DispatchQueue.main.async { [weak host = staleLink.host] in
                        host?.invalidateCaptureHierarchyIfNeeded(
                            expectedSessionID: staleLink.captureSessionID
                        )
                    }
                }
                stateOwner = scrollView
            }
            return callNext(getter, on: stateOwner, selector: selector)
        }
    }

    private static func install(
        _ getter: BODragScrollStateGetter,
        boolReplacement: IMP,
        cCharReplacement: IMP
    ) {
        let selector = getter.selector
        guard let method = class_getInstanceMethod(UIScrollView.self, selector) else {
            preconditionFailure("BODragScroll could not find UIScrollView.\(NSStringFromSelector(selector))")
        }

        let abi = booleanABI(of: method, selector: selector)
        let replacement: IMP
        switch abi {
        case .bool:
            replacement = boolReplacement
        case .cChar:
            replacement = cCharReplacement
        }

        // Capture the current implementation before replacing it. This is the next link in the hook
        // chain, which may be UIKit itself or another library installed earlier in the process.
        let nextImplementation = method_getImplementation(method)
        setHook(
            BODragScrollGetterHook(nextImplementation: nextImplementation, abi: abi),
            for: getter
        )

        guard let typeEncoding = method_getTypeEncoding(method) else {
            preconditionFailure("BODragScroll found no type encoding for \(NSStringFromSelector(selector))")
        }

        class_replaceMethod(
            UIScrollView.self,
            selector,
            replacement,
            typeEncoding
        )

        guard let installedMethod = class_getInstanceMethod(UIScrollView.self, selector),
              unsafeBitCast(method_getImplementation(installedMethod), to: UInt.self)
                == unsafeBitCast(replacement, to: UInt.self) else {
            preconditionFailure("BODragScroll failed to replace \(NSStringFromSelector(selector))")
        }
    }

    private static func booleanABI(
        of method: Method,
        selector: Selector
    ) -> BODragScrollBooleanABI {
        guard method_getNumberOfArguments(method) == 2 else {
            preconditionFailure("BODragScroll expected a zero-argument getter for \(NSStringFromSelector(selector))")
        }

        let returnType = method_copyReturnType(method)
        defer { free(returnType) }

        let returnEncoding = String(cString: returnType)
        switch returnEncoding {
        case "B":
            return .bool
        case "c":
            return .cChar
        default:
            preconditionFailure(
                "BODragScroll expected a BOOL return for \(NSStringFromSelector(selector)); got \(returnEncoding)"
            )
        }
    }

    private static func setHook(_ hook: BODragScrollGetterHook, for getter: BODragScrollStateGetter) {
        switch getter {
        case .isDragging:
            isDraggingHook = hook
        case .isTracking:
            isTrackingHook = hook
        case .isDecelerating:
            isDeceleratingHook = hook
        }
    }

    private static func hook(for getter: BODragScrollStateGetter) -> BODragScrollGetterHook? {
        switch getter {
        case .isDragging:
            return isDraggingHook
        case .isTracking:
            return isTrackingHook
        case .isDecelerating:
            return isDeceleratingHook
        }
    }

    private static func callNext(
        _ getter: BODragScrollStateGetter,
        on scrollView: UIScrollView,
        selector: Selector? = nil
    ) -> Bool {
        // `nativeState` is useful during setup, so make installation implicit rather than requiring
        // every caller to remember a separate ordering constraint.
        _ = installation

        guard let hook = hook(for: getter) else {
            assertionFailure("BODragScroll state bridge has no next implementation")
            return false
        }

        let selector = selector ?? getter.selector
        switch hook.abi {
        case .bool:
            let function = unsafeBitCast(
                hook.nextImplementation,
                to: BODragScrollBoolGetter.self
            )
            return function(scrollView, selector)
        case .cChar:
            let function = unsafeBitCast(
                hook.nextImplementation,
                to: BODragScrollCCharGetter.self
            )
            return function(scrollView, selector) != 0
        }
    }
}

#endif
