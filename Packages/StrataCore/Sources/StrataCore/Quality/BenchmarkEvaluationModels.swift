import Foundation

public enum BenchmarkMetricDisposition: String, Codable, Sendable {
    case passed
    case failed
    case unavailable
}

public enum BenchmarkScorecardDisposition: String, Codable, Sendable {
    case passed
    case failed
    case insufficientEvidence = "insufficient-evidence"
}

public struct BenchmarkEvaluationSafetyLimits: Codable, Equatable, Sendable {
    public static let `default` = BenchmarkEvaluationSafetyLimits(
        uncheckedMaximumGeometryBytes: 268_435_456,
        maximumVertices: 300_000,
        maximumTriangles: 600_000
    )

    private static let maximumAllowedGeometryBytes: Int64 = 268_435_456
    private static let maximumAllowedVertices = 300_000
    private static let maximumAllowedTriangles = 600_000

    public let maximumGeometryBytes: Int64
    public let maximumVertices: Int
    public let maximumTriangles: Int

    public init(
        maximumGeometryBytes: Int64,
        maximumVertices: Int,
        maximumTriangles: Int
    ) throws {
        guard (1...Self.maximumAllowedGeometryBytes).contains(maximumGeometryBytes),
              (1...Self.maximumAllowedVertices).contains(maximumVertices),
              (1...Self.maximumAllowedTriangles).contains(maximumTriangles) else {
            throw BenchmarkEvaluationError.geometryInvalid("Evaluation safety limits exceed the evaluator contract.")
        }
        self.maximumGeometryBytes = maximumGeometryBytes
        self.maximumVertices = maximumVertices
        self.maximumTriangles = maximumTriangles
    }

    private init(
        uncheckedMaximumGeometryBytes maximumGeometryBytes: Int64,
        maximumVertices: Int,
        maximumTriangles: Int
    ) {
        self.maximumGeometryBytes = maximumGeometryBytes
        self.maximumVertices = maximumVertices
        self.maximumTriangles = maximumTriangles
    }
}

public struct BenchmarkEvaluationThresholds: Codable, Equatable, Sendable {
    public static let initialCloseRange = BenchmarkEvaluationThresholds(
        surfaceMedianMeters: 0.03,
        surfaceP95Meters: 0.08,
        maximumDimensionRelativeError: 0.015,
        minimumObservedCompleteness: 0.90,
        maximumOutlierRatio: 0.02,
        maximumDisconnectedComponentRatio: 0.02,
        maximumBoundaryEdgeRatio: 0.05,
        minimumNormalConsistency: 0.90,
        minimumColorCoverage: 0.80,
        maximumReprojectionRMSEPixels: 2.0,
        maximumReprojectionOcclusionFailureRatio: 0,
        maximumVolumeRelativeError: 0.05,
        maximumProcessingSeconds: 600,
        maximumPeakMemoryBytes: 1_500_000_000,
        maximumStorageBytes: 4_000_000_000
    )

    public let surfaceMedianMeters: Double
    public let surfaceP95Meters: Double
    public let maximumDimensionRelativeError: Double
    public let minimumObservedCompleteness: Double
    public let maximumOutlierRatio: Double
    public let maximumDisconnectedComponentRatio: Double
    public let maximumBoundaryEdgeRatio: Double
    public let minimumNormalConsistency: Double
    public let minimumColorCoverage: Double
    public let maximumReprojectionRMSEPixels: Double
    public let maximumReprojectionOcclusionFailureRatio: Double
    public let maximumVolumeRelativeError: Double
    public let maximumProcessingSeconds: Double
    public let maximumPeakMemoryBytes: Int64
    public let maximumStorageBytes: Int64

    public init(
        surfaceMedianMeters: Double,
        surfaceP95Meters: Double,
        maximumDimensionRelativeError: Double,
        minimumObservedCompleteness: Double,
        maximumOutlierRatio: Double,
        maximumDisconnectedComponentRatio: Double,
        maximumBoundaryEdgeRatio: Double,
        minimumNormalConsistency: Double,
        minimumColorCoverage: Double,
        maximumReprojectionRMSEPixels: Double,
        maximumReprojectionOcclusionFailureRatio: Double,
        maximumVolumeRelativeError: Double,
        maximumProcessingSeconds: Double,
        maximumPeakMemoryBytes: Int64,
        maximumStorageBytes: Int64
    ) {
        self.surfaceMedianMeters = surfaceMedianMeters
        self.surfaceP95Meters = surfaceP95Meters
        self.maximumDimensionRelativeError = maximumDimensionRelativeError
        self.minimumObservedCompleteness = minimumObservedCompleteness
        self.maximumOutlierRatio = maximumOutlierRatio
        self.maximumDisconnectedComponentRatio = maximumDisconnectedComponentRatio
        self.maximumBoundaryEdgeRatio = maximumBoundaryEdgeRatio
        self.minimumNormalConsistency = minimumNormalConsistency
        self.minimumColorCoverage = minimumColorCoverage
        self.maximumReprojectionRMSEPixels = maximumReprojectionRMSEPixels
        self.maximumReprojectionOcclusionFailureRatio = maximumReprojectionOcclusionFailureRatio
        self.maximumVolumeRelativeError = maximumVolumeRelativeError
        self.maximumProcessingSeconds = maximumProcessingSeconds
        self.maximumPeakMemoryBytes = maximumPeakMemoryBytes
        self.maximumStorageBytes = maximumStorageBytes
    }
}

public struct BenchmarkEvaluationColor: Codable, Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct BenchmarkEvaluationVertex: Codable, Equatable, Sendable {
    public let position: BenchmarkVector3
    public let normal: BenchmarkVector3?
    public let color: BenchmarkEvaluationColor?

