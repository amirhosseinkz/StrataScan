import Foundation
import Testing
@testable import StrataCore

@Suite("Capture asset collector")
struct CaptureAssetCollectorTests {
    @Test("Frame and mesh events become bounded staged asset files")
    func collectsSpatialAssets() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StrataScanCapture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = try ScanCaptureAssetCollector(workingDirectory: root, pointSamplingStride: 1)
        let metadata = FrameMetadata(
            timestamp: 2,
            videoTimestamp: 0.5,
            imageWidth: 3,
            imageHeight: 3,
            intrinsics: CameraIntrinsics(imageWidth: 3, imageHeight: 3, fx: 1, fy: 1, cx: 1, cy: 1),
            worldFromCamera: .identity,
            tracking: .normal,
            worldMapping: .mapped,
            isTextureSourceCandidate: true
        )
        let depth = DepthFrameSample(
            width: 3,
            height: 3,
            depthMeters: [0, 0, 0, 0, 1, 0, 0, 0, 0],
            confidence: [0, 0, 0, 0, 2, 0, 0, 0, 0],
            observedColors: Array(
                repeating: PointCloudColor(red: 10, green: 20, blue: 30),
                count: 9
            ).map(Optional.some),
            calibration: metadata.intrinsics,
            worldFromCamera: .identity,
            timestamp: 2
        )
        let mesh = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [Point3D(x: 0, y: 0, z: 0), Point3D(x: 1, y: 0, z: 0), Point3D(x: 0, y: 1, z: 0)],
            normals: [],
            faces: [MeshFace(indices: (0, 1, 2))]
        )

        let textureSourceImageData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try await collector.consume(
            .frame(
                CaptureFramePacket(
                    metadata: metadata,
                    depth: depth,
                    featurePoints: [],
                    calibratedKeyframe: authoritativeTestKeyframe(
                        metadata: metadata,
                        depth: depth
                    ),
                    textureSourceImageData: textureSourceImageData,
                    thumbnailImageData: textureSourceImageData
                )
            )
        )
        try await collector.consume(.mesh(mesh))
        let artifacts = try await collector.finalize()

        #expect(artifacts.statistics.sampledFrameCount == 1)
        #expect(artifacts.statistics.depthPointCount == 1)
        #expect(artifacts.statistics.meshVertexCount == 3)
        #expect(artifacts.assets.filter { $0.kind == .manifestAttachment }.count == 5)
        let canonicalChunks = try #require(artifacts.assets.first(where: {
            $0.relativePath == "capture/spatial-chunks.bin"
        }))
        #expect(canonicalChunks.relativePath == "capture/spatial-chunks.bin")
        #expect(try CanonicalSpatialChunkStore.inspect(fileURL: canonicalChunks.fileURL).recordCount == 1)
        #expect(artifacts.assets.contains(where: {
            $0.relativePath == CalibratedRGBDKeyframeArchiveWriter.indexRelativePath
        }))
        #expect(artifacts.captureTelemetry?.acceptedCalibratedKeyframeCount == 1)
        let textureSource = try #require(artifacts.assets.first(where: { $0.kind == .textureSource }))
        #expect(textureSource.relativePath == "frames/images/frame-000001.jpg")
        #expect(try Data(contentsOf: textureSource.fileURL) == textureSourceImageData)
        let thumbnail = try #require(artifacts.assets.first(where: { $0.kind == .thumbnail }))
        #expect(thumbnail.relativePath == "preview/thumbnail.jpg")
        #expect(try Data(contentsOf: thumbnail.fileURL) == textureSourceImageData)
        for asset in artifacts.assets {
            #expect(FileManager.default.fileExists(atPath: asset.fileURL.path))
        }
    }

    @Test("An empty capture cannot finalize into a spatial package")
    func rejectsEmptySpatialCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "StrataScanCapture-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let collector = try ScanCaptureAssetCollector(workingDirectory: root)

        await #expect(throws: ScanCaptureAssetCollectorError.noSpatialData) {
            try await collector.finalize()
        }
    }

    @Test("Observed RGB-D samples finalize as standard colored PLY")
    func persistsObservedRGBDPointCloud() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "StrataScanCapture-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let collector = try ScanCaptureAssetCollector(workingDirectory: root, pointSamplingStride: 1)
        let metadata = FrameMetadata(
            timestamp: 4,
            videoTimestamp: nil,
            imageWidth: 1,
            imageHeight: 1,
            intrinsics: CameraIntrinsics(imageWidth: 1, imageHeight: 1, fx: 1, fy: 1, cx: 0, cy: 0),
            worldFromCamera: .identity,
            tracking: .normal,
            worldMapping: .mapped,
            isTextureSourceCandidate: false
        )
        let depth = DepthFrameSample(
            width: 1,
            height: 1,
            depthMeters: [1],
            confidence: [2],
            observedColors: [PointCloudColor(red: 17, green: 34, blue: 51)],
            calibration: metadata.intrinsics,
            worldFromCamera: .identity,
            timestamp: 4
        )
        try await collector.consume(
            .frame(CaptureFramePacket(metadata: metadata, depth: depth, featurePoints: []))
        )

        let artifacts = try await collector.finalize()
        let pointCloud = try #require(artifacts.assets.first(where: { $0.kind == .pointCloud }))
        let result = try PointCloudPLYReader().read(from: pointCloud.fileURL)

        #expect(result.header.containsRGBColor)
        #expect(result.header.recordByteCount == 16)
        #expect(result.points.count == 1)
        #expect(result.points[0].color == PointCloudColor(red: 17, green: 34, blue: 51))
        #expect(result.points[0].confidence == 2)
    }

    @Test("Optional image pressure cannot drop an accepted calibrated RGB-D keyframe")
    func preservesCalibratedKeyframeUnderImagePressure() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "StrataScanCapture-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = try ScanCaptureAssetCollector(
            workingDirectory: root,
            pointSamplingStride: 1
        )
        let intrinsics = CameraIntrinsics(
            imageWidth: 1,
            imageHeight: 1,
            fx: 1,
            fy: 1,
            cx: 0,
            cy: 0
        )
        let metadata = FrameMetadata(
            timestamp: 5,
            videoTimestamp: nil,
            imageWidth: 1,
            imageHeight: 1,
            intrinsics: intrinsics,
            worldFromCamera: .identity,
            tracking: .normal,
            worldMapping: .mapped,
            isTextureSourceCandidate: false
        )
        let depth = DepthFrameSample(
            width: 1,
            height: 1,
            depthMeters: [1],
            confidence: [2],
            observedColors: [PointCloudColor(red: 20, green: 30, blue: 40)],
            calibration: intrinsics,
            worldFromCamera: .identity,
            timestamp: 5
        )

        try await collector.consume(.frame(CaptureFramePacket(
            metadata: metadata,
            depth: depth,
            featurePoints: [],
            calibratedKeyframe: authoritativeTestKeyframe(
                metadata: metadata,
                depth: depth
            )
        )))
        try await collector.consume(
            .telemetry(.optionalKeyframeImageDropped(.writerPressure))
        )
        let artifacts = try await collector.finalize()

        #expect(artifacts.captureTelemetry?.acceptedCalibratedKeyframeCount == 1)
        #expect(artifacts.captureTelemetry?.droppedOptionalImageCount == 1)
        #expect(artifacts.assets.contains(where: { $0.relativePath.hasSuffix(".depth-f32le") }))
        #expect(artifacts.assets.contains(where: { $0.relativePath.hasSuffix(".confidence-u8") }))
        #expect(artifacts.assets.contains(where: { $0.relativePath.hasSuffix(".rgb-u8") }))
        let chunks = try #require(artifacts.assets.first(where: {
            $0.relativePath == "capture/spatial-chunks.bin"
        }))
        #expect(try CanonicalSpatialChunkStore.inspect(fileURL: chunks.fileURL).recordCount == 1)
    }

    @Test("A mesh with non-finite AR geometry is rejected before JSON staging")
    func rejectsNonFiniteMeshGeometry() throws {
        #expect(throws: MeshSnapshotError.nonFiniteGeometry) {
            try MeshSnapshot(
                anchorID: UUID(),
                worldFromAnchor: .identity,
                vertices: [Point3D(x: .nan, y: 0, z: 0)],
                normals: [],
                faces: []
            )
        }
    }

    @Test("Final mesh registry replaces pressure-era snapshots and finalization is idempotent")
    func finalRegistryAndIdempotentFinalization() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "StrataScanCapture-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = try ScanCaptureAssetCollector(workingDirectory: root)
        let retainedID = UUID()
        let removedID = UUID()
        let retained = try mesh(anchorID: retainedID, extent: 2)
        let removed = try mesh(anchorID: removedID, extent: 1)

        for _ in 0..<100 {
            try await collector.consume(.mesh(removed))
        }
        try await collector.consume(.meshRemoved([removedID]))
        try await collector.consume(.meshRegistrySnapshot([retained]))

        let first = try await collector.finalize()
        let second = try await collector.finalize()
        let meshAsset = try #require(first.assets.first(where: { $0.kind == .meshRaw }))
        let snapshots = try JSONDecoder().decode([MeshSnapshot].self, from: Data(contentsOf: meshAsset.fileURL))

        #expect(snapshots == [retained])
        #expect(first.assets.map(\.relativePath) == second.assets.map(\.relativePath))
        #expect(first.statistics == second.statistics)
    }

    @Test("Collector cancellation prevents finalization")
    func cancellationPreventsFinalization() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "StrataScanCapture-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = try ScanCaptureAssetCollector(workingDirectory: root)

        await collector.cancel()

        await #expect(throws: ScanCaptureAssetCollectorError.cancelled) {
            try await collector.finalize()
        }
    }

    private func mesh(anchorID: UUID, extent: Float) throws -> MeshSnapshot {
        try MeshSnapshot(
            anchorID: anchorID,
            worldFromAnchor: .identity,
            vertices: [
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: extent, y: 0, z: 0),
                Point3D(x: 0, y: extent, z: 0)
            ],
            normals: [],
            faces: [MeshFace(indices: (0, 1, 2))]
        )
    }
}
