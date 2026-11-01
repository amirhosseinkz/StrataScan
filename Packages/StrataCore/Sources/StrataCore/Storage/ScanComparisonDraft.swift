import Foundation

/// A user-selected before/after scan pair. It records intent only: no
/// alignment, coverage, boundary, or change result is implied by this draft.
public struct ScanComparisonDraft: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var baselineScanID: UUID
    public var comparisonScanID: UUID
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        baselineScanID: UUID,
        comparisonScanID: UUID,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.baselineScanID = baselineScanID
        self.comparisonScanID = comparisonScanID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        guard baselineScanID != comparisonScanID else {
            throw ScanComparisonDraftError.sameScan
        }
    }
}

public enum ScanComparisonDraftError: Error, Equatable, Sendable {
    case sameScan
}

public enum ScanComparisonDraftStoreError: Error, Equatable, Sendable {
    case scanNotFound(UUID)
    case draftNotFound(UUID)
    case workAreaReferenceDoesNotMatchBaseline
}

/// A finite work area in the baseline scan's AR-world coordinates. It is an
/// input to later alignment and coverage checks, never a calculated change.
public struct ScanComparisonWorkArea: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var draftID: UUID
    public var referenceScanID: UUID
    public var minimum: Point3D
    public var maximum: Point3D
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        draftID: UUID,
        referenceScanID: UUID,
        minimum: Point3D,
        maximum: Point3D,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.draftID = draftID
        self.referenceScanID = referenceScanID
        self.minimum = minimum
        self.maximum = maximum
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Makes a conservative first work area from the baseline's actual mesh
    /// extent. Flat or empty geometry is rejected instead of fabricating depth.
    public static func fromBaselineMesh(
        draftID: UUID,
        referenceScanID: UUID,
        snapshots: [MeshSnapshot],
        createdAt: Date = .now
    ) throws -> ScanComparisonWorkArea {
        let vertices = snapshots.flatMap(\.worldVertices)
        guard let first = vertices.first else {
            throw ScanComparisonWorkAreaError.emptyGeometry
        }
        guard vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw ScanComparisonWorkAreaError.nonFiniteGeometry
        }
        let bounds = vertices.dropFirst().reduce((minimum: first, maximum: first)) { bounds, vertex in
            (
                minimum: Point3D(
                    x: min(bounds.minimum.x, vertex.x),
                    y: min(bounds.minimum.y, vertex.y),
                    z: min(bounds.minimum.z, vertex.z)
                ),
                maximum: Point3D(
                    x: max(bounds.maximum.x, vertex.x),
                    y: max(bounds.maximum.y, vertex.y),
                    z: max(bounds.maximum.z, vertex.z)
                )
            )
        }
        let area = ScanComparisonWorkArea(
            draftID: draftID,
            referenceScanID: referenceScanID,
            minimum: bounds.minimum,
            maximum: bounds.maximum,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try area.validate()
        return area
    }

    /// Creates an axis-aligned work area from two operator-selected, opposite
    /// points on the baseline mesh. The selection is persisted separately from
    /// source geometry and is deliberately not a surface-change result.
    public static func fromOppositeCorners(
        id: UUID = UUID(),
        draftID: UUID,
        referenceScanID: UUID,
        first: Point3D,
        second: Point3D,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) throws -> ScanComparisonWorkArea {
        let area = ScanComparisonWorkArea(
            id: id,
            draftID: draftID,
            referenceScanID: referenceScanID,
            minimum: Point3D(
                x: min(first.x, second.x),
                y: min(first.y, second.y),
                z: min(first.z, second.z)
            ),
            maximum: Point3D(
                x: max(first.x, second.x),
                y: max(first.y, second.y),
                z: max(first.z, second.z)
            ),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        try area.validate()
        return area
    }

    public func validate() throws {
        guard
            minimum.x.isFinite, minimum.y.isFinite, minimum.z.isFinite,
            maximum.x.isFinite, maximum.y.isFinite, maximum.z.isFinite
        else {
            throw ScanComparisonWorkAreaError.nonFiniteGeometry
        }
        guard minimum.x < maximum.x, minimum.y < maximum.y, minimum.z < maximum.z else {
            throw ScanComparisonWorkAreaError.degenerateGeometry
        }
    }
}

