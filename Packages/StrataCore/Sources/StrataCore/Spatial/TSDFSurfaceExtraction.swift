import CryptoKit
import Foundation

public enum TSDFSurfaceExtractionError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidBounds
    case invalidWritableLocation
    case snapshotMismatch
    case invalidStagingArtifact(String)
    case promotionConflict
    case ioFailure(String)
}

public struct TSDFSurfaceBounds: Codable, Equatable, Sendable {
    public var minimum: Point3D
    public var maximum: Point3D

    public init(minimum: Point3D, maximum: Point3D) throws {
        guard Self.isFinite(minimum),
              Self.isFinite(maximum),
              minimum.x <= maximum.x,
              minimum.y <= maximum.y,
              minimum.z <= maximum.z
        else {
            throw TSDFSurfaceExtractionError.invalidBounds
        }
        self.minimum = minimum
        self.maximum = maximum
    }

    fileprivate func contains(_ point: Point3D, tolerance: Float) -> Bool {
        point.x >= minimum.x - tolerance && point.x <= maximum.x + tolerance
            && point.y >= minimum.y - tolerance && point.y <= maximum.y + tolerance
            && point.z >= minimum.z - tolerance && point.z <= maximum.z + tolerance
    }

    fileprivate static func isFinite(_ point: Point3D) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }
}

public struct TSDFSurfaceExtractionConfiguration: Codable, Equatable, Sendable {
    public static let `default` = TSDFSurfaceExtractionConfiguration(
        uncheckedMinimumVoxelWeight: 1,
        uncheckedMinimumDistinctFrameCount: 1,
        minimumTriangleAreaSquareMeters: 0.000_000_01,
        minimumNormalLength: 0.000_01,
        minimumDominantComponentTriangleRatio: 0.5,
        canonicalBoundsToleranceMeters: 0.25,
        maximumSubmaps: 10_000,
        maximumVerticesPerSubmap: 250_000,
        maximumTrianglesPerSubmap: 500_000,
        maximumPromotedVertices: 1_000_000,
        maximumPromotedTriangles: 2_000_000
    )

    /// Product reconstruction requires two independently accepted frames for
    /// every extracted cell; `.default` remains replay-compatible with earlier
    /// derived workspaces and focused fixtures.
    public static let productionEvidenceQualified = TSDFSurfaceExtractionConfiguration(
        uncheckedMinimumVoxelWeight: 1,
        uncheckedMinimumDistinctFrameCount: 2,
        minimumTriangleAreaSquareMeters: 0.000_000_01,
        minimumNormalLength: 0.000_01,
        minimumDominantComponentTriangleRatio: 0.5,
        canonicalBoundsToleranceMeters: 0.25,
        maximumSubmaps: 10_000,
        maximumVerticesPerSubmap: 250_000,
        maximumTrianglesPerSubmap: 500_000,
        maximumPromotedVertices: 1_000_000,
        maximumPromotedTriangles: 2_000_000
    )

    public var minimumVoxelWeight: Float
    /// A surface needs independent viewpoints, not repeated samples from one
    /// pose. This is evaluated from the per-frame TSDF deltas.
    public var minimumDistinctFrameCount: Int
    public var minimumTriangleAreaSquareMeters: Float
    public var minimumNormalLength: Float
    public var minimumDominantComponentTriangleRatio: Float
    public var canonicalBoundsToleranceMeters: Float
    public var maximumSubmaps: Int
    public var maximumVerticesPerSubmap: Int
    public var maximumTrianglesPerSubmap: Int
    public var maximumPromotedVertices: Int
    public var maximumPromotedTriangles: Int

    public init(
        minimumVoxelWeight: Float = 1,
        minimumDistinctFrameCount: Int = 1,
        minimumTriangleAreaSquareMeters: Float = 0.000_000_01,
        minimumNormalLength: Float = 0.000_01,
        minimumDominantComponentTriangleRatio: Float = 0.5,
        canonicalBoundsToleranceMeters: Float = 0.25,
        maximumSubmaps: Int = 10_000,
        maximumVerticesPerSubmap: Int = 250_000,
        maximumTrianglesPerSubmap: Int = 500_000,
        maximumPromotedVertices: Int = 1_000_000,
        maximumPromotedTriangles: Int = 2_000_000
    ) throws {
        guard minimumVoxelWeight.isFinite,
              minimumVoxelWeight > 0,
              minimumDistinctFrameCount >= 1,
              minimumTriangleAreaSquareMeters.isFinite,
              minimumTriangleAreaSquareMeters > 0,
              minimumNormalLength.isFinite,
              minimumNormalLength > 0,
              minimumDominantComponentTriangleRatio.isFinite,
              (0...1).contains(minimumDominantComponentTriangleRatio),
              canonicalBoundsToleranceMeters.isFinite,
              canonicalBoundsToleranceMeters >= 0,
              (1...100_000).contains(maximumSubmaps),
              (3...10_000_000).contains(maximumVerticesPerSubmap),
              (1...20_000_000).contains(maximumTrianglesPerSubmap),
              (3...10_000_000).contains(maximumPromotedVertices),
              (1...20_000_000).contains(maximumPromotedTriangles)
        else {
            throw TSDFSurfaceExtractionError.invalidConfiguration
        }
        self.minimumVoxelWeight = minimumVoxelWeight
        self.minimumDistinctFrameCount = minimumDistinctFrameCount
        self.minimumTriangleAreaSquareMeters = minimumTriangleAreaSquareMeters
        self.minimumNormalLength = minimumNormalLength
        self.minimumDominantComponentTriangleRatio = minimumDominantComponentTriangleRatio
        self.canonicalBoundsToleranceMeters = canonicalBoundsToleranceMeters
        self.maximumSubmaps = maximumSubmaps
        self.maximumVerticesPerSubmap = maximumVerticesPerSubmap
        self.maximumTrianglesPerSubmap = maximumTrianglesPerSubmap
        self.maximumPromotedVertices = maximumPromotedVertices
        self.maximumPromotedTriangles = maximumPromotedTriangles
    }

    private init(
        uncheckedMinimumVoxelWeight minimumVoxelWeight: Float,
        uncheckedMinimumDistinctFrameCount minimumDistinctFrameCount: Int,
        minimumTriangleAreaSquareMeters: Float,
        minimumNormalLength: Float,
        minimumDominantComponentTriangleRatio: Float,
        canonicalBoundsToleranceMeters: Float,
        maximumSubmaps: Int,
        maximumVerticesPerSubmap: Int,
        maximumTrianglesPerSubmap: Int,
        maximumPromotedVertices: Int,
        maximumPromotedTriangles: Int
    ) {
        self.minimumVoxelWeight = minimumVoxelWeight
        self.minimumDistinctFrameCount = minimumDistinctFrameCount
        self.minimumTriangleAreaSquareMeters = minimumTriangleAreaSquareMeters
        self.minimumNormalLength = minimumNormalLength
        self.minimumDominantComponentTriangleRatio = minimumDominantComponentTriangleRatio
        self.canonicalBoundsToleranceMeters = canonicalBoundsToleranceMeters
        self.maximumSubmaps = maximumSubmaps
        self.maximumVerticesPerSubmap = maximumVerticesPerSubmap
        self.maximumTrianglesPerSubmap = maximumTrianglesPerSubmap
        self.maximumPromotedVertices = maximumPromotedVertices
        self.maximumPromotedTriangles = maximumPromotedTriangles
    }

    private enum CodingKeys: String, CodingKey {
        case minimumVoxelWeight
        case minimumDistinctFrameCount
        case minimumTriangleAreaSquareMeters
        case minimumNormalLength
        case minimumDominantComponentTriangleRatio
        case canonicalBoundsToleranceMeters
        case maximumSubmaps
        case maximumVerticesPerSubmap
        case maximumTrianglesPerSubmap
        case maximumPromotedVertices
        case maximumPromotedTriangles
    }

    /// Existing derived workspaces lack distinct-frame support metadata. Decode
    /// them safely with the prior one-frame policy; newly created workspaces
    /// use the production two-frame policy above.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            minimumVoxelWeight: values.decode(Float.self, forKey: .minimumVoxelWeight),
            minimumDistinctFrameCount: try values.decodeIfPresent(
                Int.self,
                forKey: .minimumDistinctFrameCount
            ) ?? 1,
            minimumTriangleAreaSquareMeters: try values.decode(
                Float.self,
                forKey: .minimumTriangleAreaSquareMeters
            ),
            minimumNormalLength: try values.decode(Float.self, forKey: .minimumNormalLength),
            minimumDominantComponentTriangleRatio: try values.decode(
                Float.self,
                forKey: .minimumDominantComponentTriangleRatio
            ),
            canonicalBoundsToleranceMeters: try values.decode(
                Float.self,
                forKey: .canonicalBoundsToleranceMeters
            ),
            maximumSubmaps: try values.decode(Int.self, forKey: .maximumSubmaps),
            maximumVerticesPerSubmap: try values.decode(Int.self, forKey: .maximumVerticesPerSubmap),
            maximumTrianglesPerSubmap: try values.decode(Int.self, forKey: .maximumTrianglesPerSubmap),
            maximumPromotedVertices: try values.decode(Int.self, forKey: .maximumPromotedVertices),
            maximumPromotedTriangles: try values.decode(Int.self, forKey: .maximumPromotedTriangles)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(minimumVoxelWeight, forKey: .minimumVoxelWeight)
        try values.encode(minimumDistinctFrameCount, forKey: .minimumDistinctFrameCount)
        try values.encode(minimumTriangleAreaSquareMeters, forKey: .minimumTriangleAreaSquareMeters)
        try values.encode(minimumNormalLength, forKey: .minimumNormalLength)
        try values.encode(minimumDominantComponentTriangleRatio, forKey: .minimumDominantComponentTriangleRatio)
        try values.encode(canonicalBoundsToleranceMeters, forKey: .canonicalBoundsToleranceMeters)
        try values.encode(maximumSubmaps, forKey: .maximumSubmaps)
        try values.encode(maximumVerticesPerSubmap, forKey: .maximumVerticesPerSubmap)
        try values.encode(maximumTrianglesPerSubmap, forKey: .maximumTrianglesPerSubmap)
        try values.encode(maximumPromotedVertices, forKey: .maximumPromotedVertices)
        try values.encode(maximumPromotedTriangles, forKey: .maximumPromotedTriangles)
    }
}

