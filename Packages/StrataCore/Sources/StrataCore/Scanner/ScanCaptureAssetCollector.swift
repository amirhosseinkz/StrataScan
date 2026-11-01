import Foundation

public struct CapturedAssetFile: Sendable {
    public var kind: AssetKind
    public var relativePath: String
    public var fileURL: URL
    public var spatialReference: SpatialReferenceKind

    public init(kind: AssetKind, relativePath: String, fileURL: URL, spatialReference: SpatialReferenceKind = .scanLocal) {
        self.kind = kind
        self.relativePath = relativePath
        self.fileURL = fileURL
        self.spatialReference = spatialReference
    }
}

public struct CaptureArtifactBundle: Sendable {
    public var assets: [CapturedAssetFile]
    public var statistics: CaptureStatistics
    public var qualitySignals: ScanQualitySignals?
    public var captureTelemetry: CaptureTelemetry?

    public init(
        assets: [CapturedAssetFile],
        statistics: CaptureStatistics,
        qualitySignals: ScanQualitySignals? = nil,
        captureTelemetry: CaptureTelemetry? = nil
    ) {
        self.assets = assets
        self.statistics = statistics
        self.qualitySignals = qualitySignals
        self.captureTelemetry = captureTelemetry
    }
}

public enum ScanCaptureAssetCollectorError: Error, Equatable, Sendable {
    case alreadyFinalized
    case cancelled
    case noSpatialData
    case ioFailure(String)
}