public enum ScanComparisonWorkAreaError: Error, Equatable, Sendable {
    case emptyGeometry
    case nonFiniteGeometry
    case degenerateGeometry
}

/// A bounded, geometry-only check of whether an aligned comparison mesh has
/// observed support throughout a saved work area. This is not a surface-change
/// result and never infers volume, material, or unseen geometry.
public struct ScanComparisonCoverageReport: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case supported
        case insufficient
    }

    public var status: Status
    public var sampledComparisonVertexCount: Int
    public var inWorkAreaVertexCount: Int
    public var axisSpanFractions: SIMD3<Float>

    public init(
        status: Status,
        sampledComparisonVertexCount: Int,
        inWorkAreaVertexCount: Int,
        axisSpanFractions: SIMD3<Float>
    ) {
        self.status = status
        self.sampledComparisonVertexCount = sampledComparisonVertexCount
        self.inWorkAreaVertexCount = inWorkAreaVertexCount
        self.axisSpanFractions = axisSpanFractions
    }
}

public enum ScanComparisonCoverageError: Error, Equatable, Sendable {
    case workAreaDoesNotMatchAlignmentTarget
    case invalidComparisonGeometry
}

/// Uses only sampled vertices that were actually captured in the comparison
/// mesh. The explicit alignment maps those points into the baseline work-area
/// frame before any coverage observation is made.
public struct ScanComparisonWorkAreaCoverageEvaluator: Sendable {
    private static let maximumSampleCount = 8_192
    private static let minimumInWorkAreaVertices = 64
    private static let minimumAxisSpanFraction: Float = 0.60

    public init() {}

    public func evaluate(
        workArea: ScanComparisonWorkArea,
        alignment: ScanAlignment,
        comparisonSnapshots: [MeshSnapshot]
    ) throws -> ScanComparisonCoverageReport {
        guard workArea.referenceScanID == alignment.targetScanID else {
            throw ScanComparisonCoverageError.workAreaDoesNotMatchAlignmentTarget
        }
        let sourceVertices = comparisonSnapshots.flatMap(\.worldVertices)
        guard sourceVertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw ScanComparisonCoverageError.invalidComparisonGeometry
        }
        guard !sourceVertices.isEmpty else {
            return ScanComparisonCoverageReport(
                status: .insufficient,
                sampledComparisonVertexCount: 0,
                inWorkAreaVertexCount: 0,
                axisSpanFractions: .zero
            )
        }

