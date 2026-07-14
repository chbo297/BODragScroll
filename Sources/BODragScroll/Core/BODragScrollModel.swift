//
//  BODragScrollModel.swift
//  BODragScroll
//
//  Pure mathematical model for the composite panel/scroll axis.
//  This file intentionally does not import UIKit.
//

import Foundation

/// Find the index selected by the original `bo_findIdxInFloatArrayByValue` rules.
///
/// Array elements intentionally pass through Float32, matching `NSNumber.floatValue` in the OC API.
/// `nearby` chooses by distance; `ceil` resolves direction or an exact midpoint tie.
public func bo_findIndex(
    in values: [CGFloat],
    value: CGFloat,
    nearby: Bool,
    ceil: Bool
) -> Int {
    ScrollMath.sortedIndex(
        in: values.map(ScrollSourceScalar.objectiveCNumber),
        value: value,
        nearby: nearby,
        ceil: ceil
    )
}

// MARK: - Source numeric semantics

/// A scalar whose conversion point is explicit.
///
/// The Objective-C implementation reads many public `NSNumber` values through
/// `floatValue`.  That Float32 narrowing is observable around decision
/// boundaries, so the Swift port must not silently replace it with an arbitrary
/// comparison tolerance.
struct ScrollSourceScalar: Equatable {
    enum Representation: Equatable {
        case nativeCGFloat
        case objectiveCFloat
    }

    let rawValue: CGFloat
    let representation: Representation

    static func native(_ value: CGFloat) -> Self {
        Self(rawValue: value, representation: .nativeCGFloat)
    }

    static func objectiveCNumber(_ value: CGFloat) -> Self {
        Self(rawValue: value, representation: .objectiveCFloat)
    }

    var value: CGFloat {
        switch representation {
        case .nativeCGFloat:
            return rawValue
        case .objectiveCFloat:
            return CGFloat(Float(rawValue))
        }
    }
}

/// The three distinct comparison modes used by the source implementation.
/// They are algorithm decisions, not test tolerances.
struct ScrollComparisonPolicy: Equatable {
    let displayScale: CGFloat
    let jitterEpsilon: CGFloat

    init(displayScale: CGFloat, jitterEpsilon: CGFloat = 0.01) {
        self.displayScale = displayScale
        self.jitterEpsilon = jitterEpsilon
    }

    var boundaryBand: CGFloat {
        1 / displayScale
    }

    @inline(__always)
    func isJitterEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) <= jitterEpsilon
    }

    @inline(__always)
    func isWithinBoundaryBand(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) <= boundaryBand
    }
}

enum ScrollMath {
    /// Exact Swift reproduction of `bo_findIdxInFloatArrayByValue`.
    ///
    /// Values are supplied as `ScrollSourceScalar` so the caller explicitly
    /// chooses which entries reproduce Objective-C `NSNumber.floatValue`.
    static func sortedIndex(
        in values: [ScrollSourceScalar],
        value: CGFloat,
        nearby: Bool,
        ceil: Bool
    ) -> Int {
        for index in values.indices {
            let current = values[index].value
            if value > current {
                if index + 1 < values.count {
                    continue
                }
                return index
            } else if value < current {
                guard index > 0 else { return index }
                if nearby {
                    let previous = values[index - 1].value
                    let distanceDifference = abs(value - previous) - abs(current - value)
                    if distanceDifference > 0 {
                        return index
                    } else if distanceDifference < 0 {
                        return index - 1
                    }
                }
                return ceil ? index : index - 1
            } else {
                return index
            }
        }
        // The Objective-C helper returns zero for an empty array.
        return 0
    }
}

// MARK: - Axis identities and snapshots

/// Stable identity assigned by a capture session.  It deliberately contains no
/// `UIView`, `UIScrollView`, pointer, or `ObjectIdentifier` dependency.
struct ParticipantID: RawRepresentable, Hashable, Comparable, CustomStringConvertible {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String {
        "participant(\(rawValue))"
    }
}

enum SegmentOwner: Hashable {
    case panel
    case participant(ParticipantID)
}

/// A pure description of one participant-owned inner offset range.
/// The array order is the intended order on the composite axis.
struct ParticipantSegmentSnapshot: Equatable {
    let participantID: ParticipantID
    let displayHeight: ScrollSourceScalar
    let innerStart: ScrollSourceScalar
    let innerEnd: ScrollSourceScalar

