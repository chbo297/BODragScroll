import XCTest
@testable import BODragScroll

final class BODragScrollModelTests: XCTestCase {
    private let primary = ParticipantID(rawValue: 1)
    private let parent = ParticipantID(rawValue: 2)

    func testSortedIndexMatchesSourceCeilAndNearbyRules() {
        let values: [ScrollSourceScalar] = [100, 200, 600].map { .objectiveCNumber(CGFloat($0)) }

        XCTAssertEqual(ScrollMath.sortedIndex(in: values, value: 150, nearby: false, ceil: false), 0)
        XCTAssertEqual(ScrollMath.sortedIndex(in: values, value: 150, nearby: false, ceil: true), 1)
        XCTAssertEqual(ScrollMath.sortedIndex(in: values, value: 150, nearby: true, ceil: false), 0)
        XCTAssertEqual(ScrollMath.sortedIndex(in: values, value: 150, nearby: true, ceil: true), 1)
        XCTAssertEqual(ScrollMath.sortedIndex(in: values, value: 50, nearby: true, ceil: true), 0)
        XCTAssertEqual(ScrollMath.sortedIndex(in: values, value: 700, nearby: true, ceil: false), 2)
        XCTAssertEqual(ScrollMath.sortedIndex(in: [], value: 100, nearby: true, ceil: false), 0)
    }

    func testObjectiveCFloatAlignmentIsExplicitAndNotATolerance() {
        let value = CGFloat(16_777_217)
        let native = ScrollSourceScalar.native(value)
        let objectiveC = ScrollSourceScalar.objectiveCNumber(value)

        XCTAssertEqual(native.value, 16_777_217)
        XCTAssertEqual(objectiveC.value, 16_777_216)
        XCTAssertNotEqual(native.value, objectiveC.value)
    }

    func testJitterAndPhysicalPixelAreDifferentAlgorithmBands() {
        let policy = ScrollComparisonPolicy(displayScale: 2)

        XCTAssertTrue(policy.isJitterEqual(100, 100.005))
        XCTAssertFalse(policy.isJitterEqual(100, 100.02))
        XCTAssertEqual(policy.boundaryBand, 0.5)
        XCTAssertTrue(policy.isWithinBoundaryBand(100, 100.5))
        XCTAssertFalse(policy.isWithinBoundaryBand(100, 100.500_001))
    }

