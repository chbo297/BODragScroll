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

    func testValueEqualityAndPhysicalPixelAreDifferentStrictBands() {
        let policy = ScrollComparisonPolicy(displayScale: 2)

        XCTAssertTrue(policy.isValueEqual(0, ScrollComparisonPolicy.valueEqualityTolerance * 0.5))
        XCTAssertFalse(policy.isValueEqual(0, ScrollComparisonPolicy.valueEqualityTolerance))
        XCTAssertEqual(policy.boundaryBand, 0.5)
        XCTAssertTrue(policy.isWithinBoundaryBand(100, 100.499_999))
        XCTAssertFalse(policy.isWithinBoundaryBand(100, 100.5))

        XCTAssertEqual(policy.snappingToNearestEndpoint(-0.000_05, 0, 10), 0)
        XCTAssertEqual(policy.snappingToNearestEndpoint(10.000_05, 0, 10), 10)
        XCTAssertEqual(policy.snappingToNearestEndpoint(-0.25, 0, 10), -0.25)
    }

    func testProjectedHeightSeparatesKnownTargetsFromContinuousGeometry() {
        let policy = ScrollComparisonPolicy(displayScale: 3)
        let authoritative = ProjectedHeight.authoritative(873)
        let geometric = ProjectedHeight.geometric(872.75)
        let outerOffset: CGFloat = 1_234.567_89
        let fallbackOrigin: CGFloat = 400

        XCTAssertEqual(
            authoritative.panelOriginY(
                viewportHeight: 874,
                outerOffsetY: outerOffset,
                geometricFallback: fallbackOrigin
            ),
            874 + outerOffset - 873
        )
        XCTAssertEqual(
            geometric.panelOriginY(
                viewportHeight: 874,
                outerOffsetY: outerOffset,
                geometricFallback: fallbackOrigin
            ),
            fallbackOrigin
        )

        XCTAssertEqual(
            authoritative.publishedValue(actual: CGFloat(873).nextUp, comparison: policy),
            873
        )
        XCTAssertEqual(
            ProjectedHeight.authoritative(200).publishedValue(
                actual: 199.9999,
                comparison: policy
            ),
            199.9999
        )
        XCTAssertEqual(
            geometric.publishedValue(actual: CGFloat(873).nextUp, comparison: policy),
            CGFloat(873).nextUp
        )
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
        XCTAssertEqual(middle.panelOriginY, 50)
        XCTAssertEqual(middle.displayHeight, 300)

        let secondPrimarySlice = model.projection(at: -220)
        XCTAssertEqual(secondPrimarySlice.activeOwner, .participant(primary))
        XCTAssertEqual(secondPrimarySlice.offset(for: primary), 30)
        XCTAssertEqual(secondPrimarySlice.offset(for: other), 50)
        XCTAssertEqual(secondPrimarySlice.panelOriginY, 80)
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
        XCTAssertEqual(secondStart.panelOriginY, 20)

        // The same rule applies when returning to a later slice of an owner
        // that already appeared earlier on the composite axis.
        let thirdStart = model.projection(at: -230)
        XCTAssertEqual(thirdStart.activeOwner, .participant(primary))
        XCTAssertFalse(thirdStart.isParticipantScrolling)
        XCTAssertEqual(thirdStart.offset(for: primary), 20)
        XCTAssertEqual(thirdStart.offset(for: other), 50)
        XCTAssertEqual(thirdStart.panelOriginY, 70)
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
        XCTAssertEqual(exact.panelOriginY, 0)
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

    func testProjectionSnapsOnlyArithmeticEndpointResidueAndKeepsPixelPreEntry() throws {
        let model = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [.native(300)],
                participantOrder: [primary],
                participantSegments: [segment(primary, displayHeight: 300, start: 0, end: 100)]
            )
        )
        let segment = try XCTUnwrap(model.segments.first)

        let arithmeticResidue = model.projection(at: segment.outerStart - 0.000_05)
        XCTAssertEqual(arithmeticResidue.offset(for: primary), segment.innerStart)
        XCTAssertEqual(arithmeticResidue.authoritativeDisplayHeight, segment.displayHeight)
        XCTAssertEqual(arithmeticResidue.displayHeight, segment.displayHeight)

        let physicalPixelPreEntry = model.projection(at: segment.outerStart - 0.25)
        XCTAssertEqual(physicalPixelPreEntry.offset(for: primary), segment.innerStart - 0.25)
        XCTAssertNil(physicalPixelPreEntry.authoritativeDisplayHeight)
        XCTAssertEqual(physicalPixelPreEntry.displayHeight, segment.displayHeight)
    }

    func testProjectionPublishesExactModelHeightInsideParticipantSegment() throws {
        let authoritativeHeight: CGFloat = 321.123_456_789
        let model = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 873,
                displayScale: 3,
                detents: [],
                participantOrder: [primary],
                participantSegments: [
                    segment(primary, displayHeight: authoritativeHeight, start: 0, end: 2_000)
                ]
            )
        )
        let segment = try XCTUnwrap(model.segments.first)
        let projection = model.projection(at: segment.outerStart + 777.777_777)

        XCTAssertEqual(projection.authoritativeDisplayHeight, authoritativeHeight)
        XCTAssertEqual(projection.displayHeight, authoritativeHeight)
        XCTAssertEqual(
            projection.panelOriginY,
            model.viewportHeight + projection.outerOffset - authoritativeHeight
        )
    }

    func testProjectionUsesPanelAnchorAuthorityOnlyForMachineNoise() throws {
        let model = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 3,
                detents: [.native(300), .native(500)],
                participantOrder: [primary],
                participantSegments: [
                    segment(primary, displayHeight: 300, start: 0, end: 100.3)
                ]
            )
        )
        let panelAnchor = try XCTUnwrap(
            model.segments.last(where: { !$0.isParticipantSegment })
        )

        for outerOffset in [
            panelAnchor.outerStart,
            panelAnchor.outerStart.nextUp,
            panelAnchor.outerStart.nextDown
        ] {
            let projection = model.projection(at: outerOffset)
            XCTAssertEqual(projection.authoritativeDisplayHeight, panelAnchor.displayHeight)
            XCTAssertEqual(projection.displayHeight, panelAnchor.displayHeight)
        }

        let realIntermediateOffset = panelAnchor.outerStart - 0.000_05
        let intermediate = model.projection(at: realIntermediateOffset)
        XCTAssertNil(intermediate.authoritativeDisplayHeight)
        XCTAssertNotEqual(intermediate.displayHeight, panelAnchor.displayHeight)
    }

    func testAdaptiveParticipantAxisRebaseIsContinuousAtUpperPivot() throws {
        let model = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [],
                participantOrder: [primary],
                participantSegments: [segment(primary, displayHeight: 300, start: 0, end: 100)]
            )
        )
        let oldSegment = try XCTUnwrap(model.segments.first)
        let pivotDisplayHeight: CGFloat = 500
        let pivotOuterOffset = oldSegment.outerEnd + pivotDisplayHeight - oldSegment.displayHeight
        let oldPivot = model.projection(at: pivotOuterOffset)

        let rebased = try XCTUnwrap(
            model.rebasedAdaptiveParticipantAxis(to: pivotDisplayHeight)
        )
        let newSegment = try XCTUnwrap(rebased.segments.first)
        let newPivot = rebased.projection(at: pivotOuterOffset)

        XCTAssertEqual(newPivot.displayHeight, oldPivot.displayHeight)
        XCTAssertEqual(newPivot.panelOriginY, oldPivot.panelOriginY)
        XCTAssertEqual(newPivot.participantOffsets, oldPivot.participantOffsets)
        XCTAssertEqual(newSegment.displayHeight, pivotDisplayHeight)
        XCTAssertEqual(newSegment.innerStart, oldSegment.innerStart)
        XCTAssertEqual(newSegment.innerEnd, oldSegment.innerEnd)

        // On the first returning point, the old model would lower the panel. The rebased model
        // instead keeps the new activation height fixed and immediately returns inner content.
        let returningOuterOffset = pivotOuterOffset - 1
        XCTAssertEqual(model.projection(at: returningOuterOffset).displayHeight, 499)
        XCTAssertEqual(rebased.projection(at: returningOuterOffset).displayHeight, 500)
        XCTAssertEqual(rebased.projection(at: returningOuterOffset).offset(for: primary), 99)
    }

    func testAdaptiveParticipantAxisRebaseIsContinuousAtLowerPivot() throws {
        let model = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [],
                participantOrder: [primary],
                participantSegments: [segment(primary, displayHeight: 500, start: 0, end: 100)]
            )
        )
        let oldSegment = try XCTUnwrap(model.segments.first)
        let pivotDisplayHeight: CGFloat = 300
        let pivotOuterOffset = oldSegment.outerStart + pivotDisplayHeight - oldSegment.displayHeight
        let oldPivot = model.projection(at: pivotOuterOffset)

        let rebased = try XCTUnwrap(
            model.rebasedAdaptiveParticipantAxis(to: pivotDisplayHeight)
        )
        let newPivot = rebased.projection(at: pivotOuterOffset)

        XCTAssertEqual(newPivot.displayHeight, oldPivot.displayHeight)
        XCTAssertEqual(newPivot.panelOriginY, oldPivot.panelOriginY)
        XCTAssertEqual(newPivot.participantOffsets, oldPivot.participantOffsets)

        // Moving forward from the lower pivot now consumes inner distance before raising the panel.
        let returningOuterOffset = pivotOuterOffset + 1
        XCTAssertEqual(model.projection(at: returningOuterOffset).displayHeight, 301)
        XCTAssertEqual(rebased.projection(at: returningOuterOffset).displayHeight, 300)
        XCTAssertEqual(rebased.projection(at: returningOuterOffset).offset(for: primary), 1)
    }

    func testAdaptiveParticipantAxisRebasePreservesNestedSplitSegments() throws {
        let grandparent = ParticipantID(rawValue: 3)
        let model = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 3,
                detents: [],
                participantOrder: [primary, parent, grandparent],
                participantSegments: [
                    segment(grandparent, displayHeight: 320, start: -10, end: 40),
                    segment(parent, displayHeight: 320, start: 0, end: 70),
                    segment(primary, displayHeight: 320, start: -5, end: 95),
                    segment(parent, displayHeight: 320, start: 70, end: 140),
                    segment(grandparent, displayHeight: 320, start: 40, end: 90)
                ]
            )
        )
        let targetDisplayHeight: CGFloat = 480

        let rebased = try XCTUnwrap(
            model.rebasedAdaptiveParticipantAxis(to: targetDisplayHeight)
        )

        XCTAssertEqual(rebased.participantOrder, model.participantOrder)
        XCTAssertEqual(rebased.segments.map(\.owner), model.segments.map(\.owner))
        XCTAssertEqual(rebased.segments.map(\.innerStart), model.segments.map(\.innerStart))
        XCTAssertEqual(rebased.segments.map(\.innerEnd), model.segments.map(\.innerEnd))
        XCTAssertEqual(
            rebased.segments.map(\.outerStart),
            model.segments.map { $0.outerStart + targetDisplayHeight - $0.displayHeight }
        )
        XCTAssertEqual(
            rebased.segments.map(\.outerEnd),
            model.segments.map { $0.outerEnd + targetDisplayHeight - $0.displayHeight }
        )
        XCTAssertTrue(rebased.segments.allSatisfy { $0.displayHeight == targetDisplayHeight })

        let oldLast = try XCTUnwrap(model.segments.last)
        let upperPivot = oldLast.outerEnd + targetDisplayHeight - oldLast.displayHeight
        XCTAssertEqual(
            rebased.projection(at: upperPivot).participantOffsets,
            model.projection(at: upperPivot).participantOffsets
        )
        XCTAssertEqual(
            rebased.projection(at: upperPivot).displayHeight,
            model.projection(at: upperPivot).displayHeight
        )
    }

    func testAdaptiveParticipantAxisRebaseRejectsFixedOrInvalidModels() throws {
        let detentModel = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [.native(300)],
                participantOrder: [primary],
                participantSegments: [segment(primary, displayHeight: 300, start: 0, end: 100)]
            )
        )
        XCTAssertNil(detentModel.rebasedAdaptiveParticipantAxis(to: 400))

        let panelOnlyModel = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [.native(300)],
                participantOrder: [],
                participantSegments: []
            )
        )
        XCTAssertNil(panelOnlyModel.rebasedAdaptiveParticipantAxis(to: 400))

        let zeroLengthModel = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [],
                participantOrder: [primary],
                participantSegments: [segment(primary, displayHeight: 300, start: 0, end: 0)]
            )
        )
        XCTAssertNil(zeroLengthModel.rebasedAdaptiveParticipantAxis(to: 400))

        let mixedActivationModel = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [],
                participantOrder: [primary, parent],
                participantSegments: [
                    segment(primary, displayHeight: 300, start: 0, end: 100),
                    segment(parent, displayHeight: 400, start: 0, end: 100)
                ]
            )
        )
        XCTAssertNil(mixedActivationModel.rebasedAdaptiveParticipantAxis(to: 500))

        let validModel = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [],
                participantOrder: [primary],
                participantSegments: [segment(primary, displayHeight: 300, start: 0, end: 100)]
            )
        )
        XCTAssertNil(validModel.rebasedAdaptiveParticipantAxis(to: .infinity))
        XCTAssertNil(validModel.rebasedAdaptiveParticipantAxis(to: .nan))

        let emptyModel = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [],
                participantOrder: [],
                participantSegments: []
            )
        )
        XCTAssertNil(emptyModel.rebasedAdaptiveParticipantAxis(to: 400))
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
