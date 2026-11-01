import Foundation
import Testing
@testable import StrataCore

@Suite("Scan domain foundation")
struct ScanDomainFoundationTests {
    @Test("Integrity and identity failures take precedence in the presentation state")
    func resolvesCorruptionBeforeOtherStates() throws {
        let id = try #require(UUID(uuidString: "0A5B3A86-AD1B-4E94-83C6-710A239C3DC1"))
        let scan = makeMetadata(id: id, status: .completed)
        let manifest = makeManifest(id: id, status: .completed)
        let invalidIntegrity = PackageIntegrityReport(
            scanID: id,
            failures: [.checksumMismatch(path: "pointcloud/cloud.ply")]
        )

        #expect(
            ScanAssetStateResolver().resolve(
                metadata: scan,
                manifest: manifest,
                integrity: invalidIntegrity
            ) == .corrupted
        )

        let unexpectedID = try #require(UUID(uuidString: "B5C1A9AB-17A3-4BDA-AB40-237257567E96"))
        #expect(
            ScanAssetStateResolver().resolve(
                metadata: scan,
                manifest: manifest,
                integrity: PackageIntegrityReport(scanID: unexpectedID)
            ) == .corrupted
        )

        #expect(
            ScanAssetStateResolver().resolve(
                metadata: scan,
                manifest: makeManifest(id: unexpectedID, status: .completed),
                integrity: PackageIntegrityReport(scanID: id)
            ) == .corrupted
        )
    }

    @Test("Completed packages derive their sync presentation from manifest sync metadata")
    func resolvesCompletedSyncStates() throws {
        let id = try #require(UUID(uuidString: "90308A70-69BE-4DB5-8A6F-A79339673DC8"))
        let scan = makeMetadata(id: id, status: .completed)
        let cases: [(SynchronizationStatus, ScanAssetState)] = [
            (.localOnly, .ready),
            (.pendingUpload, .pendingSync),
            (.uploading, .syncing),
            (.synced, .synced),
            (.modified, .modified),
            (.conflict, .syncConflict),
            (.failed, .syncFailed),
            (.pendingDeletion, .pendingDeletion)
        ]

        for (syncStatus, expectedState) in cases {
            let manifest = makeManifest(
                id: id,
                status: .completed,
                sync: SyncMetadata(status: syncStatus)
            )

            #expect(
                ScanAssetStateResolver().resolve(
                    metadata: scan,
                    manifest: manifest,
                    integrity: PackageIntegrityReport(scanID: id)
                ) == expectedState
            )
        }
    }

    @Test("In-progress and mismatched persisted statuses are represented without pretending readiness")
    func resolvesInProgressAndInconsistentStates() throws {
        let id = try #require(UUID(uuidString: "B8669DB3-2E9B-4BAA-9D20-843785926AB0"))
        let integrity = PackageIntegrityReport(scanID: id)

        #expect(
            ScanAssetStateResolver().resolve(
                metadata: makeMetadata(id: id, status: .capturing),
                manifest: makeManifest(id: id, status: .capturing),
                integrity: integrity
            ) == .capturing
        )
        #expect(
            ScanAssetStateResolver().resolve(
                metadata: makeMetadata(id: id, status: .processing),
                manifest: makeManifest(id: id, status: .processing),
                integrity: integrity
            ) == .processing
        )
        #expect(
            ScanAssetStateResolver().resolve(
                metadata: makeMetadata(id: id, status: .failed),
                manifest: makeManifest(id: id, status: .failed),
                integrity: integrity
            ) == .processingFailed
        )
        #expect(
            ScanAssetStateResolver().resolve(
                metadata: makeMetadata(id: id, status: .completed),
                manifest: makeManifest(id: id, status: .processing),
                integrity: integrity
            ) == .incomplete
        )
    }

    @Test("Capabilities are a stable ordered view of actual manifest asset kinds")
    func derivesArtifactCapabilitiesFromManifest() throws {
        let id = try #require(UUID(uuidString: "C44F00C9-9D7B-4DE4-8942-9AE34904E02A"))
        let manifest = makeManifest(
            id: id,
            assets: [
                makeAsset(kind: .meshRaw, path: "mesh/raw-a.json", bytes: 18),
                makeAsset(kind: .pointCloud, path: "pointcloud/cloud.ply", bytes: 42),
                makeAsset(kind: .meshRaw, path: "mesh/raw-b.json", bytes: 11)
            ]
        )

        let capabilities = ScanCapabilities(manifest: manifest)
        let pointCloud = try #require(capabilities.capability(for: .pointCloud))
        let mesh = try #require(capabilities.capability(for: .meshRaw))
        let video = try #require(capabilities.capability(for: .video))

        #expect(capabilities.artifacts.map(\.kind) == AssetKind.allCases)
        #expect(pointCloud.availability == .available)
        #expect(pointCloud.assetCount == 1)
        #expect(pointCloud.totalByteCount == 42)
        #expect(pointCloud.assets.map(\.relativePath) == ["pointcloud/cloud.ply"])
        #expect(mesh.availability == .available)
        #expect(mesh.assetCount == 2)
        #expect(mesh.totalByteCount == 29)
        #expect(video.availability == .unavailable)
        #expect(video.assetCount == 0)
        #expect(video.totalByteCount == 0)
        #expect(video.assets.isEmpty)
    }

    @Test("Scan summary surfaces only counts supported by persisted artifacts")
    func derivesSummaryFromManifestAssetsAndStatistics() throws {
        let id = try #require(UUID(uuidString: "EB0CB9B0-363C-4C27-BC9B-0434E56CCF1B"))
        let statistics = CaptureStatistics(
            sampledFrameCount: 12,
            featurePointCount: 456,
            depthPointCount: 2_400,
            meshVertexCount: 321,
            meshFaceCount: 107
        )
        let manifest = makeManifest(
            id: id,
            durationSeconds: 37,
            statistics: statistics,
            assets: [
                makeAsset(kind: .frameMetadata, path: "frames/metadata.ndjson", bytes: 10),
                makeAsset(kind: .pointCloud, path: "pointcloud/cloud.ply", bytes: 200),
                makeAsset(kind: .meshRaw, path: "mesh/raw.json", bytes: 300),
                makeAsset(kind: .video, path: "video/capture.mov", bytes: 400)
            ]
        )

        let summary = ScanSummary(manifest: manifest)

        #expect(summary.durationSeconds == 37)
        #expect(summary.frameCount == 12)
        #expect(summary.pointCount == 2_400)
        #expect(summary.meshVertexCount == 321)
        #expect(summary.meshTriangleCount == 107)
        #expect(summary.assetCount == 4)
        #expect(summary.totalAssetByteCount == 910)
        #expect(summary.hasVideo)

        let semanticOnly = ScanSummary(
            manifest: makeManifest(
                id: id,
                statistics: statistics,
                assets: [makeAsset(kind: .semanticRoom, path: "room/scan.usdz", bytes: 99)]
            )
        )
        #expect(semanticOnly.frameCount == nil)
        #expect(semanticOnly.pointCount == nil)
        #expect(semanticOnly.meshVertexCount == nil)
        #expect(semanticOnly.meshTriangleCount == nil)
        #expect(!semanticOnly.hasVideo)
    }

    @Test("Quality evaluator leaves unavailable signals unscored")
    func doesNotFabricateUnavailableQualityValues() {
        let report = ScanQualityEvaluator().evaluate(ScanQualitySignals())

        #expect(report.overallScore == nil)
        #expect(report.overallLevel == nil)
        #expect(report.metrics.map(\.score) == [nil, nil, nil])
        #expect(report.warnings.isEmpty)
        #expect(report.recommendations.isEmpty)
    }

    @Test("Quality evaluator scores valid signals and makes signal-backed recommendations")
    func evaluatesAvailableQualitySignalsDeterministically() {
        let report = ScanQualityEvaluator().evaluate(
            ScanQualitySignals(
                trackingInterruptions: 4,
                lowConfidenceDepthFraction: 0.4,
                coverageFraction: 0.55
            )
        )

        #expect(report.metrics.map(\.score) == [30, 60, 55])
        #expect(report.overallScore == 48)
        #expect(report.overallLevel == .poor)
        #expect(report.warnings == [.trackingInterrupted, .lowDepthConfidence, .limitedCoverage])
        #expect(report.recommendations == [.improveTracking, .captureHigherConfidenceDepth, .captureAdditionalCoverage])
    }

    @Test("Invalid quality input is treated as unavailable rather than scored")
    func rejectsInvalidQualityValues() {
        let report = ScanQualityEvaluator().evaluate(
            ScanQualitySignals(
                trackingInterruptions: -1,
                lowConfidenceDepthFraction: -1,
                coverageFraction: .infinity
            )
        )

        #expect(report.overallScore == nil)
        #expect(report.metrics.map(\.score) == [nil, nil, nil])
    }

    private func makeMetadata(id: UUID, status: ScanStatus) -> ScanMetadata {
        ScanMetadata(
            id: id,
            displayName: "Test scan",
            status: status,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private func makeManifest(
        id: UUID,
        status: ScanStatus = .completed,
        durationSeconds: TimeInterval? = nil,
        statistics: CaptureStatistics = CaptureStatistics(),
        assets: [ScanAssetReference] = [],
        sync: SyncMetadata = SyncMetadata()
    ) -> ScanPackageManifest {
        ScanPackageManifest(
            localScanID: id,
            status: status,
            createdAt: timestamp,
            updatedAt: timestamp,
            durationSeconds: durationSeconds,
            captureStatistics: statistics,
            assets: assets,
            sync: sync
        )
    }

    private func makeAsset(kind: AssetKind, path: String, bytes: Int64) -> ScanAssetReference {
        ScanAssetReference(
            kind: kind,
            relativePath: path,
            byteCount: bytes,
            sha256: "test-checksum",
            createdAt: timestamp
        )
    }

    private var timestamp: Date {
        Date(timeIntervalSince1970: 1_700_000_000)
    }
}