/// Persists essential copied capture values. The canonical spatial stream is
/// append-only and disk-backed; the bounded fused PLY remains a compatibility
/// preview until processed reconstruction replaces it.
public actor ScanCaptureAssetCollector {
    private let workingDirectory: URL
    private let frameMetadataWriter: FrameMetadataNDJSONWriter
    private let calibratedKeyframeArchiveWriter: CalibratedRGBDKeyframeArchiveWriter
    private let spatialChunkStore: CanonicalSpatialChunkStore
    private let pointCloudGenerator: DepthPointCloudGenerator
    /// The compatibility PLY is written only at finalization from this bounded
    /// AR-world fusion. This prevents an unbounded stream of duplicate depth
    /// samples while preserving actual observed RGB when every persisted cell
    /// has one.
    private var pointCloudFusion = RGBDPointCloudFusion()
    private let meshAccumulator = MeshSnapshotAccumulator()
    private var statistics = CaptureStatistics()
    private var trackingInterruptions = 0
    private var hasObservedTracking = false
    private var lastTrackingState: FrameTrackingState?
    private var sampledDepthValueCount = 0
    private var lowConfidenceDepthValueCount = 0
    private var textureSourceCount = 0
    private var hasThumbnail = false
    private var telemetry = CaptureTelemetry()
    private var finalizationTask: Task<CaptureArtifactBundle, Error>?
    private var isCancelled = false
    /// At the adapter's 0.5 Hz cadence this caps retained RGB at one minute,
    /// independently of how long the user leaves an attempt open.
    private static let maximumTextureSourceCount = 30

    public init(
        workingDirectory: URL,
        pointMinimumConfidence: UInt8 = 1,
        pointSamplingStride: Int = 4,
        maximumPointsPerFrame: Int = 3_000,
        fileManager: FileManager = .default
    ) throws {
        self.workingDirectory = workingDirectory
        do {
            try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            frameMetadataWriter = try FrameMetadataNDJSONWriter(
                destinationURL: workingDirectory.appending(path: "frames/frame-metadata.ndjson")
            )
            calibratedKeyframeArchiveWriter = try CalibratedRGBDKeyframeArchiveWriter(
                workingDirectory: workingDirectory
            )
            spatialChunkStore = try CanonicalSpatialChunkStore(
                destinationURL: workingDirectory.appending(path: CanonicalSpatialChunkStore.relativePath)
            )
            pointCloudGenerator = DepthPointCloudGenerator(
                minimumConfidence: pointMinimumConfidence,
                samplingStride: pointSamplingStride,
                maximumPointsPerFrame: maximumPointsPerFrame
            )
        } catch let error as ScanCaptureAssetCollectorError {
            throw error
        } catch {
            throw ScanCaptureAssetCollectorError.ioFailure(error.localizedDescription)
        }
    }

    public func consume(_ event: ScanCaptureEvent) async throws {
        guard !isCancelled else { throw ScanCaptureAssetCollectorError.cancelled }
        guard finalizationTask == nil else { throw ScanCaptureAssetCollectorError.alreadyFinalized }
        switch event {
        case let .frame(packet):
            var metadata = packet.metadata
            if let calibratedKeyframe = packet.calibratedKeyframe {
                _ = try await calibratedKeyframeArchiveWriter.append(calibratedKeyframe)
                telemetry.record(calibratedKeyframe.acceptanceReason)
            }
            if let textureSourceImageData = packet.textureSourceImageData {
                // The NDJSON candidate flag and numbered JPEG sequence are a
                // single package contract. If staging the image fails, do not
                // leave metadata claiming a keyframe that is not present.
                switch writeTextureSource(textureSourceImageData) {
                case .staged:
                    metadata.isTextureSourceCandidate = true
                case let .dropped(reason):
                    metadata.isTextureSourceCandidate = false
                    telemetry.record(.optionalKeyframeImageDropped(reason))
                }
            } else {
                metadata.isTextureSourceCandidate = false
            }
            try await frameMetadataWriter.append(metadata)
            if let thumbnailImageData = packet.thumbnailImageData {
                _ = writeThumbnail(thumbnailImageData)
            }
            statistics.sampledFrameCount += 1
            statistics.featurePointCount += packet.featurePoints.count
            recordTracking(metadata.tracking, countsAsSample: true)
            if let depth = packet.depth {
                sampledDepthValueCount += depth.confidence.count
                lowConfidenceDepthValueCount += depth.confidence.count(where: {
                    $0 < pointCloudGenerator.minimumConfidence
                })
                let points = try pointCloudGenerator.generate(from: depth)
                let samples = points.map { point in
                    RGBDPointSample(
                        depthPoint: point,
                        color: depth.observedColor(at: point.sourcePixel)
                    )
                }
                _ = try await spatialChunkStore.append(samples)
                _ = pointCloudFusion.append(samples)
                statistics.depthPointCount += points.count
            }
        case let .mesh(snapshot):
            await meshAccumulator.replace(snapshot)
        case let .meshRemoved(anchorIDs):
            await meshAccumulator.remove(anchorIDs: anchorIDs)
        case let .meshRegistrySnapshot(snapshots):
            await meshAccumulator.replaceAll(snapshots)
        case let .tracking(state):
            recordTracking(state, countsAsSample: false)
        case let .telemetry(event):
            telemetry.record(event)
        case .interruptionBegan:
            trackingInterruptions += 1
            telemetry.recordInterruptionBegan()
        case .interruptionEnded:
            telemetry.recordInterruptionEnded()
        case .failed, .captureEnded:
            break
        }
    }

    public func finalize(videoFileURL: URL? = nil) async throws -> CaptureArtifactBundle {
        guard !isCancelled else { throw ScanCaptureAssetCollectorError.cancelled }
        if let finalizationTask {
            return try await finalizationTask.value
        }
        let task = Task { [self] in
            try await performFinalization(videoFileURL: videoFileURL)
        }
        finalizationTask = task
        return try await task.value
    }

    public func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        finalizationTask?.cancel()
        await frameMetadataWriter.cancel()
        await calibratedKeyframeArchiveWriter.cancel()
        await spatialChunkStore.cancel()
        await meshAccumulator.clear()
    }

    private func performFinalization(videoFileURL: URL?) async throws -> CaptureArtifactBundle {
        do {
            try Task.checkCancellation()
            try await frameMetadataWriter.finish()
            try Task.checkCancellation()
            let keyframeArchive = try await calibratedKeyframeArchiveWriter.finish()
            try Task.checkCancellation()
            _ = try await spatialChunkStore.finish()
            try Task.checkCancellation()
            try await writeFusedPointCloud()
            let meshSnapshots = await meshAccumulator.snapshots()
            statistics.meshVertexCount = meshSnapshots.reduce(0) { $0 + $1.vertices.count }
            statistics.meshFaceCount = meshSnapshots.reduce(0) { $0 + $1.faces.count }
            guard statistics.meshVertexCount > 0 || statistics.depthPointCount > 0 else {
                throw ScanCaptureAssetCollectorError.noSpatialData
            }

            let meshURL = workingDirectory.appending(path: "mesh/raw-mesh.json")
            try FileManager.default.createDirectory(at: meshURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(meshSnapshots).write(to: meshURL, options: .atomic)

            var assets = [
                CapturedAssetFile(
                    kind: .manifestAttachment,
                    relativePath: CalibratedRGBDKeyframeArchiveWriter.indexRelativePath,
                    fileURL: workingDirectory.appending(path: CalibratedRGBDKeyframeArchiveWriter.indexRelativePath),
                    spatialReference: .arWorld
                ),
                CapturedAssetFile(
                    kind: .manifestAttachment,
                    relativePath: CanonicalSpatialChunkStore.relativePath,
                    fileURL: workingDirectory.appending(path: CanonicalSpatialChunkStore.relativePath),
                    spatialReference: .arWorld
                ),
                CapturedAssetFile(
                    kind: .frameMetadata,
                    relativePath: "frames/frame-metadata.ndjson",
                    fileURL: workingDirectory.appending(path: "frames/frame-metadata.ndjson"),
                    spatialReference: .arWorld
                ),
                CapturedAssetFile(
                    kind: .meshRaw,
                    relativePath: "mesh/raw-mesh.json",
                    fileURL: meshURL,
                    spatialReference: .arWorld
                ),
                CapturedAssetFile(
                    kind: .pointCloud,
                    relativePath: "pointcloud/cloud.ply",
                    fileURL: workingDirectory.appending(path: "pointcloud/cloud.ply"),
                    spatialReference: .arWorld
                )
            ]
            assets.append(contentsOf: calibratedKeyframeAssets(recordCount: keyframeArchive.recordCount))
            assets.append(contentsOf: textureSourceAssets())
            if hasThumbnail {
                assets.append(
                    CapturedAssetFile(
                        kind: .thumbnail,
                        relativePath: "preview/thumbnail.jpg",
                        fileURL: workingDirectory.appending(path: "preview/thumbnail.jpg"),
                        spatialReference: .arWorld
                    )
                )
            }
            if let videoFileURL, FileManager.default.fileExists(atPath: videoFileURL.path) {
                assets.append(
                    CapturedAssetFile(
                        kind: .video,
                        relativePath: "video/capture.mov",
                        fileURL: videoFileURL,
                        spatialReference: .arWorld
                    )
                )
            }
            telemetry.recordFinalization()
            return CaptureArtifactBundle(
                assets: assets.sorted { $0.relativePath < $1.relativePath },
                statistics: statistics,
                qualitySignals: qualitySignals,
                captureTelemetry: telemetry.isEmpty ? nil : telemetry
            )
        } catch let error as ScanCaptureAssetCollectorError {
            throw error
        } catch {
            if isCancelled || error is CancellationError {
                throw ScanCaptureAssetCollectorError.cancelled
            }
            throw ScanCaptureAssetCollectorError.ioFailure(error.localizedDescription)
        }
    }

    private func writeTextureSource(_ data: Data) -> TextureSourceWriteDisposition {
        guard textureSourceCount < Self.maximumTextureSourceCount else {
            return .dropped(.imageLimit)
        }
        let nextIndex = textureSourceCount + 1
        let relativePath = "frames/images/frame-\(String(format: "%06d", nextIndex)).jpg"
        let destinationURL = workingDirectory.appending(path: relativePath)
        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destinationURL, options: .atomic)
            textureSourceCount = nextIndex
            return .staged
        } catch {
            return .dropped(.stagingFailure)
        }
    }

    /// Writes a conventional RGB PLY only when every bounded fused cell has
    /// actual camera RGB. If a frame could not be sampled, we retain the full
    /// geometric cloud in the legacy confidence PLY instead of filling the
    /// missing cells with an invented colour.
    private func writeFusedPointCloud() async throws {
        let destinationURL = workingDirectory.appending(path: "pointcloud/cloud.ply")
        let fusedPoints = pointCloudFusion.fusedPoints()
        let coloredPoints = fusedPoints.compactMap(\.coloredPoint)

        if !fusedPoints.isEmpty, coloredPoints.count == fusedPoints.count {
            let writer = try PointCloudPLYWriter(
                destinationURL: destinationURL,
                schema: .coloredDepthWithConfidence
            )
            try await writer.append(coloredPoints)
            try await writer.finish()
            return
        }

        let uncoloredPoints = fusedPoints.map { point in
            DepthPoint(
                position: point.position,
                confidence: point.confidence,
                timestamp: 0,
                sourcePixel: PixelCoordinate(x: 0, y: 0)
            )
        }
        let writer = try PointCloudPLYWriter(
            destinationURL: destinationURL,
            schema: .depthWithConfidence
        )
        try await writer.append(uncoloredPoints)
        try await writer.finish()
    }

    private func textureSourceAssets() -> [CapturedAssetFile] {
        guard textureSourceCount > 0 else {
            return []
        }
        return (1...textureSourceCount).map { index in
            let relativePath = "frames/images/frame-\(String(format: "%06d", index)).jpg"
            return CapturedAssetFile(
                kind: .textureSource,
                relativePath: relativePath,
                fileURL: workingDirectory.appending(path: relativePath),
                spatialReference: .arWorld
            )
        }
    }

    private func calibratedKeyframeAssets(recordCount: Int) -> [CapturedAssetFile] {
        guard recordCount > 0 else { return [] }
        return (1...recordCount).flatMap { index in
            let stem = "capture/keyframes/keyframe-\(String(format: "%06d", index))"
            return ["\(stem).depth-f32le", "\(stem).confidence-u8", "\(stem).rgb-u8"].map { relativePath in
                CapturedAssetFile(
                    kind: .manifestAttachment,
                    relativePath: relativePath,
                    fileURL: workingDirectory.appending(path: relativePath),
                    spatialReference: .arWorld
                )
            }
        }
    }

    private func writeThumbnail(_ data: Data) -> Bool {
        guard !hasThumbnail else {
            return false
        }
        let destinationURL = workingDirectory.appending(path: "preview/thumbnail.jpg")
        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destinationURL, options: .atomic)
            hasThumbnail = true
            return true
        } catch {
            return false
        }
    }

    private var qualitySignals: ScanQualitySignals? {
        guard hasObservedTracking || sampledDepthValueCount > 0 else {
            return nil
        }
        let lowConfidenceFraction = sampledDepthValueCount > 0
            ? Double(lowConfidenceDepthValueCount) / Double(sampledDepthValueCount)
            : nil
        return ScanQualitySignals(
            trackingInterruptions: hasObservedTracking ? trackingInterruptions : nil,
            lowConfidenceDepthFraction: lowConfidenceFraction,
            coverageFraction: nil
        )
    }

    private func recordTracking(_ state: FrameTrackingState, countsAsSample: Bool) {
        if countsAsSample { telemetry.recordTracking(state) }
        if lastTrackingState == .normal, state != .normal {
            trackingInterruptions += 1
        }
        lastTrackingState = state
        hasObservedTracking = true
    }
}

private enum TextureSourceWriteDisposition {
    case staged
    case dropped(OptionalKeyframeImageDropReason)
}
