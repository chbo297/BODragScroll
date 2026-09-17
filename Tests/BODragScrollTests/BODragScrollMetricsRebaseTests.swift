import XCTest
@testable import BODragScroll

/// `ScrollModel.rebasedParticipantInnerDistances(shiftingInnerEndBy:)` —— 生命周期内 participant
/// 度量变化时的窄变换：只移动剩余 inner 距离，档位表 / innerStart / 激活高度全部保持。
final class BODragScrollMetricsRebaseTests: XCTestCase {
    private let primary = ParticipantID(rawValue: 1)
    private let ancestor = ParticipantID(rawValue: 2)

    // MARK: - 基本行为

    func testShiftingInnerEndMovesOnlyRemainingDistance() throws {
        let model = try makeSingleParticipantModel(innerStart: 0, innerEnd: 100)

        let rebased = try XCTUnwrap(
            model.rebasedParticipantInnerDistances(shiftingInnerEndBy: [primary: -40])
        )

        XCTAssertEqual(rebased.detentDisplayHeights, model.detentDisplayHeights)
        XCTAssertEqual(rebased.participantOrder, model.participantOrder)
        XCTAssertEqual(rebased.viewportHeight, model.viewportHeight)

        let participantSegment = try XCTUnwrap(rebased.segments.first(where: \.isParticipantSegment))
        let originalSegment = try XCTUnwrap(model.segments.first(where: \.isParticipantSegment))
        XCTAssertEqual(participantSegment.innerStart, originalSegment.innerStart)
        XCTAssertEqual(participantSegment.displayHeight, originalSegment.displayHeight)
        XCTAssertEqual(participantSegment.innerEnd, 60)
        XCTAssertEqual(participantSegment.outerStart, originalSegment.outerStart)
        XCTAssertEqual(participantSegment.outerLength, 60)
    }

    /// 视口变大 → 合法距离变短，但已经落在保留区间内的位置投影不变（视觉几何不跳）。
    func testProjectionInsideRetainedRangeIsUnchanged() throws {
        let model = try makeSingleParticipantModel(innerStart: 0, innerEnd: 100)
        let rebased = try XCTUnwrap(
            model.rebasedParticipantInnerDistances(shiftingInnerEndBy: [primary: -40])
        )

        let segment = try XCTUnwrap(model.segments.first(where: \.isParticipantSegment))
        let insideOuterOffset = segment.outerStart + 30

        let before = model.projection(at: insideOuterOffset)
        let after = rebased.projection(at: insideOuterOffset)
        XCTAssertEqual(after.offset(for: primary), before.offset(for: primary))
        XCTAssertEqual(after.panelOriginY, before.panelOriginY)
        XCTAssertEqual(after.displayHeight, before.displayHeight)
    }

    func testShiftingInnerEndBeyondStartClampsToZeroLengthSegment() throws {
        let model = try makeSingleParticipantModel(innerStart: 10, innerEnd: 100)

        let rebased = try XCTUnwrap(
            model.rebasedParticipantInnerDistances(shiftingInnerEndBy: [primary: -500])
        )

        let participantSegment = try XCTUnwrap(rebased.segments.first(where: \.isParticipantSegment))
        XCTAssertEqual(participantSegment.innerStart, 10)
        XCTAssertEqual(participantSegment.innerEnd, 10)
        XCTAssertEqual(participantSegment.innerLength, 0)
    }

    // MARK: - 失败即回退

    func testNoMovementReturnsNil() throws {
        let model = try makeSingleParticipantModel(innerStart: 0, innerEnd: 100)

        XCTAssertNil(model.rebasedParticipantInnerDistances(shiftingInnerEndBy: [:]))
        XCTAssertNil(model.rebasedParticipantInnerDistances(shiftingInnerEndBy: [primary: 0]))
    }

    func testNonFiniteDeltaReturnsNil() throws {
        let model = try makeSingleParticipantModel(innerStart: 0, innerEnd: 100)

        XCTAssertNil(
            model.rebasedParticipantInnerDistances(shiftingInnerEndBy: [primary: .infinity])
        )
    }

    /// 一个 participant 被拆成多段（嵌套祖先被子视图切开）时重新分配区间属于拓扑变化，必须失败回退。
    func testSplitParticipantReturnsNil() throws {
        let model = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [.native(300)],
                participantOrder: [primary, ancestor],
                participantSegments: [
                    segment(primary, displayHeight: 300, start: 0, end: 20),
                    segment(ancestor, displayHeight: 300, start: 0, end: 50),
                    segment(primary, displayHeight: 300, start: 20, end: 40)
                ]
            )
        )

        XCTAssertNil(model.rebasedParticipantInnerDistances(shiftingInnerEndBy: [primary: -10]))
    }

    // MARK: - Helpers

    private func makeSingleParticipantModel(
        innerStart: CGFloat,
        innerEnd: CGFloat
    ) throws -> ScrollModel {
        try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [100, 300, 600].map { ScrollSourceScalar.native(CGFloat($0)) },
                participantOrder: [primary],
                participantSegments: [
                    segment(primary, displayHeight: 300, start: innerStart, end: innerEnd)
                ]
            )
        )
    }

    private func segment(
        _ id: ParticipantID,
        displayHeight: CGFloat,
        start: CGFloat,
        end: CGFloat
    ) -> ParticipantSegmentSnapshot {
        ParticipantSegmentSnapshot(
            participantID: id,
            displayHeight: .native(displayHeight),
            innerStart: .native(start),
            innerEnd: .native(end)
        )
    }
}
