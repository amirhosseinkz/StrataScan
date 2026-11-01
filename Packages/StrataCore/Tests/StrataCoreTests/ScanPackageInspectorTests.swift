import Foundation
import Testing
@testable import StrataCore

@Suite("Scan package inspector", .serialized)
struct ScanPackageInspectorTests {
    @Test("A healthy managed package produces stable read-only evidence")
    func inspectsHealthyPackageDeterministically() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try #require(UUID(uuidString: "A71C1D90-B2FD-4D03-8EEC-AC286D2D916C"))
        let store = try FileAssetStore(rootURL: root.appending(path: "assets"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.finalize(
            manifest: ScanPackageManifest(localScanID: id, status: .completed, createdAt: date, updatedAt: date),
            assets: [AssetInput(kind: .pointCloud, relativePath: "pointcloud/cloud.ply", data: Data("ply\n".utf8))]
        )
        let packageURL = try await store.packageURL(for: id)
        let inspector = ScanPackageInspector()
        let first = try await inspector.inspect(packageURL: packageURL)
        let second = try await inspector.inspect(packageURL: packageURL)

        #expect(first.evidence.sourcePackageID == id)
        #expect(first.evidence.stages.first(where: { $0.stage == .packageIntegrity })?.disposition == .healthy)
        #expect(try first.stableJSON() == second.stableJSON())
    }

    @Test("A missing manifest is a package-integrity failure")
    func reportsMissingManifest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let report = try await ScanPackageInspector().inspect(packageURL: root)

        #expect(report.evidence.earliestProvenFailureStage == .packageIntegrity)
        #expect(report.evidence.findings.map(\.code) == ["PKG_MANIFEST_MISSING"])
    }

