import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

public enum PublicRGBDBenchmarkDataset: String, Codable, Sendable {
    case arkitScenesRawV1 = "arkitscenes-raw-v1"
}

public enum PublicRGBDTrajectoryConvention: String, Codable, Sendable {
    /// ARKitScenes `.traj`: timestamp, world-to-camera axis-angle radians, and
    /// world-to-camera translation metres. Import converts this explicitly to
    /// StrataScan's column-major `worldFromCamera` contract.
    case worldToCameraAxisAngleRadians
}

public enum PublicRGBDCameraCoordinateConvention: String, Codable, Sendable {
    /// Historical StrataScan public-import behavior. The inverted trajectory is
    /// consumed directly by the production negative-XYZ depth unprojector.
    /// Retained only so schema-v1 manifests remain exactly reproducible.
    case legacyStrataNegativeXYZ

    /// ARKitScenes' official loader convention: optical +X right, +Y down and
    /// +Z forward. Intake converts this basis explicitly before the unchanged
    /// production depth unprojector consumes the pose.
    case opticalPositiveXYZ
}

public enum PublicRGBDAssetKind: String, Codable, Sendable {
    case colorPNG
    case depthMillimetersUInt16PNG
    case confidenceUInt8PNG
    case cameraIntrinsics
    case cameraTrajectory
    case referenceGeometry
}

public struct PublicRGBDAssetIdentity: Codable, Equatable, Sendable {
    public let kind: PublicRGBDAssetKind
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String

    public init(kind: PublicRGBDAssetKind, relativePath: String, byteCount: Int64, sha256: String) {
        self.kind = kind
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct PublicRGBDSelectedFrame: Codable, Equatable, Sendable {
    public let timestamp: TimeInterval
    public let colorPath: String
    public let depthPath: String
    public let confidencePath: String
    public let intrinsicsPath: String

    public init(
        timestamp: TimeInterval,
        colorPath: String,
        depthPath: String,
        confidencePath: String,
        intrinsicsPath: String
    ) {
        self.timestamp = timestamp
        self.colorPath = colorPath
        self.depthPath = depthPath
        self.confidencePath = confidencePath
        self.intrinsicsPath = intrinsicsPath
    }
}

public struct PublicRGBDBenchmarkIntakeManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let intakeID: String
    public let dataset: PublicRGBDBenchmarkDataset
    public let datasetRevision: String
    public let sourceURL: String
    public let licenseURL: String
    public let licenseTermsAccepted: Bool
    public let localEvaluationOnly: Bool
    public let split: String
    public let sceneID: String
    public let outputScanID: UUID
    public let capturedAt: Date
    public let trajectoryPath: String
    public let trajectoryConvention: PublicRGBDTrajectoryConvention
    public let cameraCoordinateConvention: PublicRGBDCameraCoordinateConvention?
    public let maximumPoseTimestampDeltaSeconds: TimeInterval
    public let frames: [PublicRGBDSelectedFrame]
    public let assets: [PublicRGBDAssetIdentity]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        intakeID: String,
        dataset: PublicRGBDBenchmarkDataset,
        datasetRevision: String,
        sourceURL: String,
        licenseURL: String,
        licenseTermsAccepted: Bool,
        localEvaluationOnly: Bool,
        split: String,
        sceneID: String,
        outputScanID: UUID,
        capturedAt: Date,
        trajectoryPath: String,
        trajectoryConvention: PublicRGBDTrajectoryConvention,
        cameraCoordinateConvention: PublicRGBDCameraCoordinateConvention? = .opticalPositiveXYZ,
        maximumPoseTimestampDeltaSeconds: TimeInterval,
        frames: [PublicRGBDSelectedFrame],
        assets: [PublicRGBDAssetIdentity]
    ) {
        self.schemaVersion = schemaVersion
        self.intakeID = intakeID
        self.dataset = dataset
        self.datasetRevision = datasetRevision
        self.sourceURL = sourceURL
        self.licenseURL = licenseURL
        self.licenseTermsAccepted = licenseTermsAccepted
        self.localEvaluationOnly = localEvaluationOnly
        self.split = split
        self.sceneID = sceneID
        self.outputScanID = outputScanID
        self.capturedAt = capturedAt
        self.trajectoryPath = trajectoryPath
        self.trajectoryConvention = trajectoryConvention
        self.cameraCoordinateConvention = cameraCoordinateConvention
        self.maximumPoseTimestampDeltaSeconds = maximumPoseTimestampDeltaSeconds
        self.frames = frames
        self.assets = assets
    }
}