public struct TSDFGridEdgeKey: Codable, Equatable, Hashable, Comparable, Sendable {
    public var first: TSDFGlobalVoxelCoordinate
    public var second: TSDFGlobalVoxelCoordinate

    public init(_ first: TSDFGlobalVoxelCoordinate, _ second: TSDFGlobalVoxelCoordinate) {
        if first <= second {
            self.first = first
            self.second = second
        } else {
            self.first = second
            self.second = first
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.first == rhs.first ? lhs.second < rhs.second : lhs.first < rhs.first
    }
}

public struct TSDFSurfaceExtractionStatistics: Codable, Equatable, Sendable {
    public var processedSubmapCount: Int
    public var inspectedCellCount: Int
    public var sparseCellCount: Int
    public var invalidVoxelCellCount: Int
    public var emittedVertexOccurrenceCount: Int
    public var emittedTriangleCount: Int
    public var rejectedDegenerateTriangleCount: Int
    public var droppedSubmapCount: Int
    public var droppedVertexCount: Int
    public var droppedTriangleCount: Int

    public init(
        processedSubmapCount: Int = 0,
        inspectedCellCount: Int = 0,
        sparseCellCount: Int = 0,
        invalidVoxelCellCount: Int = 0,
        emittedVertexOccurrenceCount: Int = 0,
        emittedTriangleCount: Int = 0,
        rejectedDegenerateTriangleCount: Int = 0,
        droppedSubmapCount: Int = 0,
        droppedVertexCount: Int = 0,
        droppedTriangleCount: Int = 0
    ) {
        self.processedSubmapCount = processedSubmapCount
        self.inspectedCellCount = inspectedCellCount
        self.sparseCellCount = sparseCellCount
        self.invalidVoxelCellCount = invalidVoxelCellCount
        self.emittedVertexOccurrenceCount = emittedVertexOccurrenceCount
        self.emittedTriangleCount = emittedTriangleCount
        self.rejectedDegenerateTriangleCount = rejectedDegenerateTriangleCount
        self.droppedSubmapCount = droppedSubmapCount
        self.droppedVertexCount = droppedVertexCount
        self.droppedTriangleCount = droppedTriangleCount
    }

    fileprivate mutating func add(_ other: Self) -> Bool {
        let values = [
            processedSubmapCount.addingReportingOverflow(other.processedSubmapCount),
            inspectedCellCount.addingReportingOverflow(other.inspectedCellCount),
            sparseCellCount.addingReportingOverflow(other.sparseCellCount),
            invalidVoxelCellCount.addingReportingOverflow(other.invalidVoxelCellCount),
            emittedVertexOccurrenceCount.addingReportingOverflow(other.emittedVertexOccurrenceCount),
            emittedTriangleCount.addingReportingOverflow(other.emittedTriangleCount),
            rejectedDegenerateTriangleCount.addingReportingOverflow(other.rejectedDegenerateTriangleCount),
            droppedSubmapCount.addingReportingOverflow(other.droppedSubmapCount),
            droppedVertexCount.addingReportingOverflow(other.droppedVertexCount),
            droppedTriangleCount.addingReportingOverflow(other.droppedTriangleCount)
        ]
        guard values.allSatisfy({ !$0.overflow }) else { return false }
        processedSubmapCount = values[0].partialValue
        inspectedCellCount = values[1].partialValue
        sparseCellCount = values[2].partialValue
        invalidVoxelCellCount = values[3].partialValue
        emittedVertexOccurrenceCount = values[4].partialValue
        emittedTriangleCount = values[5].partialValue
        rejectedDegenerateTriangleCount = values[6].partialValue
        droppedSubmapCount = values[7].partialValue
        droppedVertexCount = values[8].partialValue
        droppedTriangleCount = values[9].partialValue
        return true
    }
}

public enum TSDFSurfaceValidationFailure: String, Codable, Equatable, Sendable {
    case emptyGeometry
    case nonFiniteAttribute
    case invalidIndex
    case invalidTriangleArea
    case invalidNormal
    case fragmentedGeometry
    case invalidBounds
    case canonicalBoundsDisagreement
    case boundarySeamMismatch
    case resourceLimitReached
}

public struct TSDFSurfaceValidationReport: Codable, Equatable, Sendable {
    public var isValid: Bool
    public var failures: [TSDFSurfaceValidationFailure]
    public var vertexCount: Int
    public var triangleCount: Int
    public var componentTriangleCounts: [Int]
    public var bounds: TSDFSurfaceBounds?
    public var robustBounds: TSDFSurfaceBounds?
    public var duplicateBoundaryVertexCount: Int
    public var boundarySeamMismatchCount: Int
    public var sourceStatistics: TSDFReconstructionStatistics
    public var statistics: TSDFSurfaceExtractionStatistics

    public init(
        failures: [TSDFSurfaceValidationFailure],
        vertexCount: Int,
        triangleCount: Int,
        componentTriangleCounts: [Int],
        bounds: TSDFSurfaceBounds?,
        robustBounds: TSDFSurfaceBounds?,
        duplicateBoundaryVertexCount: Int,
        boundarySeamMismatchCount: Int,
        sourceStatistics: TSDFReconstructionStatistics,
        statistics: TSDFSurfaceExtractionStatistics
    ) {
        self.failures = failures
        isValid = failures.isEmpty
        self.vertexCount = vertexCount
        self.triangleCount = triangleCount
        self.componentTriangleCounts = componentTriangleCounts
        self.bounds = bounds
        self.robustBounds = robustBounds
        self.duplicateBoundaryVertexCount = duplicateBoundaryVertexCount
        self.boundarySeamMismatchCount = boundarySeamMismatchCount
        self.sourceStatistics = sourceStatistics
        self.statistics = statistics
    }
}

public struct TSDFDerivedFileReference: Codable, Equatable, Sendable {
    public var relativePath: String
    public var byteCount: Int64
    public var sha256: String

    public init(relativePath: String, byteCount: Int64, sha256: String) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct TSDFProcessedSurfaceManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var scanID: UUID
    public var prefix: TSDFCompletedPrefixIdentity
    public var extractionConfiguration: TSDFSurfaceExtractionConfiguration
    public var vertexCount: Int
    public var triangleCount: Int
    public var robustBounds: TSDFSurfaceBounds
    public var geometryFiles: [TSDFDerivedFileReference]
    public var validationFile: TSDFDerivedFileReference

    public init(
        scanID: UUID,
        prefix: TSDFCompletedPrefixIdentity,
        extractionConfiguration: TSDFSurfaceExtractionConfiguration,
        vertexCount: Int,
        triangleCount: Int,
        robustBounds: TSDFSurfaceBounds,
        geometryFiles: [TSDFDerivedFileReference],
        validationFile: TSDFDerivedFileReference
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.scanID = scanID
        self.prefix = prefix
        self.extractionConfiguration = extractionConfiguration
        self.vertexCount = vertexCount
        self.triangleCount = triangleCount
        self.robustBounds = robustBounds
        self.geometryFiles = geometryFiles
        self.validationFile = validationFile
    }
}

public struct TSDFSurfaceExtractionResult: Sendable {
    public var stagingDirectory: URL
    public var promotedDirectory: URL?
    public var validation: TSDFSurfaceValidationReport
    public var manifest: TSDFProcessedSurfaceManifest?

    public init(
        stagingDirectory: URL,
        promotedDirectory: URL?,
        validation: TSDFSurfaceValidationReport,
        manifest: TSDFProcessedSurfaceManifest?
    ) {
        self.stagingDirectory = stagingDirectory
        self.promotedDirectory = promotedDirectory
        self.validation = validation
        self.manifest = manifest
    }
}

public struct TSDFSurfaceExtractionProgress: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case extracting
        case validating
        case promoting
    }

    public var phase: Phase
    public var completedSubmapCount: Int
    public var totalSubmapCount: Int

    public init(phase: Phase, completedSubmapCount: Int, totalSubmapCount: Int) {
        self.phase = phase
        self.completedSubmapCount = completedSubmapCount
        self.totalSubmapCount = totalSubmapCount
    }
}