    func testBuilderMergesDetentWithParticipantSegmentAtSameDisplayHeight() throws {
        let model = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [100, 300, 600].map { .objectiveCNumber(CGFloat($0)) },
                participantOrder: [primary],
                participantSegments: [
                    ParticipantSegmentSnapshot(
                        participantID: primary,
                        displayHeight: .objectiveCNumber(300),
                        innerStart: .objectiveCNumber(0),
                        innerEnd: .objectiveCNumber(100)
                    )
                ]
            )
        )

        XCTAssertEqual(model.segments.count, 3)
        XCTAssertEqual(model.segments[0].owner, .panel)
        XCTAssertEqual(model.segments[0].outerStart, -500)
        XCTAssertEqual(model.segments[1].owner, .participant(primary))
        XCTAssertEqual(model.segments[1].outerStart, -300)
        XCTAssertEqual(model.segments[1].outerEnd, -200)
        XCTAssertEqual(model.segments[2].owner, .panel)
        XCTAssertEqual(model.segments[2].outerStart, 100)
    }

    func testProjectionSupportsMultipleNonContiguousSegmentsWithSameOwner() throws {
        let other = ParticipantID(rawValue: 3)
        let model = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [.objectiveCNumber(300)],
                participantOrder: [primary, other],
                participantSegments: [
                    segment(primary, displayHeight: 300, start: 0, end: 20),
                    segment(other, displayHeight: 300, start: 0, end: 50),
                    segment(primary, displayHeight: 300, start: 20, end: 40)
                ]
            )
        )

        let middle = model.projection(at: -250)
        XCTAssertEqual(middle.activeOwner, .participant(other))
        XCTAssertEqual(middle.offset(for: primary), 20)
        XCTAssertEqual(middle.offset(for: other), 30)
        XCTAssertEqual(middle.panelTranslation, 50)
        XCTAssertEqual(middle.displayHeight, 300)

        let secondPrimarySlice = model.projection(at: -220)
        XCTAssertEqual(secondPrimarySlice.activeOwner, .participant(primary))
        XCTAssertEqual(secondPrimarySlice.offset(for: primary), 30)
        XCTAssertEqual(secondPrimarySlice.offset(for: other), 50)
        XCTAssertEqual(secondPrimarySlice.panelTranslation, 80)
        XCTAssertEqual(secondPrimarySlice.displayHeight, 300)
    }

    func testProjectionTransfersOwnershipAtExactNextParticipantStart() throws {
        let other = ParticipantID(rawValue: 3)
        let model = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [.objectiveCNumber(300)],
                participantOrder: [primary, other],
                participantSegments: [
                    segment(primary, displayHeight: 300, start: 0, end: 20),
                    segment(other, displayHeight: 300, start: 0, end: 50),
                    segment(primary, displayHeight: 300, start: 20, end: 40)
                ]
            )
        )

        // The first segment ends exactly where the second begins. The source
        // completes the first and lets the second own that point.
        let secondStart = model.projection(at: -280)
        XCTAssertEqual(secondStart.activeOwner, .participant(other))
        XCTAssertFalse(secondStart.isParticipantScrolling)
        XCTAssertEqual(secondStart.offset(for: primary), 20)
        XCTAssertEqual(secondStart.offset(for: other), 0)
        XCTAssertEqual(secondStart.panelTranslation, 20)

        // The same rule applies when returning to a later slice of an owner
        // that already appeared earlier on the composite axis.
        let thirdStart = model.projection(at: -230)
        XCTAssertEqual(thirdStart.activeOwner, .participant(primary))
        XCTAssertFalse(thirdStart.isParticipantScrolling)
        XCTAssertEqual(thirdStart.offset(for: primary), 20)
        XCTAssertEqual(thirdStart.offset(for: other), 50)
        XCTAssertEqual(thirdStart.panelTranslation, 70)
    }

    func testProjectionSkipsZeroLengthSegmentWhenNextSegmentHasSameStart() throws {
        let other = ParticipantID(rawValue: 3)
        let model = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [.objectiveCNumber(300)],
                participantOrder: [primary, other],
                participantSegments: [
                    segment(primary, displayHeight: 300, start: 0, end: 0),
                    segment(other, displayHeight: 300, start: 0, end: 10)
                ]
            )
        )

        let exact = model.projection(at: -300)
        XCTAssertEqual(exact.activeOwner, .participant(other))
        XCTAssertFalse(exact.isParticipantScrolling)
        XCTAssertEqual(exact.offset(for: primary), 0)
        XCTAssertEqual(exact.offset(for: other), 0)
        XCTAssertEqual(exact.panelTranslation, 0)
    }

    func testZeroLengthParticipantRemainsADragInnerAnchor() throws {
        let model = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [.objectiveCNumber(300)],
                participantOrder: [primary],
                participantSegments: [segment(primary, displayHeight: 300, start: 0, end: 0)]
            )
        )

        XCTAssertEqual(model.segments.count, 1)
        XCTAssertEqual(model.segments[0].owner, .participant(primary))
        XCTAssertEqual(model.segments[0].outerStart, -300)
        XCTAssertEqual(model.segments[0].outerEnd, -300)

        let exact = model.projection(at: -300)
        XCTAssertEqual(exact.activeOwner, .participant(primary))
        XCTAssertFalse(exact.isParticipantScrolling)
        XCTAssertEqual(exact.offset(for: primary), 0)

        // This is the source's one-pixel decision band, not an assertion
        // tolerance: at -0.25 pt from the anchor on a 2x screen it enters the
        // participant branch with a negative progress.
        let insideDecisionBand = model.projection(at: -300.25)
        XCTAssertEqual(insideDecisionBand.activeOwner, .participant(primary))
        XCTAssertFalse(insideDecisionBand.isParticipantScrolling)
        XCTAssertEqual(insideDecisionBand.offset(for: primary), -0.25)
    }

    func testNestedBuilderClampsShortBouncingContentToAZeroLengthParticipant() throws {
        let segments = try NestedParticipantBuilder.makeSegments(
            chain: [
                NestedParticipantSnapshot(
                    id: primary,
                    contentHeight: 120,
                    viewportHeight: 300,
                    insetTop: 0,
                    insetBottom: 0,
                    contentOffset: 0,
                    childFrame: nil
                )
            ],
            displayHeight: .native(300),
            comparison: ScrollComparisonPolicy(displayScale: 3)
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].innerStart.value, 0)
        XCTAssertEqual(segments[0].innerEnd.value, 0)
    }

    func testNestedBuilderCreatesParentBeforeAndAfterSlicesAroundPrimary() throws {
        let comparison = ScrollComparisonPolicy(displayScale: 2)
        let slices = try NestedParticipantBuilder.makeSegments(
            chain: [
                NestedParticipantSnapshot(
                    id: primary,
                    contentHeight: 400,
                    viewportHeight: 300,
                    insetTop: 0,
                    insetBottom: 0,
                    contentOffset: 0,
                    childFrame: nil
                ),
                NestedParticipantSnapshot(
                    id: parent,
                    contentHeight: 1_000,
                    viewportHeight: 300,
                    insetTop: 0,
                    insetBottom: 0,
                    contentOffset: 0,
                    childFrame: 400...600
                )
            ],
            displayHeight: .native(300),
            comparison: comparison
        )

        XCTAssertEqual(slices.map(\.participantID), [parent, primary, parent])
        XCTAssertEqual(slices.map { $0.innerStart.value }, [0, 0, 400])
        XCTAssertEqual(slices.map { $0.innerEnd.value }, [400, 100, 700])
    }

    func testNestedAlreadyScrolledBranchKeepsPhysicalOffsetSlicesContinuous() throws {
        let slices = try NestedParticipantBuilder.makeSegments(
            chain: [
                NestedParticipantSnapshot(
                    id: primary,
                    contentHeight: 400,
                    viewportHeight: 300,
                    insetTop: 0,
                    insetBottom: 0,
                    contentOffset: 0,
                    childFrame: nil
                ),
                NestedParticipantSnapshot(
                    id: parent,
                    contentHeight: 1_000,
                    viewportHeight: 300,
                    insetTop: 20,
                    insetBottom: 0,
                    contentOffset: 100,
                    childFrame: 100...350
                )
            ],
            displayHeight: .native(300),
            comparison: ScrollComparisonPolicy(displayScale: 2)
        )

        XCTAssertEqual(slices.map(\.participantID), [parent, primary, parent])
        XCTAssertEqual(slices[0].innerStart.value, -20)
        XCTAssertEqual(slices[0].innerEnd.value, 100)
        XCTAssertEqual(slices[2].innerStart.value, 100)
        XCTAssertEqual(slices[2].innerEnd.value, 700)

        _ = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [.native(300)],
                participantOrder: [primary, parent],
                participantSegments: slices
            )
        )
    }

    func testNestedAlreadyScrolledInsetNearBottomDoesNotDropAncestor() throws {
        let slices = try NestedParticipantBuilder.makeSegments(
            chain: [
                NestedParticipantSnapshot(
                    id: primary,
                    contentHeight: 400,
                    viewportHeight: 300,
                    insetTop: 0,
                    insetBottom: 0,
                    contentOffset: 0,
                    childFrame: nil
                ),
                NestedParticipantSnapshot(
                    id: parent,
                    contentHeight: 1_000,
                    viewportHeight: 300,
                    insetTop: 20,
                    insetBottom: 0,
                    contentOffset: 690,
                    childFrame: 600...900
                )
            ],
            displayHeight: .native(300),
            comparison: ScrollComparisonPolicy(displayScale: 2)
        )

        XCTAssertEqual(slices.map(\.participantID), [parent, primary, parent])
        XCTAssertEqual(slices[0].innerStart.value, -20)
        XCTAssertEqual(slices[0].innerEnd.value, 690)
        XCTAssertEqual(slices[2].innerStart.value, 690)
        XCTAssertEqual(slices[2].innerEnd.value, 700)
    }

    func testThreeLevelNestedChainPreservesEachAncestorsBeforeAndAfterSlices() throws {
        let grandparent = ParticipantID(rawValue: 3)
        let slices = try NestedParticipantBuilder.makeSegments(
            chain: [
                NestedParticipantSnapshot(
                    id: primary,
                    contentHeight: 400,
                    viewportHeight: 300,
                    insetTop: 0,
                    insetBottom: 0,
                    contentOffset: 0,
                    childFrame: nil
                ),
                NestedParticipantSnapshot(
                    id: parent,
                    contentHeight: 1_000,
                    viewportHeight: 300,
                    insetTop: 0,
                    insetBottom: 0,
                    contentOffset: 0,
                    childFrame: 400...600
                ),
                NestedParticipantSnapshot(
                    id: grandparent,
                    contentHeight: 1_200,
                    viewportHeight: 400,
                    insetTop: 0,
                    insetBottom: 0,
                    contentOffset: 0,
                    childFrame: 300...900
                )
            ],
            displayHeight: .native(300),
            comparison: ScrollComparisonPolicy(displayScale: 3)
        )

        XCTAssertEqual(
            slices.map(\.participantID),
            [grandparent, parent, primary, parent, grandparent]
        )
        XCTAssertEqual(slices[0].innerStart.value, 0)
        XCTAssertEqual(slices[0].innerEnd.value, 300)
        XCTAssertEqual(slices[4].innerStart.value, 300)
        XCTAssertEqual(slices[4].innerEnd.value, 800)
    }

    func testNegativeParticipantLengthIsRejected() {
        XCTAssertThrowsError(
            try ScrollModelBuilder.build(
                from: ScrollModelSnapshot(
                    viewportHeight: 600,
                    displayScale: 2,
                    detents: [.native(300)],
                    participantOrder: [primary],
                    participantSegments: [segment(primary, displayHeight: 300, start: 10, end: 9)]
                )
            )
        ) { error in
            guard case ScrollModelError.invalidInnerRange = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDetentThatBecomesNonFiniteAfterFloat32ConversionIsRejected() {
        XCTAssertThrowsError(
            try ScrollModelBuilder.build(
                from: ScrollModelSnapshot(
                    viewportHeight: 600,
                    displayScale: 2,
                    detents: [.objectiveCNumber(.greatestFiniteMagnitude)],
                    participantOrder: [],
                    participantSegments: []
                )
            )
        ) { error in
            guard case ScrollModelError.invalidDetent(let value) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(value.isInfinite)
        }
    }

    func testDetentsMustBeStrictlyIncreasingAfterSourceConversion() {
        let valuesThatCollapseToTheSameFloat: [ScrollSourceScalar] = [
            .objectiveCNumber(16_777_216),
            .objectiveCNumber(16_777_217)
        ]

        XCTAssertThrowsError(
            try ScrollModelBuilder.build(
                from: ScrollModelSnapshot(
                    viewportHeight: 600,
                    displayScale: 2,
                    detents: valuesThatCollapseToTheSameFloat,
                    participantOrder: [],
                    participantSegments: []
                )
            )
        ) { error in
            guard case ScrollModelError.unorderedDetents = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(
            try ScrollModelBuilder.build(
                from: ScrollModelSnapshot(
                    viewportHeight: 600,
                    displayScale: 2,
                    detents: [.native(300), .native(100)],
                    participantOrder: [],
                    participantSegments: []
                )
            )
        ) { error in
            guard case ScrollModelError.unorderedDetents = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testParticipantDisplayHeightOrderingDoesNotUsePhysicalPixelBand() {
        XCTAssertThrowsError(
            try ScrollModelBuilder.build(
                from: ScrollModelSnapshot(
                    viewportHeight: 600,
                    displayScale: 2,
                    detents: [.native(300)],
                    participantOrder: [primary],
                    participantSegments: [
                        segment(primary, displayHeight: 300, start: 0, end: 10),
                        // This is inside the 0.5-point runtime decision band,
                        // but it is still structurally out of order.
                        segment(primary, displayHeight: 299.75, start: 10, end: 20)
                    ]
                )
            )
        ) { error in
            guard case ScrollModelError.unorderedParticipantSegments = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLaterRangeForSameParticipantCannotMoveBackwardOrOverlap() {
        let other = ParticipantID(rawValue: 3)
        XCTAssertThrowsError(
            try ScrollModelBuilder.build(
                from: ScrollModelSnapshot(
                    viewportHeight: 600,
                    displayScale: 2,
                    detents: [.native(300)],
                    participantOrder: [primary, other],
                    participantSegments: [
                        segment(primary, displayHeight: 300, start: 0, end: 20),
                        segment(other, displayHeight: 300, start: 0, end: 50),
                        segment(primary, displayHeight: 300, start: 19, end: 40)
                    ]
                )
            )
        ) { error in
            guard case ScrollModelError.unorderedParticipantInnerRanges(
                participant: let participant,
                previousEnd: let previousEnd,
                nextStart: let nextStart
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(participant, primary)
            XCTAssertEqual(previousEnd, 20)
            XCTAssertEqual(nextStart, 19)
        }
    }

    func testCompositeOuterArithmeticRejectsFiniteInputOverflow() {
        let other = ParticipantID(rawValue: 3)
        let individuallyFiniteLength = CGFloat.greatestFiniteMagnitude * 0.75

        XCTAssertThrowsError(
            try ScrollModelBuilder.build(
                from: ScrollModelSnapshot(
                    viewportHeight: 600,
                    displayScale: 2,
                    detents: [],
                    participantOrder: [primary, other],
                    participantSegments: [
                        segment(primary, displayHeight: 300, start: 0, end: individuallyFiniteLength),
                        segment(other, displayHeight: 300, start: 0, end: individuallyFiniteLength)
                    ]
                )
            )
        ) { error in
            guard case ScrollModelError.nonFiniteOuterGeometry = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
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