private extension PublicRGBDBenchmarkIntakeManifest {
    var resolvedCameraCoordinateConvention: PublicRGBDCameraCoordinateConvention {
        cameraCoordinateConvention ?? .legacyStrataNegativeXYZ
    }
}

public struct PublicRGBDBenchmarkProvenance: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let importerVersion = "R0-audit-public-rgbd-v2"

    public let schemaVersion: Int
    public let importerVersion: String
    public let sourceManifestSHA256: String
    public let dataset: PublicRGBDBenchmarkDataset
    public let datasetRevision: String
    public let sourceURL: String
    public let licenseURL: String
    public let split: String
    public let sceneID: String
    public let trajectoryConvention: PublicRGBDTrajectoryConvention
    public let cameraCoordinateConvention: PublicRGBDCameraCoordinateConvention
    public let selectedFrameCount: Int
    public let sourceAssetSetSHA256: String
    public let referenceGeometry: PublicRGBDAssetIdentity?

    public init(
        sourceManifestSHA256: String,
        manifest: PublicRGBDBenchmarkIntakeManifest,
        sourceAssetSetSHA256: String,
        referenceGeometry: PublicRGBDAssetIdentity?
    ) {
        schemaVersion = Self.currentSchemaVersion
        importerVersion = Self.importerVersion
        self.sourceManifestSHA256 = sourceManifestSHA256
        dataset = manifest.dataset
        datasetRevision = manifest.datasetRevision
        sourceURL = manifest.sourceURL
        licenseURL = manifest.licenseURL
        split = manifest.split
        sceneID = manifest.sceneID
        trajectoryConvention = manifest.trajectoryConvention
        cameraCoordinateConvention = manifest.resolvedCameraCoordinateConvention
        selectedFrameCount = manifest.frames.count
        self.sourceAssetSetSHA256 = sourceAssetSetSHA256
        self.referenceGeometry = referenceGeometry
    }
}

public struct PublicRGBDBenchmarkIntakeReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let importerVersion: String
    public let intakeID: String
    public let datasetID: String
    public let sceneID: String
    public let outputScanID: UUID
    public let cameraCoordinateConvention: PublicRGBDCameraCoordinateConvention
    public let packageRelativePath: String
    public let selectedFrameCount: Int
    public let validDepthSampleCount: Int
    public let canonicalSpatialRecordCount: Int
    public let sourceManifestSHA256: String
    public let sourceAssetSetSHA256: String
    public let referenceGeometrySHA256: String?
    public let mutatedOutput: Bool
    public let evidenceLevel: String
    public let limitations: [String]

    public func stableJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum PublicRGBDBenchmarkIntakeError: Error, Equatable {
    case unsafeSourceRoot
    case unsafeOutputRoot
    case malformedManifest
    case invalidManifest(String)
    case unsafeAsset(String)
    case assetIntegrityMismatch(String)
    case unsupportedImage(String)
    case invalidIntrinsics(String)
    case invalidTrajectory
    case poseUnavailable(TimeInterval)
    case outputConflict(UUID)
    case packageValidationFailed
    case ioFailure(String)
}

public struct PublicRGBDBenchmarkIntake: Sendable {
    public static let provenanceRelativePath = "benchmark/public-intake.json"
    public static let maximumManifestBytes: Int64 = 1_048_576
    public static let maximumAssetBytes: Int64 = 67_108_864
    public static let maximumFrames = 1_200
    public static let maximumTrajectoryEntries = 250_000

    public init() {}

    public func importDataset(
        manifestURL: URL,
        sourceRoot: URL,
        outputRoot: URL
    ) async throws -> PublicRGBDBenchmarkIntakeReport {
        try Task.checkCancellation()
        let source = try safeDirectory(sourceRoot, failure: .unsafeSourceRoot)
        let output = try ensuredOutputDirectory(outputRoot)
        let manifestData = try boundedRegularFileData(
            manifestURL,
            maximumBytes: Self.maximumManifestBytes,
            failure: .malformedManifest
        )
        let manifest: PublicRGBDBenchmarkIntakeManifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(PublicRGBDBenchmarkIntakeManifest.self, from: manifestData)
        } catch {
            throw PublicRGBDBenchmarkIntakeError.malformedManifest
        }
        try validate(manifest)
        let sourceManifestSHA256 = digest(manifestData)
        let assetsByPath = try validateAssets(manifest.assets, sourceRoot: source)
        try validateFrameAssets(manifest, assetsByPath: assetsByPath)
        let sourceAssetSetSHA256 = assetSetDigest(manifest.assets)
        let reference = manifest.assets.first(where: { $0.kind == .referenceGeometry })
        let provenance = PublicRGBDBenchmarkProvenance(
            sourceManifestSHA256: sourceManifestSHA256,
            manifest: manifest,
            sourceAssetSetSHA256: sourceAssetSetSHA256,
            referenceGeometry: reference
        )
        let provenanceData = try stableJSON(provenance)
        let store = try FileAssetStore(rootURL: output)