        let stride = max(1, sourceVertices.count / Self.maximumSampleCount)
        let sampled = sourceVertices.enumerated().compactMap { index, point in
            index.isMultiple(of: stride) ? alignment.targetFromSource.applying(to: point) : nil
        }
        let margin = coverageMargin(for: workArea)
        let observed = sampled.filter { contains($0, in: workArea, margin: margin) }
        let spans = axisSpanFractions(for: observed, workArea: workArea)
        let isSupported = observed.count >= Self.minimumInWorkAreaVertices
            && spans.x >= Self.minimumAxisSpanFraction
            && spans.y >= Self.minimumAxisSpanFraction
            && spans.z >= Self.minimumAxisSpanFraction
        return ScanComparisonCoverageReport(
            status: isSupported ? .supported : .insufficient,
            sampledComparisonVertexCount: sampled.count,
            inWorkAreaVertexCount: observed.count,
            axisSpanFractions: spans
        )
    }

    private func coverageMargin(for workArea: ScanComparisonWorkArea) -> Float {
        let extent = SIMD3<Float>(
            workArea.maximum.x - workArea.minimum.x,
            workArea.maximum.y - workArea.minimum.y,
            workArea.maximum.z - workArea.minimum.z
        )
        return min(max(max(extent.x, extent.y, extent.z) * 0.02, 0.03), 0.15)
    }

    private func contains(_ point: Point3D, in workArea: ScanComparisonWorkArea, margin: Float) -> Bool {
        point.x >= workArea.minimum.x - margin && point.x <= workArea.maximum.x + margin
            && point.y >= workArea.minimum.y - margin && point.y <= workArea.maximum.y + margin
            && point.z >= workArea.minimum.z - margin && point.z <= workArea.maximum.z + margin
    }

    private func axisSpanFractions(
        for points: [Point3D],
        workArea: ScanComparisonWorkArea
    ) -> SIMD3<Float> {
        guard let first = points.first else { return .zero }
        let bounds = points.dropFirst().reduce((minimum: first, maximum: first)) { bounds, point in
            (
                minimum: Point3D(
                    x: min(bounds.minimum.x, point.x),
                    y: min(bounds.minimum.y, point.y),
                    z: min(bounds.minimum.z, point.z)
                ),
                maximum: Point3D(
                    x: max(bounds.maximum.x, point.x),
                    y: max(bounds.maximum.y, point.y),
                    z: max(bounds.maximum.z, point.z)
                )
            )
        }
        let extent = SIMD3<Float>(
            workArea.maximum.x - workArea.minimum.x,
            workArea.maximum.y - workArea.minimum.y,
            workArea.maximum.z - workArea.minimum.z
        )
        let observedExtent = SIMD3<Float>(
            bounds.maximum.x - bounds.minimum.x,
            bounds.maximum.y - bounds.minimum.y,
            bounds.maximum.z - bounds.minimum.z
        )
        return SIMD3<Float>(
            min(max(observedExtent.x / extent.x, 0), 1),
            min(max(observedExtent.y / extent.y, 0), 1),
            min(max(observedExtent.z / extent.z, 0), 1)
        )
    }
}

/// Prepares only observed mesh geometry that lies wholly within a saved work
/// area. The optional transform maps source scan geometry into the work area's
/// baseline frame. Triangles intersecting the boundary are omitted rather than
/// being cut or inferred, so this remains a conservative visual-inspection
/// input rather than a surface reconstruction.
public struct ScanComparisonWorkAreaMeshClipper: Sendable {
    public init() {}

    public func clip(
        snapshots: [MeshSnapshot],
        to workArea: ScanComparisonWorkArea,
        applying transform: Transform4x4 = .identity
    ) throws -> [MeshSnapshot] {
        try snapshots.compactMap { snapshot -> MeshSnapshot? in
            let transformedVertices = snapshot.worldVertices.map(transform.applying)
            guard transformedVertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
                throw ScanComparisonCoverageError.invalidComparisonGeometry
            }
            let includedIndices = Set(
                transformedVertices.indices.filter { contains(transformedVertices[$0], in: workArea) }
            )
            guard !includedIndices.isEmpty else { return nil }

            let includedFaces = snapshot.faces.filter { face in
                face.indices.allSatisfy(includedIndices.contains)
            }
            let retainedIndices: [Int]
            if includedFaces.isEmpty {
                retainedIndices = includedIndices.sorted()
            } else {
                retainedIndices = Array(Set(includedFaces.flatMap(\.indices))).sorted()
            }
            let indexMap = Dictionary(uniqueKeysWithValues: retainedIndices.enumerated().map { ($0.element, $0.offset) })
            let vertices = retainedIndices.map { transformedVertices[$0] }
            let faces = includedFaces.compactMap { face -> MeshFace? in
                guard let first = indexMap[face.indices[0]],
                      let second = indexMap[face.indices[1]],
                      let third = indexMap[face.indices[2]]
                else {
                    return nil
                }
                return MeshFace(indices: (first, second, third))
            }
            return try MeshSnapshot(
                anchorID: snapshot.anchorID,
                worldFromAnchor: .identity,
                vertices: vertices,
                normals: [],
                faces: faces
            )
        }
    }

    private func contains(_ point: Point3D, in workArea: ScanComparisonWorkArea) -> Bool {
        point.x >= workArea.minimum.x && point.x <= workArea.maximum.x
            && point.y >= workArea.minimum.y && point.y <= workArea.maximum.y
            && point.z >= workArea.minimum.z && point.z <= workArea.maximum.z
    }
}