    init(
        participantID: ParticipantID,
        displayHeight: ScrollSourceScalar,
        innerStart: ScrollSourceScalar,
        innerEnd: ScrollSourceScalar
    ) {
        self.participantID = participantID
        self.displayHeight = displayHeight
        self.innerStart = innerStart
        self.innerEnd = innerEnd
    }
}

/// UIKit capture code converts its geometry to this value snapshot before
/// calling the pure model builder.
struct ScrollModelSnapshot: Equatable {
    let viewportHeight: CGFloat
    let displayScale: CGFloat
    /// Strictly increasing after each scalar applies its source representation.
    let detents: [ScrollSourceScalar]
    let participantOrder: [ParticipantID]
    /// Composite-axis order. Display heights are nondecreasing; repeated
    /// ranges for one participant move forward without overlap, but may leave
    /// a gap when a nested ancestor is split around its child.
    let participantSegments: [ParticipantSegmentSnapshot]

    init(
        viewportHeight: CGFloat,
        displayScale: CGFloat,
        detents: [ScrollSourceScalar],
        participantOrder: [ParticipantID],
        participantSegments: [ParticipantSegmentSnapshot]
    ) {
        self.viewportHeight = viewportHeight
        self.displayScale = displayScale
        self.detents = detents
        self.participantOrder = participantOrder
        self.participantSegments = participantSegments
    }
}

// MARK: - Nested participant snapshots

/// Geometry for one scroll participant in a primary-to-ancestor chain.
///
/// `childFrame` is the immediate child's frame expressed in this participant's
/// content coordinate space. It is nil only for the primary participant.
struct NestedParticipantSnapshot: Equatable {
    let id: ParticipantID
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    let insetTop: CGFloat
    let insetBottom: CGFloat
    let contentOffset: CGFloat
    let childFrame: ClosedRange<CGFloat>?

    var minimumOffset: CGFloat { -insetTop }

    /// UIKit still permits a vertically bouncing participant when its content is shorter than its
    /// viewport (`alwaysBounceVertical == true`). The Objective-C engine represents that case as a
    /// zero-length inner segment, so the pure model clamps only the negative *length* to zero.
    var totalScrollableLength: CGFloat {
        max(0, insetTop + contentHeight + insetBottom - viewportHeight)
    }

    var maximumOffset: CGFloat {
        totalScrollableLength - insetTop
    }
}

enum ScrollModelError: Error, Equatable, CustomStringConvertible {
    case invalidViewportHeight(CGFloat)
    case invalidDisplayScale(CGFloat)
    case invalidDetent(CGFloat)
    case unorderedDetents
    case duplicateParticipantID(ParticipantID)
    case missingParticipant(ParticipantID)
    case invalidParticipantDisplayHeight(participant: ParticipantID, displayHeight: CGFloat)
    case invalidInnerRange(participant: ParticipantID, start: CGFloat, end: CGFloat)
    case unorderedParticipantSegments
    case unorderedParticipantInnerRanges(
        participant: ParticipantID,
        previousEnd: CGFloat,
        nextStart: CGFloat
    )
    case invalidNestedParticipant(ParticipantID)
    case missingChildFrame(ParticipantID)
    case invalidChildFrame(ParticipantID)
    case invalidNestedSplit(ParticipantID, CGFloat)
    case nonFiniteOuterGeometry
    case unorderedOuterSegments

    var description: String {
        switch self {
        case .invalidViewportHeight(let value):
            return "Invalid viewport height: \(value)"
        case .invalidDisplayScale(let value):
            return "Invalid display scale: \(value)"
        case .invalidDetent(let value):
            return "Invalid detent after source-number conversion: \(value)"
        case .unorderedDetents:
            return "Detents must be strictly increasing after source-number conversion"
        case .duplicateParticipantID(let id):
            return "Duplicate participant ID: \(id)"
        case .missingParticipant(let id):
            return "Segment owner is missing from participantOrder: \(id)"
        case .invalidParticipantDisplayHeight(let id, let displayHeight):
            return "Invalid participant display height for \(id): \(displayHeight)"
        case .invalidInnerRange(let id, let start, let end):
            return "Invalid inner range for \(id): \(start)...\(end)"
        case .unorderedParticipantSegments:
            return "Participant segments are not in composite-axis order"
        case .unorderedParticipantInnerRanges(let id, let previousEnd, let nextStart):
            return "Participant ranges for \(id) move backward or overlap: previous end \(previousEnd), next start \(nextStart)"
        case .invalidNestedParticipant(let id):
            return "Invalid nested participant geometry: \(id)"
        case .missingChildFrame(let id):
            return "Missing immediate-child frame for ancestor: \(id)"
        case .invalidChildFrame(let id):
            return "Invalid immediate-child frame for ancestor: \(id)"
        case .invalidNestedSplit(let id, let value):
            return "Invalid nested split for \(id): \(value)"
        case .nonFiniteOuterGeometry:
            return "Composite outer-axis arithmetic overflowed to a non-finite value"
        case .unorderedOuterSegments:
            return "Built outer segments are not ordered"
        }
    }
}