private struct TSDFSurfaceExtractionState: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var snapshot: TSDFExtractionSnapshot
    var configuration: TSDFSurfaceExtractionConfiguration
    var canonicalBounds: TSDFSurfaceBounds
    var submapKeys: [TSDFSubmapKey]
    var nextSubmapOffset: Int
    var statistics: TSDFSurfaceExtractionStatistics
}

private struct TSDFSurfaceChunkMarker: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var snapshotPrefix: TSDFCompletedPrefixIdentity
    var extractionConfiguration: TSDFSurfaceExtractionConfiguration
    var submapKey: TSDFSubmapKey
    var vertexCount: Int
    var triangleCount: Int
    var files: [TSDFDerivedFileReference]
    var statistics: TSDFSurfaceExtractionStatistics
}

private struct TSDFSurfaceChunkVertex: Sendable {
    var edgeKey: TSDFGridEdgeKey
    var position: Point3D
    var gradient: Point3D
    var gradientCount: UInt32
    var color: PointCloudColor?
}

private struct TSDFSurfaceChunk: Sendable {
    var vertices: [TSDFSurfaceChunkVertex]
    var indices: [UInt32]
    var statistics: TSDFSurfaceExtractionStatistics
}

private struct TSDFSurfaceMergedVertex: Sendable {
    var edgeKey: TSDFGridEdgeKey
    var position: Point3D
    var gradientSum: Point3D
    var gradientCount: Int
    var color: PointCloudColor?
}

private struct TSDFSurfaceCellCorner: Sendable {
    var coordinate: TSDFGlobalVoxelCoordinate
    var position: Point3D
    var signedDistance: Float
    var color: PointCloudColor?
    var offset: Point3D
}

private struct TSDFSurfaceInterpolatedVertex: Sendable {
    var edgeKey: TSDFGridEdgeKey
    var position: Point3D
    var gradient: Point3D
    var color: PointCloudColor?
}

public struct TSDFSurfaceExtractionPipeline: Sendable {
    private static let stateFilename = "surface-extraction-state.json"
    private static let verticesFilename = "vertices.bin"
    private static let normalsFilename = "normals.bin"
    private static let colorsFilename = "colors.bin"
    private static let indicesFilename = "indices.bin"
    private static let chunkManifestFilename = "manifest.json"
    private static let validationFilename = "validation.json"

    public init() {}

    public func run(
        source: any TSDFSurfaceExtractionSource,
        sourcePackageURL: URL,
        stagingDirectory: URL,
        promotionDirectory: URL,
        canonicalSpatialBounds: TSDFSurfaceBounds,
        configuration: TSDFSurfaceExtractionConfiguration = .default,
        progress: (@Sendable (TSDFSurfaceExtractionProgress) async throws -> Void)? = nil
    ) async throws -> TSDFSurfaceExtractionResult {
        try Self.requireWritableLocation(stagingDirectory, outside: sourcePackageURL)
        try Self.requireWritableLocation(promotionDirectory, outside: sourcePackageURL)
        let stagingPath = Self.canonicalPath(for: stagingDirectory)
        let promotionPath = Self.canonicalPath(for: promotionDirectory)
        guard stagingPath != promotionPath,
              !stagingPath.hasPrefix(promotionPath + "/"),
              !promotionPath.hasPrefix(stagingPath + "/")
        else {
            throw TSDFSurfaceExtractionError.invalidWritableLocation
        }

        let snapshot = try await source.makeExtractionSnapshot()
        let allKeys = snapshot.submapKeys.sorted()
        let selectedKeys = Array(allKeys.prefix(configuration.maximumSubmaps))
        var initialStatistics = TSDFSurfaceExtractionStatistics()
        initialStatistics.droppedSubmapCount = allKeys.count - selectedKeys.count
        let state = try Self.openState(
            at: stagingDirectory,
            snapshot: snapshot,
            configuration: configuration,
            canonicalBounds: canonicalSpatialBounds,
            submapKeys: selectedKeys,
            initialStatistics: initialStatistics
        )
        var recovered = try Self.recoveredState(state, at: stagingDirectory)

        for offset in recovered.nextSubmapOffset..<selectedKeys.count {
            try Task.checkCancellation()
            let key = selectedKeys[offset]
            let neighborhood = try await source.loadSubmapWithOneVoxelHalo(key, from: snapshot)
            let chunk = try Self.extract(
                neighborhood: neighborhood,
                snapshot: snapshot,
                configuration: configuration
            )
            try Self.requireWritableLocation(stagingDirectory, outside: sourcePackageURL)
            try Self.writeChunk(
                chunk,
                key: key,
                snapshot: snapshot,
                configuration: configuration,
                stagingDirectory: stagingDirectory
            )
            guard recovered.statistics.add(chunk.statistics) else {
                throw TSDFSurfaceExtractionError.invalidStagingArtifact("statistics-overflow")
            }
            recovered.nextSubmapOffset = offset + 1
            try await progress?(TSDFSurfaceExtractionProgress(
                phase: .extracting,
                completedSubmapCount: recovered.nextSubmapOffset,
                totalSubmapCount: selectedKeys.count
            ))
            try Task.checkCancellation()
            try Self.writeJSON(
                recovered,
                to: stagingDirectory.appending(path: Self.stateFilename)
            )
        }

        try await progress?(TSDFSurfaceExtractionProgress(
            phase: .validating,
            completedSubmapCount: selectedKeys.count,
            totalSubmapCount: selectedKeys.count
        ))
        try Task.checkCancellation()
        let merged = try Self.mergeAndValidate(
            state: recovered,
            stagingDirectory: stagingDirectory
        )
        let diagnosticValidationURL = stagingDirectory.appending(path: Self.validationFilename)
        try Self.requireWritableLocation(stagingDirectory, outside: sourcePackageURL)
        try Self.writeJSON(merged.validation, to: diagnosticValidationURL)
        guard merged.validation.isValid, let robustBounds = merged.validation.robustBounds else {
            return TSDFSurfaceExtractionResult(
                stagingDirectory: stagingDirectory,
                promotedDirectory: nil,
                validation: merged.validation,
                manifest: nil
            )
        }

        try await progress?(TSDFSurfaceExtractionProgress(
            phase: .promoting,
            completedSubmapCount: selectedKeys.count,
            totalSubmapCount: selectedKeys.count
        ))
        try Task.checkCancellation()
        let manifest = try Self.promote(
            vertices: merged.vertices,
            normals: merged.normals,
            colors: merged.colors,
            indices: merged.indices,
            validation: merged.validation,
            robustBounds: robustBounds,
            state: recovered,
            sourcePackageURL: sourcePackageURL,
            to: promotionDirectory
        )
        return TSDFSurfaceExtractionResult(
            stagingDirectory: stagingDirectory,
            promotedDirectory: promotionDirectory,
            validation: merged.validation,
            manifest: manifest
        )
    }
}

private extension TSDFSurfaceExtractionPipeline {
    struct MergedSurface {
        var vertices: [Point3D]
        var normals: [Point3D]
        var colors: [PointCloudColor?]
        var indices: [UInt32]
        var validation: TSDFSurfaceValidationReport
    }

    static let cornerOffsets = [
        TSDFGlobalVoxelCoordinate(x: 0, y: 0, z: 0),
        TSDFGlobalVoxelCoordinate(x: 1, y: 0, z: 0),
        TSDFGlobalVoxelCoordinate(x: 0, y: 1, z: 0),
        TSDFGlobalVoxelCoordinate(x: 1, y: 1, z: 0),
        TSDFGlobalVoxelCoordinate(x: 0, y: 0, z: 1),
        TSDFGlobalVoxelCoordinate(x: 1, y: 0, z: 1),
        TSDFGlobalVoxelCoordinate(x: 0, y: 1, z: 1),
        TSDFGlobalVoxelCoordinate(x: 1, y: 1, z: 1)
    ]

    // Freudenthal triangulation gives every shared cube face the same diagonal.
    static let tetrahedra = [
        [0, 1, 3, 7], [0, 1, 5, 7], [0, 2, 3, 7],
        [0, 2, 6, 7], [0, 4, 5, 7], [0, 4, 6, 7]
    ]
    static let tetrahedronEdges = [(0, 1), (1, 2), (2, 0), (0, 3), (1, 3), (2, 3)]
    static let tetrahedronTriangles = [
        [], [0, 3, 2], [0, 1, 4], [1, 4, 2, 2, 4, 3],
        [1, 2, 5], [0, 3, 5, 0, 5, 1], [0, 2, 5, 0, 5, 4], [5, 4, 3],
        [3, 4, 5], [4, 5, 0, 5, 2, 0], [1, 5, 0, 5, 3, 0], [5, 2, 1],
        [3, 4, 2, 2, 4, 1], [4, 1, 0], [2, 3, 0], []
    ]

