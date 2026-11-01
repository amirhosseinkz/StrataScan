import Foundation
import SQLite3
import XCTest
@testable import StrataCore

final class SpatialLayerPersistenceTests: XCTestCase {
    func testRoundTripsNoteAndMeasurementLayerAcrossRepositoryReopen() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let databaseURL = root.appending(path: "metadata.sqlite")
        let assetsURL = root.appending(path: "assets")
        let metadataStore = try SQLiteMetadataStore(databaseURL: databaseURL)
        let assetStore = try FileAssetStore(rootURL: assetsURL)
        let repository = LocalScanRepository(metadataStore: metadataStore, assetStore: assetStore)
        let scanID = try XCTUnwrap(UUID(uuidString: "3D2A98EC-99D4-41AB-A36F-79B89E3B2C08"))
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        try await saveScan(id: scanID, at: timestamp, through: repository)
        let layer = try makeAnnotationLayer(at: timestamp)

        try await repository.save(spatialLayer: layer, forScanID: scanID)

        let reopenedRepository = LocalScanRepository(
            metadataStore: try SQLiteMetadataStore(databaseURL: databaseURL),
            assetStore: try FileAssetStore(rootURL: assetsURL)
        )
        let reopenedScanResult = try await reopenedRepository.reopen(id: scanID)
        let reopenedScan = try XCTUnwrap(reopenedScanResult)
        let reopenedLayers = try await reopenedRepository.spatialLayers(forScanID: scanID)
        let integrity = try await assetStore.validatePackage(id: scanID)

