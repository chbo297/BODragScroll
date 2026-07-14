import Foundation
import XCTest
@testable import BODragScroll

/// 纯函数测试：bo_findIndex（对应 OC 版 bo_findIdxInFloatArrayByValue）。
final class BODragScrollMathTests: XCTestCase {

    private let ar: [CGFloat] = [100, 200, 600]

    // MARK: - 精确命中

    func testExactMatch() {
        XCTAssertEqual(bo_findIndex(in: ar, value: 100, nearby: false, ceil: false), 0)
        XCTAssertEqual(bo_findIndex(in: ar, value: 200, nearby: true, ceil: true), 1)
        XCTAssertEqual(bo_findIndex(in: ar, value: 600, nearby: false, ceil: true), 2)
    }

    // MARK: - 超出边界

    func testBelowFirst() {
        // 小于最小值：返回 0
        XCTAssertEqual(bo_findIndex(in: ar, value: 50, nearby: false, ceil: false), 0)
        XCTAssertEqual(bo_findIndex(in: ar, value: 50, nearby: true, ceil: true), 0)
    }

    func testAboveLast() {
        // 大于最大值：返回末位
        XCTAssertEqual(bo_findIndex(in: ar, value: 700, nearby: false, ceil: true), 2)
        XCTAssertEqual(bo_findIndex(in: ar, value: 700, nearby: true, ceil: false), 2)
    }

    // MARK: - 区间内 ceil 语义（nearby=false）

    func testBetweenCeil() {
        // 150 在 100 与 200 之间：ceil=true 返回较大点(1)，ceil=false 返回较小点(0)
        XCTAssertEqual(bo_findIndex(in: ar, value: 150, nearby: false, ceil: true), 1)
        XCTAssertEqual(bo_findIndex(in: ar, value: 150, nearby: false, ceil: false), 0)
    }

    // MARK: - 区间内 nearby 语义

    func testBetweenNearby() {
        // 120 更靠近 100 → 0
        XCTAssertEqual(bo_findIndex(in: ar, value: 120, nearby: true, ceil: true), 0)
        // 180 更靠近 200 → 1
        XCTAssertEqual(bo_findIndex(in: ar, value: 180, nearby: true, ceil: false), 1)
        // 正中央 150：距离相等，按 ceil 选择
        XCTAssertEqual(bo_findIndex(in: ar, value: 150, nearby: true, ceil: true), 1)
        XCTAssertEqual(bo_findIndex(in: ar, value: 150, nearby: true, ceil: false), 0)
    }

    // MARK: - 单元素 / 空数组

    func testSingleElement() {
        XCTAssertEqual(bo_findIndex(in: [300], value: 100, nearby: true, ceil: true), 0)
        XCTAssertEqual(bo_findIndex(in: [300], value: 500, nearby: false, ceil: false), 0)
        XCTAssertEqual(bo_findIndex(in: [300], value: 300, nearby: false, ceil: true), 0)
    }

    func testEmpty() {
        XCTAssertEqual(bo_findIndex(in: [], value: 100, nearby: true, ceil: true), 0)
    }

}