    static func extract(
        neighborhood: TSDFSubmapNeighborhood,
        snapshot: TSDFExtractionSnapshot,
        configuration: TSDFSurfaceExtractionConfiguration
    ) throws -> TSDFSurfaceChunk {
        guard neighborhood.voxelDimension == snapshot.prefix.configuration.submapVoxelDimension,
              neighborhood.haloWidth == 1
        else {
            throw TSDFSurfaceExtractionError.snapshotMismatch
        }
        let dimension = neighborhood.voxelDimension
        let dimension64 = Int64(dimension)
        guard let coreX = checkedMultiply(neighborhood.key.x, dimension64),
              let coreY = checkedMultiply(neighborhood.key.y, dimension64),
              let coreZ = checkedMultiply(neighborhood.key.z, dimension64)
        else {
            throw TSDFSurfaceExtractionError.invalidStagingArtifact("submap-coordinate-overflow")
        }
        var vertices: [TSDFSurfaceChunkVertex] = []
        var vertexIndexByEdge: [TSDFGridEdgeKey: UInt32] = [:]
        var indices: [UInt32] = []
        var statistics = TSDFSurfaceExtractionStatistics(processedSubmapCount: 1)

        for localZ in 0..<dimension {
            for localY in 0..<dimension {
                for localX in 0..<dimension {
                    try Task.checkCancellation()
                    statistics.inspectedCellCount += 1
                    guard let cellX = checkedAdd(coreX, Int64(localX)),
                          let cellY = checkedAdd(coreY, Int64(localY)),
                          let cellZ = checkedAdd(coreZ, Int64(localZ))
                    else {
                        statistics.invalidVoxelCellCount += 1
                        continue
                    }
                    let minimum = TSDFGlobalVoxelCoordinate(x: cellX, y: cellY, z: cellZ)
                    var corners: [TSDFSurfaceCellCorner] = []
                    corners.reserveCapacity(8)
                    var invalidVoxel = false
                    for offset in cornerOffsets {
                        guard let coordinate = adding(minimum, offset),
                              let voxel = neighborhood.voxelsByGlobalCoordinate[coordinate]
                        else {
                            break
                        }
                        guard voxel.signedDistance.isFinite,
                              (-1...1).contains(voxel.signedDistance),
                              voxel.weight.isFinite,
                              voxel.weight >= configuration.minimumVoxelWeight,
                              voxel.supportingFrameCount >= configuration.minimumDistinctFrameCount,
                              let position = voxelCenter(
                                  coordinate,
                                  voxelSize: snapshot.prefix.configuration.voxelSizeMeters
                              )
                        else {
                            invalidVoxel = true
                            break
                        }
                        corners.append(TSDFSurfaceCellCorner(
                            coordinate: coordinate,
                            position: position,
                            signedDistance: voxel.signedDistance,
                            color: voxel.color,
                            offset: Point3D(x: Float(offset.x), y: Float(offset.y), z: Float(offset.z))
                        ))
                    }
                    guard !invalidVoxel else {
                        statistics.invalidVoxelCellCount += 1
                        continue
                    }
                    guard corners.count == 8 else {
                        statistics.sparseCellCount += 1
                        continue
                    }
                    try emitCell(
                        corners: corners,
                        voxelSize: snapshot.prefix.configuration.voxelSizeMeters,
                        configuration: configuration,
                        vertices: &vertices,
                        vertexIndexByEdge: &vertexIndexByEdge,
                        indices: &indices,
                        statistics: &statistics
                    )
                }
            }
        }
        statistics.emittedVertexOccurrenceCount = vertices.count
        statistics.emittedTriangleCount = indices.count / 3
        return TSDFSurfaceChunk(vertices: vertices, indices: indices, statistics: statistics)
    }

    static func emitCell(
        corners: [TSDFSurfaceCellCorner],
        voxelSize: Float,
        configuration: TSDFSurfaceExtractionConfiguration,
        vertices: inout [TSDFSurfaceChunkVertex],
        vertexIndexByEdge: inout [TSDFGridEdgeKey: UInt32],
        indices: inout [UInt32],
        statistics: inout TSDFSurfaceExtractionStatistics
    ) throws {
        for tetrahedron in tetrahedra {
            var caseIndex = 0
            for (offset, cornerIndex) in tetrahedron.enumerated()
                where corners[cornerIndex].signedDistance < 0 {
                caseIndex |= 1 << offset
            }
            let triangleEdges = tetrahedronTriangles[caseIndex]
            guard !triangleEdges.isEmpty else { continue }
            var interpolatedByEdge: [Int: TSDFSurfaceInterpolatedVertex] = [:]
            for edgeIndex in Set(triangleEdges).sorted() {
                let edge = tetrahedronEdges[edgeIndex]
                let first = corners[tetrahedron[edge.0]]
                let second = corners[tetrahedron[edge.1]]
                guard let interpolated = interpolate(
                    first,
                    second,
                    corners: corners,
                    voxelSize: voxelSize
                ) else {
                    continue
                }
                interpolatedByEdge[edgeIndex] = interpolated
            }
            for triangleOffset in stride(from: 0, to: triangleEdges.count, by: 3) {
                let edgeIndices = Array(triangleEdges[triangleOffset..<(triangleOffset + 3)])
                guard var triangle = edgeIndices.compactMap({ interpolatedByEdge[$0] }).nilUnlessCount(3),
                      Set(triangle.map(\.edgeKey)).count == 3
                else {
                    statistics.rejectedDegenerateTriangleCount += 1
                    continue
                }
                let face = cross(subtract(triangle[1].position, triangle[0].position),
                                 subtract(triangle[2].position, triangle[0].position))
                let area = 0.5 * length(face)
                guard area.isFinite, area >= configuration.minimumTriangleAreaSquareMeters else {
                    statistics.rejectedDegenerateTriangleCount += 1
                    continue
                }
                let averageGradient = add(add(triangle[0].gradient, triangle[1].gradient), triangle[2].gradient)
                if dot(face, averageGradient) < 0 {
                    triangle.swapAt(1, 2)
                }
                let newVertexCount = triangle.reduce(into: 0) { count, vertex in
                    if vertexIndexByEdge[vertex.edgeKey] == nil { count += 1 }
                }
                guard vertices.count + newVertexCount <= configuration.maximumVerticesPerSubmap,
                      indices.count / 3 < configuration.maximumTrianglesPerSubmap
                else {
                    statistics.droppedVertexCount += newVertexCount
                    statistics.droppedTriangleCount += 1
                    continue
                }
                for vertex in triangle {
                    if let existing = vertexIndexByEdge[vertex.edgeKey] {
                        let existingIndex = Int(existing)
                        let count = vertices[existingIndex].gradientCount.addingReportingOverflow(1)
                        guard !count.overflow else {
                            throw TSDFSurfaceExtractionError.invalidStagingArtifact("gradient-count")
                        }
                        vertices[existingIndex].gradient = add(
                            vertices[existingIndex].gradient,
                            vertex.gradient
                        )
                        vertices[existingIndex].gradientCount = count.partialValue
                        indices.append(existing)
                    } else {
                        guard let index = UInt32(exactly: vertices.count) else {
                            throw TSDFSurfaceExtractionError.invalidConfiguration
                        }
                        vertexIndexByEdge[vertex.edgeKey] = index
                        vertices.append(TSDFSurfaceChunkVertex(
                            edgeKey: vertex.edgeKey,
                            position: vertex.position,
                            gradient: vertex.gradient,
                            gradientCount: 1,
                            color: vertex.color
                        ))
                        indices.append(index)
                    }
                }
            }
        }
    }

    static func interpolate(
        _ first: TSDFSurfaceCellCorner,
        _ second: TSDFSurfaceCellCorner,
        corners: [TSDFSurfaceCellCorner],
        voxelSize: Float
    ) -> TSDFSurfaceInterpolatedVertex? {
        let denominator = first.signedDistance - second.signedDistance
        guard denominator.isFinite, denominator != 0 else { return nil }
        let t = first.signedDistance / denominator
        guard t.isFinite, (0...1).contains(t) else { return nil }
        let position = lerp(first.position, second.position, t: t)
        let local = lerp(first.offset, second.offset, t: t)
        let gradient = trilinearGradient(corners: corners, local: local, voxelSize: voxelSize)
        guard TSDFSurfaceBounds.isFinite(position), TSDFSurfaceBounds.isFinite(gradient) else {
            return nil
        }
        let edgeKey: TSDFGridEdgeKey
        if t == 0 {
            edgeKey = TSDFGridEdgeKey(first.coordinate, first.coordinate)
        } else if t == 1 {
            edgeKey = TSDFGridEdgeKey(second.coordinate, second.coordinate)
        } else {
            edgeKey = TSDFGridEdgeKey(first.coordinate, second.coordinate)
        }
        return TSDFSurfaceInterpolatedVertex(
            edgeKey: edgeKey,
            position: position,
            gradient: gradient,
            color: interpolateColor(first.color, second.color, t: t)
        )
    }