/// Pure translation of the source implementation's nested before/child/after
/// construction. The UIKit layer only has to provide coordinate snapshots.
enum NestedParticipantBuilder {
    static func makeSegments(
        chain: [NestedParticipantSnapshot],
        displayHeight: ScrollSourceScalar,
        comparison: ScrollComparisonPolicy
    ) throws -> [ParticipantSegmentSnapshot] {
        guard let primary = chain.first else { return [] }
        try validate(primary)

        var result = [try fullSegment(for: primary, displayHeight: displayHeight)]

        for ancestor in chain.dropFirst() {
            try validate(ancestor)
            guard let childFrame = ancestor.childFrame else {
                throw ScrollModelError.missingChildFrame(ancestor.id)
            }
            guard childFrame.lowerBound.isFinite,
                  childFrame.upperBound.isFinite,
                  childFrame.upperBound >= childFrame.lowerBound else {
                throw ScrollModelError.invalidChildFrame(ancestor.id)
            }

            let minimum = ancestor.minimumOffset
            let maximum = ancestor.maximumOffset
            let total = ancestor.totalScrollableLength
            let currentProgress = ancestor.contentOffset + ancestor.insetTop
            let band = comparison.boundaryBand

            enum Placement {
                case before
                case after
                case split(beforeEnd: CGFloat, afterStart: CGFloat)
            }

            let placement: Placement
            if currentProgress > band,
               ancestor.contentOffset + ancestor.viewportHeight >= childFrame.upperBound {
                // Keep both slices in the physical contentOffset coordinate space. The source used
                // `currentProgress` for the second start, which adds insetTop twice, creates a gap,
                // and can exceed maximumOffset near the bottom.
                if currentProgress >= total - band {
                    placement = .before
                } else {
                    placement = .split(
                        beforeEnd: ancestor.contentOffset,
                        afterStart: ancestor.contentOffset
                    )
                }
            } else if childFrame.lowerBound <= minimum + band {
                placement = .after
            } else if childFrame.upperBound >= ancestor.contentHeight + ancestor.insetBottom - band {
                placement = .before
            } else {
                let childHeight = childFrame.upperBound - childFrame.lowerBound
                let bottomExpansion = ancestor.contentHeight
                    + ancestor.insetBottom
                    - childFrame.upperBound
                let topExpansion = ancestor.viewportHeight - (bottomExpansion + childHeight)
                if topExpansion + band >= 0 {
                    placement = .before
                } else {
                    placement = .split(
                        beforeEnd: childFrame.lowerBound,
                        afterStart: childFrame.lowerBound
                    )
                }
            }

            switch placement {
            case .before:
                result.insert(
                    try segment(
                        id: ancestor.id,
                        displayHeight: displayHeight,
                        start: minimum,
                        end: maximum
                    ),
                    at: 0
                )
            case .after:
                result.append(
                    try segment(
                        id: ancestor.id,
                        displayHeight: displayHeight,
                        start: minimum,
                        end: maximum
                    )
                )
            case .split(let beforeEnd, let afterStart):
                guard beforeEnd >= minimum, beforeEnd <= maximum,
                      afterStart >= minimum, afterStart <= maximum else {
                    throw ScrollModelError.invalidNestedSplit(
                        ancestor.id,
                        beforeEnd < minimum || beforeEnd > maximum ? beforeEnd : afterStart
                    )
                }
                if beforeEnd > minimum {
                    result.insert(
                        try segment(
                            id: ancestor.id,
                            displayHeight: displayHeight,
                            start: minimum,
                            end: beforeEnd
                        ),
                        at: 0
                    )
                }
                if afterStart < maximum {
                    result.append(
                        try segment(
                            id: ancestor.id,
                            displayHeight: displayHeight,
                            start: afterStart,
                            end: maximum
                        )
                    )
                }
            }
        }

        return result
    }