        XCTAssertEqual(reopenedLayers, [layer])
        XCTAssertEqual(reopenedScan.manifest.assets.map(\.relativePath), ["pointcloud/cloud.ply"])
        XCTAssertTrue(integrity.isValid)
    }

    func testDeletingLayerOnlyDeletesMetadataForItsScan() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let metadataStore = try SQLiteMetadataStore(databaseURL: root.appending(path: "metadata.sqlite"))
        let assetStore = try FileAssetStore(rootURL: root.appending(path: "assets"))
        let repository = LocalScanRepository(metadataStore: metadataStore, assetStore: assetStore)
        let scanID = try XCTUnwrap(UUID(uuidString: "827A3F16-4798-4C3D-B75F-38F3466F7D85"))
        let timestamp = Date(timeIntervalSince1970: 1_700_000_010)
        try await saveScan(id: scanID, at: timestamp, through: repository)
        let layer = try makeAnnotationLayer(at: timestamp)

        try await repository.save(spatialLayer: layer, forScanID: scanID)
        let didDelete = try await repository.deleteSpatialLayer(id: layer.id, forScanID: scanID)
        let didDeleteAgain = try await repository.deleteSpatialLayer(id: layer.id, forScanID: scanID)
        let remainingLayers = try await repository.spatialLayers(forScanID: scanID)
        let reopenedScan = try await repository.reopen(id: scanID)
        let integrity = try await assetStore.validatePackage(id: scanID)

        XCTAssertTrue(didDelete)
        XCTAssertFalse(didDeleteAgain)
        XCTAssertEqual(remainingLayers, [])
        XCTAssertNotNil(reopenedScan)
        XCTAssertTrue(integrity.isValid)
    }

    func testPersistenceRejectsInvalidLayerBeforeWritingMetadata() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let metadataStore = try SQLiteMetadataStore(databaseURL: root.appending(path: "metadata.sqlite"))
        let assetStore = try FileAssetStore(rootURL: root.appending(path: "assets"))
        let repository = LocalScanRepository(metadataStore: metadataStore, assetStore: assetStore)
        let scanID = try XCTUnwrap(UUID(uuidString: "8FE5F216-55D8-48CE-920E-CA217E418444"))
        let timestamp = Date(timeIntervalSince1970: 1_700_000_020)
        try await saveScan(id: scanID, at: timestamp, through: repository)

        let invalidFeatureID = try XCTUnwrap(UUID(uuidString: "C9F1A741-7712-442C-9569-1B6A4C879B3F"))
        let invalidLayer = SpatialLayer(
            id: try XCTUnwrap(UUID(uuidString: "72556B2A-054F-4FC2-9CE6-42AE4812B504")),
            name: "Invalid space",
            spatialReference: .scanLocal,
            features: [
                SpatialFeature(
                    id: invalidFeatureID,
                    kind: .note,
                    geometry: .point(Point3D(x: 1, y: 2, z: 3)),
                    provenance: SpatialProvenance(source: "manual", observedAt: timestamp),
                    spatialReference: .arWorld,
                    createdAt: timestamp
                )
            ],
            provenance: SpatialProvenance(source: "manual", observedAt: timestamp),
            createdAt: timestamp
        )

        do {
            try await repository.save(spatialLayer: invalidLayer, forScanID: scanID)
            XCTFail("Expected invalid coordinate-space layer to be rejected")
        } catch let error as SpatialValidationError {
            XCTAssertEqual(
                error,
                .layerFeatureSpatialReferenceMismatch(
                    featureID: invalidFeatureID,
                    layer: .scanLocal,
                    feature: .arWorld
                )
            )
        }

        let layers = try await repository.spatialLayers(forScanID: scanID)
        XCTAssertEqual(layers, [])
    }

    func testPersistenceRequiresAnExistingScan() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let metadataStore = try SQLiteMetadataStore(databaseURL: root.appending(path: "metadata.sqlite"))
        let assetStore = try FileAssetStore(rootURL: root.appending(path: "assets"))
        let repository = LocalScanRepository(metadataStore: metadataStore, assetStore: assetStore)
        let scanID = try XCTUnwrap(UUID(uuidString: "D3275A5B-B67C-43B6-B1B1-F75491A4F513"))
        let layer = try makeAnnotationLayer(at: Date(timeIntervalSince1970: 1_700_000_025))

        do {
            try await repository.save(spatialLayer: layer, forScanID: scanID)
            XCTFail("Expected an unknown scan to be rejected")
        } catch let error as SpatialLayerStoreError {
            XCTAssertEqual(error, .scanNotFound(scanID))
        }
    }

    func testLinearDistanceUsesMeterSpacesAndRejectsUnsupportedData() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_030)
        let provenance = SpatialProvenance(source: "manual", observedAt: timestamp)
        let measurement = SpatialFeature(
            id: try XCTUnwrap(UUID(uuidString: "E6EB11C5-98B4-48B8-804B-02B6573C07D4")),
            kind: .measurement,
            geometry: .polyline([
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 3, y: 4, z: 0)
            ]),
            provenance: provenance,
            spatialReference: .scanLocal,
            createdAt: timestamp
        )
        let geographicMeasurement = SpatialFeature(
            kind: .measurement,
            geometry: .polyline([
                Point3D(x: -122, y: 37, z: 0),
                Point3D(x: -121, y: 38, z: 0)
            ]),
            provenance: provenance,
            spatialReference: .geographicWGS84,
            createdAt: timestamp
        )
        let pointMeasurement = SpatialFeature(
            kind: .measurement,
            geometry: .point(Point3D(x: 0, y: 0, z: 0)),
            provenance: provenance,
            spatialReference: .arWorld,
            createdAt: timestamp
        )
        let invalidMeasurement = SpatialFeature(
            kind: .measurement,
            geometry: .polyline([Point3D(x: 0, y: 0, z: 0)]),
            provenance: provenance,
            spatialReference: .arWorld,
            createdAt: timestamp
        )
        let note = SpatialFeature(
            kind: .note,
            geometry: .point(Point3D(x: 0, y: 0, z: 0)),
            provenance: provenance,
            spatialReference: .scanLocal,
            createdAt: timestamp
        )

        XCTAssertEqual(try SpatialMeasurementEvaluator.linearDistanceMeters(for: measurement), 5, accuracy: 0.000_001)
        var arWorldMeasurement = measurement
        arWorldMeasurement.spatialReference = .arWorld
        XCTAssertEqual(try SpatialMeasurementEvaluator.linearDistanceMeters(for: arWorldMeasurement), 5, accuracy: 0.000_001)
        XCTAssertThrowsError(try SpatialMeasurementEvaluator.linearDistanceMeters(for: geographicMeasurement)) { error in
            XCTAssertEqual(error as? SpatialMeasurementError, .unsupportedSpatialReference(.geographicWGS84))
        }
        XCTAssertThrowsError(try SpatialMeasurementEvaluator.linearDistanceMeters(for: pointMeasurement)) { error in
            XCTAssertEqual(error as? SpatialMeasurementError, .invalidMeasurementGeometry(.point))
        }
        XCTAssertThrowsError(try SpatialMeasurementEvaluator.linearDistanceMeters(for: invalidMeasurement)) { error in
            XCTAssertEqual(error as? SpatialValidationError, .insufficientPolylineVertices(count: 1))
        }
        XCTAssertThrowsError(try SpatialMeasurementEvaluator.linearDistanceMeters(for: note)) { error in
            XCTAssertEqual(error as? SpatialMeasurementError, .notMeasurementFeature)
        }
    }

    func testMigrationBackfillsFullSpatialSemanticsForVersionOneTables() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }

        let databaseURL = root.appending(path: "metadata.sqlite")
        let scanID = try XCTUnwrap(UUID(uuidString: "FB53B1B0-FEAB-4F3F-8A5D-54A586053B82"))
        let layerID = try XCTUnwrap(UUID(uuidString: "1F459B86-9BD3-4E7E-B7B8-799F26FF4F1C"))
        let featureID = try XCTUnwrap(UUID(uuidString: "95C636AE-7E7F-48DF-AF3D-A9817562B82C"))
        let timestamp = Date(timeIntervalSince1970: 1_700_000_040)
        let featureProvenance = SpatialProvenance(source: "legacy import", observedAt: timestamp)
        let featureGeometry = SpatialGeometry.point(Point3D(x: 1, y: 2, z: 3))
        let featureProperties: SpatialProperties = ["text": .string("legacy note")]

        try createVersionOneDatabase(
            at: databaseURL,
            scanID: scanID,
            layerID: layerID,
            featureID: featureID,
            spatialReference: .arWorld,
            timestamp: timestamp,
            geometryJSON: try encodedJSONString(featureGeometry),
            propertiesJSON: try encodedJSONString(featureProperties),
            provenanceJSON: try encodedJSONString(featureProvenance)
        )

        let store = try SQLiteMetadataStore(databaseURL: databaseURL)
        let schemaVersion = try await store.schemaVersion()
        let layers = try await store.spatialLayers(forScanID: scanID)
        let layer = try XCTUnwrap(layers.first)
        let feature = try XCTUnwrap(layer.features.first)

        XCTAssertEqual(schemaVersion, 8)
        XCTAssertEqual(layer.spatialReference, .arWorld)
        XCTAssertEqual(layer.properties, [:])
        XCTAssertEqual(layer.provenance, SpatialProvenance(source: "legacy spatial metadata"))
        XCTAssertEqual(feature.kind, .custom("legacy"))
        XCTAssertEqual(feature.spatialReference, .arWorld)
        XCTAssertEqual(feature.geometry, featureGeometry)
        XCTAssertEqual(feature.properties, featureProperties)
        XCTAssertEqual(feature.provenance, featureProvenance)
    }

    private func saveScan(id: UUID, at timestamp: Date, through repository: LocalScanRepository) async throws {
        try await repository.save(
            scan: ScanMetadata(
                id: id,
                displayName: "Spatial persistence fixture",
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
                    kind: .pointCloud,
                    relativePath: "pointcloud/cloud.ply",
                    data: Data("point-cloud-fixture".utf8)
                )
            ]
        )
    }

    private func makeAnnotationLayer(at timestamp: Date) throws -> SpatialLayer {
        let provenance = SpatialProvenance(
            source: "workspace annotation",
            author: "Field engineer",
            observedAt: timestamp,
            metadata: ["method": .string("manual")]
        )
        let note = SpatialFeature(
            id: try XCTUnwrap(UUID(uuidString: "3F1BBA9B-1D73-428A-901F-BEDB2D13E967")),
            kind: .note,
            geometry: .point(Point3D(x: 1.5, y: 2, z: -0.5)),
            properties: ["text": .string("Check exposed conduit")],
            provenance: provenance,
            spatialReference: .scanLocal,
            createdAt: timestamp
        )
        let measurement = SpatialFeature(
            id: try XCTUnwrap(UUID(uuidString: "4AA030EA-FCDE-4AA9-AEA6-2E895B3123F9")),
            kind: .measurement,
            geometry: .polyline([
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 3, y: 4, z: 0)
            ]),
            properties: ["label": .string("Clear width")],
            provenance: provenance,
            spatialReference: .scanLocal,
            createdAt: timestamp
        )
        return SpatialLayer(
            id: try XCTUnwrap(UUID(uuidString: "8EC0A505-2BFE-41B8-B327-62BD20FCE506")),
            name: "Field notes",
            spatialReference: .scanLocal,
            features: [note, measurement],
            properties: ["color": .string("orange")],
            provenance: provenance,
            createdAt: timestamp
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "StrataScanSpatialTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func removeTemporaryDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func createVersionOneDatabase(
        at url: URL,
        scanID: UUID,
        layerID: UUID,
        featureID: UUID,
        spatialReference: SpatialReferenceKind,
        timestamp: Date,
        geometryJSON: String,
        propertiesJSON: String,
        provenanceJSON: String
    ) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            if let database {
                sqlite3_close_v2(database)
            }
            throw TestSQLiteError.openFailed(result)
        }
        defer { sqlite3_close_v2(database) }

        try executeSQL(database, sql: """
        CREATE TABLE schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at REAL NOT NULL
        );
        CREATE TABLE scans (
            id TEXT PRIMARY KEY NOT NULL,
            display_name TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            duration_seconds REAL,
            remote_id TEXT
        );
        CREATE TABLE spatial_layers (
            id TEXT PRIMARY KEY NOT NULL,
            scan_id TEXT NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            spatial_reference TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE spatial_features (
            id TEXT PRIMARY KEY NOT NULL,
            layer_id TEXT NOT NULL REFERENCES spatial_layers(id) ON DELETE CASCADE,
            geometry_json TEXT NOT NULL,
            properties_json TEXT NOT NULL,
            provenance_json TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)

        let time = timestamp.timeIntervalSince1970
        try executeSQL(database, sql: """
        INSERT INTO schema_migrations (version, applied_at) VALUES (1, \(time));
        INSERT INTO scans (id, display_name, status, created_at, updated_at)
        VALUES ('\(scanID.uuidString)', 'Legacy scan', 'completed', \(time), \(time));
        INSERT INTO spatial_layers (id, scan_id, name, spatial_reference, created_at, updated_at)
        VALUES ('\(layerID.uuidString)', '\(scanID.uuidString)', 'Legacy layer', '\(spatialReference.rawValue)', \(time), \(time));
        INSERT INTO spatial_features (id, layer_id, geometry_json, properties_json, provenance_json, created_at, updated_at)
        VALUES (
            '\(featureID.uuidString)',
            '\(layerID.uuidString)',
            '\(sqlLiteral(geometryJSON))',
            '\(sqlLiteral(propertiesJSON))',
            '\(sqlLiteral(provenanceJSON))',
            \(time),
            \(time)
        );
        """)
    }

    private func encodedJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw TestSQLiteError.invalidJSONEncoding
        }
        return string
    }

    private func executeSQL(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite error \(result)"
            sqlite3_free(errorMessage)
            throw TestSQLiteError.executionFailed(message)
        }
    }

    private func sqlLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private enum TestSQLiteError: Error {
        case openFailed(Int32)
        case executionFailed(String)
        case invalidJSONEncoding
    }
}
