import Foundation

public enum ScanStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case capturing
    case processing
    case completed
    case failed
    case corrupted
    case deleted
}

public enum AssetKind: String, Codable, CaseIterable, Sendable {
    case video
    case frameMetadata
    case pointCloud
    case meshRaw
    case meshProcessed
    case semanticRoom
    case textureSource
    case gisLayer
    case alignment
    case thumbnail
    case manifestAttachment
}

public enum SpatialReferenceKind: String, Codable, CaseIterable, Sendable {
    case scanLocal
    case arWorld
    case geographicWGS84
}

public enum SynchronizationStatus: String, Codable, CaseIterable, Sendable {
    case localOnly
    case pendingUpload
    case uploading
    case synced
    case modified
    case conflict
    case failed
    case pendingDeletion
}

public struct SourceDeviceInfo: Codable, Equatable, Sendable {
    public var modelIdentifier: String
    public var operatingSystemVersion: String
    public var appVersion: String
    public var operatingSystemBuild: String?
    public var appBuildCommit: String?

    public init(
        modelIdentifier: String = "unknown",
        operatingSystemVersion: String = "unknown",
        appVersion: String = "unknown",
        operatingSystemBuild: String? = nil,
        appBuildCommit: String? = nil
    ) {
        self.modelIdentifier = modelIdentifier
        self.operatingSystemVersion = operatingSystemVersion
        self.appVersion = appVersion
        self.operatingSystemBuild = operatingSystemBuild
        self.appBuildCommit = appBuildCommit
    }
}

public struct CaptureStatistics: Codable, Equatable, Sendable {
    public var sampledFrameCount: Int
    public var featurePointCount: Int
    public var depthPointCount: Int
    public var meshVertexCount: Int
    public var meshFaceCount: Int

    public init(sampledFrameCount: Int = 0, featurePointCount: Int = 0, depthPointCount: Int = 0, meshVertexCount: Int = 0, meshFaceCount: Int = 0) {
        self.sampledFrameCount = sampledFrameCount
        self.featurePointCount = featurePointCount
        self.depthPointCount = depthPointCount
        self.meshVertexCount = meshVertexCount
        self.meshFaceCount = meshFaceCount
    }
}

public struct SyncMetadata: Codable, Equatable, Sendable {
    public var status: SynchronizationStatus
    public var remoteID: String?
    public var revision: String?
    public var retryCount: Int
    public var lastError: String?

    public init(status: SynchronizationStatus = .localOnly, remoteID: String? = nil, revision: String? = nil, retryCount: Int = 0, lastError: String? = nil) {
        self.status = status
        self.remoteID = remoteID
        self.revision = revision
        self.retryCount = retryCount
        self.lastError = lastError
    }
}

public struct ProcessingMetadata: Codable, Equatable, Sendable {
    public var pipelineVersion: String
    public var textureProjectionStatus: String

    public init(pipelineVersion: String = "1", textureProjectionStatus: String = "sourceOnly") {
        self.pipelineVersion = pipelineVersion
        self.textureProjectionStatus = textureProjectionStatus
    }
}

public struct ScanAssetReference: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: AssetKind
    public var relativePath: String
    public var byteCount: Int64
    public var sha256: String
    public var spatialReference: SpatialReferenceKind
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: AssetKind, relativePath: String, byteCount: Int64, sha256: String, spatialReference: SpatialReferenceKind = .scanLocal, createdAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.spatialReference = spatialReference
        self.createdAt = createdAt
    }
}