    private static func validate(_ snapshot: NestedParticipantSnapshot) throws {
        guard snapshot.contentHeight.isFinite,
              snapshot.viewportHeight.isFinite,
              snapshot.insetTop.isFinite,
              snapshot.insetBottom.isFinite,
              snapshot.contentOffset.isFinite,
              snapshot.viewportHeight > 0,
              snapshot.totalScrollableLength >= 0 else {
            throw ScrollModelError.invalidNestedParticipant(snapshot.id)
        }
    }

    private static func fullSegment(
        for snapshot: NestedParticipantSnapshot,
        displayHeight: ScrollSourceScalar
    ) throws -> ParticipantSegmentSnapshot {
        try segment(
            id: snapshot.id,
            displayHeight: displayHeight,
            start: snapshot.minimumOffset,
            end: snapshot.maximumOffset
        )
    }

    private static func segment(
        id: ParticipantID,
        displayHeight: ScrollSourceScalar,
        start: CGFloat,
        end: CGFloat
    ) throws -> ParticipantSegmentSnapshot {
        // A zero-length participant segment is meaningful in the source: a
        // scroll view with no normal scrollable content can still participate
        // when `bounces && alwaysBounceVertical` is enabled. It remains a
        // drag-inner anchor even though it contributes no axis length.
        guard start.isFinite, end.isFinite, end >= start else {
            throw ScrollModelError.invalidInnerRange(participant: id, start: start, end: end)
        }
        return ParticipantSegmentSnapshot(
            participantID: id,
            displayHeight: displayHeight,
            innerStart: .native(start),
            innerEnd: .native(end)
        )
    }
}

// MARK: - Built model and projection

struct ScrollSegment: Equatable {
    let owner: SegmentOwner
    let displayHeight: CGFloat
    let outerStart: CGFloat
    let outerEnd: CGFloat
    let innerStart: CGFloat
    let innerEnd: CGFloat

    var outerLength: CGFloat { outerEnd - outerStart }
    var innerLength: CGFloat { innerEnd - innerStart }

    var participantID: ParticipantID? {
        guard case .participant(let id) = owner else { return nil }
        return id
    }

    var isParticipantSegment: Bool {
        participantID != nil
    }
}

struct ParticipantProjection: Equatable {
    let participantID: ParticipantID
    let contentOffset: CGFloat
}

struct Projection: Equatable {
    let outerOffset: CGFloat
    let panelTranslation: CGFloat
    let displayHeight: CGFloat
    let activeOwner: SegmentOwner
    /// Mirrors the source's `isinnersc = (exty > 0)` decision. In particular,
    /// merely being inside the one-pixel band of a zero-length drag-inner
    /// anchor does not mean participant content is actively scrolling.
    let isParticipantScrolling: Bool
    let participantOffsets: [ParticipantProjection]

    func offset(for participantID: ParticipantID) -> CGFloat? {
        participantOffsets.first(where: { $0.participantID == participantID })?.contentOffset
    }
}

struct ScrollModel: Equatable {
    let viewportHeight: CGFloat
    let comparison: ScrollComparisonPolicy
    let detentDisplayHeights: [CGFloat]
    let participantOrder: [ParticipantID]
    let segments: [ScrollSegment]

    var hasDetents: Bool { !detentDisplayHeights.isEmpty }