    static func trilinearGradient(
        corners: [TSDFSurfaceCellCorner],
        local: Point3D,
        voxelSize: Float
    ) -> Point3D {
        let values = corners.map(\.signedDistance)
        let u = local.x
        let v = local.y
        let w = local.z
        let du = (1 - v) * (1 - w) * (values[1] - values[0])
            + v * (1 - w) * (values[3] - values[2])
            + (1 - v) * w * (values[5] - values[4])
            + v * w * (values[7] - values[6])
        let dv = (1 - u) * (1 - w) * (values[2] - values[0])
            + u * (1 - w) * (values[3] - values[1])
            + (1 - u) * w * (values[6] - values[4])
            + u * w * (values[7] - values[5])
        let dw = (1 - u) * (1 - v) * (values[4] - values[0])
            + u * (1 - v) * (values[5] - values[1])
            + (1 - u) * v * (values[6] - values[2])
            + u * v * (values[7] - values[3])
        return Point3D(x: du / voxelSize, y: dv / voxelSize, z: dw / voxelSize)
    }

    static func interpolateColor(
        _ first: PointCloudColor?,
        _ second: PointCloudColor?,
        t: Float
    ) -> PointCloudColor? {
        switch (first, second) {
        case let (.some(first), .some(second)):
            return PointCloudColor(
                red: UInt8(clamping: Int((Float(first.red) + t * Float(Int(second.red) - Int(first.red))).rounded())),
                green: UInt8(clamping: Int((Float(first.green) + t * Float(Int(second.green) - Int(first.green))).rounded())),
                blue: UInt8(clamping: Int((Float(first.blue) + t * Float(Int(second.blue) - Int(first.blue))).rounded()))
            )
        case (.some, .none), (.none, .some), (.none, .none):
            return nil
        }
    }
}

private extension TSDFSurfaceExtractionPipeline {
    static func openState(
        at stagingDirectory: URL,
        snapshot: TSDFExtractionSnapshot,
        configuration: TSDFSurfaceExtractionConfiguration,
        canonicalBounds: TSDFSurfaceBounds,
        submapKeys: [TSDFSubmapKey],
        initialStatistics: TSDFSurfaceExtractionStatistics
    ) throws -> TSDFSurfaceExtractionState {
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let chunks = stagingDirectory.appending(path: "chunks", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
            let stateURL = stagingDirectory.appending(path: stateFilename)
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let state = try JSONDecoder().decode(
                    TSDFSurfaceExtractionState.self,
                    from: Data(contentsOf: stateURL)
                )
                guard state.schemaVersion == TSDFSurfaceExtractionState.currentSchemaVersion,
                      state.snapshot == snapshot,
                      state.configuration == configuration,
                      state.canonicalBounds == canonicalBounds,
                      state.submapKeys == submapKeys,
                      validStatistics(state.statistics),
                      state.statistics.droppedSubmapCount == snapshot.submapKeys.count - submapKeys.count
                else {
                    throw TSDFSurfaceExtractionError.snapshotMismatch
                }
                return state
            }
            let state = TSDFSurfaceExtractionState(
                schemaVersion: TSDFSurfaceExtractionState.currentSchemaVersion,
                snapshot: snapshot,
                configuration: configuration,
                canonicalBounds: canonicalBounds,
                submapKeys: submapKeys,
                nextSubmapOffset: 0,
                statistics: initialStatistics
            )
            try writeJSON(state, to: stateURL)
            return state
        } catch let error as TSDFSurfaceExtractionError {
            throw error
        } catch {
            throw TSDFSurfaceExtractionError.ioFailure(error.localizedDescription)
        }
    }

    static func recoveredState(
        _ persisted: TSDFSurfaceExtractionState,
        at stagingDirectory: URL
    ) throws -> TSDFSurfaceExtractionState {
        var recovered = persisted
        recovered.nextSubmapOffset = 0
        recovered.statistics = TSDFSurfaceExtractionStatistics(
            droppedSubmapCount: persisted.statistics.droppedSubmapCount
        )
        for key in persisted.submapKeys {
            let directory = chunkDirectory(for: key, stagingDirectory: stagingDirectory)
            guard FileManager.default.fileExists(
                atPath: directory.appending(path: chunkManifestFilename).path
            ) else { break }
            let marker = try readChunkMarker(
                key: key,
                snapshot: persisted.snapshot,
                configuration: persisted.configuration,
                stagingDirectory: stagingDirectory
            )
            guard recovered.statistics.add(marker.statistics) else {
                throw TSDFSurfaceExtractionError.invalidStagingArtifact("statistics-overflow")
            }
            recovered.nextSubmapOffset += 1
        }
        try writeJSON(recovered, to: stagingDirectory.appending(path: stateFilename))
        return recovered
    }

    static func writeChunk(
        _ chunk: TSDFSurfaceChunk,
        key: TSDFSubmapKey,
        snapshot: TSDFExtractionSnapshot,
        configuration: TSDFSurfaceExtractionConfiguration,
        stagingDirectory: URL
    ) throws {
        let chunksDirectory = stagingDirectory.appending(path: "chunks", directoryHint: .isDirectory)
        let destination = chunkDirectory(for: key, stagingDirectory: stagingDirectory)
        let temporary = chunksDirectory.appending(
            path: ".\(chunkName(for: key)).\(UUID().uuidString).partial",
            directoryHint: .isDirectory
        )
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            try writeChunkVertices(chunk.vertices, to: temporary.appending(path: verticesFilename))
            try writeChunkNormals(chunk.vertices, to: temporary.appending(path: normalsFilename))
            try writeChunkColors(chunk.vertices, to: temporary.appending(path: colorsFilename))
            try writeUInt32(chunk.indices, to: temporary.appending(path: indicesFilename))
            let files = try [verticesFilename, normalsFilename, colorsFilename, indicesFilename].map {
                try fileReference(at: temporary.appending(path: $0), relativePath: $0)
            }
            let marker = TSDFSurfaceChunkMarker(
                schemaVersion: TSDFSurfaceChunkMarker.currentSchemaVersion,
                snapshotPrefix: snapshot.prefix,
                extractionConfiguration: configuration,
                submapKey: key,
                vertexCount: chunk.vertices.count,
                triangleCount: chunk.indices.count / 3,
                files: files,
                statistics: chunk.statistics
            )
            try writeJSON(marker, to: temporary.appending(path: chunkManifestFilename))
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if error is CancellationError { throw CancellationError() }
            if let error = error as? TSDFSurfaceExtractionError { throw error }
            throw TSDFSurfaceExtractionError.ioFailure(error.localizedDescription)
        }
    }

    static func readChunkMarker(
        key: TSDFSubmapKey,
        snapshot: TSDFExtractionSnapshot,
        configuration: TSDFSurfaceExtractionConfiguration,
        stagingDirectory: URL
    ) throws -> TSDFSurfaceChunkMarker {
        let directory = chunkDirectory(for: key, stagingDirectory: stagingDirectory)
        let markerURL = directory.appending(path: chunkManifestFilename)
        let marker: TSDFSurfaceChunkMarker
        do {
            marker = try JSONDecoder().decode(TSDFSurfaceChunkMarker.self, from: Data(contentsOf: markerURL))
        } catch {
            throw TSDFSurfaceExtractionError.invalidStagingArtifact(markerURL.lastPathComponent)
        }
        guard marker.schemaVersion == TSDFSurfaceChunkMarker.currentSchemaVersion,
              marker.snapshotPrefix == snapshot.prefix,
              marker.extractionConfiguration == configuration,
              marker.submapKey == key,
              marker.vertexCount >= 0,
              marker.vertexCount <= configuration.maximumVerticesPerSubmap,
              marker.triangleCount >= 0,
              marker.triangleCount <= configuration.maximumTrianglesPerSubmap,
              validStatistics(marker.statistics),
              marker.statistics.emittedVertexOccurrenceCount == marker.vertexCount,
              marker.statistics.emittedTriangleCount == marker.triangleCount,
              marker.files.map(\.relativePath) == [
                  verticesFilename, normalsFilename, colorsFilename, indicesFilename
              ]
        else {
            throw TSDFSurfaceExtractionError.snapshotMismatch
        }
        for reference in marker.files {
            try verify(reference, under: directory)
        }
        return marker
    }

    static func readChunk(
        marker: TSDFSurfaceChunkMarker,
        stagingDirectory: URL
    ) throws -> TSDFSurfaceChunk {
        let directory = chunkDirectory(for: marker.submapKey, stagingDirectory: stagingDirectory)
        let verticesData = try Data(contentsOf: directory.appending(path: verticesFilename))
        let normalsData = try Data(contentsOf: directory.appending(path: normalsFilename))
        let colorsData = try Data(contentsOf: directory.appending(path: colorsFilename))
        let indicesData = try Data(contentsOf: directory.appending(path: indicesFilename))
        guard checkedByteCount(marker.vertexCount, stride: 60) == verticesData.count,
              checkedByteCount(marker.vertexCount, stride: 16) == normalsData.count,
              checkedByteCount(marker.vertexCount, stride: 4) == colorsData.count,
              checkedByteCount(marker.triangleCount, stride: 12) == indicesData.count
        else {
            throw TSDFSurfaceExtractionError.invalidStagingArtifact(chunkName(for: marker.submapKey))
        }
        var vertices: [TSDFSurfaceChunkVertex] = []
        vertices.reserveCapacity(marker.vertexCount)
        for index in 0..<marker.vertexCount {
            let vertexOffset = index * 60
            let normalOffset = index * 16
            guard let ax = verticesData.readInt64LittleEndian(at: vertexOffset),
                  let ay = verticesData.readInt64LittleEndian(at: vertexOffset + 8),
                  let az = verticesData.readInt64LittleEndian(at: vertexOffset + 16),
                  let bx = verticesData.readInt64LittleEndian(at: vertexOffset + 24),
                  let by = verticesData.readInt64LittleEndian(at: vertexOffset + 32),
                  let bz = verticesData.readInt64LittleEndian(at: vertexOffset + 40),
                  let px = verticesData.readFloat32LittleEndian(at: vertexOffset + 48),
                  let py = verticesData.readFloat32LittleEndian(at: vertexOffset + 52),
                  let pz = verticesData.readFloat32LittleEndian(at: vertexOffset + 56),
                  let nx = normalsData.readFloat32LittleEndian(at: normalOffset),
                  let ny = normalsData.readFloat32LittleEndian(at: normalOffset + 4),
                  let nz = normalsData.readFloat32LittleEndian(at: normalOffset + 8),
                  let gradientCount = normalsData.readUInt32LittleEndian(at: normalOffset + 12),
                  gradientCount > 0
            else {
                throw TSDFSurfaceExtractionError.invalidStagingArtifact(verticesFilename)
            }
            let colorOffset = index * 4
            let color = colorsData[colorOffset + 3] == 1
                ? PointCloudColor(
                    red: colorsData[colorOffset],
                    green: colorsData[colorOffset + 1],
                    blue: colorsData[colorOffset + 2]
                )
                : nil
            guard colorsData[colorOffset + 3] <= 1 else {
                throw TSDFSurfaceExtractionError.invalidStagingArtifact(colorsFilename)
            }
            vertices.append(TSDFSurfaceChunkVertex(
                edgeKey: TSDFGridEdgeKey(
                    TSDFGlobalVoxelCoordinate(x: ax, y: ay, z: az),
                    TSDFGlobalVoxelCoordinate(x: bx, y: by, z: bz)
                ),
                position: Point3D(x: px, y: py, z: pz),
                gradient: Point3D(x: nx, y: ny, z: nz),
                gradientCount: gradientCount,
                color: color
            ))
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(marker.triangleCount * 3)
        for offset in stride(from: 0, to: indicesData.count, by: 4) {
            guard let value = indicesData.readUInt32LittleEndian(at: offset) else {
                throw TSDFSurfaceExtractionError.invalidStagingArtifact(indicesFilename)
            }
            indices.append(value)
        }
        return TSDFSurfaceChunk(vertices: vertices, indices: indices, statistics: marker.statistics)
    }
}