/// A direction relative to an observed baseline surface normal. These labels
/// are intentionally geometric: they do not claim material type, removal, or
/// a measured quantity.
public enum ObservedSurfaceDifferenceClass: Equatable, Sendable {
    case coincident
    case towardBaselineNormal
    case againstBaselineNormal
}

public struct ObservedSurfaceDifferenceObservation: Equatable, Sendable {
    public var point: Point3D
    public var classification: ObservedSurfaceDifferenceClass

    public init(point: Point3D, classification: ObservedSurfaceDifferenceClass) {
        self.point = point
        self.classification = classification
    }
}

/// A bounded collection of locally supported comparison observations. Any
/// comparison point without a nearby, normal-consistent baseline vertex is
/// deliberately omitted rather than represented as a change.
public struct ScanComparisonSurfaceDifferencePreview: Equatable, Sendable {
    public var observations: [ObservedSurfaceDifferenceObservation]
    public var unclassifiedComparisonVertexCount: Int

    public init(
        observations: [ObservedSurfaceDifferenceObservation],
        unclassifiedComparisonVertexCount: Int
    ) {
        self.observations = observations
        self.unclassifiedComparisonVertexCount = unclassifiedComparisonVertexCount
    }
}

/// Produces a conservative, read-only preview from observed local surface
/// correspondences. It is not a signed-distance field, surface reconstruction,
/// volume calculation, or a completeness claim.
public struct ScanComparisonSurfaceDifferenceEvaluator: Sendable {
    private static let maximumBaselineSamples = 16_384
    private static let maximumComparisonSamples = 16_384
    private static let cellSize: Float = 0.15
    private static let maximumCorrespondenceDistance: Float = 0.15
    private static let maximumTangentialDistance: Float = 0.05
    private static let coincidenceThreshold: Float = 0.025

    public init() {}

    public func evaluate(
        baselineSnapshots: [MeshSnapshot],
        comparisonSnapshots: [MeshSnapshot],
        workArea: ScanComparisonWorkArea,
        targetFromSource: Transform4x4
    ) throws -> ScanComparisonSurfaceDifferencePreview {
        let baselineSamples = try baselineSamples(from: baselineSnapshots, in: workArea)
        guard !baselineSamples.isEmpty else {
            return ScanComparisonSurfaceDifferencePreview(observations: [], unclassifiedComparisonVertexCount: 0)
        }
        let index = spatialIndex(from: baselineSamples)
        let comparisonPoints = try comparisonPoints(
            from: comparisonSnapshots,
            in: workArea,
            applying: targetFromSource
        )
        var observations: [ObservedSurfaceDifferenceObservation] = []
        observations.reserveCapacity(comparisonPoints.count)
        var unclassifiedCount = 0

        for point in comparisonPoints {
            guard let nearest = nearestSample(to: point, in: index) else {
                unclassifiedCount += 1
                continue
            }
            let offset = subtract(point, nearest.point)
            let squaredDistance = dot(offset, offset)
            guard squaredDistance <= Self.maximumCorrespondenceDistance * Self.maximumCorrespondenceDistance else {
                unclassifiedCount += 1
                continue
            }
            let signedOffset = dot(offset, nearest.normal)
            let tangentialSquared = max(squaredDistance - signedOffset * signedOffset, 0)
            guard tangentialSquared <= Self.maximumTangentialDistance * Self.maximumTangentialDistance else {
                unclassifiedCount += 1
                continue
            }
            let classification: ObservedSurfaceDifferenceClass
            if abs(signedOffset) <= Self.coincidenceThreshold {
                classification = .coincident
            } else if signedOffset > 0 {
                classification = .towardBaselineNormal
            } else {
                classification = .againstBaselineNormal
            }
            observations.append(
                ObservedSurfaceDifferenceObservation(point: point, classification: classification)
            )
        }
        return ScanComparisonSurfaceDifferencePreview(
            observations: observations,
            unclassifiedComparisonVertexCount: unclassifiedCount
        )
    }

