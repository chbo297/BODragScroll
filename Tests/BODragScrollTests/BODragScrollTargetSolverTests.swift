import XCTest
@testable import BODragScroll

final class BODragScrollTargetSolverTests: XCTestCase {
    private let primary = ParticipantID(rawValue: 1)

    func testNoDetentsKeepsSystemPredictionEvenWhenParticipantSegmentsExist() throws {
        let model = try makeModel(detents: [])
        let decision = TargetSolver.solve(
            input(model, current: -200, proposed: 123, velocity: 4)
        )

        XCTAssertEqual(decision.targetOuterOffset, 123)
        XCTAssertEqual(decision.scrollType, .none)
        XCTAssertFalse(decision.bypassedSnapping)
    }

    func testKnownPanelBoundaryKeepsCanonicalHeightAcrossProjectionAndTargetSolving() throws {
        let model = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 640,
                displayScale: 3,
                detents: [.native(25), .native(50)],
                participantOrder: [primary],
                participantSegments: [
                    segment(primary, displayHeight: 25, start: 0, end: 1.0 / 3.0)
                ]
            )
        )
        let participant = try XCTUnwrap(model.segments.first(where: \.isParticipantSegment))
        let panelAnchor = try XCTUnwrap(model.segments.last)
        let projection = model.projection(at: panelAnchor.outerStart)
        XCTAssertEqual(projection.authoritativeDisplayHeight, panelAnchor.displayHeight)
        XCTAssertEqual(projection.displayHeight, panelAnchor.displayHeight)

        let decision = TargetSolver.solve(
            input(
                model,
                current: participant.outerEnd - 0.1,
                proposed: panelAnchor.outerStart,
                velocity: 3
            )
        )

        XCTAssertEqual(decision.targetOuterOffset, panelAnchor.outerStart)
        XCTAssertEqual(decision.targetDisplayHeight, panelAnchor.displayHeight)
        XCTAssertEqual(decision.targetDisplayHeight, 50)
    }

    func testNonSnappingRangeReturnsPredictionEarly() throws {
        let model = try makeModel()
        var configuration = TargetSolverConfiguration()
        configuration.nonSnappingRanges = [
            NonSnappingRange(.objectiveCNumber(190), .objectiveCNumber(210))
        ]

        // Relative to the participant anchor at -300, proposed -400 maps to
        // displayHeight 200 in the source's shouldMisAttach calculation.
        let decision = TargetSolver.solve(
            input(
                model,
                current: -450,
                proposed: -400,
                velocity: 0,
                configuration: configuration
            )
        )

        XCTAssertEqual(decision.targetOuterOffset, -400)
        XCTAssertEqual(decision.scrollType, .none)
        XCTAssertTrue(decision.bypassedSnapping)
    }

    func testNonSnappingDisplayBelowParticipantDoesNotAddItsLengthTwice() throws {
        let model = try makeModel()
        var configuration = TargetSolverConfiguration()
        configuration.nonSnappingRanges = [
            NonSnappingRange(.native(390), .native(410))
        ]

        // The participant is -300 ... -100 with displayHeight 300. Proposed 0
        // is therefore displayHeight 400. Subtracting outerStart (the OC bug)
        // would incorrectly produce 600 and fail to enter this range.
        let decision = TargetSolver.solve(
            input(
                model,
                current: -50,
                proposed: 0,
                velocity: 1,
                configuration: configuration
            )
        )

        XCTAssertEqual(decision.targetOuterOffset, 0)
        XCTAssertEqual(decision.scrollType, .none)
        XCTAssertTrue(decision.bypassedSnapping)
    }

    func testExplicitFalseNonSnappingOverrideSuppressesConfiguredRanges() throws {
        let model = try makeModel()
        var configuration = TargetSolverConfiguration()
        configuration.nonSnappingRanges = [
            NonSnappingRange(.native(190), .native(210))
        ]

        let decision = TargetSolver.solve(
            TargetSolverInput(
                model: model,
                currentOuterOffset: -450,
                proposedOuterOffset: -400,
                velocity: 0,
                minimumOuterOffset: -500,
                maximumOuterOffset: 200,
                configuration: configuration,
                nonSnappingOverride: false
            )
        )

        XCTAssertEqual(decision.targetOuterOffset, -500)
        XCTAssertFalse(decision.bypassedSnapping)
        XCTAssertEqual(decision.scrollType, .panelToPanel)
    }

    func testDisableInnerMomentumTransferClampsToCurrentParticipant() throws {
        let model = try makeModel()
        var configuration = TargetSolverConfiguration()
        configuration.disableInnerMomentumTransfer = true

        let decision = TargetSolver.solve(
            input(
                model,
                current: -200,
                proposed: 100,
                velocity: 4,
                configuration: configuration
            )
        )

        XCTAssertEqual(decision.targetOuterOffset, -100)
        XCTAssertEqual(decision.scrollType, .participantToPanel)
        XCTAssertEqual(decision.selectedOwner, .participant(primary))
    }

    func testParticipantMomentumJumpsToAdjacentAnchorOnlyAboveSourceThreshold() throws {
        let model = try makeModel()

        let above = TargetSolver.solve(
            input(model, current: -120, proposed: 100, velocity: 2.200_001)
        )
        XCTAssertEqual(above.targetOuterOffset, 200)
        XCTAssertEqual(above.selectedOwner, .panel)

        let exact = TargetSolver.solve(
            input(model, current: -120, proposed: 100, velocity: 2.2)
        )
        XCTAssertEqual(exact.targetOuterOffset, -100)
        XCTAssertEqual(exact.selectedOwner, .participant(primary))
    }

    func testParticipantMomentumUsesVelocityDirectionTowardPreviousAnchor() throws {
        let model = try makeModel()
        let decision = TargetSolver.solve(
            input(model, current: -280, proposed: -450, velocity: -3)
        )

        XCTAssertEqual(decision.targetOuterOffset, -500)
        XCTAssertEqual(decision.scrollType, .participantToPanel)
        XCTAssertEqual(decision.selectedOwner, .panel)
    }

    func testPanelToParticipantUsesStrict140PointCaptureDistance() throws {
        let model = try makeModel()

        let inside = TargetSolver.solve(
            input(model, current: -400, proposed: -250, velocity: 1)
        )
        XCTAssertEqual(inside.scrollType, .panelToParticipant)
        XCTAssertEqual(inside.targetOuterOffset, -300)

        let exactBoundary = TargetSolver.solve(
            input(model, current: -400, proposed: -160, velocity: 1)
        )
        XCTAssertEqual(exactBoundary.scrollType, .panelToParticipant)
        XCTAssertEqual(exactBoundary.targetOuterOffset, -160)
    }

    func testPanelHighVelocitySkipsAdjacentAnchorOnlyInsideStrict86PointWindow() throws {
        let model = try makeModel()

        let inside = TargetSolver.solve(
            input(model, current: -320, proposed: 100, velocity: 3)
        )
        XCTAssertEqual(inside.targetOuterOffset, 200)

        let exactBoundary = TargetSolver.solve(
            input(model, current: -386, proposed: 100, velocity: 3)
        )
        XCTAssertEqual(exactBoundary.targetOuterOffset, -300)
    }

    func testCollapseResistanceKeepsNearCurrentAnchor() throws {
        let model = try makeModel()

        var resistedConfiguration = TargetSolverConfiguration()
        resistedConfiguration.collapseResistance = true
        let resisted = TargetSolver.solve(
            input(
                model,
                current: -350,
                proposed: -600,
                velocity: -1,
                configuration: resistedConfiguration
            )
        )
        XCTAssertEqual(resisted.targetOuterOffset, -300)

        let normal = TargetSolver.solve(
            input(model, current: -350, proposed: -600, velocity: -1)
        )
        XCTAssertEqual(normal.targetOuterOffset, -500)
    }

    func testLowVelocityThresholdIsStrictlyLessThanPointTwo() throws {
        let model = try makeModel()

        let below = TargetSolver.solve(
            input(model, current: -450, proposed: 100, velocity: 0.199_999)
        )
        XCTAssertEqual(below.targetOuterOffset, -500)

        let exact = TargetSolver.solve(
            input(model, current: -450, proposed: 100, velocity: 0.2)
        )
        XCTAssertEqual(exact.targetOuterOffset, -300)
    }

    func testCrossParticipantLowVelocityReturnsToCurrentSegment() throws {
        let other = ParticipantID(rawValue: 2)
        let model = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [.native(100), .native(300), .native(600)],
                participantOrder: [primary, other],
                participantSegments: [
                    segment(primary, displayHeight: 300, start: 0, end: 100),
                    segment(other, displayHeight: 300, start: 0, end: 100)
                ]
            )
        )

        let below = TargetSolver.solve(
            input(model, current: -250, proposed: -150, velocity: 0.199_999)
        )
        XCTAssertEqual(below.targetOuterOffset, -200)
        XCTAssertEqual(below.scrollType, .participantToParticipant)
        XCTAssertEqual(below.selectedOwner, .participant(primary))

        let exact = TargetSolver.solve(
            input(model, current: -250, proposed: -150, velocity: 0.2)
        )
        XCTAssertEqual(exact.targetOuterOffset, -200)
        XCTAssertEqual(exact.scrollType, .participantToPanel)
        XCTAssertEqual(exact.selectedOwner, .participant(other))
    }

    func testBounceReturnClassificationMatchesTopAndBottomSourceBranches() throws {
        let model = try makeModel()

        let top = TargetSolver.solve(
            input(model, current: -550, proposed: -500, velocity: 0)
        )
        XCTAssertEqual(top.targetOuterOffset, -500)
        XCTAssertEqual(top.scrollType, .bounceReturn)

        let bottom = TargetSolver.solve(
            input(model, current: 250, proposed: 200, velocity: 0)
        )
        XCTAssertEqual(bottom.targetOuterOffset, 200)
        XCTAssertEqual(bottom.scrollType, .bounceReturn)
    }

    func testZeroLengthParticipantIsLocatedInsideOnePixelDecisionBand() throws {
        let model = try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: [.native(300)],
                participantOrder: [primary],
                participantSegments: [segment(primary, displayHeight: 300, start: 0, end: 0)]
            )
        )

        let match = TargetSolver.locate(
            outerOffset: -300.25,
            anchors: model.segments,
            accuracy: model.comparison.boundaryBand
        )
        XCTAssertEqual(match.location, .inside)
        XCTAssertEqual(match.segment.owner, .participant(primary))

        let decision = TargetSolver.solve(
            input(model, current: -300.25, proposed: -300.1, velocity: 0)
        )
        XCTAssertEqual(decision.scrollType, .participantToParticipant)
        XCTAssertEqual(decision.selectedOwner, .participant(primary))
    }

    func testDecisionProvidesSameSegmentValidationForUIKitDelegateAdjustment() throws {
        let model = try makeModel()
        let decision = TargetSolver.solve(
            input(model, current: -200, proposed: -150, velocity: 1)
        )

        XCTAssertTrue(
            decision.containsDelegateAdjustedTarget(
                -299.5,
                in: model
            )
        )
        // The source validates the nearest attach-info index, not merely the
        // literal segment bounds, so the participant's surrounding Voronoi
        // region is still accepted.
        XCTAssertTrue(decision.containsDelegateAdjustedTarget(0, in: model))
        XCTAssertFalse(
            decision.containsDelegateAdjustedTarget(
                -401,
                in: model
            )
        )
        XCTAssertFalse(
            decision.containsDelegateAdjustedTarget(
                51,
                in: model
            )
        )
    }

    private func makeModel(detents: [CGFloat] = [100, 300, 600]) throws -> ScrollModel {
        try ScrollModelBuilder.build(
            from: ScrollModelSnapshot(
                viewportHeight: 600,
                displayScale: 2,
                detents: detents.map { .objectiveCNumber($0) },
                participantOrder: [primary],
                participantSegments: [
                    segment(primary, displayHeight: 300, start: 0, end: 200)
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

    private func input(
        _ model: ScrollModel,
        current: CGFloat,
        proposed: CGFloat,
        velocity: CGFloat,
        configuration: TargetSolverConfiguration = .init()
    ) -> TargetSolverInput {
        TargetSolverInput(
            model: model,
            currentOuterOffset: current,
            proposedOuterOffset: proposed,
            velocity: velocity,
            minimumOuterOffset: -500,
            maximumOuterOffset: 200,
            configuration: configuration
        )
    }
}