private extension TSDFSurfaceExtractionPipeline {
    static func mergeAndValidate(
        state: TSDFSurfaceExtractionState,
        stagingDirectory: URL
    ) throws -> MergedSurface {
        var mergedVertices: [TSDFSurfaceMergedVertex] = []
        var globalIndexByEdge: [TSDFGridEdgeKey: UInt32] = [:]
        var indices: [UInt32] = []
        var statistics = state.statistics
        var seamDuplicates = 0
        var seamMismatches = 0
        var invalidIndex = false
        var invalidAttribute = false

        for key in state.submapKeys {
            try Task.checkCancellation()
            let marker = try readChunkMarker(
                key: key,
                snapshot: state.snapshot,
                configuration: state.configuration,
                stagingDirectory: stagingDirectory
            )
            let chunk = try readChunk(marker: marker, stagingDirectory: stagingDirectory)
            var localToGlobal: [UInt32?] = Array(repeating: nil, count: chunk.vertices.count)
            for (localIndex, vertex) in chunk.vertices.enumerated() {
                guard TSDFSurfaceBounds.isFinite(vertex.position),
                      TSDFSurfaceBounds.isFinite(vertex.gradient)
                else {
                    invalidAttribute = true
                    continue
                }
                if let existingIndex = globalIndexByEdge[vertex.edgeKey] {
                    seamDuplicates += 1
                    let index = Int(existingIndex)
                    guard index < mergedVertices.count else {
                        invalidIndex = true
                        continue
                    }
                    if !mergedVertices[index].position.isApproximatelyEqual(
                        to: vertex.position,
                        tolerance: state.snapshot.prefix.configuration.voxelSizeMeters * 0.000_1
                    ) || mergedVertices[index].color != vertex.color {
                        seamMismatches += 1
                    }
                    mergedVertices[index].gradientSum = add(
                        mergedVertices[index].gradientSum,
                        vertex.gradient
                    )
                    let count = mergedVertices[index].gradientCount.addingReportingOverflow(
                        Int(vertex.gradientCount)
                    )
                    guard !count.overflow else {
                        throw TSDFSurfaceExtractionError.invalidStagingArtifact("gradient-count")
                    }
                    mergedVertices[index].gradientCount = count.partialValue
                    localToGlobal[localIndex] = existingIndex
                } else if mergedVertices.count < state.configuration.maximumPromotedVertices,
                          let index = UInt32(exactly: mergedVertices.count) {
                    globalIndexByEdge[vertex.edgeKey] = index
                    mergedVertices.append(TSDFSurfaceMergedVertex(
                        edgeKey: vertex.edgeKey,
                        position: vertex.position,
                        gradientSum: vertex.gradient,
                        gradientCount: Int(vertex.gradientCount),
                        color: vertex.color
                    ))
                    localToGlobal[localIndex] = index
                } else {
                    statistics.droppedVertexCount += 1
                }
            }
            for offset in stride(from: 0, to: chunk.indices.count, by: 3) {
                guard offset + 2 < chunk.indices.count,
                      let firstLocal = Int(exactly: chunk.indices[offset]),
                      let secondLocal = Int(exactly: chunk.indices[offset + 1]),
                      let thirdLocal = Int(exactly: chunk.indices[offset + 2]),
                      chunk.vertices.indices.contains(firstLocal),
                      chunk.vertices.indices.contains(secondLocal),
                      chunk.vertices.indices.contains(thirdLocal)
                else {
                    invalidIndex = true
                    continue
                }
                guard let first = localToGlobal[firstLocal],
                      let second = localToGlobal[secondLocal],
                      let third = localToGlobal[thirdLocal]
                else {
                    statistics.droppedTriangleCount += 1
                    continue
                }
                guard first != second, second != third, first != third else {
                    statistics.rejectedDegenerateTriangleCount += 1
                    continue
                }
                guard indices.count / 3 < state.configuration.maximumPromotedTriangles else {
                    statistics.droppedTriangleCount += 1
                    continue
                }
                indices.append(contentsOf: [first, second, third])
            }
        }

        let positions = mergedVertices.map(\.position)
        let colors = mergedVertices.map(\.color)
        var normals: [Point3D] = []
        normals.reserveCapacity(mergedVertices.count)
        var invalidNormal = false
        for vertex in mergedVertices {
            let normal = normalized(vertex.gradientSum)
            if let normal, length(normal) >= state.configuration.minimumNormalLength {
                normals.append(normal)
            } else {
                invalidNormal = true
                normals.append(Point3D(x: 0, y: 0, z: 0))
            }
        }
        let topology = validateTopology(
            positions: positions,
            indices: indices,
            minimumArea: state.configuration.minimumTriangleAreaSquareMeters
        )
        let allBounds = bounds(for: positions)
        let components = connectedComponents(vertexCount: positions.count, indices: indices)
        let robustBounds = components.dominantRoot.flatMap { root in
            bounds(for: positions.enumerated().compactMap {
                components.rootByVertex[$0.offset] == root ? $0.element : nil
            })
        }
        let dominantRatio = indices.isEmpty
            ? 0
            : Float(components.triangleCounts.first ?? 0) / Float(indices.count / 3)

        var failures: [TSDFSurfaceValidationFailure] = []
        if positions.isEmpty || indices.isEmpty { failures.append(.emptyGeometry) }
        // Ineligible TSDF cells are expected in a sparse, confidence-gated
        // volume. They are counted above and excluded before geometry is
        // emitted. Only a non-finite attribute that reaches a staged surface
        // chunk invalidates the promoted output.
        if invalidAttribute { failures.append(.nonFiniteAttribute) }
        if invalidIndex || topology.invalidIndex { failures.append(.invalidIndex) }
        if topology.invalidArea { failures.append(.invalidTriangleArea) }
        if invalidNormal { failures.append(.invalidNormal) }
        if dominantRatio < state.configuration.minimumDominantComponentTriangleRatio {
            failures.append(.fragmentedGeometry)
        }
        if components.triangleCounts.count > 1,
           components.triangleCounts[0] == components.triangleCounts[1] {
            failures.append(.fragmentedGeometry)
        }
        if allBounds == nil || robustBounds == nil { failures.append(.invalidBounds) }
        if let robustBounds,
           !state.canonicalBounds.contains(robustBounds.minimum, tolerance: state.configuration.canonicalBoundsToleranceMeters)
            || !state.canonicalBounds.contains(robustBounds.maximum, tolerance: state.configuration.canonicalBoundsToleranceMeters) {
            failures.append(.canonicalBoundsDisagreement)
        }
        if seamMismatches > 0 { failures.append(.boundarySeamMismatch) }
        if statistics.droppedSubmapCount > 0
            || statistics.droppedVertexCount > 0
            || statistics.droppedTriangleCount > 0
            || state.snapshot.statistics.droppedVoxelUpdateCount > 0 {
            failures.append(.resourceLimitReached)
        }
        failures = Array(Set(failures)).sorted { $0.rawValue < $1.rawValue }
        let validation = TSDFSurfaceValidationReport(
            failures: failures,
            vertexCount: positions.count,
            triangleCount: indices.count / 3,
            componentTriangleCounts: components.triangleCounts,
            bounds: allBounds,
            robustBounds: robustBounds,
            duplicateBoundaryVertexCount: seamDuplicates,
            boundarySeamMismatchCount: seamMismatches,
            sourceStatistics: state.snapshot.statistics,
            statistics: statistics
        )
        return MergedSurface(
            vertices: positions,
            normals: normals,
            colors: colors,
            indices: indices,
            validation: validation
        )
    }