    private func baselineSamples(
        from snapshots: [MeshSnapshot],
        in workArea: ScanComparisonWorkArea
    ) throws -> [BaselineSample] {
        let vertexCount = snapshots.reduce(0) { $0 + $1.vertices.count }
        let stride = max(1, vertexCount / Self.maximumBaselineSamples)
        var samples: [BaselineSample] = []
        var ordinal = 0
        for snapshot in snapshots where snapshot.normals.count == snapshot.vertices.count {
            for (index, vertex) in snapshot.vertices.enumerated() {
                defer { ordinal += 1 }
                guard ordinal.isMultiple(of: stride) else { continue }
                let point = snapshot.worldFromAnchor.applying(to: vertex)
                let normalEndpoint = snapshot.worldFromAnchor.applying(
                    to: Point3D(
                        x: vertex.x + snapshot.normals[index].x,
                        y: vertex.y + snapshot.normals[index].y,
                        z: vertex.z + snapshot.normals[index].z
                    )
                )
                guard isFinite(point), isFinite(normalEndpoint), contains(point, in: workArea),
                      let normal = normalized(subtract(normalEndpoint, point))
                else {
                    continue
                }
                samples.append(BaselineSample(point: point, normal: normal))
            }
        }
        return samples
    }

    private func comparisonPoints(
        from snapshots: [MeshSnapshot],
        in workArea: ScanComparisonWorkArea,
        applying transform: Transform4x4
    ) throws -> [Point3D] {
        let vertexCount = snapshots.reduce(0) { $0 + $1.vertices.count }
        let stride = max(1, vertexCount / Self.maximumComparisonSamples)
        var points: [Point3D] = []
        var ordinal = 0
        for snapshot in snapshots {
            for vertex in snapshot.vertices {
                defer { ordinal += 1 }
                guard ordinal.isMultiple(of: stride) else { continue }
                let point = transform.applying(to: snapshot.worldFromAnchor.applying(to: vertex))
                guard isFinite(point) else {
                    throw ScanComparisonCoverageError.invalidComparisonGeometry
                }
                guard contains(point, in: workArea) else { continue }
                points.append(point)
            }
        }
        return points
    }

    private func spatialIndex(from samples: [BaselineSample]) -> [VoxelKey: [BaselineSample]] {
        var index: [VoxelKey: [BaselineSample]] = [:]
        for sample in samples {
            index[key(for: sample.point), default: []].append(sample)
        }
        return index
    }

    private func nearestSample(
        to point: Point3D,
        in index: [VoxelKey: [BaselineSample]]
    ) -> BaselineSample? {
        let center = key(for: point)
        var nearest: BaselineSample?
        var nearestDistanceSquared = Float.greatestFiniteMagnitude
        for x in (center.x - 1)...(center.x + 1) {
            for y in (center.y - 1)...(center.y + 1) {
                for z in (center.z - 1)...(center.z + 1) {
                    for candidate in index[VoxelKey(x: x, y: y, z: z), default: []] {
                        let offset = subtract(point, candidate.point)
                        let distanceSquared = dot(offset, offset)
                        if distanceSquared < nearestDistanceSquared {
                            nearest = candidate
                            nearestDistanceSquared = distanceSquared
                        }
                    }
                }
            }
        }
        return nearest
    }

    private func key(for point: Point3D) -> VoxelKey {
        VoxelKey(
            x: Int(floor(point.x / Self.cellSize)),
            y: Int(floor(point.y / Self.cellSize)),
            z: Int(floor(point.z / Self.cellSize))
        )
    }