    func projection(at outerOffset: CGFloat) -> Projection {
        var offsets: [ParticipantID: CGFloat] = [:]
        var encounterOrder: [ParticipantID] = []

        // Establish each participant's initial offset once. A later segment
        // with the same owner must not overwrite a partially traversed earlier
        // segment.
        for segment in segments {
            guard let id = segment.participantID, offsets[id] == nil else { continue }
            offsets[id] = segment.innerStart
            encounterOrder.append(id)
        }

        var panelTranslation: CGFloat = 0
        var activeOwner: SegmentOwner = .panel
        var isParticipantScrolling = false

        var iterator = segments.lazy.filter(\.isParticipantSegment).makeIterator()
        var currentSegment = iterator.next()
        while let segment = currentSegment {
            // The OC loop gives the next inner segment ownership as soon as the
            // outer offset reaches its start, even when that point is also the
            // current segment's end. This is intentionally separate from the
            // one-pixel entry band below.
            let nextSegment = iterator.next()
            currentSegment = nextSegment

            guard let id = segment.participantID else { continue }
            if outerOffset + comparison.boundaryBand < segment.outerStart {
                break
            }

            if let nextSegment, outerOffset >= nextSegment.outerStart {
                offsets[id] = segment.innerEnd
                panelTranslation += segment.innerLength
                continue
            }

            let progress = outerOffset - segment.outerStart
            if progress > segment.innerLength {
                offsets[id] = segment.innerEnd
                panelTranslation += segment.innerLength
                continue
            }

            // Deliberately do not clamp a progress in [-onePixel, 0). The OC
            // source enters the segment using `offset + onePixel >= start` and
            // therefore preserves that narrow boundary behavior.
            offsets[id] = segment.innerStart + progress
            panelTranslation += progress
            activeOwner = segment.owner
            isParticipantScrolling = progress > 0
            break
        }

        var orderedIDs = participantOrder
        for id in encounterOrder where !orderedIDs.contains(id) {
            orderedIDs.append(id)
        }

        let participantOffsets = orderedIDs.compactMap { id -> ParticipantProjection? in
            guard let offset = offsets[id] else { return nil }
            return ParticipantProjection(participantID: id, contentOffset: offset)
        }

        return Projection(
            outerOffset: outerOffset,
            panelTranslation: panelTranslation,
            displayHeight: viewportHeight + outerOffset - panelTranslation,
            activeOwner: activeOwner,
            isParticipantScrolling: isParticipantScrolling,
            participantOffsets: participantOffsets
        )
    }
}

enum ScrollModelBuilder {
    static func build(from snapshot: ScrollModelSnapshot) throws -> ScrollModel {
        guard snapshot.viewportHeight.isFinite, snapshot.viewportHeight > 0 else {
            throw ScrollModelError.invalidViewportHeight(snapshot.viewportHeight)
        }
        guard snapshot.displayScale.isFinite, snapshot.displayScale > 0 else {
            throw ScrollModelError.invalidDisplayScale(snapshot.displayScale)
        }

        var seen = Set<ParticipantID>()
        for id in snapshot.participantOrder {
            guard seen.insert(id).inserted else {
                throw ScrollModelError.duplicateParticipantID(id)
            }
        }

        let comparison = ScrollComparisonPolicy(displayScale: snapshot.displayScale)

        // The UIKit boundary narrows public NSNumber-compatible values before
        // creating the snapshot. Validate the converted values themselves: a
        // finite CGFloat can overflow to infinity when represented as Float32.
        // Structural ordering is exact and must not use the physical-pixel
        // decision band used later for runtime branch selection.
        let detents = snapshot.detents.map(\.value)
        var previousDetent: CGFloat?
        for detent in detents {
            guard detent.isFinite else {
                throw ScrollModelError.invalidDetent(detent)
            }
            if let previousDetent, detent <= previousDetent {
                throw ScrollModelError.unorderedDetents
            }
            previousDetent = detent
        }

        var slices: [(id: ParticipantID, displayHeight: CGFloat, innerStart: CGFloat, innerEnd: CGFloat)] = []
        var previousDisplayHeight: CGFloat?
        var previousInnerEndByParticipant: [ParticipantID: CGFloat] = [:]
        for rawSegment in snapshot.participantSegments {
            guard seen.contains(rawSegment.participantID) else {
                throw ScrollModelError.missingParticipant(rawSegment.participantID)
            }
            let displayHeight = rawSegment.displayHeight.value
            let innerStart = rawSegment.innerStart.value
            let innerEnd = rawSegment.innerEnd.value
            guard displayHeight.isFinite else {
                throw ScrollModelError.invalidParticipantDisplayHeight(
                    participant: rawSegment.participantID,
                    displayHeight: displayHeight
                )
            }
            guard innerStart.isFinite,
                  innerEnd.isFinite,
                  innerEnd >= innerStart,
                  (innerEnd - innerStart).isFinite else {
                throw ScrollModelError.invalidInnerRange(
                    participant: rawSegment.participantID,
                    start: innerStart,
                    end: innerEnd
                )
            }
            if let previousDisplayHeight,
               displayHeight < previousDisplayHeight {
                throw ScrollModelError.unorderedParticipantSegments
            }
            if let previousInnerEnd = previousInnerEndByParticipant[rawSegment.participantID],
               innerStart < previousInnerEnd {
                throw ScrollModelError.unorderedParticipantInnerRanges(
                    participant: rawSegment.participantID,
                    previousEnd: previousInnerEnd,
                    nextStart: innerStart
                )
            }
            previousDisplayHeight = displayHeight
            previousInnerEndByParticipant[rawSegment.participantID] = innerEnd
            slices.append((rawSegment.participantID, displayHeight, innerStart, innerEnd))
        }

        var segments: [ScrollSegment] = []
        var detentIndex = 0
        var sliceIndex = 0
        var accumulatedParticipantDistance: CGFloat = 0

        while detentIndex < detents.count || sliceIndex < slices.count {
            let detent = detentIndex < detents.count ? detents[detentIndex] : nil
            let slice = sliceIndex < slices.count ? slices[sliceIndex] : nil

            if let detent, let slice {
                if slice.displayHeight < detent - comparison.boundaryBand {
                    try appendParticipant(
                        slice,
                        viewportHeight: snapshot.viewportHeight,
                        accumulatedDistance: &accumulatedParticipantDistance,
                        to: &segments
                    )
                    sliceIndex += 1
                } else if slice.displayHeight > detent + comparison.boundaryBand {
                    try appendPanel(
                        displayHeight: detent,
                        viewportHeight: snapshot.viewportHeight,
                        accumulatedDistance: accumulatedParticipantDistance,
                        to: &segments
                    )
                    detentIndex += 1
                } else {
                    // Equal display heights use the participant segment so its
                    // inner mapping is retained, matching the OC merge.
                    try appendParticipant(
                        slice,
                        viewportHeight: snapshot.viewportHeight,
                        accumulatedDistance: &accumulatedParticipantDistance,
                        to: &segments
                    )
                    detentIndex += 1
                    sliceIndex += 1
                }
            } else if let detent {
                try appendPanel(
                    displayHeight: detent,
                    viewportHeight: snapshot.viewportHeight,
                    accumulatedDistance: accumulatedParticipantDistance,
                    to: &segments
                )
                detentIndex += 1
            } else if let slice {
                try appendParticipant(
                    slice,
                    viewportHeight: snapshot.viewportHeight,
                    accumulatedDistance: &accumulatedParticipantDistance,
                    to: &segments
                )
                sliceIndex += 1
            }
        }

        for pair in zip(segments, segments.dropFirst()) {
            guard pair.1.outerStart >= pair.0.outerStart else {
                throw ScrollModelError.unorderedOuterSegments
            }
        }

        return ScrollModel(
            viewportHeight: snapshot.viewportHeight,
            comparison: comparison,
            detentDisplayHeights: detents,
            participantOrder: snapshot.participantOrder,
            segments: segments
        )
    }

