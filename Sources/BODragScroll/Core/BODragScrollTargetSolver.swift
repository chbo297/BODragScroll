//
//  BODragScrollTargetSolver.swift
//  BODragScroll
//
//  Pure release-target solver. This file intentionally does not import UIKit.
//

import Foundation

enum TargetScrollType: Equatable {
    case none
    case participantToParticipant
    case participantToPanel
    case panelToParticipant
    case panelToPanel
    case bounceReturn
}

enum TargetAnchorLocation: Int, Equatable {
    case before = -1
    case inside = 0
    case after = 1
}

struct TargetAnchorMatch: Equatable {
    let index: Int
    let location: TargetAnchorLocation
    let segment: ScrollSegment
}

struct NonSnappingRange: Equatable {
    let lowerBound: ScrollSourceScalar
    let upperBound: ScrollSourceScalar

    init(_ lowerBound: ScrollSourceScalar, _ upperBound: ScrollSourceScalar) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    func contains(_ displayHeight: CGFloat, boundaryBand: CGFloat) -> Bool {
        // The source uses strict comparisons with the physical-pixel decision
        // band expanded around both range endpoints.
        displayHeight > lowerBound.value - boundaryBand
            && displayHeight < upperBound.value + boundaryBand
    }
}

struct TargetSolverConfiguration: Equatable {
    var disableInnerMomentumTransfer: Bool
    var collapseResistance: Bool
    var lowVelocityThreshold: CGFloat
    var highVelocityThreshold: CGFloat
    var adjacentAnchorDistance: CGFloat
    var panelToParticipantCaptureDistance: CGFloat
    var nonSnappingRanges: [NonSnappingRange]

    init(
        disableInnerMomentumTransfer: Bool = false,
        collapseResistance: Bool = false,
        lowVelocityThreshold: CGFloat = 0.2,
        highVelocityThreshold: CGFloat = 2.2,
        adjacentAnchorDistance: CGFloat = 86,
        panelToParticipantCaptureDistance: CGFloat = 140,
        nonSnappingRanges: [NonSnappingRange] = []
    ) {
        self.disableInnerMomentumTransfer = disableInnerMomentumTransfer
        self.collapseResistance = collapseResistance
        self.lowVelocityThreshold = lowVelocityThreshold
        self.highVelocityThreshold = highVelocityThreshold
        self.adjacentAnchorDistance = adjacentAnchorDistance
        self.panelToParticipantCaptureDistance = panelToParticipantCaptureDistance
        self.nonSnappingRanges = nonSnappingRanges
    }
}

struct TargetSolverInput: Equatable {
    let model: ScrollModel
    let currentOuterOffset: CGFloat
    let proposedOuterOffset: CGFloat
    let velocity: CGFloat
    let minimumOuterOffset: CGFloat
    let maximumOuterOffset: CGFloat
    let configuration: TargetSolverConfiguration

    /// Mirrors the delegate precedence in the Objective-C source:
    /// - nil: no delegate decision; consult configured ranges.
    /// - true: delegate explicitly disables snapping for this target.
    /// - false: delegate explicitly keeps snapping and ranges are ignored.
    let nonSnappingOverride: Bool?

    init(
        model: ScrollModel,
        currentOuterOffset: CGFloat,
        proposedOuterOffset: CGFloat,
        velocity: CGFloat,
        minimumOuterOffset: CGFloat,
        maximumOuterOffset: CGFloat,
        configuration: TargetSolverConfiguration = .init(),
        nonSnappingOverride: Bool? = nil
    ) {
        self.model = model
        self.currentOuterOffset = currentOuterOffset
        self.proposedOuterOffset = proposedOuterOffset
        self.velocity = velocity
        self.minimumOuterOffset = minimumOuterOffset
        self.maximumOuterOffset = maximumOuterOffset
        self.configuration = configuration
        self.nonSnappingOverride = nonSnappingOverride
    }
}

struct TargetDecision: Equatable {
    let targetOuterOffset: CGFloat
    let targetDisplayHeight: CGFloat
    let scrollType: TargetScrollType
    let selectedAnchor: TargetAnchorMatch?
    let proposedAnchor: TargetAnchorMatch?
    let bypassedSnapping: Bool