/// App-owned package metadata. Large payloads are always referenced externally.
public struct ScanPackageManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var localScanID: UUID
    public var remoteScanID: String?
    public var status: ScanStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var durationSeconds: TimeInterval?
    public var sourceDevice: SourceDeviceInfo
    public var coordinateSystem: String
    public var cameraMetadataDescription: String
    public var captureStatistics: CaptureStatistics
    /// Optional because packages created before capture-quality telemetry was
    /// introduced remain readable and must not be assigned invented values.
    public var qualitySignals: ScanQualitySignals?
    /// Internal capture-path counters. These explain selection and pressure;
    /// they are not a user-facing quality, coverage, or accuracy score.
    public var captureTelemetry: CaptureTelemetry?
    public var assets: [ScanAssetReference]
    public var sync: SyncMetadata
    public var processing: ProcessingMetadata

    public init(
        schemaVersion: Int = ScanPackageManifest.currentSchemaVersion,
        localScanID: UUID,
        remoteScanID: String? = nil,
        status: ScanStatus,
        createdAt: Date,
        updatedAt: Date,
        durationSeconds: TimeInterval? = nil,
        sourceDevice: SourceDeviceInfo = SourceDeviceInfo(),
        coordinateSystem: String = "ARKit right-handed meters; column-major worldFromLocal",
        cameraMetadataDescription: String = "Sampled frame metadata and calibrated RGB-D keyframes record intrinsics and worldFromCamera.",
        captureStatistics: CaptureStatistics = CaptureStatistics(),
        qualitySignals: ScanQualitySignals? = nil,
        captureTelemetry: CaptureTelemetry? = nil,
        assets: [ScanAssetReference] = [],
        sync: SyncMetadata = SyncMetadata(),
        processing: ProcessingMetadata = ProcessingMetadata()
    ) {
        self.schemaVersion = schemaVersion
        self.localScanID = localScanID
        self.remoteScanID = remoteScanID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.durationSeconds = durationSeconds
        self.sourceDevice = sourceDevice
        self.coordinateSystem = coordinateSystem
        self.cameraMetadataDescription = cameraMetadataDescription
        self.captureStatistics = captureStatistics
        self.qualitySignals = qualitySignals
        self.captureTelemetry = captureTelemetry
        self.assets = assets
        self.sync = sync
        self.processing = processing
    }
}

public struct ScanMetadata: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var status: ScanStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var durationSeconds: TimeInterval?
    public var remoteID: String?

    public init(id: UUID, displayName: String, status: ScanStatus, createdAt: Date, updatedAt: Date, durationSeconds: TimeInterval? = nil, remoteID: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.durationSeconds = durationSeconds
        self.remoteID = remoteID
    }
}

public enum AssetInputSource: Sendable {
    case data(Data)
    case file(URL)
}

public struct AssetInput: Sendable {
    public var kind: AssetKind
    public var relativePath: String
    public var source: AssetInputSource
    public var spatialReference: SpatialReferenceKind

    public init(kind: AssetKind, relativePath: String, data: Data, spatialReference: SpatialReferenceKind = .scanLocal) {
        self.kind = kind
        self.relativePath = relativePath
        source = .data(data)
        self.spatialReference = spatialReference
    }

    public init(kind: AssetKind, relativePath: String, fileURL: URL, spatialReference: SpatialReferenceKind = .scanLocal) {
        self.kind = kind
        self.relativePath = relativePath
        source = .file(fileURL)
        self.spatialReference = spatialReference
    }
}

public enum PackageIntegrityFailure: Equatable, Sendable {
    case manifestMissing
    case manifestUnreadable
    case manifestIDMismatch
    case unsafePath(path: String)
    case duplicatePath(path: String)
    case assetMissing(path: String)
    case byteCountMismatch(path: String)
    case checksumMismatch(path: String)
}

public struct PackageIntegrityReport: Equatable, Sendable {
    public var scanID: UUID
    public var failures: [PackageIntegrityFailure]

    public init(scanID: UUID, failures: [PackageIntegrityFailure] = []) {
        self.scanID = scanID
        self.failures = failures
    }

    public var isValid: Bool { failures.isEmpty }
}

public struct StoredScan: Sendable {
    public var scan: ScanMetadata
    public var manifest: ScanPackageManifest
    public var integrity: PackageIntegrityReport

    public init(scan: ScanMetadata, manifest: ScanPackageManifest, integrity: PackageIntegrityReport) {
        self.scan = scan
        self.manifest = manifest
        self.integrity = integrity
    }
}

public enum AssetStoreError: Error, Equatable, Sendable {
    case unsafeRelativePath(String)
    case duplicateRelativePath(String)
    case packageAlreadyExists(UUID)
    case packageNotFound(UUID)
    case manifestScanIDMismatch
    case invalidAssetSource(URL)
    case ioFailure(String)
}