    static func validateTopology(
        positions: [Point3D],
        indices: [UInt32],
        minimumArea: Float
    ) -> (invalidIndex: Bool, invalidArea: Bool) {
        var invalidIndex = indices.count % 3 != 0
        var invalidArea = false
        for offset in stride(from: 0, to: indices.count - indices.count % 3, by: 3) {
            guard let first = Int(exactly: indices[offset]),
                  let second = Int(exactly: indices[offset + 1]),
                  let third = Int(exactly: indices[offset + 2]),
                  positions.indices.contains(first),
                  positions.indices.contains(second),
                  positions.indices.contains(third)
            else {
                invalidIndex = true
                continue
            }
            let area = 0.5 * length(cross(
                subtract(positions[second], positions[first]),
                subtract(positions[third], positions[first])
            ))
            if !area.isFinite || area < minimumArea { invalidArea = true }
        }
        return (invalidIndex, invalidArea)
    }

    struct ComponentResult {
        var rootByVertex: [Int]
        var triangleCounts: [Int]
        var dominantRoot: Int?
    }

    static func connectedComponents(vertexCount: Int, indices: [UInt32]) -> ComponentResult {
        var unionFind = UnionFind(count: vertexCount)
        for offset in stride(from: 0, to: indices.count - indices.count % 3, by: 3) {
            let first = Int(indices[offset])
            let second = Int(indices[offset + 1])
            let third = Int(indices[offset + 2])
            guard first < vertexCount, second < vertexCount, third < vertexCount else { continue }
            unionFind.union(first, second)
            unionFind.union(first, third)
        }
        var rootByVertex = (0..<vertexCount).map { unionFind.find($0) }
        var countsByRoot: [Int: Int] = [:]
        for offset in stride(from: 0, to: indices.count - indices.count % 3, by: 3) {
            let first = Int(indices[offset])
            guard first < rootByVertex.count else { continue }
            countsByRoot[rootByVertex[first], default: 0] += 1
        }
        let ordered = countsByRoot.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        // Path compression after all unions keeps robust-bound membership stable.
        rootByVertex = (0..<vertexCount).map { unionFind.find($0) }
        return ComponentResult(
            rootByVertex: rootByVertex,
            triangleCounts: ordered.map(\.value),
            dominantRoot: ordered.first?.key
        )
    }
}

private extension TSDFSurfaceExtractionPipeline {
    static func promote(
        vertices: [Point3D],
        normals: [Point3D],
        colors: [PointCloudColor?],
        indices: [UInt32],
        validation: TSDFSurfaceValidationReport,
        robustBounds: TSDFSurfaceBounds,
        state: TSDFSurfaceExtractionState,
        sourcePackageURL: URL,
        to destination: URL
    ) throws -> TSDFProcessedSurfaceManifest {
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appending(
            path: ".\(destination.lastPathComponent).\(UUID().uuidString).partial",
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: temporary.appending(path: "geometry", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
            let geometry = temporary.appending(path: "geometry", directoryHint: .isDirectory)
            try writePoints(vertices, to: geometry.appending(path: verticesFilename))
            try writePoints(normals, to: geometry.appending(path: normalsFilename))
            try writeColors(colors, to: geometry.appending(path: colorsFilename))
            try writeUInt32(indices, to: geometry.appending(path: indicesFilename))
            let validationURL = temporary.appending(path: validationFilename)
            try writeJSON(validation, to: validationURL)
            let geometryReferences = try [verticesFilename, normalsFilename, colorsFilename, indicesFilename].map {
                try fileReference(
                    at: geometry.appending(path: $0),
                    relativePath: "geometry/\($0)"
                )
            }
            let validationReference = try fileReference(
                at: validationURL,
                relativePath: validationFilename
            )
            let manifest = TSDFProcessedSurfaceManifest(
                scanID: state.snapshot.prefix.source.scanID,
                prefix: state.snapshot.prefix,
                extractionConfiguration: state.configuration,
                vertexCount: vertices.count,
                triangleCount: indices.count / 3,
                robustBounds: robustBounds,
                geometryFiles: geometryReferences,
                validationFile: validationReference
            )
            try writeJSON(manifest, to: temporary.appending(path: "manifest.json"))
            for reference in geometryReferences + [validationReference] {
                try verify(reference, under: temporary)
            }
            try Task.checkCancellation()
            try requireWritableLocation(destination, outside: sourcePackageURL)
            if FileManager.default.fileExists(atPath: destination.path) {
                let existing = try readPromotedManifest(at: destination)
                guard existing == manifest else {
                    throw TSDFSurfaceExtractionError.promotionConflict
                }
                try FileManager.default.removeItem(at: temporary)
                return existing
            }
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
                return manifest
            } catch {
                if FileManager.default.fileExists(atPath: destination.path),
                   try readPromotedManifest(at: destination) == manifest {
                    try? FileManager.default.removeItem(at: temporary)
                    return manifest
                }
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if error is CancellationError { throw CancellationError() }
            if let error = error as? TSDFSurfaceExtractionError { throw error }
            throw TSDFSurfaceExtractionError.ioFailure(error.localizedDescription)
        }
    }

    static func readPromotedManifest(at directory: URL) throws -> TSDFProcessedSurfaceManifest {
        let manifest: TSDFProcessedSurfaceManifest
        do {
            manifest = try JSONDecoder().decode(
                TSDFProcessedSurfaceManifest.self,
                from: Data(contentsOf: directory.appending(path: "manifest.json"))
            )
        } catch {
            throw TSDFSurfaceExtractionError.promotionConflict
        }
        guard manifest.schemaVersion == TSDFProcessedSurfaceManifest.currentSchemaVersion else {
            throw TSDFSurfaceExtractionError.promotionConflict
        }
        for reference in manifest.geometryFiles + [manifest.validationFile] {
            try verify(reference, under: directory)
        }
        return manifest
    }
}

private extension TSDFSurfaceExtractionPipeline {
    static func writeChunkVertices(_ vertices: [TSDFSurfaceChunkVertex], to url: URL) throws {
        let writer = try BufferedBinaryWriter(url: url)
        for (index, vertex) in vertices.enumerated() {
            if index % 4_096 == 0 { try Task.checkCancellation() }
            try writer.append(vertex.edgeKey.first.x)
            try writer.append(vertex.edgeKey.first.y)
            try writer.append(vertex.edgeKey.first.z)
            try writer.append(vertex.edgeKey.second.x)
            try writer.append(vertex.edgeKey.second.y)
            try writer.append(vertex.edgeKey.second.z)
            try writer.append(vertex.position.x)
            try writer.append(vertex.position.y)
            try writer.append(vertex.position.z)
        }
        try writer.finish()
    }

    static func writeChunkNormals(_ vertices: [TSDFSurfaceChunkVertex], to url: URL) throws {
        let writer = try BufferedBinaryWriter(url: url)
        for (index, vertex) in vertices.enumerated() {
            if index % 4_096 == 0 { try Task.checkCancellation() }
            try writer.append(vertex.gradient.x)
            try writer.append(vertex.gradient.y)
            try writer.append(vertex.gradient.z)
            try writer.append(vertex.gradientCount)
        }
        try writer.finish()
    }

    static func writeChunkColors(_ vertices: [TSDFSurfaceChunkVertex], to url: URL) throws {
        try writeColors(vertices.map(\.color), to: url)
    }

    static func writePoints(_ points: [Point3D], to url: URL) throws {
        let writer = try BufferedBinaryWriter(url: url)
        for (index, point) in points.enumerated() {
            if index % 4_096 == 0 { try Task.checkCancellation() }
            try writer.append(point.x)
            try writer.append(point.y)
            try writer.append(point.z)
        }
        try writer.finish()
    }

    static func writeColors(_ colors: [PointCloudColor?], to url: URL) throws {
        let writer = try BufferedBinaryWriter(url: url)
        for (index, color) in colors.enumerated() {
            if index % 4_096 == 0 { try Task.checkCancellation() }
            try writer.append(color?.red ?? 0)
            try writer.append(color?.green ?? 0)
            try writer.append(color?.blue ?? 0)
            try writer.append(UInt8(color == nil ? 0 : 1))
        }
        try writer.finish()
    }