    var selectedOwner: SegmentOwner? {
        selectedAnchor?.segment.owner
    }

    /// UIKit may accept an inner delegate's target adjustment only while it
    /// remains in this exact segment. This supplies the source's validation
    /// boundary without putting delegate calls in Core.
    func containsDelegateAdjustedTarget(_ outerOffset: CGFloat, in model: ScrollModel) -> Bool {
        guard let selectedAnchor, !model.segments.isEmpty else { return false }
        let adjustedMatch = TargetSolver.locate(
            outerOffset: outerOffset,
            anchors: model.segments,
            accuracy: model.comparison.boundaryBand
        )
        // The source accepts the inner delegate's adjustment when its nearest
        // attach-info index is unchanged, even if its location is before/after
        // that segment. UIKit can separately use adjustedMatch.location when
        // reproducing the source's boundary handling.
        return adjustedMatch.index == selectedAnchor.index
    }
}

enum TargetSolver {
    static func solve(_ input: TargetSolverInput) -> TargetDecision {
        let model = input.model
        let anchors = model.segments

        // Source behavior: inner segments alone do not activate snapping.
        // `attachDisplayHAr.count <= 0` returns immediately.
        guard model.hasDetents, !anchors.isEmpty else {
            return passthrough(input, proposedAnchor: nil, bypassedSnapping: false)
        }

        let accuracy = model.comparison.boundaryBand
        let current = locate(
            outerOffset: input.currentOuterOffset,
            anchors: anchors,
            accuracy: accuracy
        )
        var target = locate(
            outerOffset: input.proposedOuterOffset,
            anchors: anchors,
            accuracy: accuracy
        )
        let originalProposedAnchor = target

        let currentIsParticipant = current.location == .inside
            && current.segment.isParticipantSegment
        let targetIsParticipant = target.location == .inside
            && target.segment.isParticipantSegment

        if !targetIsParticipant,
           let proposedDisplayHeight = nonSnappingDisplayHeight(
               proposedOuterOffset: input.proposedOuterOffset,
               target: target
           ),
           shouldBypassSnapping(
               displayHeight: proposedDisplayHeight,
               input: input,
               accuracy: accuracy
           ) {
            return passthrough(
                input,
                proposedAnchor: originalProposedAnchor,
                bypassedSnapping: true
            )
        }

        var targetOuterOffset = input.proposedOuterOffset
        var scrollType: TargetScrollType = .none
        let absoluteVelocity = abs(input.velocity)

        if currentIsParticipant {
            if targetIsParticipant {
                // OC 11: participant -> participant.
                scrollType = .participantToParticipant
                if current.index != target.index {
                    if absoluteVelocity < input.configuration.lowVelocityThreshold {
                        target = TargetAnchorMatch(
                            index: current.index,
                            location: targetOuterOffset > input.currentOuterOffset ? .after : .before,
                            segment: current.segment
                        )
                    } else {
                        if input.velocity > 0 {
                            if current.index + 1 < anchors.count {
                                target = TargetAnchorMatch(
                                    index: current.index + 1,
                                    location: .before,
                                    segment: anchors[current.index + 1]
                                )
                            } else {
                                target = TargetAnchorMatch(
                                    index: current.index,
                                    location: .after,
                                    segment: current.segment
                                )
                            }
                        } else if current.index > 0 {
                            target = TargetAnchorMatch(
                                index: current.index - 1,
                                location: .after,
                                segment: anchors[current.index - 1]
                            )
                        } else {
                            target = TargetAnchorMatch(
                                index: current.index,
                                location: .before,
                                segment: current.segment
                            )
                        }
                        scrollType = .participantToPanel
                    }
                    targetOuterOffset = boundaryOffset(for: target)
                }
                // Same participant segment: preserve the system prediction.
            } else {
                // OC 12: participant -> panel.
                scrollType = .participantToPanel
                if current.index == target.index {
                    targetOuterOffset = clamp(
                        targetOuterOffset,
                        lower: target.segment.outerStart,
                        upper: target.segment.outerEnd
                    )
                } else if input.configuration.disableInnerMomentumTransfer {
                    target = current
                    targetOuterOffset = clamp(
                        targetOuterOffset,
                        lower: current.segment.outerStart,
                        upper: current.segment.outerEnd
                    )
                } else if input.velocity > 0 {
                    if absoluteVelocity > input.configuration.highVelocityThreshold,
                       input.currentOuterOffset
                        > current.segment.outerEnd - input.configuration.adjacentAnchorDistance,
                       current.index + 1 < anchors.count {
                        target = TargetAnchorMatch(
                            index: current.index + 1,
                            location: .before,
                            segment: anchors[current.index + 1]
                        )
                    } else {
                        target = TargetAnchorMatch(
                            index: current.index,
                            location: .after,
                            segment: current.segment
                        )
                    }
                    targetOuterOffset = boundaryOffset(for: target)
                } else {
                    if absoluteVelocity > input.configuration.highVelocityThreshold,
                       input.currentOuterOffset
                        < current.segment.outerStart + input.configuration.adjacentAnchorDistance,
                       current.index > 0 {
                        target = TargetAnchorMatch(
                            index: current.index - 1,
                            location: .after,
                            segment: anchors[current.index - 1]
                        )
                    } else {
                        target = TargetAnchorMatch(
                            index: current.index,
                            location: .before,
                            segment: current.segment
                        )
                    }
                    targetOuterOffset = boundaryOffset(for: target)
                }
            }
        } else {
            if targetIsParticipant {
                // OC 21: panel -> participant.
                scrollType = .panelToParticipant
                let captureDistance = input.configuration.panelToParticipantCaptureDistance
                if input.currentOuterOffset < target.segment.outerStart,
                   targetOuterOffset - target.segment.outerStart < captureDistance {
                    targetOuterOffset = target.segment.outerStart
                } else if input.currentOuterOffset > target.segment.outerEnd,
                          target.segment.outerEnd - targetOuterOffset < captureDistance {
                    targetOuterOffset = target.segment.outerEnd
                }
            } else {
                // OC 22: panel -> panel.
                scrollType = .panelToPanel
                if absoluteVelocity < input.configuration.lowVelocityThreshold {
                    target = current
                } else if input.velocity > 0 {
                    if current.location == .before {
                        if absoluteVelocity > input.configuration.highVelocityThreshold,
                           current.segment.outerStart - input.currentOuterOffset
                            < input.configuration.adjacentAnchorDistance,
                           current.index + 1 < anchors.count {
                            target = TargetAnchorMatch(
                                index: current.index + 1,
                                location: .before,
                                segment: anchors[current.index + 1]
                            )
                        } else {
                            target = TargetAnchorMatch(
                                index: current.index,
                                location: .before,
                                segment: current.segment
                            )
                        }
                    } else if current.index + 1 < anchors.count {
                        target = TargetAnchorMatch(
                            index: current.index + 1,
                            location: .before,
                            segment: anchors[current.index + 1]
                        )
                    } else {
                        target = TargetAnchorMatch(
                            index: current.index,
                            location: .after,
                            segment: current.segment
                        )
                    }
                } else if current.location == .after {
                    if absoluteVelocity > input.configuration.highVelocityThreshold,
                       input.currentOuterOffset - current.segment.outerEnd
                        < input.configuration.adjacentAnchorDistance,
                       current.index > 0 {
                        target = TargetAnchorMatch(
                            index: current.index - 1,
                            location: .after,
                            segment: anchors[current.index - 1]
                        )
                    } else {
                        target = TargetAnchorMatch(
                            index: current.index,
                            location: .after,
                            segment: current.segment
                        )
                    }
                } else if input.configuration.collapseResistance {
                    if current.segment.outerStart - input.currentOuterOffset
                        < input.configuration.adjacentAnchorDistance {
                        target = current
                    } else if current.index > 0 {
                        target = TargetAnchorMatch(
                            index: current.index - 1,
                            location: .after,
                            segment: anchors[current.index - 1]
                        )
                    } else {
                        target = TargetAnchorMatch(
                            index: current.index,
                            location: .before,
                            segment: current.segment
                        )
                    }
                } else if current.index > 0 {
                    target = TargetAnchorMatch(
                        index: current.index - 1,
                        location: .after,
                        segment: anchors[current.index - 1]
                    )
                } else {
                    target = TargetAnchorMatch(
                        index: current.index,
                        location: .before,
                        segment: current.segment
                    )
                }

                targetOuterOffset = boundaryOffset(for: target)
            }

            // OC 32: return from an outer bounce. The bottom source branch
            // classifies any current offset beyond max, while the top branch
            // additionally checks that the target is exactly the normal min.
            if input.currentOuterOffset < input.minimumOuterOffset,
               model.comparison.isJitterEqual(targetOuterOffset, input.minimumOuterOffset) {
                scrollType = .bounceReturn
            } else if input.currentOuterOffset > input.maximumOuterOffset {
                scrollType = .bounceReturn
            }
        }

        return TargetDecision(
            targetOuterOffset: targetOuterOffset,
            targetDisplayHeight: displayHeight(
                at: targetOuterOffset,
                relativeTo: target.segment
            ),
            scrollType: scrollType,
            selectedAnchor: target,
            proposedAnchor: originalProposedAnchor,
            bypassedSnapping: false
        )
    }

