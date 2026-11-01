import Foundation
import Testing
@testable import StrataCore

@Suite("Chunked TSDF reconstruction")
struct ChunkedTSDFReconstructionTests {
    @Test("A calibrated plane produces a signed band and source color at the surface")
    func integratesKnownPlane() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try testConfiguration()
        let reconstructor = try ChunkedTSDFReconstructor(
            outputDirectory: root,
            source: source(),
            configuration: configuration
        )

        let state = try await reconstructor.integrate(keyframe(), frameIndex: 1)
        var voxels: [TSDFVoxel] = []
        for key in state.submapKeys {
            voxels.append(contentsOf: try await reconstructor.loadSubmap(key).voxelsByLocalIndex.values)
        }

        #expect(state.nextFrameIndex == 2)
        #expect(state.statistics.processedFrameCount == 1)
        #expect(state.statistics.integratedRayCount == 1)
        #expect(voxels.count == 5)
        #expect(voxels.contains(where: { $0.signedDistance > 0 }))
        #expect(voxels.contains(where: { $0.signedDistance < 0 }))
        let surface = try #require(voxels.min(by: {
            abs($0.signedDistance) < abs($1.signedDistance)
        }))
        #expect(abs(surface.signedDistance) <= 0.26)
        #expect(surface.color == PointCloudColor(red: 30, green: 60, blue: 90))
        #expect(voxels.filter { $0.color != nil }.count >= 1)
    }

    @Test("Negative world voxels use stable mathematical-floor submap boundaries")
    func partitionsNegativeCoordinates() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reconstructor = try ChunkedTSDFReconstructor(
            outputDirectory: root,
            source: source(),
            configuration: try testConfiguration()
        )

        let state = try await reconstructor.integrate(keyframe(), frameIndex: 1)

        #expect(state.submapKeys.contains(TSDFSubmapKey(x: 0, y: 0, z: -2)))
        #expect(state.submapKeys.contains(TSDFSubmapKey(x: 0, y: 0, z: -3)))
        for key in state.submapKeys {
            let submap = try await reconstructor.loadSubmap(key)
            #expect(submap.voxelsByLocalIndex.keys.allSatisfy { (0..<64).contains($0) })
        }
    }

    @Test("Restart recovery is idempotent and rejects another source")
    func resumesCompletedFrames() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try testConfiguration()
        let first = try ChunkedTSDFReconstructor(
            outputDirectory: root,
            source: source(),
            configuration: configuration
        )
        let firstState = try await first.integrate(keyframe(), frameIndex: 1)
        var firstSubmaps: [TSDFSubmap] = []
        for key in firstState.submapKeys {
            firstSubmaps.append(try await first.loadSubmap(key))
        }
        for key in firstState.submapKeys {
            let directory = root.appending(
                path: "submaps/x_\(key.x)_y_\(key.y)_z_\(key.z)",
                directoryHint: .isDirectory
            )
            try FileManager.default.copyItem(
                at: directory.appending(path: "frame-000001.delta"),
                to: directory.appending(path: "frame-000002.delta")
            )
        }
        let staleState = TSDFReconstructionState(
            source: source(),
            configuration: configuration
        )
        let encoder = JSONEncoder()
        try encoder.encode(staleState).write(
            to: root.appending(path: "reconstruction-state.json"),
            options: .atomic
        )

        let resumed = try ChunkedTSDFReconstructor(
            outputDirectory: root,
            source: source(),
            configuration: configuration
        )
        #expect(await resumed.currentState() == firstState)
        let firstSnapshot = try await resumed.makeExtractionSnapshot()
        #expect(firstSnapshot.prefix.completedFrameCount == 1)
        #expect(firstSnapshot.submapKeys == firstState.submapKeys)
        for (offset, key) in firstState.submapKeys.enumerated() {
            #expect(try await resumed.loadSubmap(key).voxelsByLocalIndex == firstSubmaps[offset].voxelsByLocalIndex)
        }
        #expect(try await resumed.integrate(keyframe(), frameIndex: 1) == firstState)
        let secondState = try await resumed.integrate(
            keyframe(timestamp: 2, transform: .translation(x: 2, y: 0, z: 0)),
            frameIndex: 2
        )
        #expect(secondState.nextFrameIndex == 3)
        #expect(secondState.statistics.processedFrameCount == 2)
        let secondSnapshot = try await resumed.makeExtractionSnapshot()
        #expect(secondSnapshot.prefix.completedFrameCount == 2)
        #expect(secondSnapshot.prefix.sha256 != firstSnapshot.prefix.sha256)
        for (offset, key) in firstState.submapKeys.enumerated() {
            #expect(try await resumed.loadSubmap(key).voxelsByLocalIndex == firstSubmaps[offset].voxelsByLocalIndex)
        }

        #expect(throws: TSDFReconstructionError.sourceMismatch) {
            _ = try ChunkedTSDFReconstructor(
                outputDirectory: root,
                source: TSDFReconstructionSource(
                    scanID: UUID(),
                    keyframeIndexSHA256: "different",
                    calibratedArchiveSHA256: "different",
                    keyframeCount: 1
                ),
                configuration: configuration
            )
        }
    }

    @Test("Per-frame unique-voxel limits are explicit and deterministic")
    func boundsFrameUpdates() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try TSDFReconstructionConfiguration(
            voxelSizeMeters: 0.1,
            truncationDistanceMeters: 0.2,
            submapVoxelDimension: 4,
            depthPixelStride: 1,
            maximumRaysPerFrame: 1,
            maximumUniqueVoxelUpdatesPerFrame: 2,
            maximumRaySteps: 5,
            minimumConfidence: 1,
            minimumDepthMeters: 0.1,
            maximumDepthMeters: 5,
            maximumVoxelWeight: 8
        )
        let reconstructor = try ChunkedTSDFReconstructor(
            outputDirectory: root,
            source: source(),
            configuration: configuration
        )

        let state = try await reconstructor.integrate(keyframe(), frameIndex: 1)

        #expect(state.statistics.updatedVoxelContributionCount == 2)
        #expect(state.statistics.droppedVoxelUpdateCount == 3)
    }

    @Test("A frozen extraction prefix rejects changed completion markers")
    func rejectsMarkerMutationAfterSnapshot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reconstructor = try ChunkedTSDFReconstructor(
            outputDirectory: root,
            source: source(),
            configuration: try testConfiguration()
        )
        _ = try await reconstructor.integrate(keyframe(), frameIndex: 1)
        let snapshot = try await reconstructor.makeExtractionSnapshot()
        let key = try #require(snapshot.submapKeys.first)
        let markerURL = root.appending(path: "frames/frame-000001.complete.json")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
        )
        var changed = object
        changed["submapKeys"] = []
        try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys])
            .write(to: markerURL, options: .atomic)

        await #expect(throws: TSDFReconstructionError.invalidFile(markerURL.lastPathComponent)) {
            try await reconstructor.loadSubmapWithOneVoxelHalo(key, from: snapshot)
        }
    }

    @Test("The balanced production profile has a distinct bounded identity")
    func productionProfileIdentity() throws {
        let profile = TSDFReconstructionConfiguration.productionBalanced

        #expect(profile.qualityProfile == .balancedV1)
        #expect(profile.voxelSizeMeters == 0.04)
        #expect(profile.truncationDistanceMeters == 0.12)
        #expect(profile.minimumDepthMeters == 0.10)
        #expect(profile.maximumDepthMeters == 5)
        #expect(profile.minimumConfidence == 1)
        #expect(profile.minimumConsistentNeighborCount == 2)
        #expect(profile.absoluteNeighborToleranceMeters == 0.08)
        #expect(profile.relativeNeighborTolerance == 0.025)
        #expect(profile.preservesSparseObservations)
        #expect(profile != .default)

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ChunkedTSDFReconstructor(
            outputDirectory: root,
            source: source(),
            configuration: .default
        )
        #expect(throws: TSDFReconstructionError.configurationMismatch) {
            _ = try ChunkedTSDFReconstructor(
                outputDirectory: root,
                source: source(),
                configuration: .productionBalanced
            )
        }
    }

    @Test("The production profile accepts sparse medium confidence depth at five meters")
    func productionProfileAcceptsBoundedSparseDepth() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reconstructor = try ChunkedTSDFReconstructor(
            outputDirectory: root,
            source: source(),
            configuration: .productionBalanced
        )

        let state = try await reconstructor.integrate(
            keyframe(depthMeters: [5], confidence: [1]),
            frameIndex: 1
        )

        #expect(state.statistics.integratedRayCount == 1)
        #expect(state.statistics.rejectedDepthSampleCount == 0)
    }

    @Test("The production profile reports range and confidence rejections")
    func productionProfileReportsBasicRejections() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try TSDFReconstructionConfiguration(
            voxelSizeMeters: 0.04,
            truncationDistanceMeters: 0.12,
            submapVoxelDimension: 16,
            depthPixelStride: 1,
            maximumRaysPerFrame: 100,
            maximumUniqueVoxelUpdatesPerFrame: 1_000,
            maximumRaySteps: 15,
            minimumConfidence: 1,
            minimumDepthMeters: 0.1,
            maximumDepthMeters: 5,
            maximumVoxelWeight: 64,
            qualityProfile: .balancedV1,
            minimumConsistentNeighborCount: 2
        )
        let reconstructor = try ChunkedTSDFReconstructor(
            outputDirectory: root,
            source: source(),
            configuration: configuration
        )

        let state = try await reconstructor.integrate(
            keyframe(
                width: 3,
                height: 1,
                depthMeters: [.nan, 5.01, 1],
                confidence: [2, 2, 0]
            ),
            frameIndex: 1
        )

        #expect(state.statistics.integratedRayCount == 0)
        #expect(state.statistics.rejectedDepthSampleCount == 3)
        #expect(state.statistics.depthRejections?.nonFinite == 1)
        #expect(state.statistics.depthRejections?.aboveMaximumDepth == 1)
        #expect(state.statistics.depthRejections?.lowConfidence == 1)
    }

    @Test("The production profile rejects inconsistent depth with plausible neighbors")
    func productionProfileRequiresConsistentNeighbors() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try TSDFReconstructionConfiguration(
            voxelSizeMeters: 0.04,
            truncationDistanceMeters: 0.12,
            submapVoxelDimension: 16,
            depthPixelStride: 1,
            maximumRaysPerFrame: 100,
            maximumUniqueVoxelUpdatesPerFrame: 1_000,
            maximumRaySteps: 15,
            minimumConfidence: 1,
            minimumDepthMeters: 0.1,
            maximumDepthMeters: 5,
            maximumVoxelWeight: 64,
            qualityProfile: .balancedV1,
            minimumConsistentNeighborCount: 2
        )
        let reconstructor = try ChunkedTSDFReconstructor(
            outputDirectory: root,
            source: source(),
            configuration: configuration
        )
        var depths = Array(repeating: Float(2), count: 9)
        depths[4] = 1

        let state = try await reconstructor.integrate(
            keyframe(width: 3, height: 3, depthMeters: depths, confidence: Array(repeating: 2, count: 9)),
            frameIndex: 1
        )

        #expect(state.statistics.depthRejections?.neighborInconsistent == 1)
        #expect(state.statistics.integratedRayCount == 8)
    }

    @Test("The pipeline replays one archive at a time, resumes, and leaves the package immutable")
    func reconstructsIntegrityValidPackage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appending(path: "capture", directoryHint: .isDirectory)
        let writer = try CalibratedRGBDKeyframeArchiveWriter(workingDirectory: staging)
        let firstRecord = try await writer.append(keyframe().archiveSample)
        let secondRecord = try await writer.append(
            keyframe(timestamp: 2, transform: .translation(x: 0.2, y: 0, z: 0)).archiveSample
        )
        _ = try await writer.finish()

        let scanID = UUID()
        let assetStore = try FileAssetStore(rootURL: root.appending(path: "assets"))
        let paths = [
            CalibratedRGBDKeyframeArchiveWriter.indexRelativePath,
            firstRecord.depthPath,
            firstRecord.confidencePath,
            firstRecord.rgbPath,
            secondRecord.depthPath,
            secondRecord.confidencePath,
            secondRecord.rgbPath
        ]
        let manifest = try await assetStore.finalize(
            manifest: ScanPackageManifest(
                localScanID: scanID,
                status: .completed,
                createdAt: .now,
                updatedAt: .now
            ),
            assets: paths.map {
                AssetInput(
                    kind: .manifestAttachment,
                    relativePath: $0,
                    fileURL: staging.appending(path: $0),
                    spatialReference: .arWorld
                )
            }
        )
        let packageURL = try await assetStore.packageURL(for: scanID)
        let integrity = try await assetStore.validatePackage(id: scanID)
        let packageBytesBefore = try await assetStore.packageByteCount(id: scanID)
        let output = root.appending(path: "derived/tsdf", directoryHint: .isDirectory)
        let pipeline = CalibratedRGBDTSDFPipeline()

        let firstRun = try await pipeline.run(
            packageURL: packageURL,
            manifest: manifest,
            integrity: integrity,
            outputDirectory: output,
            configuration: try testConfiguration()
        )
        let resumed = try await pipeline.run(
            packageURL: packageURL,
            manifest: manifest,
            integrity: integrity,
            outputDirectory: output,
            configuration: try testConfiguration()
        )

        #expect(firstRun.nextFrameIndex == 3)
        #expect(firstRun.statistics.processedFrameCount == 2)
        #expect(resumed == firstRun)
        #expect(try await assetStore.packageByteCount(id: scanID) == packageBytesBefore)
        #expect((try await assetStore.validatePackage(id: scanID)).isValid)
        await #expect(throws: TSDFReconstructionError.invalidOutputLocation) {
            try await pipeline.run(
                packageURL: packageURL,
                manifest: manifest,
                integrity: integrity,
                outputDirectory: packageURL.appending(path: "derived"),
                configuration: try testConfiguration()
            )
        }
        let packageLink = root.appending(path: "package-link")
        try FileManager.default.createSymbolicLink(at: packageLink, withDestinationURL: packageURL)
        await #expect(throws: TSDFReconstructionError.invalidOutputLocation) {
            try await pipeline.run(
                packageURL: packageURL,
                manifest: manifest,
                integrity: integrity,
                outputDirectory: packageLink.appending(path: "derived"),
                configuration: try testConfiguration()
            )
        }
    }

    private func source() -> TSDFReconstructionSource {
        TSDFReconstructionSource(
            scanID: UUID(uuid: (
                0x65, 0xAE, 0x42, 0xE4,
                0x1E, 0xDB, 0x40, 0xA4,
                0xBB, 0xEA, 0xB0, 0x3F,
                0x4C, 0x68, 0x99, 0x50
            )),
            keyframeIndexSHA256: String(repeating: "a", count: 64),
            calibratedArchiveSHA256: String(repeating: "b", count: 64),
            keyframeCount: 2
        )
    }

    private func testConfiguration() throws -> TSDFReconstructionConfiguration {
        try TSDFReconstructionConfiguration(
            voxelSizeMeters: 0.1,
            truncationDistanceMeters: 0.2,
            submapVoxelDimension: 4,
            depthPixelStride: 1,
            maximumRaysPerFrame: 10,
            maximumUniqueVoxelUpdatesPerFrame: 100,
            maximumRaySteps: 5,
            minimumConfidence: 1,
            minimumDepthMeters: 0.1,
            maximumDepthMeters: 5,
            maximumVoxelWeight: 8
        )
    }

    private func keyframe(
        timestamp: TimeInterval = 1,
        transform: Transform4x4 = .identity,
        width: Int = 1,
        height: Int = 1,
        depthMeters: [Float] = [1],
        confidence: [UInt8] = [2]
    ) -> CalibratedRGBDKeyframe {
        let intrinsics = CameraIntrinsics(
            imageWidth: width,
            imageHeight: height,
            fx: 1,
            fy: 1,
            cx: 0,
            cy: 0
        )
        let metadata = FrameMetadata(
            timestamp: timestamp,
            videoTimestamp: nil,
            imageWidth: width,
            imageHeight: height,
            intrinsics: intrinsics,
            worldFromCamera: transform,
            tracking: .normal,
            worldMapping: .mapped,
            isTextureSourceCandidate: false
        )
        let depth = DepthFrameSample(
            width: width,
            height: height,
            depthMeters: depthMeters,
            confidence: confidence,
            observedColors: Array(
                repeating: PointCloudColor(red: 30, green: 60, blue: 90),
                count: width * height
            ),
            calibration: intrinsics,
            worldFromCamera: transform,
            timestamp: timestamp
        )
        let record = CalibratedRGBDKeyframeRecord(
            index: Int(timestamp),
            metadata: metadata,
            acceptanceReason: .initialFrame,
            depthWidth: width,
            depthHeight: height,
            depthPath: "depth",
            confidencePath: "confidence",
            rgbPath: "rgb"
        )
        return CalibratedRGBDKeyframe(record: record, depth: depth)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "StrataScanTSDF-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private extension CalibratedRGBDKeyframe {
    var archiveSample: CalibratedRGBDKeyframeSample {
        authoritativeTestKeyframe(
            metadata: record.metadata,
            depth: depth,
            acceptanceReason: record.acceptanceReason
        )
    }
}