    private func contains(_ point: Point3D, in workArea: ScanComparisonWorkArea) -> Bool {
        point.x >= workArea.minimum.x && point.x <= workArea.maximum.x
            && point.y >= workArea.minimum.y && point.y <= workArea.maximum.y
            && point.z >= workArea.minimum.z && point.z <= workArea.maximum.z
    }

    private func isFinite(_ point: Point3D) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }

    private func normalized(_ point: Point3D) -> Point3D? {
        let lengthSquared = dot(point, point)
        guard lengthSquared.isFinite, lengthSquared > Float.ulpOfOne else { return nil }
        let inverseLength = 1 / sqrt(lengthSquared)
        return Point3D(x: point.x * inverseLength, y: point.y * inverseLength, z: point.z * inverseLength)
    }

    private func subtract(_ lhs: Point3D, _ rhs: Point3D) -> Point3D {
        Point3D(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    private func dot(_ lhs: Point3D, _ rhs: Point3D) -> Float {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private struct BaselineSample: Sendable {
        let point: Point3D
        let normal: Point3D
    }

    private struct VoxelKey: Hashable, Sendable {
        let x: Int
        let y: Int
        let z: Int
    }
}

/// Read-only evidence quality for deciding whether landmark alignment is safe
/// enough to support a local surface-difference preview. It deliberately does
/// not certify registration or alter the persisted alignment.
public struct ScanComparisonAlignmentQualityReport: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case supported
        case landmarkSpreadInsufficient
        case landmarkDistributionDegenerate
        case residualTooHigh
    }

    public var status: Status
    public var landmarkCount: Int
    public var rmsErrorMeters: Float
    public var requiredLandmarkSpanMeters: Float
    public var targetLandmarkSpanMeters: Float
    public var sourceLandmarkSpanMeters: Float

    public init(
        status: Status,
        landmarkCount: Int,
        rmsErrorMeters: Float,
        requiredLandmarkSpanMeters: Float,
        targetLandmarkSpanMeters: Float,
        sourceLandmarkSpanMeters: Float
    ) {
        self.status = status
        self.landmarkCount = landmarkCount
        self.rmsErrorMeters = rmsErrorMeters
        self.requiredLandmarkSpanMeters = requiredLandmarkSpanMeters
        self.targetLandmarkSpanMeters = targetLandmarkSpanMeters
        self.sourceLandmarkSpanMeters = sourceLandmarkSpanMeters
    }
}

public enum ScanComparisonAlignmentQualityError: Error, Equatable, Sendable {
    case workAreaDoesNotMatchAlignmentTarget
    case landmarkEvidenceDoesNotMatchAlignment
}

/// Evaluates only saved operator-selected landmark evidence. The limits are a
/// conservative preview gate, not a survey accuracy certification: landmarks
/// must span enough of the work area, form a non-linear arrangement, and have
/// a residual comfortably below the local correspondence distance.
public struct ScanComparisonAlignmentQualityEvaluator: Sendable {
    private static let minimumAbsoluteLandmarkSpanMeters: Float = 0.30
    private static let maximumRequiredLandmarkSpanMeters: Float = 1.50
    private static let workAreaSpanFraction: Float = 0.15
    private static let minimumTriangleQuality: Float = 0.12
    private static let minimumResidualLimitMeters: Float = 0.025
    private static let maximumResidualLimitMeters: Float = 0.075
    private static let workAreaResidualFraction: Float = 0.015

    public init() {}

