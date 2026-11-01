import Foundation
import Testing
@testable import StrataCore

@Suite("Public RGB-D production reconstruction")
struct PublicRGBDBenchmarkReconstructionTests {
    @Test("Runs an immutable imported-style package through the production coordinator")
    func reconstructsAndReusesValidatedPromotion() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "PublicRGBDReconstruction-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appending(path: "staging", directoryHint: .isDirectory)
        let packageStoreRoot = root.appending(path: "packages", directoryHint: .isDirectory)
        let workRoot = root.appending(path: "work", directoryHint: .isDirectory)
        let scanID = try #require(UUID(uuidString: "1CFBDA64-31C3-4DC3-9283-52F6CA1DC95A"))
        let sample = keyframe()

        let archiveWriter = try CalibratedRGBDKeyframeArchiveWriter(workingDirectory: staging)
        let record = try await archiveWriter.append(sample)
        _ = try await archiveWriter.finish()
        let canonicalStore = try CanonicalSpatialChunkStore(
            destinationURL: staging.appending(path: CanonicalSpatialChunkStore.relativePath)
        )
        let points = try DepthPointCloudGenerator(
            minimumConfidence: 1,
            samplingStride: 4,
            maximumPointsPerFrame: 3_000
        ).generate(from: sample.depth)
        _ = try await canonicalStore.append(points.map {
            RGBDPointSample(depthPoint: $0, color: sample.depth.observedColor(at: $0.sourcePixel))
        })
        _ = try await canonicalStore.finish()

        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try FileAssetStore(rootURL: packageStoreRoot)
        let paths = [
            CalibratedRGBDKeyframeArchiveWriter.indexRelativePath,
            record.depthPath,
            record.confidencePath,
            record.rgbPath,
            CanonicalSpatialChunkStore.relativePath
        ]
        _ = try await store.finalize(
            manifest: ScanPackageManifest(
                localScanID: scanID,
                status: .completed,
                createdAt: createdAt,
                updatedAt: createdAt
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
        let packageBytes = try await store.packageByteCount(id: scanID)

        let first = try await PublicRGBDBenchmarkReconstructionRunner().run(
            packageStoreRoot: packageStoreRoot,
            scanID: scanID,
            workRoot: workRoot
        )
        let firstEvaluatorData = try Data(
            contentsOf: workRoot.appending(path: first.evaluatorGeometryRelativePath)
        )
        let second = try await PublicRGBDBenchmarkReconstructionRunner().run(
            packageStoreRoot: packageStoreRoot,
            scanID: scanID,
            workRoot: workRoot
        )

        #expect(first.source.keyframeCount == 1)
        #expect(first.promotedVertexCount > 0)
        #expect(first.promotedTriangleCount > 0)
        #expect(!first.reusedValidatedPromotion)
        #expect(second.reusedValidatedPromotion)
        #expect(first.source == second.source)
        #expect(first.evaluatorGeometrySHA256 == second.evaluatorGeometrySHA256)
        #expect(first.evaluatorGeometrySHA256.count == 64)
        #expect(first.evaluatorVertexCount > 0)
        #expect(first.evaluatorTriangleCount > 0)
        #expect(first.evaluatorVertexCount == first.promotedVertexCount)
        #expect(first.evaluatorTriangleCount == first.promotedTriangleCount)
        #expect(first.evaluatorGeometryMode == "completePromotedSurface")
        #expect(first.evaluatorGeometryIsCompleteSurface)
        #expect(first.evaluatorSafetyLimits == BenchmarkEvaluator.safetyLimits)
        #expect(first.evaluatorHasCompleteNormalEvidence)
        let evaluatorURL = workRoot.appending(path: first.evaluatorGeometryRelativePath)
        #expect(try Data(contentsOf: evaluatorURL) == firstEvaluatorData)
        let evaluatorGeometry = try JSONDecoder().decode(
            BenchmarkEvaluationGeometry.self,
            from: Data(contentsOf: evaluatorURL)
        )
        #expect(evaluatorGeometry.coordinateFrame == "geometry-local")
        #expect(evaluatorGeometry.fixtureFromGeometry == .identity)
        #expect(evaluatorGeometry.vertices.count == first.evaluatorVertexCount)
        #expect(evaluatorGeometry.triangles.count == first.evaluatorTriangleCount)
        #expect(try await store.packageByteCount(id: scanID) == packageBytes)
        #expect(try await store.validatePackage(id: scanID).isValid)

        let cancelledWorkRoot = root.appending(path: "cancelled-work", directoryHint: .isDirectory)
        await #expect(throws: CancellationError.self) {
            try await PublicRGBDBenchmarkReconstructionRunner().run(
                packageStoreRoot: packageStoreRoot,
                scanID: scanID,
                workRoot: cancelledWorkRoot,
                event: { event in
                    if case let .extracting(progress) = event, progress.phase == .promoting {
                        throw CancellationError()
                    }
                }
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: cancelledWorkRoot.appending(path: "evaluator-candidates").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: cancelledWorkRoot
                .appending(path: "derived/\(scanID.uuidString)/processed-surface")
                .path
        ))
        #expect(try await store.packageByteCount(id: scanID) == packageBytes)
    }

    private func keyframe() -> CalibratedRGBDKeyframeSample {
        let width = 16
        let height = 16
        let intrinsics = CameraIntrinsics(
            imageWidth: width,
            imageHeight: height,
            fx: 100,
            fy: 100,
            cx: 7.5,
            cy: 7.5
        )
        let color = PointCloudColor(red: 40, green: 80, blue: 120)
        return authoritativeTestKeyframe(
            metadata: FrameMetadata(
                timestamp: 1,
                videoTimestamp: nil,
                imageWidth: width,
                imageHeight: height,
                intrinsics: intrinsics,
                worldFromCamera: .identity,
                tracking: .normal,
                worldMapping: .mapped,
                isTextureSourceCandidate: true
            ),
            depth: DepthFrameSample(
                width: width,
                height: height,
                depthMeters: Array(repeating: 1, count: width * height),
                confidence: Array(repeating: 2, count: width * height),
                observedColors: Array(repeating: color, count: width * height),
                calibration: intrinsics,
                worldFromCamera: .identity,
                timestamp: 1
            )
        )
    }
}