    @Test("An oversized manifest is rejected before decoding")
    func reportsOversizedManifest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x20, count: 1_048_577).write(to: root.appending(path: "manifest.json"))

        let report = try await ScanPackageInspector().inspect(packageURL: root)

        #expect(report.evidence.earliestProvenFailureStage == .packageIntegrity)
        #expect(report.evidence.findings.map(\.code) == ["PKG_MANIFEST_LIMIT"])
    }

    @Test("A checksum mismatch is a deterministic integrity failure")
    func reportsChecksumMismatch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let store = try FileAssetStore(rootURL: root.appending(path: "assets"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.finalize(
            manifest: ScanPackageManifest(localScanID: id, status: .completed, createdAt: date, updatedAt: date),
            assets: [AssetInput(kind: .pointCloud, relativePath: "pointcloud/cloud.ply", data: Data("before".utf8))]
        )
        let packageURL = try await store.packageURL(for: id)
        try Data("after".utf8).write(to: packageURL.appending(path: "pointcloud/cloud.ply"))

        let report = try await ScanPackageInspector().inspect(packageURL: packageURL)

        #expect(report.evidence.findings.map(\.code).contains("PKG_CHECKSUM"))
        #expect(report.evidence.stages.first(where: { $0.stage == .packageIntegrity })?.disposition == .failed)
    }

    @Test("Cancellation is propagated instead of reported as corrupt evidence")
    func propagatesCancellation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = try await makePackage(in: root, assets: [
            AssetInput(kind: .pointCloud, relativePath: "pointcloud/cloud.ply", data: Data("ply\n".utf8))
        ])
        let task = Task { try await ScanPackageInspector().inspect(packageURL: packageURL) }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("A symbolic-link package root is rejected before payload inspection")
    func rejectsSymbolicLinkPackageRoot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = try await makePackage(in: root, assets: [])
        let link = root.appending(path: "package-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: packageURL)

        await #expect(throws: ScanPackageInspectorError.unsafePackageRoot) {
            try await ScanPackageInspector().inspect(packageURL: link)
        }
    }

    @Test("A malformed calibrated archive is isolated at RGB-D replay")
    func reportsMalformedRGBDArchive() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = try await makePackage(in: root, assets: [
            AssetInput(
                kind: .manifestAttachment,
                relativePath: CalibratedRGBDKeyframeArchiveWriter.indexRelativePath,
                data: Data("not-json\n".utf8),
                spatialReference: .arWorld
            )
        ])

        let report = try await ScanPackageInspector().inspect(packageURL: packageURL)

        #expect(report.evidence.findings.map(\.code).contains("RGBD_ARCHIVE_INVALID"))
        #expect(report.evidence.stages.first(where: { $0.stage == .rgbdArchive })?.disposition == .failed)
        #expect(report.evidence.earliestProvenFailureStage == .rgbdArchive)
    }

    @Test("Malformed TSDF state is reported without mutating derived work")
    func reportsMalformedReconstructionState() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let packageURL = try await makePackage(in: root, id: id, assets: [])
        let appSupport = root.appending(path: "app-support", directoryHint: .isDirectory)
        let workspace = appSupport.appending(path: "processing-work", directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
            .appending(path: "tsdf", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let stateURL = workspace.appending(path: "reconstruction-state.json")
        let original = Data("{}".utf8)
        try original.write(to: stateURL)

        let report = try await ScanPackageInspector().inspect(packageURL: packageURL, derivedProcessingRoot: appSupport)

        #expect(report.evidence.findings.map(\.code).contains("RECONSTRUCTION_CHECKPOINT_INVALID"))
        #expect(report.evidence.stages.first(where: { $0.stage == .reconstruction })?.disposition == .failed)
        #expect(try Data(contentsOf: stateURL) == original)
    }

    @Test("Durable TSDF markers without a checkpoint are resumable incomplete evidence")
    func reportsMissingReconstructionStateAsResumable() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let packageURL = try await makePackage(in: root, id: id, assets: [])
        let appSupport = root.appending(path: "app-support", directoryHint: .isDirectory)
        let workspace = appSupport.appending(path: "processing-work", directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
            .appending(path: "tsdf", directoryHint: .isDirectory)
        let frames = workspace.appending(path: "frames", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let source = TSDFReconstructionSource(
            scanID: id,
            keyframeIndexSHA256: String(repeating: "1", count: 64),
            calibratedArchiveSHA256: String(repeating: "2", count: 64),
            keyframeCount: 2
        )
        let marker = CompletedFrameFixture(
            schemaVersion: TSDFReconstructionState.currentSchemaVersion,
            frameIndex: 1,
            source: source,
            configuration: .productionBalanced,
            submapKeys: [],
            statistics: TSDFReconstructionStatistics(processedFrameCount: 1)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(marker).write(
            to: frames.appending(path: "frame-000001.complete.json")
        )

        let report = try await ScanPackageInspector().inspect(
            packageURL: packageURL,
            derivedProcessingRoot: appSupport
        )

        #expect(report.evidence.findings.map(\.code).contains("RECONSTRUCTION_CHECKPOINT_PENDING"))
        #expect(report.evidence.stages.first(where: { $0.stage == .reconstruction })?.disposition == .insufficientEvidence)
        #expect(!FileManager.default.fileExists(atPath: workspace.appending(path: "reconstruction-state.json").path))
    }

    @Test("Malformed extraction staging is not mistaken for absent work")
    func reportsMalformedExtractionState() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let packageURL = try await makePackage(in: root, id: id, assets: [])
        let appSupport = root.appending(path: "app-support", directoryHint: .isDirectory)
        let staging = appSupport.appending(path: "processing-work", directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
            .appending(path: "surface-extraction", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let stateURL = staging.appending(path: "surface-extraction-state.json")
        try Data("{}".utf8).write(to: stateURL)

        let report = try await ScanPackageInspector().inspect(packageURL: packageURL, derivedProcessingRoot: appSupport)

        #expect(report.evidence.findings.map(\.code).contains("SURFACE_EXTRACTION_STATE_INVALID"))
        #expect(report.evidence.stages.first(where: { $0.stage == .surfaceExtraction })?.disposition == .failed)
    }

    @Test("Unsafe derived roots fail the downstream evidence boundary")
    func reportsUnsafeDerivedRoot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = try await makePackage(in: root, assets: [])
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appending(path: "derived-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let report = try await ScanPackageInspector().inspect(packageURL: packageURL, derivedProcessingRoot: link)

        #expect(report.evidence.findings.map(\.code).contains("DERIVED_ROOT_INVALID"))
        #expect(report.evidence.stages.first(where: { $0.stage == .reconstruction })?.disposition == .failed)
    }

    @Test("Unexpected files remain visible but do not become replayable evidence")
    func reportsUnexpectedFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = try await makePackage(in: root, assets: [])
        try Data("private".utf8).write(to: packageURL.appending(path: "unexpected.bin"))

        let report = try await ScanPackageInspector().inspect(packageURL: packageURL)

        #expect(report.evidence.findings.map(\.code).contains("PKG_UNEXPECTED_ASSET"))
        #expect(report.evidence.stages.first(where: { $0.stage == .packageIntegrity })?.disposition == .suspicious)
    }

    @Test("A declared asset replaced by a symbolic link fails containment")
    func rejectsSymbolicLinkAsset() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = try await makePackage(in: root, assets: [
            AssetInput(kind: .pointCloud, relativePath: "pointcloud/cloud.ply", data: Data("inside".utf8))
        ])
        let declared = packageURL.appending(path: "pointcloud/cloud.ply")
        let outside = root.appending(path: "outside.ply")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: declared)
        try FileManager.default.createSymbolicLink(at: declared, withDestinationURL: outside)

        let report = try await ScanPackageInspector().inspect(packageURL: packageURL)

        #expect(report.evidence.findings.map(\.code).contains("PKG_CONTAINMENT"))
        #expect(report.evidence.stages.first(where: { $0.stage == .packageIntegrity })?.disposition == .failed)
    }

    @Test("Invalid raw mesh geometry cannot qualify canonical geometry")
    func reportsInvalidRawMesh() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = try await makePackage(in: root, assets: [
            AssetInput(kind: .meshRaw, relativePath: "mesh/raw-mesh.json", data: Data("not-json".utf8), spatialReference: .arWorld)
        ])

        let report = try await ScanPackageInspector().inspect(packageURL: packageURL)

        #expect(report.evidence.findings.map(\.code).contains("RAW_MESH_NONFINITE_GEOMETRY"))
        #expect(report.evidence.stages.first(where: { $0.stage == .canonicalGeometry })?.disposition == .failed)
    }

    @Test("Calibrated replay reports depth, pose, and coverage evidence with explicit bounds")
    func reportsCalibratedArchiveEvidence() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let samples = (0..<12).map { index in
            keyframe(
                timestamp: Double(index) * 0.5,
                transform: .translation(x: Float(index) * 0.1, y: 0, z: 0),
                depth: 1,
                confidence: 2
            )
        }
        let packageURL = try await makeRGBDPackage(in: root, samples: samples)

        let report = try await ScanPackageInspector().inspect(packageURL: packageURL)
        let archive = try #require(report.evidence.stages.first(where: { $0.stage == .rgbdArchive }))
        let trajectory = try #require(report.evidence.stages.first(where: { $0.stage == .trajectory }))
        let coverage = try #require(report.evidence.stages.first(where: { $0.stage == .coverage }))

        #expect(archive.metrics.counts["recordCount"] == 12)
        #expect(archive.metrics.ratios["validDepthRatio"] == 1)
        #expect(archive.metrics.ratios["mediumOrHigherConfidenceRatio"] == 1)
        #expect(trajectory.metrics.counts["poseCount"] == 12)
        #expect(trajectory.metrics.ratios["effectiveAcceptedFrameRateHz"] == 2)
        #expect(trajectory.metrics.values["firstPositionMeters"] == "0.0,0.0,0.0")
        #expect(trajectory.metrics.values["finalPositionMeters"] == "1.1,0.0,0.0")
        #expect(coverage.metrics.values["cellSizeMeters"] == "0.25")
        #expect(!report.evidence.findings.map(\.code).contains("RGBD_CONFIDENCE_LOW"))
    }

    @Test("Pixels in one retained frame cannot establish repeated coverage")
    func singleFrameIsNotRevisit() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = try await makeRGBDPackage(in: root, samples: [
            keyframe(timestamp: 1, transform: .identity, depth: 1, confidence: 2)
        ])
        let report = try await ScanPackageInspector().inspect(packageURL: packageURL)
        let coverage = try #require(report.evidence.stages.first { $0.stage == .coverage })
        #expect(coverage.metrics.counts["repeatedObservationCells"] == 0)
        #expect(coverage.metrics.counts["viewDiverseCells"] == 0)
        #expect(coverage.metrics.counts["observationGapReturnCells"] == 0)
    }

    @Test("Stationary repeated frames are not diverse views or a surface revisit")
    func stationaryFramesAreNotDiverse() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = try await makeRGBDPackage(in: root, samples: [
            keyframe(timestamp: 1, transform: .identity, depth: 1, confidence: 2),
            keyframe(timestamp: 2, transform: .identity, depth: 1, confidence: 2)
        ])
        let report = try await ScanPackageInspector().inspect(packageURL: packageURL)
        let coverage = try #require(report.evidence.stages.first { $0.stage == .coverage })
        #expect((coverage.metrics.counts["repeatedObservationCells"] ?? 0) > 0)
        #expect(coverage.metrics.counts["viewDiverseCells"] == 0)
        #expect(coverage.metrics.counts["observationGapReturnCells"] == 0)
    }

    @Test("Complete M1.1 evidence qualifies structurally without claiming spatial quality")
    func qualifiesAuthoritativeCaptureEvidence() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var sample = keyframe(timestamp: 1, transform: .identity, depth: 1, confidence: 2)
        let admissionEvidence = CalibratedKeyframeEvidence(
            timestamp: 1,
            confidenceRatio: 1,
            overlapRatio: 0,
            newCoverageRatio: 1,
            poseBaselineMeters: 0,
            cadenceSeconds: 0
        )
        sample.evidence = admissionEvidence
        sample.evidenceContract?.acceptanceEvidence = admissionEvidence
        sample.evidenceContract?.source = .arkitWorldTracking
        sample.evidenceContract?.depthSource = .smoothedSceneDepth
        sample.evidenceContract?.rgbSource = .capturedImageNearestNeighborToDepthGrid
        sample.evidenceContract?.synchronization = .sameARFrame
        sample.evidenceContract?.meshTimelineRelationship = .independentTimestampedFinalRegistry
        sample.evidenceContract?.exposure = CaptureExposureEvidence(
            availability: .measured,
            exposureDurationSeconds: 0.01,
            exposureTargetOffsetEV: 0,
            sampledLuminanceMean: 0.5,
            sampledLuminanceVariance: 0.1,
            sampledAdjacentDifference: 0.1
        )
        let mesh = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [Point3D(x: 0, y: 0, z: 0), Point3D(x: 1, y: 0, z: 0), Point3D(x: 0, y: 1, z: 0)],
            normals: [],
            faces: [MeshFace(indices: (0, 1, 2))],
            captureTimestamp: 1,
            provenance: .finalSessionSnapshot
        )
        let telemetry = CaptureTelemetry(
            calibratedKeyframeAcceptanceCounts: [CalibratedKeyframeAcceptanceReason.initialFrame.rawValue: 1],
            calibratedKeyframeCandidateCount: 1,
            trackingStateCounts: [FrameTrackingState.normal.rawValue: 1],
            finalizationCount: 1
        )
        let packageURL = try await makeRGBDPackage(
            in: root,
            samples: [sample],
            captureTelemetry: telemetry,
            sourceDevice: SourceDeviceInfo(
                modelIdentifier: "iPhone18,2",
                operatingSystemVersion: "iOS 26.6.1",
                appVersion: "1.0 (1)",
                operatingSystemBuild: "Version 26.6.1 (Build 23G93)",
                appBuildCommit: String(repeating: "a", count: 40)
            ),
            additionalAssets: [AssetInput(
                kind: .meshRaw,
                relativePath: "mesh/raw-mesh.json",
                data: try JSONEncoder().encode([mesh]),
                spatialReference: .arWorld
            )]
        )

        let report = try await ScanPackageInspector().inspect(packageURL: packageURL)
        let archive = try #require(report.evidence.stages.first(where: { $0.stage == .rgbdArchive }))
        let timeline = try #require(report.evidence.stages.first(where: { $0.stage == .captureTimeline }))

        #expect(archive.metrics.values["m11StructuralQualification"] == "satisfied")
        #expect(archive.metrics.values["inertialPolicy"] == CaptureInertialEvidencePolicy.arkitVIOOnly.rawValue)
        #expect(timeline.metrics.values["m11StructuralQualification"] == "satisfied")
        #expect(timeline.metrics.values["qualificationMeaning"] == "structural capture-evidence contract only")
        #expect(timeline.metrics.values["m1AdmissionQualification"] == "insufficientEvidence")
        #expect(timeline.disposition == .insufficientEvidence)
    }

    @Test("Low-confidence out-of-range depth and discontinuous poses remain diagnosable")
    func reportsWeakRGBDAndTrajectoryEvidence() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var samples = (0..<11).map { index in
            keyframe(
                timestamp: Double(index) * 0.5,
                transform: .translation(x: Float(index) * 0.05, y: 0, z: 0),
                depth: 8,
                confidence: 0
            )
        }
        samples.append(keyframe(timestamp: 10, transform: .translation(x: 3, y: 0, z: 0), depth: 1, confidence: 0))
        let packageURL = try await makeRGBDPackage(in: root, samples: samples)

        let report = try await ScanPackageInspector().inspect(packageURL: packageURL)
        let codes = Set(report.evidence.findings.map(\.code))

        #expect(codes.contains("RGBD_VALID_DEPTH_LOW"))
        #expect(codes.contains("RGBD_CONFIDENCE_LOW"))
        #expect(codes.contains("RGBD_RANGE_REJECTION_HIGH"))
        #expect(codes.contains("TRAJECTORY_IMPLAUSIBLE_JUMP"))
        #expect(codes.contains("CAPTURE_LONG_OBSERVATION_GAP"))
        #expect(codes.contains("COVERAGE_SPARSE"))
        #expect(report.evidence.earliestSuspiciousStage == .rgbdArchive)
    }

    @Test("Canonical records are compared with the compatibility PLY without treating it as source")
    func reportsCanonicalPreviewMismatch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appending(path: "staging", directoryHint: .isDirectory)
        let canonicalURL = staging.appending(path: CanonicalSpatialChunkStore.relativePath)
        let canonical = try CanonicalSpatialChunkStore(destinationURL: canonicalURL)
        _ = try await canonical.append([
            RGBDPointSample(position: Point3D(x: 0, y: 0, z: 1), confidence: 2, color: nil),
            RGBDPointSample(position: Point3D(x: 1, y: 0, z: 1), confidence: 2, color: nil)
        ])
        _ = try await canonical.finish()
        let previewURL = staging.appending(path: "pointcloud/cloud.ply")
        let preview = try PointCloudPLYWriter(destinationURL: previewURL)
        try await preview.append((0..<3).map { index in
            DepthPoint(
                position: Point3D(x: Float(index), y: 0, z: 1),
                confidence: 2,
                timestamp: 1,
                sourcePixel: PixelCoordinate(x: index, y: 0)
            )
        })
        try await preview.finish()
        let packageURL = try await makePackage(in: root, assets: [
            AssetInput(kind: .manifestAttachment, relativePath: CanonicalSpatialChunkStore.relativePath, fileURL: canonicalURL, spatialReference: .arWorld),
            AssetInput(kind: .pointCloud, relativePath: "pointcloud/cloud.ply", fileURL: previewURL, spatialReference: .arWorld)
        ])

        let report = try await ScanPackageInspector().inspect(packageURL: packageURL)
        let canonicalStage = try #require(report.evidence.stages.first(where: { $0.stage == .canonicalGeometry }))

        #expect(canonicalStage.metrics.counts["recordCount"] == 2)
        #expect(canonicalStage.metrics.counts["previewVertexCount"] == 3)
        #expect(report.evidence.findings.map(\.code).contains("CANONICAL_PREVIEW_COUNT_EXCEEDS_SOURCE"))
        #expect(canonicalStage.disposition == .suspicious)
    }

    @Test("Manifest traversal is rejected without reading the escaped payload")
    func rejectsManifestTraversal() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let packageURL = root.appending(path: "package", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let escaped = ScanAssetReference(
            kind: .manifestAttachment,
            relativePath: "../escaped.bin",
            byteCount: 1,
            sha256: String(repeating: "0", count: 64),
            spatialReference: .arWorld,
            createdAt: date
        )
        let manifest = ScanPackageManifest(
            localScanID: id,
            status: .completed,
            createdAt: date,
            updatedAt: date,
            assets: [escaped]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: packageURL.appending(path: "manifest.json"))
        try Data([1]).write(to: root.appending(path: "escaped.bin"))

        let report = try await ScanPackageInspector().inspect(packageURL: packageURL)

        #expect(report.evidence.findings.map(\.code).contains("PKG_UNSAFE_PATH"))
        #expect(report.evidence.earliestProvenFailureStage == .packageIntegrity)
    }

    @Test("Truncated calibrated depth and confidence payloads fail at RGB-D replay")
    func rejectsTruncatedCalibratedPayloads() async throws {
        for payload in [CalibratedPayload.depth, .confidence] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let packageURL = try await makeRGBDPackage(
                in: root,
                samples: [keyframe(timestamp: 0, transform: .identity, depth: 1, confidence: 2)]
            ) { staging, records in
                let path = payload == .depth ? records[0].depthPath : records[0].confidencePath
                try Data().write(to: staging.appending(path: path))
            }

            let report = try await ScanPackageInspector().inspect(packageURL: packageURL)

            #expect(report.evidence.stages.first(where: { $0.stage == .packageIntegrity })?.disposition == .suspicious)
            #expect(report.evidence.findings.map(\.code).contains("RGBD_ARCHIVE_INVALID"))
            #expect(report.evidence.earliestProvenFailureStage == .rgbdArchive)
        }
    }

    @Test("Invalid dimensions and duplicate calibrated records fail at RGB-D replay")
    func rejectsInvalidCalibratedRecords() async throws {
        let dimensionRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dimensionRoot) }
        let invalidDimensions = try await makeRGBDPackage(
            in: dimensionRoot,
            samples: [keyframe(timestamp: 0, transform: .identity, depth: 1, confidence: 2)]
        ) { _, records in
            records[0].depthWidth = 0
        }
        let dimensionReport = try await ScanPackageInspector().inspect(packageURL: invalidDimensions)
        #expect(dimensionReport.evidence.findings.map(\.code).contains("RGBD_ARCHIVE_INVALID"))
        #expect(dimensionReport.evidence.earliestProvenFailureStage == .rgbdArchive)

        let duplicateRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: duplicateRoot) }
        let duplicateRecords = try await makeRGBDPackage(
            in: duplicateRoot,
            samples: [keyframe(timestamp: 0, transform: .identity, depth: 1, confidence: 2)]
        ) { _, records in
            records.append(records[0])
        }
        let duplicateReport = try await ScanPackageInspector().inspect(packageURL: duplicateRecords)
        #expect(duplicateReport.evidence.findings.map(\.code).contains("RGBD_ARCHIVE_INVALID"))
        #expect(duplicateReport.evidence.earliestProvenFailureStage == .rgbdArchive)
    }

    @Test("Non-finite calibration metadata fails closed at RGB-D replay")
    func rejectsNonFiniteCalibratedMetadata() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = try await makeRGBDPackage(
            in: root,
            samples: [keyframe(timestamp: 0, transform: .identity, depth: 1, confidence: 2)]
        ) { _, records in
            var columns = records[0].metadata.worldFromCamera.columns
            columns[0] = .infinity
            records[0].metadata.worldFromCamera = try Transform4x4(columns: columns)
        }

        let report = try await ScanPackageInspector().inspect(packageURL: packageURL)

        #expect(report.evidence.stages.first(where: { $0.stage == .packageIntegrity })?.disposition == .healthy)
        #expect(report.evidence.findings.map(\.code).contains("RGBD_ARCHIVE_INVALID"))
        #expect(report.evidence.earliestProvenFailureStage == .rgbdArchive)
    }

    private func makePackage(
        in root: URL,
        id: UUID = UUID(),
        assets: [AssetInput],
        captureTelemetry: CaptureTelemetry? = nil,
        sourceDevice: SourceDeviceInfo = SourceDeviceInfo()
    ) async throws -> URL {
        let store = try FileAssetStore(rootURL: root.appending(path: "assets"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.finalize(
            manifest: ScanPackageManifest(
                localScanID: id,
                status: .completed,
                createdAt: date,
                updatedAt: date,
                sourceDevice: sourceDevice,
                captureTelemetry: captureTelemetry
            ),
            assets: assets
        )
        return try await store.packageURL(for: id)
    }

    private func makeRGBDPackage(
        in root: URL,
        samples: [CalibratedRGBDKeyframeSample],
        captureTelemetry: CaptureTelemetry? = nil,
        sourceDevice: SourceDeviceInfo = SourceDeviceInfo(),
        additionalAssets: [AssetInput] = [],
        mutate: (URL, inout [CalibratedRGBDKeyframeRecord]) throws -> Void = { _, _ in }
    ) async throws -> URL {
        let staging = root.appending(path: "rgbd-staging", directoryHint: .isDirectory)
        let writer = try CalibratedRGBDKeyframeArchiveWriter(workingDirectory: staging)
        var records: [CalibratedRGBDKeyframeRecord] = []
        for sample in samples { records.append(try await writer.append(sample)) }
        _ = try await writer.finish()
        try mutate(staging, &records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        var indexData = Data()
        for record in records {
            indexData.append(try encoder.encode(record))
            indexData.append(0x0A)
        }
        try indexData.write(to: staging.appending(path: CalibratedRGBDKeyframeArchiveWriter.indexRelativePath))
        let paths = Set([CalibratedRGBDKeyframeArchiveWriter.indexRelativePath] + records.flatMap {
            [$0.depthPath, $0.confidencePath, $0.rgbPath]
        }).sorted()
        return try await makePackage(in: root, assets: paths.map {
            AssetInput(
                kind: .manifestAttachment,
                relativePath: $0,
                fileURL: staging.appending(path: $0),
                spatialReference: .arWorld
            )
        } + additionalAssets, captureTelemetry: captureTelemetry, sourceDevice: sourceDevice)
    }

    private func keyframe(
        timestamp: TimeInterval,
        transform: Transform4x4,
        depth: Float,
        confidence: UInt8
    ) -> CalibratedRGBDKeyframeSample {
        let intrinsics = CameraIntrinsics(imageWidth: 1, imageHeight: 1, fx: 1, fy: 1, cx: 0, cy: 0)
        let metadata = FrameMetadata(
            timestamp: timestamp,
            videoTimestamp: nil,
            imageWidth: 1,
            imageHeight: 1,
            intrinsics: intrinsics,
            worldFromCamera: transform,
            tracking: .normal,
            worldMapping: .mapped,
            isTextureSourceCandidate: false
        )
        return authoritativeTestKeyframe(
            metadata: metadata,
            depth: DepthFrameSample(
                width: 1,
                height: 1,
                depthMeters: [depth],
                confidence: [confidence],
                observedColors: [PointCloudColor(red: 20, green: 40, blue: 60)],
                calibration: intrinsics,
                worldFromCamera: transform,
                timestamp: timestamp
            )
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private enum CalibratedPayload {
        case depth
        case confidence
    }

    private struct CompletedFrameFixture: Encodable {
        var schemaVersion: Int
        var frameIndex: Int
        var source: TSDFReconstructionSource
        var configuration: TSDFReconstructionConfiguration
        var submapKeys: [TSDFSubmapKey]
        var statistics: TSDFReconstructionStatistics
    }
}