        if await store.packageExists(id: manifest.outputScanID) {
            return try await existingReport(
                store: store,
                manifest: manifest,
                sourceManifestSHA256: sourceManifestSHA256,
                sourceAssetSetSHA256: sourceAssetSetSHA256,
                reference: reference,
                expectedProvenance: provenanceData
            )
        }

        let trajectoryURL = try assetURL(
            sourceRoot: source,
            relativePath: manifest.trajectoryPath,
            expectedKind: .cameraTrajectory,
            assetsByPath: assetsByPath
        )
        let trajectory = try parseTrajectory(trajectoryURL, convention: manifest.trajectoryConvention)
        let workingRoot = output.appending(path: "public-import-staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workingRoot, withIntermediateDirectories: true)
        let working = workingRoot.appending(
            path: "\(manifest.outputScanID.uuidString).\(UUID().uuidString).partial",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: working) }

        let writer = try CalibratedRGBDKeyframeArchiveWriter(workingDirectory: working)
        let canonicalStore = try CanonicalSpatialChunkStore(
            destinationURL: working.appending(path: CanonicalSpatialChunkStore.relativePath)
        )
        let pointCloudGenerator = DepthPointCloudGenerator(
            minimumConfidence: 1,
            samplingStride: 4,
            maximumPointsPerFrame: 3_000
        )
        var validDepthSampleCount = 0
        var canonicalSpatialRecordCount = 0
        do {
            for frame in manifest.frames {
                try Task.checkCancellation()
                let depthImage = try decodeUInt16Grayscale(
                    try assetURL(
                        sourceRoot: source,
                        relativePath: frame.depthPath,
                        expectedKind: .depthMillimetersUInt16PNG,
                        assetsByPath: assetsByPath
                    )
                )
                let confidenceImage = try decodeUInt8Grayscale(
                    try assetURL(
                        sourceRoot: source,
                        relativePath: frame.confidencePath,
                        expectedKind: .confidenceUInt8PNG,
                        assetsByPath: assetsByPath
                    )
                )
                guard confidenceImage.width == depthImage.width,
                      confidenceImage.height == depthImage.height,
                      confidenceImage.values.allSatisfy({ $0 <= 2 }) else {
                    throw PublicRGBDBenchmarkIntakeError.unsupportedImage(frame.confidencePath)
                }
                let colorURL = try assetURL(
                    sourceRoot: source,
                    relativePath: frame.colorPath,
                    expectedKind: .colorPNG,
                    assetsByPath: assetsByPath
                )
                let color = try decodeRGB(
                    colorURL,
                    targetWidth: depthImage.width,
                    targetHeight: depthImage.height
                )
                let intrinsics = try parseIntrinsics(
                    try assetURL(
                        sourceRoot: source,
                        relativePath: frame.intrinsicsPath,
                        expectedKind: .cameraIntrinsics,
                        assetsByPath: assetsByPath
                    )
                )
                guard color.sourceWidth == intrinsics.imageWidth,
                      color.sourceHeight == intrinsics.imageHeight
                else {
                    throw PublicRGBDBenchmarkIntakeError.invalidIntrinsics(frame.intrinsicsPath)
                }
                let sourcePose = try nearestPose(
                    timestamp: frame.timestamp,
                    trajectory: trajectory,
                    maximumDelta: manifest.maximumPoseTimestampDeltaSeconds
                )
                let pose = (
                    timestamp: sourcePose.timestamp,
                    worldFromCamera: try Self.normalizedWorldFromCamera(
                        sourcePose.worldFromCamera,
                        convention: manifest.resolvedCameraCoordinateConvention
                    )
                )
                let depthMeters = depthImage.values.map { Float($0) / 1_000 }
                validDepthSampleCount += depthImage.values.lazy.filter { $0 > 0 }.count
                let metadata = FrameMetadata(
                    timestamp: frame.timestamp,
                    videoTimestamp: nil,
                    imageWidth: intrinsics.imageWidth,
                    imageHeight: intrinsics.imageHeight,
                    intrinsics: intrinsics,
                    worldFromCamera: pose.worldFromCamera,
                    tracking: .normal,
                    worldMapping: .mapped,
                    isTextureSourceCandidate: true
                )
                let depth = DepthFrameSample(
                    width: depthImage.width,
                    height: depthImage.height,
                    depthMeters: depthMeters,
                    confidence: confidenceImage.values,
                    observedColors: color.colors.map(Optional.some),
                    calibration: intrinsics,
                    worldFromCamera: pose.worldFromCamera,
                    timestamp: frame.timestamp
                )
                let canonicalSamples = try pointCloudGenerator.generate(from: depth).map { point in
                    RGBDPointSample(
                        depthPoint: point,
                        color: depth.observedColor(at: point.sourcePixel)
                    )
                }
                canonicalSpatialRecordCount += try await canonicalStore.append(canonicalSamples)
                let contract = CaptureEvidenceContract(
                    source: .publicRGBDDataset,
                    depthSource: .externalDepth,
                    rgbSource: .externalColorResampledToDepthGrid,
                    synchronization: .sourceTimestampMatched,
                    timestamps: CaptureEvidenceTimestamps(
                        capture: frame.timestamp,
                        cameraImage: frame.timestamp,
                        depth: frame.timestamp,
                        confidence: frame.timestamp,
                        pose: pose.timestamp,
                        maximumSourceDeltaSeconds: manifest.maximumPoseTimestampDeltaSeconds
                    ),
                    cameraImageWidth: intrinsics.imageWidth,
                    cameraImageHeight: intrinsics.imageHeight,
                    depthWidth: depthImage.width,
                    depthHeight: depthImage.height,
                    exposure: .unavailable,
                    acceptanceEvidence: nil
                )
                try await writer.append(CalibratedRGBDKeyframeSample(
                    metadata: metadata,
                    depth: depth,
                    acceptanceReason: .externalSourceSelection,
                    evidence: nil,
                    evidenceContract: contract
                ))
            }
            _ = try await writer.finish()
            _ = try await canonicalStore.finish()
        } catch {
            await writer.cancel()
            await canonicalStore.cancel()
            throw error
        }

