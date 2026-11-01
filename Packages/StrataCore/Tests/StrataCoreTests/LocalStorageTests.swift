import Foundation
import Testing
@testable import StrataCore

@Suite("Local scan storage", .serialized)
struct LocalStorageTests {
    @Test("A new database applies the current migration")
    func appliesInitialMigration() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let store = try SQLiteMetadataStore(databaseURL: root.appending(path: "metadata.sqlite"))

        #expect(try await store.schemaVersion() == 8)
    }

    @Test("A scan package persists, reloads, and validates")
    func savesAndReopensPackage() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let metadataStore = try SQLiteMetadataStore(databaseURL: root.appending(path: "metadata.sqlite"))
        let assetStore = try FileAssetStore(rootURL: root.appending(path: "assets"))
        let repository = LocalScanRepository(metadataStore: metadataStore, assetStore: assetStore)
        let id = try #require(UUID(uuidString: "C618E2E2-BA62-4925-A9D6-D505FFD5125F"))
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let scan = ScanMetadata(id: id, displayName: "West stairwell", status: .completed, createdAt: createdAt, updatedAt: createdAt, durationSeconds: 42)
        let manifest = ScanPackageManifest(localScanID: id, status: .completed, createdAt: createdAt, updatedAt: createdAt)
        let inputs = [
            AssetInput(kind: .pointCloud, relativePath: "pointcloud/cloud.ply", data: Data("ply-data".utf8)),
            AssetInput(kind: .frameMetadata, relativePath: "frames/frame-metadata.ndjson", data: Data("frame-data".utf8))
        ]

        try await repository.save(scan: scan, manifest: manifest, assets: inputs)

        let reopened = try await repository.reopen(id: id)
        #expect(reopened?.scan == scan)
        #expect(reopened?.manifest.localScanID == id)
        #expect(reopened?.manifest.assets.map(\.relativePath) == ["frames/frame-metadata.ndjson", "pointcloud/cloud.ply"])
        #expect((try await assetStore.validatePackage(id: id)).isValid)
        #expect(try await assetStore.packageByteCount(id: id) > 0)
    }

    @Test("Renaming a scan persists metadata without changing package asset references")
    func renamesMetadataWithoutChangingPackageAssets() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let databaseURL = root.appending(path: "metadata.sqlite")
        let assetsURL = root.appending(path: "assets")
        let metadataStore = try SQLiteMetadataStore(databaseURL: databaseURL)
        let assetStore = try FileAssetStore(rootURL: assetsURL)
        let repository = LocalScanRepository(metadataStore: metadataStore, assetStore: assetStore)
        let id = try #require(UUID(uuidString: "C87B3A46-6EC3-435D-937B-15CD4ED5ED50"))
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let renamedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let scan = ScanMetadata(
            id: id,
            displayName: "Original scan name",
            status: .completed,
            createdAt: createdAt,
            updatedAt: createdAt,
            durationSeconds: 42
        )
        let manifest = ScanPackageManifest(
            localScanID: id,
            status: .completed,
            createdAt: createdAt,
            updatedAt: createdAt
        )

        try await repository.save(
            scan: scan,
            manifest: manifest,
            assets: [
                AssetInput(kind: .pointCloud, relativePath: "pointcloud/cloud.ply", data: Data("ply-data".utf8)),
                AssetInput(kind: .frameMetadata, relativePath: "frames/frame-metadata.ndjson", data: Data("frame-data".utf8))
            ]
        )
        let originalAssetReferences = try #require(try await repository.reopen(id: id)).manifest.assets

        try await repository.rename(id: id, displayName: "  Renamed scan  ", updatedAt: renamedAt)

        let reopenedRepository = LocalScanRepository(
            metadataStore: try SQLiteMetadataStore(databaseURL: databaseURL),
            assetStore: try FileAssetStore(rootURL: assetsURL)
        )
        let reopened = try #require(try await reopenedRepository.reopen(id: id))
        #expect(reopened.scan.displayName == "Renamed scan")
        #expect(reopened.scan.updatedAt == renamedAt)
        #expect(reopened.scan.createdAt == createdAt)
        #expect(reopened.scan.status == .completed)
        #expect(reopened.scan.durationSeconds == 42)
        #expect(reopened.manifest.assets == originalAssetReferences)
        #expect(reopened.manifest.updatedAt == createdAt)
        #expect(reopened.integrity.isValid)
        #expect(try await reopenedRepository.list() == [reopened.scan])
    }

    @Test("A scan comparison draft persists independently and cascades with its source scan")
    func persistsScanComparisonDraft() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let databaseURL = root.appending(path: "metadata.sqlite")
        let assetsURL = root.appending(path: "assets")
        let repository = LocalScanRepository(
            metadataStore: try SQLiteMetadataStore(databaseURL: databaseURL),
            assetStore: try FileAssetStore(rootURL: assetsURL)
        )
        let baselineID = UUID()
        let comparisonID = UUID()
        try await saveCompletedScan(id: baselineID, named: "Before", to: repository)
        try await saveCompletedScan(id: comparisonID, named: "After", to: repository)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_100)
        let draft = ScanComparisonDraft(
            baselineScanID: baselineID,
            comparisonScanID: comparisonID,
            createdAt: timestamp,
            updatedAt: timestamp
        )

        try await repository.save(scanComparisonDraft: draft)
        let workArea = ScanComparisonWorkArea(
            draftID: draft.id,
            referenceScanID: baselineID,
            minimum: Point3D(x: -1, y: -2, z: -3),
            maximum: Point3D(x: 4, y: 5, z: 6),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try await repository.save(scanComparisonWorkArea: workArea)

        let reopenedRepository = LocalScanRepository(
            metadataStore: try SQLiteMetadataStore(databaseURL: databaseURL),
            assetStore: try FileAssetStore(rootURL: assetsURL)
        )
        #expect(try await reopenedRepository.latestScanComparisonDraft() == draft)
        #expect(try await reopenedRepository.scanComparisonWorkArea(forDraftID: draft.id) == workArea)

        try await reopenedRepository.delete(id: baselineID)
        #expect(try await reopenedRepository.latestScanComparisonDraft() == nil)
        #expect(try await reopenedRepository.scanComparisonWorkArea(forDraftID: draft.id) == nil)
    }

    @Test("A scan comparison draft rejects a missing or duplicate source scan")
    func rejectsInvalidScanComparisonDraft() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let repository = LocalScanRepository(
            metadataStore: try SQLiteMetadataStore(databaseURL: root.appending(path: "metadata.sqlite")),
            assetStore: try FileAssetStore(rootURL: root.appending(path: "assets"))
        )
        let missingID = UUID()

        await #expect(throws: ScanComparisonDraftError.sameScan) {
            try await repository.save(
                scanComparisonDraft: ScanComparisonDraft(
                    baselineScanID: missingID,
                    comparisonScanID: missingID
                )
            )
        }
        await #expect(throws: ScanComparisonDraftStoreError.scanNotFound(missingID)) {
            try await repository.save(
                scanComparisonDraft: ScanComparisonDraft(
                    baselineScanID: missingID,
                    comparisonScanID: UUID()
                )
            )
        }
    }

    @Test("Renaming rejects a whitespace-only display name")
    func rejectsWhitespaceOnlyRename() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let metadataStore = try SQLiteMetadataStore(databaseURL: root.appending(path: "metadata.sqlite"))
        let assetStore = try FileAssetStore(rootURL: root.appending(path: "assets"))
        let repository = LocalScanRepository(metadataStore: metadataStore, assetStore: assetStore)
        let id = UUID()

        await #expect(throws: ScanRepositoryError.emptyDisplayName) {
            try await repository.rename(id: id, displayName: " \n\t ", updatedAt: .now)
        }
    }

    @Test("Checksum validation detects a changed finalized asset")
    func detectsIntegrityFailure() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let assetStore = try FileAssetStore(rootURL: root)
        let id = try #require(UUID(uuidString: "502433E0-9C5F-4CCF-B66B-8B58FB2B5523"))
        let manifest = ScanPackageManifest(localScanID: id, status: .completed, createdAt: .now, updatedAt: .now)
        try await assetStore.finalize(
            manifest: manifest,
            assets: [AssetInput(kind: .meshRaw, relativePath: "mesh/raw.bin", data: Data("original".utf8))]
        )

        let packageURL = try await assetStore.packageURL(for: id)
        try Data("changed".utf8).write(to: packageURL.appending(path: "mesh/raw.bin"), options: .atomic)

        let report = try await assetStore.validatePackage(id: id)
        #expect(!report.isValid)
        #expect(report.failures.contains(.checksumMismatch(path: "mesh/raw.bin")))
    }

    @Test("A semantic room USDZ is retained as a scan-local package asset")
    func savesSemanticRoomPackage() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let metadataStore = try SQLiteMetadataStore(databaseURL: root.appending(path: "metadata.sqlite"))
        let assetStore = try FileAssetStore(rootURL: root.appending(path: "assets"))
        let repository = LocalScanRepository(metadataStore: metadataStore, assetStore: assetStore)
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let scan = ScanMetadata(
            id: id,
            displayName: "Conference room",
            status: .completed,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let manifest = ScanPackageManifest(
            localScanID: id,
            status: .completed,
            createdAt: timestamp,
            updatedAt: timestamp,
            coordinateSystem: "RoomPlan semantic room coordinates; no ARKit world transform is inferred.",
            cameraMetadataDescription: "No raw ARKit frame metadata is retained for this semantic room capture."
        )

        try await repository.save(
            scan: scan,
            manifest: manifest,
            assets: [
                AssetInput(
                    kind: .semanticRoom,
                    relativePath: "room/semantic-room.usdz",
                    data: Data("usdz-fixture".utf8),
                    spatialReference: .scanLocal
                )
            ]
        )

        let reopened = try await repository.reopen(id: id)
        #expect(reopened?.integrity.isValid == true)
        #expect(reopened?.manifest.assets.map(\.kind) == [.semanticRoom])
        #expect(reopened?.manifest.assets.first?.spatialReference == .scanLocal)
    }

    @Test("Deleting a scan removes metadata and its asset package")
    func deletesCompleteScan() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let metadataStore = try SQLiteMetadataStore(databaseURL: root.appending(path: "metadata.sqlite"))
        let assetStore = try FileAssetStore(rootURL: root.appending(path: "assets"))
        let repository = LocalScanRepository(metadataStore: metadataStore, assetStore: assetStore)
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let scan = ScanMetadata(id: id, displayName: "Delete me", status: .completed, createdAt: now, updatedAt: now)
        let manifest = ScanPackageManifest(localScanID: id, status: .completed, createdAt: now, updatedAt: now)

        try await repository.save(
            scan: scan,
            manifest: manifest,
            assets: [AssetInput(kind: .manifestAttachment, relativePath: "notes.txt", data: Data("temporary".utf8))]
        )
        try await repository.delete(id: id)

        #expect(try await repository.reopen(id: id) == nil)
        #expect(!(await assetStore.packageExists(id: id)))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "StrataScanTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func removeTemporaryDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func saveCompletedScan(
        id: UUID,
        named displayName: String,
        to repository: LocalScanRepository
    ) async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try await repository.save(
            scan: ScanMetadata(
                id: id,
                displayName: displayName,
                status: .completed,
                createdAt: timestamp,
                updatedAt: timestamp
            ),
            manifest: ScanPackageManifest(
                localScanID: id,
                status: .completed,
                createdAt: timestamp,
                updatedAt: timestamp
            ),
            assets: [
                AssetInput(
                    kind: .manifestAttachment,
                    relativePath: "notes/scan.txt",
                    data: Data(displayName.utf8)
                )
            ]
        )
    }
}