    static func locate(
        outerOffset: CGFloat,
        anchors: [ScrollSegment],
        accuracy: CGFloat
    ) -> TargetAnchorMatch {
        precondition(!anchors.isEmpty)

        for index in anchors.indices {
            let segment = anchors[index]
            if outerOffset < segment.outerStart - accuracy {
                if index > 0 {
                    let previous = anchors[index - 1]
                    if outerOffset - previous.outerEnd < segment.outerStart - outerOffset {
                        return TargetAnchorMatch(
                            index: index - 1,
                            location: .after,
                            segment: previous
                        )
                    }
                }
                return TargetAnchorMatch(index: index, location: .before, segment: segment)
            } else if outerOffset <= segment.outerEnd + accuracy {
                return TargetAnchorMatch(index: index, location: .inside, segment: segment)
            } else if index == anchors.count - 1 {
                return TargetAnchorMatch(index: index, location: .after, segment: segment)
            }
        }

        // The source returns index zero if no branch matched. This is only a
        // defensive fallback because the last-anchor branch normally returns.
        return TargetAnchorMatch(index: 0, location: .inside, segment: anchors[0])
    }

    private static func passthrough(
        _ input: TargetSolverInput,
        proposedAnchor: TargetAnchorMatch?,
        bypassedSnapping: Bool
    ) -> TargetDecision {
        TargetDecision(
            targetOuterOffset: input.proposedOuterOffset,
            targetDisplayHeight: input.model.projection(at: input.proposedOuterOffset).displayHeight,
            scrollType: .none,
            selectedAnchor: proposedAnchor,
            proposedAnchor: proposedAnchor,
            bypassedSnapping: bypassedSnapping
        )
    }