        var inputs = try archiveInputs(at: working)
        inputs.append(AssetInput(
            kind: .manifestAttachment,
            relativePath: Self.provenanceRelativePath,
            data: provenanceData,
            spatialReference: .arWorld
        ))
        let duration = manifest.frames.last.map { $0.timestamp - manifest.frames[0].timestamp }
        let packageManifest = ScanPackageManifest(
            localScanID: manifest.outputScanID,
            status: .completed,
            createdAt: manifest.capturedAt,
            updatedAt: manifest.capturedAt,
            durationSeconds: duration,
            sourceDevice: SourceDeviceInfo(
                modelIdentifier: "ARKitScenes/\(manifest.sceneID)",
                operatingSystemVersion: "dataset-\(manifest.split)",
                appVersion: PublicRGBDBenchmarkProvenance.importerVersion
            ),
            coordinateSystem: "ARKitScenes world; right-handed meters; column-major normalized worldFromCamera; source camera basis \(manifest.resolvedCameraCoordinateConvention.rawValue)",
            cameraMetadataDescription: "Public ARKitScenes RGB-D replay converted from checksum-bound selected source frames.",
            captureStatistics: CaptureStatistics(
                sampledFrameCount: manifest.frames.count,
                depthPointCount: validDepthSampleCount
            )
        )
        do {
            _ = try await store.finalize(manifest: packageManifest, assets: inputs)
            let integrity = try await store.validatePackage(id: manifest.outputScanID)
            guard integrity.isValid else { throw PublicRGBDBenchmarkIntakeError.packageValidationFailed }
            let packageURL = try await store.packageURL(for: manifest.outputScanID)
            let finalizedManifest = try await store.loadManifest(id: manifest.outputScanID)
            _ = try CalibratedRGBDKeyframeArchiveReader().open(
                packageURL: packageURL,
                manifest: finalizedManifest,
                integrity: integrity
            )
        } catch let error as PublicRGBDBenchmarkIntakeError {
            throw error
        } catch {
            throw PublicRGBDBenchmarkIntakeError.ioFailure(error.localizedDescription)
        }