    static func writeUInt32(_ values: [UInt32], to url: URL) throws {
        let writer = try BufferedBinaryWriter(url: url)
        for (index, value) in values.enumerated() {
            if index % 12_288 == 0 { try Task.checkCancellation() }
            try writer.append(value)
        }
        try writer.finish()
    }

    static func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            throw TSDFSurfaceExtractionError.ioFailure(error.localizedDescription)
        }
    }

    static func fileReference(at url: URL, relativePath: String) throws -> TSDFDerivedFileReference {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw TSDFSurfaceExtractionError.invalidStagingArtifact(relativePath)
        }
        return TSDFDerivedFileReference(
            relativePath: relativePath,
            byteCount: Int64(values.fileSize ?? 0),
            sha256: try sha256(for: url)
        )
    }

    static func verify(_ reference: TSDFDerivedFileReference, under directory: URL) throws {
        guard !reference.relativePath.isEmpty,
              !reference.relativePath.hasPrefix("/"),
              !reference.relativePath.contains("\\"),
              !reference.relativePath.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw TSDFSurfaceExtractionError.invalidStagingArtifact(reference.relativePath)
        }
        let url = directory.appending(path: reference.relativePath)
        let rootPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw TSDFSurfaceExtractionError.invalidStagingArtifact(reference.relativePath)
        }
        let actual = try fileReference(at: url, relativePath: reference.relativePath)
        guard actual == reference else {
            throw TSDFSurfaceExtractionError.invalidStagingArtifact(reference.relativePath)
        }
    }

    static func sha256(for url: URL) throws -> String {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            throw TSDFSurfaceExtractionError.ioFailure(error.localizedDescription)
        }
    }

    static func chunkDirectory(for key: TSDFSubmapKey, stagingDirectory: URL) -> URL {
        stagingDirectory.appending(path: "chunks", directoryHint: .isDirectory)
            .appending(path: chunkName(for: key), directoryHint: .isDirectory)
    }

    static func chunkName(for key: TSDFSubmapKey) -> String {
        "x_\(key.x)_y_\(key.y)_z_\(key.z)"
    }

    static func requireWritableLocation(_ writable: URL, outside source: URL) throws {
        let sourcePath = canonicalPath(for: source)
        let writablePath = canonicalPath(for: writable)
        guard writablePath != sourcePath, !writablePath.hasPrefix(sourcePath + "/") else {
            throw TSDFSurfaceExtractionError.invalidWritableLocation
        }
    }

    static func canonicalPath(for url: URL) -> String {
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existingAncestor.path),
              existingAncestor.pathComponents.count > 1 {
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor.deleteLastPathComponent()
        }
        var resolved = existingAncestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() { resolved.append(path: component) }
        return resolved.standardizedFileURL.path
    }
}

private extension TSDFSurfaceExtractionPipeline {
    static func adding(
        _ lhs: TSDFGlobalVoxelCoordinate,
        _ rhs: TSDFGlobalVoxelCoordinate
    ) -> TSDFGlobalVoxelCoordinate? {
        guard let x = checkedAdd(lhs.x, rhs.x),
              let y = checkedAdd(lhs.y, rhs.y),
              let z = checkedAdd(lhs.z, rhs.z)
        else { return nil }
        return TSDFGlobalVoxelCoordinate(x: x, y: y, z: z)
    }

    static func checkedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }

    static func checkedMultiply(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? nil : result.partialValue
    }

    static func checkedByteCount(_ count: Int, stride: Int) -> Int? {
        guard count >= 0, stride >= 0 else { return nil }
        let result = count.multipliedReportingOverflow(by: stride)
        return result.overflow ? nil : result.partialValue
    }

    static func validStatistics(_ statistics: TSDFSurfaceExtractionStatistics) -> Bool {
        statistics.processedSubmapCount >= 0
            && statistics.inspectedCellCount >= 0
            && statistics.sparseCellCount >= 0
            && statistics.invalidVoxelCellCount >= 0
            && statistics.emittedVertexOccurrenceCount >= 0
            && statistics.emittedTriangleCount >= 0
            && statistics.rejectedDegenerateTriangleCount >= 0
            && statistics.droppedSubmapCount >= 0
            && statistics.droppedVertexCount >= 0
            && statistics.droppedTriangleCount >= 0
    }

    static func voxelCenter(_ coordinate: TSDFGlobalVoxelCoordinate, voxelSize: Float) -> Point3D? {
        let size = Double(voxelSize)
        let x = (Double(coordinate.x) + 0.5) * size
        let y = (Double(coordinate.y) + 0.5) * size
        let z = (Double(coordinate.z) + 0.5) * size
        guard x.isFinite, y.isFinite, z.isFinite,
              abs(x) <= Double(Float.greatestFiniteMagnitude),
              abs(y) <= Double(Float.greatestFiniteMagnitude),
              abs(z) <= Double(Float.greatestFiniteMagnitude)
        else { return nil }
        return Point3D(x: Float(x), y: Float(y), z: Float(z))
    }

    static func lerp(_ first: Point3D, _ second: Point3D, t: Float) -> Point3D {
        Point3D(
            x: first.x + (second.x - first.x) * t,
            y: first.y + (second.y - first.y) * t,
            z: first.z + (second.z - first.z) * t
        )
    }

    static func add(_ lhs: Point3D, _ rhs: Point3D) -> Point3D {
        Point3D(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    static func subtract(_ lhs: Point3D, _ rhs: Point3D) -> Point3D {
        Point3D(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    static func cross(_ lhs: Point3D, _ rhs: Point3D) -> Point3D {
        Point3D(
            x: lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.z * rhs.x - lhs.x * rhs.z,
            z: lhs.x * rhs.y - lhs.y * rhs.x
        )
    }

    static func dot(_ lhs: Point3D, _ rhs: Point3D) -> Float {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    static func length(_ point: Point3D) -> Float {
        sqrt(dot(point, point))
    }

    static func normalized(_ point: Point3D) -> Point3D? {
        let magnitude = length(point)
        guard magnitude.isFinite, magnitude > 0 else { return nil }
        return Point3D(x: point.x / magnitude, y: point.y / magnitude, z: point.z / magnitude)
    }

    static func bounds(for points: [Point3D]) -> TSDFSurfaceBounds? {
        guard let first = points.first, TSDFSurfaceBounds.isFinite(first) else { return nil }
        var minimum = first
        var maximum = first
        for point in points.dropFirst() {
            guard TSDFSurfaceBounds.isFinite(point) else { return nil }
            minimum.x = min(minimum.x, point.x)
            minimum.y = min(minimum.y, point.y)
            minimum.z = min(minimum.z, point.z)
            maximum.x = max(maximum.x, point.x)
            maximum.y = max(maximum.y, point.y)
            maximum.z = max(maximum.z, point.z)
        }
        return try? TSDFSurfaceBounds(minimum: minimum, maximum: maximum)
    }
}

private struct UnionFind {
    private var parent: [Int]
    private var rank: [UInt8]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    mutating func find(_ value: Int) -> Int {
        if parent[value] != value { parent[value] = find(parent[value]) }
        return parent[value]
    }

    mutating func union(_ lhs: Int, _ rhs: Int) {
        let lhsRoot = find(lhs)
        let rhsRoot = find(rhs)
        guard lhsRoot != rhsRoot else { return }
        if rank[lhsRoot] < rank[rhsRoot] {
            parent[lhsRoot] = rhsRoot
        } else if rank[lhsRoot] > rank[rhsRoot] {
            parent[rhsRoot] = lhsRoot
        } else {
            parent[rhsRoot] = lhsRoot
            rank[lhsRoot] += 1
        }
    }
}

private final class BufferedBinaryWriter {
    private let handle: FileHandle
    private var buffer = Data()
    private var isFinished = false

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        buffer.reserveCapacity(65_536)
    }

    deinit {
        try? handle.close()
    }

    func append(_ value: UInt8) throws {
        buffer.append(value)
        try flushIfNeeded()
    }

    func append(_ value: UInt32) throws {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { buffer.append(contentsOf: $0) }
        try flushIfNeeded()
    }

    func append(_ value: Int64) throws {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { buffer.append(contentsOf: $0) }
        try flushIfNeeded()
    }

    func append(_ value: Float) throws {
        try append(value.bitPattern)
    }

    func finish() throws {
        guard !isFinished else { return }
        try flush()
        try handle.synchronize()
        try handle.close()
        isFinished = true
    }

    private func flushIfNeeded() throws {
        if buffer.count >= 65_536 { try flush() }
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}

private extension Data {
    func readUInt32LittleEndian(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func readInt64LittleEndian(at offset: Int) -> Int64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        var value: UInt64 = 0
        for byteOffset in 0..<8 {
            value |= UInt64(self[offset + byteOffset]) << UInt64(byteOffset * 8)
        }
        return Int64(bitPattern: value)
    }

    func readFloat32LittleEndian(at offset: Int) -> Float? {
        readUInt32LittleEndian(at: offset).map(Float.init(bitPattern:))
    }
}

private extension Array {
    func nilUnlessCount(_ expected: Int) -> Self? {
        count == expected ? self : nil
    }
}