    private static func shouldBypassSnapping(
        displayHeight: CGFloat,
        input: TargetSolverInput,
        accuracy: CGFloat
    ) -> Bool {
        if let override = input.nonSnappingOverride {
            return override
        }
        return input.configuration.nonSnappingRanges.contains {
            $0.contains(displayHeight, boundaryBand: accuracy)
        }
    }

    private static func nonSnappingDisplayHeight(
        proposedOuterOffset: CGFloat,
        target: TargetAnchorMatch
    ) -> CGFloat? {
        let segment = target.segment
        if proposedOuterOffset < segment.outerStart {
            return segment.displayHeight - segment.outerStart + proposedOuterOffset
        } else if proposedOuterOffset > segment.outerEnd {
            // Intentional source fix: the display height below a participant
            // segment is relative to its outer end. The Objective-C code uses
            // outerStart here and therefore adds the complete inner-scroll
            // length a second time.
            return segment.displayHeight + proposedOuterOffset - segment.outerEnd
        }
        return nil
    }

    private static func boundaryOffset(for target: TargetAnchorMatch) -> CGFloat {
        target.location == .before
            ? target.segment.outerStart
            : target.segment.outerEnd
    }

    private static func displayHeight(
        at outerOffset: CGFloat,
        relativeTo segment: ScrollSegment
    ) -> CGFloat {
        if outerOffset < segment.outerStart {
            return segment.displayHeight - segment.outerStart + outerOffset
        } else if outerOffset <= segment.outerEnd {
            return segment.displayHeight
        } else {
            return segment.displayHeight + outerOffset - segment.outerEnd
        }
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        max(lower, min(upper, value))
    }
}