        return makeReport(
            manifest: manifest,
            validDepthSampleCount: validDepthSampleCount,
            canonicalSpatialRecordCount: canonicalSpatialRecordCount,
            sourceManifestSHA256: sourceManifestSHA256,
            sourceAssetSetSHA256: sourceAssetSetSHA256,
            reference: reference,
            mutated: true
        )
    }

    private func validate(_ manifest: PublicRGBDBenchmarkIntakeManifest) throws {
        let timestamps = manifest.frames.map(\.timestamp)
        guard (1...PublicRGBDBenchmarkIntakeManifest.currentSchemaVersion).contains(manifest.schemaVersion),
              (manifest.schemaVersion == 1 || manifest.cameraCoordinateConvention != nil),
              !manifest.intakeID.isEmpty,
              !manifest.datasetRevision.isEmpty,
              manifest.sourceURL == "https://github.com/apple/ARKitScenes",
              manifest.licenseURL == "https://github.com/apple/ARKitScenes/blob/main/LICENSE",
              manifest.licenseTermsAccepted,
              manifest.localEvaluationOnly,
              !manifest.split.isEmpty,
              !manifest.sceneID.isEmpty,
              manifest.maximumPoseTimestampDeltaSeconds.isFinite,
              manifest.maximumPoseTimestampDeltaSeconds >= 0,
              !manifest.frames.isEmpty,
              manifest.frames.count <= Self.maximumFrames,
              timestamps.allSatisfy(\.isFinite),
              zip(timestamps, timestamps.dropFirst()).allSatisfy(<),
              manifest.assets.count <= Self.maximumFrames * 4 + 2,
              manifest.assets.filter({ $0.kind == .cameraTrajectory }).count == 1,
              manifest.assets.filter({ $0.kind == .referenceGeometry }).count <= 1 else {
            throw PublicRGBDBenchmarkIntakeError.invalidManifest("public RGB-D contract")
        }
        guard Set(manifest.assets.map(\.relativePath)).count == manifest.assets.count else {
            throw PublicRGBDBenchmarkIntakeError.invalidManifest("duplicate source asset")
        }
    }

    private func validateAssets(
        _ assets: [PublicRGBDAssetIdentity],
        sourceRoot: URL
    ) throws -> [String: PublicRGBDAssetIdentity] {
        var result: [String: PublicRGBDAssetIdentity] = [:]
        for asset in assets.sorted(by: { $0.relativePath < $1.relativePath }) {
            try Task.checkCancellation()
            guard asset.byteCount >= 0,
                  asset.byteCount <= Self.maximumAssetBytes,
                  isSHA256(asset.sha256),
                  isSafeRelativePath(asset.relativePath) else {
                throw PublicRGBDBenchmarkIntakeError.unsafeAsset(asset.relativePath)
            }
            let url = try containedRegularFile(sourceRoot: sourceRoot, relativePath: asset.relativePath)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard Int64(values.fileSize ?? -1) == asset.byteCount,
                  try digest(url) == asset.sha256.lowercased() else {
                throw PublicRGBDBenchmarkIntakeError.assetIntegrityMismatch(asset.relativePath)
            }
            result[asset.relativePath] = asset
        }
        return result
    }

    private func validateFrameAssets(
        _ manifest: PublicRGBDBenchmarkIntakeManifest,
        assetsByPath: [String: PublicRGBDAssetIdentity]
    ) throws {
        guard assetsByPath[manifest.trajectoryPath]?.kind == .cameraTrajectory else {
            throw PublicRGBDBenchmarkIntakeError.invalidManifest("trajectory asset")
        }
        for frame in manifest.frames {
            let expected: [(String, PublicRGBDAssetKind)] = [
                (frame.colorPath, .colorPNG),
                (frame.depthPath, .depthMillimetersUInt16PNG),
                (frame.confidencePath, .confidenceUInt8PNG),
                (frame.intrinsicsPath, .cameraIntrinsics)
            ]
            for (path, kind) in expected where assetsByPath[path]?.kind != kind {
                throw PublicRGBDBenchmarkIntakeError.invalidManifest("frame asset \(path)")
            }
        }
    }

    private func existingReport(
        store: FileAssetStore,
        manifest: PublicRGBDBenchmarkIntakeManifest,
        sourceManifestSHA256: String,
        sourceAssetSetSHA256: String,
        reference: PublicRGBDAssetIdentity?,
        expectedProvenance: Data
    ) async throws -> PublicRGBDBenchmarkIntakeReport {
        let integrity = try await store.validatePackage(id: manifest.outputScanID)
        let packageURL = try await store.packageURL(for: manifest.outputScanID)
        let existingManifest = try await store.loadManifest(id: manifest.outputScanID)
        guard integrity.isValid,
              let referenceAsset = existingManifest.assets.first(where: {
                  $0.relativePath == Self.provenanceRelativePath
              }),
              referenceAsset.byteCount == expectedProvenance.count,
              referenceAsset.sha256 == digest(expectedProvenance),
              try Data(contentsOf: packageURL.appending(path: Self.provenanceRelativePath)) == expectedProvenance else {
            throw PublicRGBDBenchmarkIntakeError.outputConflict(manifest.outputScanID)
        }
        let archive = try CalibratedRGBDKeyframeArchiveReader().open(
            packageURL: packageURL,
            manifest: existingManifest,
            integrity: integrity
        )
        var validDepthSamples = 0
        for index in archive.records.indices {
            try Task.checkCancellation()
            validDepthSamples += try archive.readKeyframe(at: index).depth.depthMeters.lazy.filter {
                $0.isFinite && $0 > 0
            }.count
        }
        let canonical = try CanonicalSpatialChunkReader().open(
            packageURL: packageURL,
            manifest: existingManifest,
            integrity: integrity
        )
        return makeReport(
            manifest: manifest,
            validDepthSampleCount: validDepthSamples,
            canonicalSpatialRecordCount: canonical.recordCount,
            sourceManifestSHA256: sourceManifestSHA256,
            sourceAssetSetSHA256: sourceAssetSetSHA256,
            reference: reference,
            mutated: false
        )
    }

    private func makeReport(
        manifest: PublicRGBDBenchmarkIntakeManifest,
        validDepthSampleCount: Int,
        canonicalSpatialRecordCount: Int,
        sourceManifestSHA256: String,
        sourceAssetSetSHA256: String,
        reference: PublicRGBDAssetIdentity?,
        mutated: Bool
    ) -> PublicRGBDBenchmarkIntakeReport {
        PublicRGBDBenchmarkIntakeReport(
            schemaVersion: PublicRGBDBenchmarkIntakeReport.currentSchemaVersion,
            importerVersion: PublicRGBDBenchmarkProvenance.importerVersion,
            intakeID: manifest.intakeID,
            datasetID: manifest.dataset.rawValue,
            sceneID: manifest.sceneID,
            outputScanID: manifest.outputScanID,
            cameraCoordinateConvention: manifest.resolvedCameraCoordinateConvention,
            packageRelativePath: "packages/\(manifest.outputScanID.uuidString)",
            selectedFrameCount: manifest.frames.count,
            validDepthSampleCount: validDepthSampleCount,
            canonicalSpatialRecordCount: canonicalSpatialRecordCount,
            sourceManifestSHA256: sourceManifestSHA256,
            sourceAssetSetSHA256: sourceAssetSetSHA256,
            referenceGeometrySHA256: reference?.sha256.lowercased(),
            mutatedOutput: mutated,
            evidenceLevel: reference == nil ? "E1" : "E2-input-ready",
            limitations: [
                "Import proves identity, decoding, calibration, pose conversion, canonical-sample persistence, and replay readability; it does not prove reconstruction quality.",
                "The declared public camera basis is normalized only at the public intake boundary; this does not change or qualify physical ARKit capture coordinates.",
                "Public benchmark evidence is not a competitor-app comparison and cannot support a named competitive claim.",
                "Dataset assets remain local-only and are not redistributed by the repository or shipped application."
            ]
        )
    }

    private func parseTrajectory(
        _ url: URL,
        convention: PublicRGBDTrajectoryConvention
    ) throws -> [(timestamp: TimeInterval, worldFromCamera: Transform4x4)] {
        guard convention == .worldToCameraAxisAngleRadians else {
            throw PublicRGBDBenchmarkIntakeError.invalidTrajectory
        }
        let data = try boundedRegularFileData(
            url,
            maximumBytes: Self.maximumAssetBytes,
            failure: .invalidTrajectory
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw PublicRGBDBenchmarkIntakeError.invalidTrajectory
        }
        var result: [(timestamp: TimeInterval, worldFromCamera: Transform4x4)] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            try Task.checkCancellation()
            guard result.count < Self.maximumTrajectoryEntries else {
                throw PublicRGBDBenchmarkIntakeError.invalidTrajectory
            }
            let values = rawLine.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            guard values.count == 7, values.allSatisfy(\.isFinite) else {
                throw PublicRGBDBenchmarkIntakeError.invalidTrajectory
            }
            let worldToCamera = try axisAngleTransform(
                x: Float(values[1]),
                y: Float(values[2]),
                z: Float(values[3]),
                tx: Float(values[4]),
                ty: Float(values[5]),
                tz: Float(values[6])
            )
            result.append((values[0], try worldToCamera.inverted()))
        }
        guard !result.isEmpty,
              zip(result, result.dropFirst()).allSatisfy({ $0.timestamp < $1.timestamp }) else {
            throw PublicRGBDBenchmarkIntakeError.invalidTrajectory
        }
        return result
    }

    static func normalizedWorldFromCamera(
        _ worldFromSourceCamera: Transform4x4,
        convention: PublicRGBDCameraCoordinateConvention
    ) throws -> Transform4x4 {
        guard convention == .opticalPositiveXYZ else { return worldFromSourceCamera }
        // DepthPointCloudGenerator emits (-x, -y, -z). ARKitScenes' official
        // loader emits (+x, +y, +z), so sourceCameraFromStrataCamera is -I.
        let sourceCameraFromStrataCamera = try Transform4x4(columns: [
            -1, 0, 0, 0,
            0, -1, 0, 0,
            0, 0, -1, 0,
            0, 0, 0, 1
        ])
        return worldFromSourceCamera.composed(with: sourceCameraFromStrataCamera)
    }

    private func axisAngleTransform(
        x: Float,
        y: Float,
        z: Float,
        tx: Float,
        ty: Float,
        tz: Float
    ) throws -> Transform4x4 {
        let angle = sqrt(x * x + y * y + z * z)
        let r: [Float]
        if angle <= 0.000_000_1 {
            r = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        } else {
            let kx = x / angle
            let ky = y / angle
            let kz = z / angle
            let c = cos(angle)
            let s = sin(angle)
            let v = 1 - c
            r = [
                kx * kx * v + c, kx * ky * v - kz * s, kx * kz * v + ky * s,
                ky * kx * v + kz * s, ky * ky * v + c, ky * kz * v - kx * s,
                kz * kx * v - ky * s, kz * ky * v + kx * s, kz * kz * v + c
            ]
        }
        return try Transform4x4(columns: [
            r[0], r[3], r[6], 0,
            r[1], r[4], r[7], 0,
            r[2], r[5], r[8], 0,
            tx, ty, tz, 1
        ])
    }

    private func nearestPose(
        timestamp: TimeInterval,
        trajectory: [(timestamp: TimeInterval, worldFromCamera: Transform4x4)],
        maximumDelta: TimeInterval
    ) throws -> (timestamp: TimeInterval, worldFromCamera: Transform4x4) {
        var low = 0
        var high = trajectory.count
        while low < high {
            let middle = (low + high) / 2
            if trajectory[middle].timestamp < timestamp { low = middle + 1 } else { high = middle }
        }
        let candidates = [low - 1, low].filter { trajectory.indices.contains($0) }
        guard let index = candidates.min(by: {
            abs(trajectory[$0].timestamp - timestamp) < abs(trajectory[$1].timestamp - timestamp)
        }), abs(trajectory[index].timestamp - timestamp) <= maximumDelta else {
            throw PublicRGBDBenchmarkIntakeError.poseUnavailable(timestamp)
        }
        return trajectory[index]
    }

    private func parseIntrinsics(_ url: URL) throws -> CameraIntrinsics {
        let data = try boundedRegularFileData(
            url,
            maximumBytes: 4_096,
            failure: .invalidIntrinsics(url.lastPathComponent)
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw PublicRGBDBenchmarkIntakeError.invalidIntrinsics(url.lastPathComponent)
        }
        let values = text.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard values.count == 6,
              values.allSatisfy(\.isFinite),
              values[0] > 0,
              values[1] > 0,
              values[2] > 0,
              values[3] > 0 else {
            throw PublicRGBDBenchmarkIntakeError.invalidIntrinsics(url.lastPathComponent)
        }
        return CameraIntrinsics(
            imageWidth: Int(values[0]),
            imageHeight: Int(values[1]),
            fx: Float(values[2]),
            fy: Float(values[3]),
            cx: Float(values[4]),
            cy: Float(values[5])
        )
    }

    private func decodeUInt16Grayscale(_ url: URL) throws -> (width: Int, height: Int, values: [UInt16]) {
        let image = try cgImage(url)
        guard image.width > 0, image.height > 0 else {
            throw PublicRGBDBenchmarkIntakeError.unsupportedImage(url.lastPathComponent)
        }
        var values = Array(repeating: UInt16.zero, count: image.width * image.height)
        let rendered = values.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 16,
                bytesPerRow: image.width * 2,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.translateBy(x: 0, y: CGFloat(image.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw PublicRGBDBenchmarkIntakeError.unsupportedImage(url.lastPathComponent) }
        return (image.width, image.height, values)
    }

    private func decodeUInt8Grayscale(_ url: URL) throws -> (width: Int, height: Int, values: [UInt8]) {
        let image = try cgImage(url)
        var values = Array(repeating: UInt8.zero, count: image.width * image.height)
        let rendered = values.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.translateBy(x: 0, y: CGFloat(image.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw PublicRGBDBenchmarkIntakeError.unsupportedImage(url.lastPathComponent) }
        return (image.width, image.height, values)
    }

    private func decodeRGB(
        _ url: URL,
        targetWidth: Int,
        targetHeight: Int
    ) throws -> (colors: [PointCloudColor], sourceWidth: Int, sourceHeight: Int) {
        let image = try cgImage(url)
        var rgba = Array(repeating: UInt8.zero, count: targetWidth * targetHeight * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: targetWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.translateBy(x: 0, y: CGFloat(targetHeight))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            return true
        }
        guard rendered else { throw PublicRGBDBenchmarkIntakeError.unsupportedImage(url.lastPathComponent) }
        let colors = stride(from: 0, to: rgba.count, by: 4).map {
            PointCloudColor(red: rgba[$0], green: rgba[$0 + 1], blue: rgba[$0 + 2])
        }
        return (colors, image.width, image.height)
    }

    private func cgImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PublicRGBDBenchmarkIntakeError.unsupportedImage(url.lastPathComponent)
        }
        return image
    }

    private func archiveInputs(at working: URL) throws -> [AssetInput] {
        let canonicalWorking = working.standardizedFileURL.resolvingSymlinksInPath()
        let enumerator = FileManager.default.enumerator(
            at: canonicalWorking,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var inputs: [AssetInput] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PublicRGBDBenchmarkIntakeError.unsafeAsset(url.path)
            }
            guard values.isRegularFile == true else { continue }
            let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
            let prefix = canonicalWorking.path.hasSuffix("/") ? canonicalWorking.path : canonicalWorking.path + "/"
            guard canonicalURL.path.hasPrefix(prefix) else {
                throw PublicRGBDBenchmarkIntakeError.unsafeAsset(url.path)
            }
            inputs.append(AssetInput(
                kind: .manifestAttachment,
                relativePath: String(canonicalURL.path.dropFirst(prefix.count)),
                fileURL: canonicalURL,
                spatialReference: .arWorld
            ))
        }
        return inputs.sorted(by: { $0.relativePath < $1.relativePath })
    }

    private func assetURL(
        sourceRoot: URL,
        relativePath: String,
        expectedKind: PublicRGBDAssetKind,
        assetsByPath: [String: PublicRGBDAssetIdentity]
    ) throws -> URL {
        guard assetsByPath[relativePath]?.kind == expectedKind else {
            throw PublicRGBDBenchmarkIntakeError.invalidManifest("asset kind \(relativePath)")
        }
        return try containedRegularFile(sourceRoot: sourceRoot, relativePath: relativePath)
    }

    private func containedRegularFile(sourceRoot: URL, relativePath: String) throws -> URL {
        guard isSafeRelativePath(relativePath) else {
            throw PublicRGBDBenchmarkIntakeError.unsafeAsset(relativePath)
        }
        let candidate = sourceRoot.appending(path: relativePath).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved == candidate, resolved.path.hasPrefix(sourceRoot.path + "/") else {
            throw PublicRGBDBenchmarkIntakeError.unsafeAsset(relativePath)
        }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PublicRGBDBenchmarkIntakeError.unsafeAsset(relativePath)
        }
        return resolved
    }

    private func safeDirectory(
        _ url: URL,
        failure: PublicRGBDBenchmarkIntakeError
    ) throws -> URL {
        let canonical = url.standardizedFileURL
        let resolved = canonical.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard canonical == resolved,
              FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw failure }
        return resolved
    }

    private func ensuredOutputDirectory(_ url: URL) throws -> URL {
        let canonical = url.standardizedFileURL
        guard canonical == canonical.resolvingSymlinksInPath() else {
            throw PublicRGBDBenchmarkIntakeError.unsafeOutputRoot
        }
        do {
            try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
            return try safeDirectory(canonical, failure: .unsafeOutputRoot)
        } catch let error as PublicRGBDBenchmarkIntakeError {
            throw error
        } catch {
            throw PublicRGBDBenchmarkIntakeError.ioFailure(error.localizedDescription)
        }
    }

    private func boundedRegularFileData(
        _ url: URL,
        maximumBytes: Int64,
        failure: PublicRGBDBenchmarkIntakeError
    ) throws -> Data {
        let canonical = url.standardizedFileURL
        let resolved = canonical.resolvingSymlinksInPath()
        guard canonical == resolved else { throw failure }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0,
              Int64(size) <= maximumBytes else { throw failure }
        return try Data(contentsOf: resolved, options: .mappedIfSafe)
    }

    private func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private func stableJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func assetSetDigest(_ assets: [PublicRGBDAssetIdentity]) -> String {
        var data = Data("StrataScanPublicRGBDAssetSetV1\n".utf8)
        for asset in assets.sorted(by: { $0.relativePath < $1.relativePath }) {
            data.append(contentsOf: asset.kind.rawValue.utf8)
            data.append(0)
            data.append(contentsOf: asset.relativePath.utf8)
            data.append(0)
            data.append(contentsOf: String(asset.byteCount).utf8)
            data.append(0)
            data.append(contentsOf: asset.sha256.lowercased().utf8)
            data.append(0x0A)
        }
        return digest(data)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}