    private static func appendPanel(
        displayHeight: CGFloat,
        viewportHeight: CGFloat,
        accumulatedDistance: CGFloat,
        to segments: inout [ScrollSegment]
    ) throws {
        let outerOffset = accumulatedDistance + displayHeight - viewportHeight
        guard outerOffset.isFinite else {
            throw ScrollModelError.nonFiniteOuterGeometry
        }
        segments.append(
            ScrollSegment(
                owner: .panel,
                displayHeight: displayHeight,
                outerStart: outerOffset,
                outerEnd: outerOffset,
                innerStart: 0,
                innerEnd: 0
            )
        )
    }

    private static func appendParticipant(
        _ slice: (id: ParticipantID, displayHeight: CGFloat, innerStart: CGFloat, innerEnd: CGFloat),
        viewportHeight: CGFloat,
        accumulatedDistance: inout CGFloat,
        to segments: inout [ScrollSegment]
    ) throws {
        let length = slice.innerEnd - slice.innerStart
        let outerStart = accumulatedDistance + slice.displayHeight - viewportHeight
        let outerEnd = outerStart + length
        let nextAccumulatedDistance = accumulatedDistance + length
        guard outerStart.isFinite,
              outerEnd.isFinite,
              nextAccumulatedDistance.isFinite else {
            throw ScrollModelError.nonFiniteOuterGeometry
        }
        segments.append(
            ScrollSegment(
                owner: .participant(slice.id),
                displayHeight: slice.displayHeight,
                outerStart: outerStart,
                outerEnd: outerEnd,
                innerStart: slice.innerStart,
                innerEnd: slice.innerEnd
            )
        )
        accumulatedDistance = nextAccumulatedDistance
    }
}