    public init(position: BenchmarkVector3, normal: BenchmarkVector3? = nil, color: BenchmarkEvaluationColor? = nil) {
        self.position = position
        self.normal = normal
        self.color = color
    }
}

public struct BenchmarkEvaluationTriangle: Codable, Equatable, Sendable {
    public let a: Int
    public let b: Int
    public let c: Int

    public init(a: Int, b: Int, c: Int) {
        self.a = a
        self.b = b
        self.c = c
    }
}

public struct BenchmarkEvaluationGeometry: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let coordinateFrame: String
    /// Column-major fixtureFromGeometry transform, in meters.
    public let fixtureFromGeometry: Transform4x4
    public let vertices: [BenchmarkEvaluationVertex]
    public let triangles: [BenchmarkEvaluationTriangle]

    public init(
        schemaVersion: Int = BenchmarkEvaluationGeometry.currentSchemaVersion,
        coordinateFrame: String,
        fixtureFromGeometry: Transform4x4,
        vertices: [BenchmarkEvaluationVertex],
        triangles: [BenchmarkEvaluationTriangle]
    ) {
        self.schemaVersion = schemaVersion
        self.coordinateFrame = coordinateFrame
        self.fixtureFromGeometry = fixtureFromGeometry
        self.vertices = vertices
        self.triangles = triangles
    }
}

public struct BenchmarkReprojectionSample: Codable, Equatable, Sendable {
    public let projectedX: Double
    public let projectedY: Double
    public let observedX: Double
    public let observedY: Double
    public let passedOcclusionTest: Bool

    public init(
        projectedX: Double,
        projectedY: Double,
        observedX: Double,
        observedY: Double,
        passedOcclusionTest: Bool
    ) {
        self.projectedX = projectedX
        self.projectedY = projectedY
        self.observedX = observedX
        self.observedY = observedY
        self.passedOcclusionTest = passedOcclusionTest
    }
}

public struct BenchmarkResourceObservation: Codable, Equatable, Sendable {
    public let processingSeconds: Double?
    public let peakMemoryBytes: Int64?
    public let storageBytes: Int64?

    public init(processingSeconds: Double?, peakMemoryBytes: Int64?, storageBytes: Int64?) {
        self.processingSeconds = processingSeconds
        self.peakMemoryBytes = peakMemoryBytes
        self.storageBytes = storageBytes
    }
}

public struct BenchmarkEvaluationRunManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let fixtureID: String
    public let fixtureVersion: Int
    public let sourcePackageSHA256: String
    public let reconstructionConfigurationSHA256: String
    public let buildCommit: String
    public let geometry: BenchmarkAssetReference
    public let resources: BenchmarkResourceObservation?
    public let reprojectionSamples: [BenchmarkReprojectionSample]
    public let warnings: [String]

    public init(
        schemaVersion: Int = BenchmarkEvaluationRunManifest.currentSchemaVersion,
        fixtureID: String,
        fixtureVersion: Int,
        sourcePackageSHA256: String,
        reconstructionConfigurationSHA256: String,
        buildCommit: String,
        geometry: BenchmarkAssetReference,
        resources: BenchmarkResourceObservation? = nil,
        reprojectionSamples: [BenchmarkReprojectionSample] = [],
        warnings: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.fixtureID = fixtureID
        self.fixtureVersion = fixtureVersion
        self.sourcePackageSHA256 = sourcePackageSHA256
        self.reconstructionConfigurationSHA256 = reconstructionConfigurationSHA256
        self.buildCommit = buildCommit
        self.geometry = geometry
        self.resources = resources
        self.reprojectionSamples = reprojectionSamples
        self.warnings = warnings
    }
}

public struct BenchmarkMetricResult: Codable, Equatable, Sendable {
    public let id: String
    public let disposition: BenchmarkMetricDisposition
    public let value: Double?
    public let unit: String?
    public let threshold: String
    public let detail: String

    public init(
        id: String,
        disposition: BenchmarkMetricDisposition,
        value: Double?,
        unit: String?,
        threshold: String,
        detail: String
    ) {
        self.id = id
        self.disposition = disposition
        self.value = value
        self.unit = unit
        self.threshold = threshold
        self.detail = detail
    }
}

public struct BenchmarkFixedViewArtifact: Codable, Equatable, Sendable {
    public let cameraID: String
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String
}

public struct BenchmarkEvaluationScorecard: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let evaluatorVersion = "r0.3-v1"

    public let schemaVersion: Int
    public let evaluatorVersion: String
    public let fixtureID: String
    public let fixtureVersion: Int
    public let fixtureManifestSHA256: String
    public let referenceGeometrySHA256: String?
    public let sourcePackageSHA256: String
    public let reconstructionConfigurationSHA256: String
    public let candidateGeometrySHA256: String
    public let buildCommit: String
    public let disposition: BenchmarkScorecardDisposition
    public let thresholds: BenchmarkEvaluationThresholds
    public let metrics: [BenchmarkMetricResult]
    public let warnings: [String]
    public let fixedViews: [BenchmarkFixedViewArtifact]

    public func metric(_ id: String) -> BenchmarkMetricResult? {
        metrics.first(where: { $0.id == id })
    }

    public func stableJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum BenchmarkEvaluationError: Error, Equatable, Sendable {
    case unsafeDirectory
    case fixtureNotValid
    case manifestMissing
    case manifestUnreadable
    case runIdentityMismatch
    case unsafeAsset
    case assetIntegrityFailed
    case geometryUnreadable
    case geometryInvalid(String)
    case referenceUnavailable
    case outputFailure(String)
}
