import Foundation
import Testing
@testable import StrataCore

@Suite("Two-scan alignment")
struct AlignmentTests {
    @Test("Manual alignment persists translation and rotation as targetFromSource")
    func createsManualTransform() throws {
        let engine = ManualAlignmentEngine()
        let transform = engine.transform(
            translation: Point3D(x: 2, y: 3, z: 0),
            rotationRadians: .pi / 2,
            axis: .z
        )

        let transformed = transform.applying(to: Point3D(x: 1, y: 0, z: 0))
        #expect(transformed.isApproximatelyEqual(to: Point3D(x: 2, y: 4, z: 0)))
        #expect(engine.reset() == .identity)
    }

    @Test("Landmark alignment estimates a rigid transform without scale")
    func estimatesLandmarkTransform() throws {
        let engine = LandmarkAlignmentEngine()
        let source = [
            Point3D(x: 0, y: 0, z: 0),
            Point3D(x: 1, y: 0, z: 0),
            Point3D(x: 0, y: 1, z: 0),
            Point3D(x: 0, y: 0, z: 1)
        ]
        let target = [
            Point3D(x: 2, y: 3, z: 0),
            Point3D(x: 2, y: 4, z: 0),
            Point3D(x: 1, y: 3, z: 0),
            Point3D(x: 2, y: 3, z: 1)
        ]

        let estimate = try engine.estimate(source: source, target: target)

        for (sourcePoint, targetPoint) in zip(source, target) {
            #expect(estimate.targetFromSource.applying(to: sourcePoint).isApproximatelyEqual(to: targetPoint, tolerance: 0.001))
        }
        #expect(estimate.rmsError < 0.001)
    }

    @Test("Correspondence alignment rejects incomplete or mismatched landmarks")
    func rejectsInvalidCorrespondences() {
        let engine = LandmarkAlignmentEngine()

        #expect(throws: AlignmentError.insufficientLandmarks) {
            _ = try engine.estimate(
                source: [Point3D(x: 0, y: 0, z: 0), Point3D(x: 1, y: 0, z: 0)],
                target: [Point3D(x: 0, y: 0, z: 0), Point3D(x: 1, y: 0, z: 0)]
            )
        }
        #expect(throws: AlignmentError.mismatchedLandmarkCount) {
            _ = try engine.estimate(
                source: [Point3D(x: 0, y: 0, z: 0), Point3D(x: 1, y: 0, z: 0), Point3D(x: 0, y: 1, z: 0)],
                target: [Point3D(x: 0, y: 0, z: 0), Point3D(x: 1, y: 0, z: 0), Point3D(x: 0, y: 1, z: 0), Point3D(x: 0, y: 0, z: 1)]
            )
        }
    }

    @Test("Saved alignment remains separate from source scan data")
    func savesIndependentAlignmentRecord() async throws {
        let sourceID = UUID()
        let targetID = UUID()
        let store = InMemoryAlignmentStore()
        let alignment = ScanAlignment(
            targetScanID: targetID,
            sourceScanID: sourceID,
            targetFromSource: .translation(x: 4, y: 0, z: 0),
            method: .manual,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try await store.save(alignment)

        #expect(await store.alignment(targetScanID: targetID, sourceScanID: sourceID) == alignment)
    }

    @Test("SQLite persists a non-destructive alignment between existing scans")
    func persistsAlignmentInMetadataStore() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StrataScanAlignment-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadataStore = try SQLiteMetadataStore(databaseURL: root.appending(path: "metadata.sqlite"))
        let sourceID = UUID()
        let targetID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await metadataStore.save(
            scan: ScanMetadata(id: sourceID, displayName: "Source", status: .completed, createdAt: now, updatedAt: now),
            assets: []
        )
        try await metadataStore.save(
            scan: ScanMetadata(id: targetID, displayName: "Target", status: .completed, createdAt: now, updatedAt: now),
            assets: []
        )
        let alignment = ScanAlignment(
            targetScanID: targetID,
            sourceScanID: sourceID,
            targetFromSource: .translation(x: 2, y: 0, z: 0),
            method: .manual,
            createdAt: now,
            updatedAt: now
        )
        let store = SQLiteAlignmentStore(metadataStore: metadataStore)

        try await store.save(alignment)

        #expect(await store.alignment(targetScanID: targetID, sourceScanID: sourceID) == alignment)
    }

    @Test("SQLite retains the landmark evidence for a saved alignment")
    func persistsLandmarkEvidenceInMetadataStore() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StrataScanAlignmentEvidence-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadataStore = try SQLiteMetadataStore(databaseURL: root.appending(path: "metadata.sqlite"))
        let sourceID = UUID()
        let targetID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await metadataStore.save(
            scan: ScanMetadata(id: sourceID, displayName: "Source", status: .completed, createdAt: now, updatedAt: now),
            assets: []
        )
        try await metadataStore.save(
            scan: ScanMetadata(id: targetID, displayName: "Target", status: .completed, createdAt: now, updatedAt: now),
            assets: []
        )
        let evidence = ScanAlignmentLandmarkSet(
            targetScanID: targetID,
            sourceScanID: sourceID,
            targetLandmarks: [
                Point3D(x: 1, y: 2, z: 3),
                Point3D(x: 2, y: 2, z: 3),
                Point3D(x: 1, y: 3, z: 3)
            ],
            sourceLandmarks: [
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 1, y: 0, z: 0),
                Point3D(x: 0, y: 1, z: 0)
            ],
            rmsErrorMeters: 0.01,
            createdAt: now,
            updatedAt: now
        )

        try await metadataStore.save(scanAlignmentLandmarks: evidence)

        #expect(
            try await metadataStore.scanAlignmentLandmarks(
                targetScanID: targetID,
                sourceScanID: sourceID
            ) == evidence
        )
    }
}