    public func evaluate(
        landmarks: ScanAlignmentLandmarkSet,
        alignment: ScanAlignment,
        workArea: ScanComparisonWorkArea
    ) throws -> ScanComparisonAlignmentQualityReport {
        try landmarks.validate()
        guard workArea.referenceScanID == alignment.targetScanID else {
            throw ScanComparisonAlignmentQualityError.workAreaDoesNotMatchAlignmentTarget
        }
        guard
            landmarks.targetScanID == alignment.targetScanID,
            landmarks.sourceScanID == alignment.sourceScanID
        else {
            throw ScanComparisonAlignmentQualityError.landmarkEvidenceDoesNotMatchAlignment
        }

        let workAreaDiagonal = length(
            Point3D(
                x: workArea.maximum.x - workArea.minimum.x,
                y: workArea.maximum.y - workArea.minimum.y,
                z: workArea.maximum.z - workArea.minimum.z
            )
        )
        let requiredSpan = min(
            max(Self.minimumAbsoluteLandmarkSpanMeters, workAreaDiagonal * Self.workAreaSpanFraction),
            Self.maximumRequiredLandmarkSpanMeters
        )
        let targetSpan = maximumPairwiseDistance(in: landmarks.targetLandmarks)
        let sourceSpan = maximumPairwiseDistance(in: landmarks.sourceLandmarks)
        let residualLimit = min(
            max(Self.minimumResidualLimitMeters, workAreaDiagonal * Self.workAreaResidualFraction),
            Self.maximumResidualLimitMeters
        )
        let status: ScanComparisonAlignmentQualityReport.Status
        if targetSpan < requiredSpan || sourceSpan < requiredSpan {
            status = .landmarkSpreadInsufficient
        } else if maximumTriangleQuality(in: landmarks.targetLandmarks) < Self.minimumTriangleQuality
                    || maximumTriangleQuality(in: landmarks.sourceLandmarks) < Self.minimumTriangleQuality {
            status = .landmarkDistributionDegenerate
        } else if landmarks.rmsErrorMeters > residualLimit {
            status = .residualTooHigh
        } else {
            status = .supported
        }
        return ScanComparisonAlignmentQualityReport(
            status: status,
            landmarkCount: landmarks.targetLandmarks.count,
            rmsErrorMeters: landmarks.rmsErrorMeters,
            requiredLandmarkSpanMeters: requiredSpan,
            targetLandmarkSpanMeters: targetSpan,
            sourceLandmarkSpanMeters: sourceSpan
        )
    }

    private func maximumPairwiseDistance(in points: [Point3D]) -> Float {
        var maximumSquaredDistance: Float = 0
        for firstIndex in points.indices {
            for secondIndex in points.indices where secondIndex > firstIndex {
                maximumSquaredDistance = max(
                    maximumSquaredDistance,
                    squaredLength(subtract(points[firstIndex], points[secondIndex]))
                )
            }
        }
        return sqrt(maximumSquaredDistance)
    }

    private func maximumTriangleQuality(in points: [Point3D]) -> Float {
        var maximumQuality: Float = 0
        for firstIndex in points.indices {
            for secondIndex in points.indices where secondIndex > firstIndex {
                for thirdIndex in points.indices where thirdIndex > secondIndex {
                    let firstEdge = subtract(points[secondIndex], points[firstIndex])
                    let secondEdge = subtract(points[thirdIndex], points[firstIndex])
                    let areaTwice = length(cross(firstEdge, secondEdge))
                    let longestEdgeSquared = max(
                        squaredLength(firstEdge),
                        squaredLength(secondEdge),
                        squaredLength(subtract(points[thirdIndex], points[secondIndex]))
                    )
                    guard longestEdgeSquared > Float.ulpOfOne else { continue }
                    maximumQuality = max(maximumQuality, areaTwice / longestEdgeSquared)
                }
            }
        }
        return maximumQuality
    }

    private func subtract(_ lhs: Point3D, _ rhs: Point3D) -> Point3D {
        Point3D(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    private func squaredLength(_ point: Point3D) -> Float {
        point.x * point.x + point.y * point.y + point.z * point.z
    }

    private func length(_ point: Point3D) -> Float {
        sqrt(squaredLength(point))
    }

    private func cross(_ lhs: Point3D, _ rhs: Point3D) -> Point3D {
        Point3D(
            x: lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.z * rhs.x - lhs.x * rhs.z,
            z: lhs.x * rhs.y - lhs.y * rhs.x
        )
    }
}
