import Foundation
import SQLite3

public enum SQLiteStoreError: Error, Equatable, Sendable {
    case openFailed(String)
    case executionFailed(String)
    case invalidRecord(String)
}

public enum SpatialLayerStoreError: Error, Equatable, Sendable {
    case scanNotFound(UUID)
    case layerBelongsToAnotherScan(layerID: UUID, scanID: UUID)
}

public enum MineSurveyStoreError: Error, Equatable, Sendable {
    case projectNotFound(UUID)
    case scanNotFound(UUID)
    case controlPointNotFound(UUID)
    case controlPointOutsideProject(controlPointID: UUID, projectID: UUID)
    case stationNotFound(UUID)
    case stationOutsideProject(stationID: UUID, projectID: UUID)
    case surveyEpochNotFound(UUID)
    case surveyBoundaryNotFound(UUID)
}

/// SQLite owns indexable metadata only. Asset bytes remain in FileAssetStore.
public actor SQLiteMetadataStore {
    private let connection: SQLiteConnection

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var openedDatabase: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &openedDatabase,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(result)"
            if let openedDatabase {
                sqlite3_close_v2(openedDatabase)
            }
            throw SQLiteStoreError.openFailed(message)
        }
        connection = SQLiteConnection(handle: openedDatabase)
        sqlite3_busy_timeout(openedDatabase, 5_000)
        try Self.execute(openedDatabase, sql: "PRAGMA foreign_keys = ON;")
        try Self.execute(openedDatabase, sql: "PRAGMA journal_mode = WAL;")
        try Self.execute(openedDatabase, sql: "PRAGMA synchronous = FULL;")
        try Self.applyMigrations(to: openedDatabase)
    }

    public func schemaVersion() throws -> Int {
        try Self.schemaVersion(in: connection.handle)
    }

    public func save(scan: ScanMetadata, assets: [ScanAssetReference]) throws {
        let database = connection.handle
        try Self.transaction(on: database) {
            let statement = try Self.prepare(database, sql: """
            INSERT INTO scans (id, display_name, status, created_at, updated_at, duration_seconds, remote_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                status = excluded.status,
                updated_at = excluded.updated_at,
                duration_seconds = excluded.duration_seconds,
                remote_id = excluded.remote_id;
            """)
            defer { sqlite3_finalize(statement) }
            try Self.bindText(statement, index: 1, value: scan.id.uuidString)
            try Self.bindText(statement, index: 2, value: scan.displayName)
            try Self.bindText(statement, index: 3, value: scan.status.rawValue)
            try Self.bindDouble(statement, index: 4, value: scan.createdAt.timeIntervalSince1970)
            try Self.bindDouble(statement, index: 5, value: scan.updatedAt.timeIntervalSince1970)
            try Self.bindOptionalDouble(statement, index: 6, value: scan.durationSeconds)
            try Self.bindOptionalText(statement, index: 7, value: scan.remoteID)
            try Self.stepDone(statement)

            let deleteStatement = try Self.prepare(database, sql: "DELETE FROM scan_assets WHERE scan_id = ?;")
            defer { sqlite3_finalize(deleteStatement) }
            try Self.bindText(deleteStatement, index: 1, value: scan.id.uuidString)
            try Self.stepDone(deleteStatement)

            for asset in assets {
                let assetStatement = try Self.prepare(database, sql: """
                INSERT INTO scan_assets (id, scan_id, kind, relative_path, byte_count, sha256, spatial_reference, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """)
                defer { sqlite3_finalize(assetStatement) }
                try Self.bindText(assetStatement, index: 1, value: asset.id.uuidString)
                try Self.bindText(assetStatement, index: 2, value: scan.id.uuidString)
                try Self.bindText(assetStatement, index: 3, value: asset.kind.rawValue)
                try Self.bindText(assetStatement, index: 4, value: asset.relativePath)
                try Self.bindInt64(assetStatement, index: 5, value: asset.byteCount)
                try Self.bindText(assetStatement, index: 6, value: asset.sha256)
                try Self.bindText(assetStatement, index: 7, value: asset.spatialReference.rawValue)
                try Self.bindDouble(assetStatement, index: 8, value: asset.createdAt.timeIntervalSince1970)
                try Self.stepDone(assetStatement)
            }
        }
    }

    public func scan(id: UUID) throws -> ScanMetadata? {
        let database = connection.handle
        let statement = try Self.prepare(database, sql: """
        SELECT id, display_name, status, created_at, updated_at, duration_seconds, remote_id
        FROM scans WHERE id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: id.uuidString)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try Self.decodeScan(statement)
    }

    public func allScans() throws -> [ScanMetadata] {
        let database = connection.handle
        let statement = try Self.prepare(database, sql: """
        SELECT id, display_name, status, created_at, updated_at, duration_seconds, remote_id
        FROM scans ORDER BY updated_at DESC, id ASC;
        """)
        defer { sqlite3_finalize(statement) }
        var result: [ScanMetadata] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try Self.decodeScan(statement))
        }
        return result
    }

    /// Updates user-editable scan metadata without touching the asset index.
    public func rename(scanID: UUID, displayName: String, updatedAt: Date) throws -> Bool {
        let database = connection.handle
        let statement = try Self.prepare(database, sql: """
        UPDATE scans
        SET display_name = ?, updated_at = ?
        WHERE id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: displayName)
        try Self.bindDouble(statement, index: 2, value: updatedAt.timeIntervalSince1970)
        try Self.bindText(statement, index: 3, value: scanID.uuidString)
        try Self.stepDone(statement)
        return sqlite3_changes(database) > 0
    }

    public func delete(scanID: UUID) throws {
        let database = connection.handle
        let statement = try Self.prepare(database, sql: "DELETE FROM scans WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: scanID.uuidString)
        try Self.stepDone(statement)
    }

    /// Saves editable spatial metadata without modifying a scan package or its
    /// binary assets. A layer always belongs to exactly one saved scan.
    public func save(spatialLayer: SpatialLayer, forScanID scanID: UUID) throws {
        try spatialLayer.validate()

        let layerPropertiesJSON = try Self.encodedJSONString(spatialLayer.properties)
        let layerProvenanceJSON = try Self.encodedJSONString(spatialLayer.provenance)
        let encodedFeatures = try spatialLayer.features.map { feature in
            EncodedSpatialFeature(
                feature: feature,
                kindJSON: try Self.encodedJSONString(feature.kind),
                geometryJSON: try Self.encodedJSONString(feature.geometry),
                propertiesJSON: try Self.encodedJSONString(feature.properties),
                provenanceJSON: try Self.encodedJSONString(feature.provenance)
            )
        }

        let database = connection.handle
        guard try Self.scanExists(id: scanID, in: database) else {
            throw SpatialLayerStoreError.scanNotFound(scanID)
        }

        try Self.transaction(on: database) {
            if let existingScanID = try Self.spatialLayerScanID(id: spatialLayer.id, in: database), existingScanID != scanID {
                throw SpatialLayerStoreError.layerBelongsToAnotherScan(
                    layerID: spatialLayer.id,
                    scanID: existingScanID
                )
            }

            let layerStatement = try Self.prepare(database, sql: """
            INSERT INTO spatial_layers (
                id, scan_id, name, spatial_reference, properties_json,
                provenance_json, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                spatial_reference = excluded.spatial_reference,
                properties_json = excluded.properties_json,
                provenance_json = excluded.provenance_json,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at;
            """)
            defer { sqlite3_finalize(layerStatement) }
            try Self.bindText(layerStatement, index: 1, value: spatialLayer.id.uuidString)
            try Self.bindText(layerStatement, index: 2, value: scanID.uuidString)
            try Self.bindText(layerStatement, index: 3, value: spatialLayer.name)
            try Self.bindText(layerStatement, index: 4, value: spatialLayer.spatialReference.rawValue)
            try Self.bindText(layerStatement, index: 5, value: layerPropertiesJSON)
            try Self.bindText(layerStatement, index: 6, value: layerProvenanceJSON)
            try Self.bindDouble(layerStatement, index: 7, value: spatialLayer.createdAt.timeIntervalSince1970)
            try Self.bindDouble(layerStatement, index: 8, value: spatialLayer.updatedAt.timeIntervalSince1970)
            try Self.stepDone(layerStatement)

            let deleteFeaturesStatement = try Self.prepare(database, sql: "DELETE FROM spatial_features WHERE layer_id = ?;")
            defer { sqlite3_finalize(deleteFeaturesStatement) }
            try Self.bindText(deleteFeaturesStatement, index: 1, value: spatialLayer.id.uuidString)
            try Self.stepDone(deleteFeaturesStatement)

            for encodedFeature in encodedFeatures {
                let feature = encodedFeature.feature
                let featureStatement = try Self.prepare(database, sql: """
                INSERT INTO spatial_features (
                    id, layer_id, kind_json, geometry_json, properties_json,
                    provenance_json, spatial_reference, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """)
                defer { sqlite3_finalize(featureStatement) }
                try Self.bindText(featureStatement, index: 1, value: feature.id.uuidString)
                try Self.bindText(featureStatement, index: 2, value: spatialLayer.id.uuidString)
                try Self.bindText(featureStatement, index: 3, value: encodedFeature.kindJSON)
                try Self.bindText(featureStatement, index: 4, value: encodedFeature.geometryJSON)
                try Self.bindText(featureStatement, index: 5, value: encodedFeature.propertiesJSON)
                try Self.bindText(featureStatement, index: 6, value: encodedFeature.provenanceJSON)
                try Self.bindText(featureStatement, index: 7, value: feature.spatialReference.rawValue)
                try Self.bindDouble(featureStatement, index: 8, value: feature.createdAt.timeIntervalSince1970)
                try Self.bindDouble(featureStatement, index: 9, value: feature.updatedAt.timeIntervalSince1970)
                try Self.stepDone(featureStatement)
            }
        }
    }

    public func spatialLayers(forScanID scanID: UUID) throws -> [SpatialLayer] {
        let database = connection.handle
        let statement = try Self.prepare(database, sql: """
        SELECT id, name, spatial_reference, properties_json, provenance_json, created_at, updated_at
        FROM spatial_layers
        WHERE scan_id = ?
        ORDER BY updated_at DESC, id ASC;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: scanID.uuidString)

        var layers: [SpatialLayer] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var layer = try Self.decodeSpatialLayer(statement)
            layer.features = try Self.spatialFeatures(forLayerID: layer.id, in: database)
            try layer.validate()
            layers.append(layer)
        }
        return layers
    }

    @discardableResult
    public func deleteSpatialLayer(id: UUID, forScanID scanID: UUID) throws -> Bool {
        let database = connection.handle
        let statement = try Self.prepare(database, sql: """
        DELETE FROM spatial_layers
        WHERE id = ? AND scan_id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: id.uuidString)
        try Self.bindText(statement, index: 2, value: scanID.uuidString)
        try Self.stepDone(statement)
        return sqlite3_changes(database) > 0
    }

    /// Stores a selected before/after pair as metadata. The scan packages and
    /// their binary assets remain immutable.
    public func save(scanComparisonDraft: ScanComparisonDraft) throws {
        try scanComparisonDraft.validate()
        let database = connection.handle
        guard try Self.scanExists(id: scanComparisonDraft.baselineScanID, in: database) else {
            throw ScanComparisonDraftStoreError.scanNotFound(scanComparisonDraft.baselineScanID)
        }
        guard try Self.scanExists(id: scanComparisonDraft.comparisonScanID, in: database) else {
            throw ScanComparisonDraftStoreError.scanNotFound(scanComparisonDraft.comparisonScanID)
        }

        let statement = try Self.prepare(database, sql: """
        INSERT INTO scan_comparison_drafts (
            id, baseline_scan_id, comparison_scan_id, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            baseline_scan_id = excluded.baseline_scan_id,
            comparison_scan_id = excluded.comparison_scan_id,
            updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: scanComparisonDraft.id.uuidString)
        try Self.bindText(statement, index: 2, value: scanComparisonDraft.baselineScanID.uuidString)
        try Self.bindText(statement, index: 3, value: scanComparisonDraft.comparisonScanID.uuidString)
        try Self.bindDouble(statement, index: 4, value: scanComparisonDraft.createdAt.timeIntervalSince1970)
        try Self.bindDouble(statement, index: 5, value: scanComparisonDraft.updatedAt.timeIntervalSince1970)
        try Self.stepDone(statement)
    }

    public func latestScanComparisonDraft() throws -> ScanComparisonDraft? {
        let database = connection.handle
        let statement = try Self.prepare(database, sql: """
        SELECT id, baseline_scan_id, comparison_scan_id, created_at, updated_at
        FROM scan_comparison_drafts
        ORDER BY updated_at DESC, id ASC
        LIMIT 1;
        """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try Self.decodeScanComparisonDraft(statement)
    }

    /// Persists one finite work area for a comparison draft. The work area is
    /// always expressed in the baseline scan's existing AR-world coordinates.
    public func save(scanComparisonWorkArea: ScanComparisonWorkArea) throws {
        try scanComparisonWorkArea.validate()
        let database = connection.handle
        guard let baselineScanID = try Self.comparisonDraftBaselineScanID(
            id: scanComparisonWorkArea.draftID,
            in: database
        ) else {
            throw ScanComparisonDraftStoreError.draftNotFound(scanComparisonWorkArea.draftID)
        }
        guard baselineScanID == scanComparisonWorkArea.referenceScanID else {
            throw ScanComparisonDraftStoreError.workAreaReferenceDoesNotMatchBaseline
        }
        let minimumJSON = try Self.encodedJSONString(scanComparisonWorkArea.minimum)
        let maximumJSON = try Self.encodedJSONString(scanComparisonWorkArea.maximum)
        let statement = try Self.prepare(database, sql: """
        INSERT INTO scan_comparison_work_areas (
            id, draft_id, reference_scan_id, minimum_json, maximum_json, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(draft_id) DO UPDATE SET
            reference_scan_id = excluded.reference_scan_id,
            minimum_json = excluded.minimum_json,
            maximum_json = excluded.maximum_json,
            updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: scanComparisonWorkArea.id.uuidString)
        try Self.bindText(statement, index: 2, value: scanComparisonWorkArea.draftID.uuidString)
        try Self.bindText(statement, index: 3, value: scanComparisonWorkArea.referenceScanID.uuidString)
        try Self.bindText(statement, index: 4, value: minimumJSON)
        try Self.bindText(statement, index: 5, value: maximumJSON)
        try Self.bindDouble(statement, index: 6, value: scanComparisonWorkArea.createdAt.timeIntervalSince1970)
        try Self.bindDouble(statement, index: 7, value: scanComparisonWorkArea.updatedAt.timeIntervalSince1970)
        try Self.stepDone(statement)
    }

    public func scanComparisonWorkArea(forDraftID draftID: UUID) throws -> ScanComparisonWorkArea? {
        let database = connection.handle
        let statement = try Self.prepare(database, sql: """
        SELECT id, reference_scan_id, minimum_json, maximum_json, created_at, updated_at
        FROM scan_comparison_work_areas
        WHERE draft_id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: draftID.uuidString)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try Self.decodeScanComparisonWorkArea(statement, draftID: draftID)
    }

    /// Saves mine-level metadata separately from immutable scan packages.
    /// A project coordinate reference is descriptive provenance; it does not
    /// create an AR-world-to-mine transform by itself.
    public func save(mineProject: MineProject) throws {
        try mineProject.validate()
        let coordinateReferenceJSON = try Self.encodedJSONString(mineProject.coordinateReference)
        let database = connection.handle
        let statement = try Self.prepare(database, sql: """
        INSERT INTO mine_projects (id, name, coordinate_reference_json, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            coordinate_reference_json = excluded.coordinate_reference_json,
            updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: mineProject.id.uuidString)
        try Self.bindText(statement, index: 2, value: mineProject.name)
        try Self.bindText(statement, index: 3, value: coordinateReferenceJSON)
        try Self.bindDouble(statement, index: 4, value: mineProject.createdAt.timeIntervalSince1970)
        try Self.bindDouble(statement, index: 5, value: mineProject.updatedAt.timeIntervalSince1970)
        try Self.stepDone(statement)
    }

    public func mineProject(id: UUID) throws -> MineProject? {
        let database = connection.handle
        let statement = try Self.prepare(database, sql: """
        SELECT id, name, coordinate_reference_json, created_at, updated_at
        FROM mine_projects WHERE id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: id.uuidString)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try Self.decodeMineProject(statement)
    }

    public func mineProjects() throws -> [MineProject] {
        let database = connection.handle
        let statement = try Self.prepare(database, sql: """
        SELECT id, name, coordinate_reference_json, created_at, updated_at
        FROM mine_projects ORDER BY updated_at DESC, id ASC;
        """)
        defer { sqlite3_finalize(statement) }
        var projects: [MineProject] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            projects.append(try Self.decodeMineProject(statement))
        }
        return projects
    }

    public func save(mineControlPoint: MineControlPoint) throws {
        try mineControlPoint.validate()
        let database = connection.handle
        guard try Self.mineProjectExists(id: mineControlPoint.projectID, in: database) else {
            throw MineSurveyStoreError.projectNotFound(mineControlPoint.projectID)
        }
        let positionJSON = try Self.encodedJSONString(mineControlPoint.minePosition)
        let statement = try Self.prepare(database, sql: """
        INSERT INTO mine_control_points (id, project_id, code, mine_position_json, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            project_id = excluded.project_id,
            code = excluded.code,
            mine_position_json = excluded.mine_position_json,
            updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: mineControlPoint.id.uuidString)
        try Self.bindText(statement, index: 2, value: mineControlPoint.projectID.uuidString)
        try Self.bindText(statement, index: 3, value: mineControlPoint.code)
        try Self.bindText(statement, index: 4, value: positionJSON)
        try Self.bindDouble(statement, index: 5, value: mineControlPoint.createdAt.timeIntervalSince1970)
        try Self.bindDouble(statement, index: 6, value: mineControlPoint.updatedAt.timeIntervalSince1970)
        try Self.stepDone(statement)
    }

    public func mineControlPoints(projectID: UUID) throws -> [MineControlPoint] {
        let database = connection.handle
        guard try Self.mineProjectExists(id: projectID, in: database) else {
            throw MineSurveyStoreError.projectNotFound(projectID)
        }
        let statement = try Self.prepare(database, sql: """
        SELECT id, project_id, code, mine_position_json, created_at, updated_at
        FROM mine_control_points
        WHERE project_id = ?
        ORDER BY code COLLATE NOCASE ASC, id ASC;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: projectID.uuidString)
        var controlPoints: [MineControlPoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            controlPoints.append(try Self.decodeMineControlPoint(statement))
        }
        return controlPoints
    }

    /// Persists an already-estimated, rigid mineFromARWorld relationship. The
    /// raw scan package remains untouched and the source control identifiers
    /// make the registration auditable.
    public func save(mineScanRegistration: MineScanRegistration) throws {
        try mineScanRegistration.validate()
        let database = connection.handle
        guard try Self.mineProjectExists(id: mineScanRegistration.projectID, in: database) else {
            throw MineSurveyStoreError.projectNotFound(mineScanRegistration.projectID)
        }
        guard try Self.scanExists(id: mineScanRegistration.scanID, in: database) else {
            throw MineSurveyStoreError.scanNotFound(mineScanRegistration.scanID)
        }
        for controlPointID in mineScanRegistration.controlPointIDs {
            guard let controlProjectID = try Self.mineControlPointProjectID(id: controlPointID, in: database) else {
                throw MineSurveyStoreError.controlPointNotFound(controlPointID)
            }
            guard controlProjectID == mineScanRegistration.projectID else {
                throw MineSurveyStoreError.controlPointOutsideProject(
                    controlPointID: controlPointID,
                    projectID: mineScanRegistration.projectID
                )
            }
        }

        let transformJSON = try Self.encodedJSONString(mineScanRegistration.mineFromARWorld)
        let controlPointIDsJSON = try Self.encodedJSONString(mineScanRegistration.controlPointIDs)
        let statement = try Self.prepare(database, sql: """
        INSERT INTO mine_scan_registrations (
            id, project_id, scan_id, mine_from_ar_world_json, method,
            rms_residual_meters, control_point_ids_json, created_at, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(project_id, scan_id) DO UPDATE SET
            mine_from_ar_world_json = excluded.mine_from_ar_world_json,
            method = excluded.method,
            rms_residual_meters = excluded.rms_residual_meters,
            control_point_ids_json = excluded.control_point_ids_json,
            updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: mineScanRegistration.id.uuidString)
        try Self.bindText(statement, index: 2, value: mineScanRegistration.projectID.uuidString)
        try Self.bindText(statement, index: 3, value: mineScanRegistration.scanID.uuidString)
        try Self.bindText(statement, index: 4, value: transformJSON)
        try Self.bindText(statement, index: 5, value: mineScanRegistration.method.rawValue)
        try Self.bindDouble(statement, index: 6, value: Double(mineScanRegistration.rmsResidualMeters))
        try Self.bindText(statement, index: 7, value: controlPointIDsJSON)
        try Self.bindDouble(statement, index: 8, value: mineScanRegistration.createdAt.timeIntervalSince1970)
        try Self.bindDouble(statement, index: 9, value: mineScanRegistration.updatedAt.timeIntervalSince1970)
        try Self.stepDone(statement)
    }

    public func mineScanRegistration(projectID: UUID, scanID: UUID) throws -> MineScanRegistration? {
        let database = connection.handle
        let statement = try Self.prepare(database, sql: """
        SELECT id, project_id, scan_id, mine_from_ar_world_json, method,
               rms_residual_meters, control_point_ids_json, created_at, updated_at
        FROM mine_scan_registrations
        WHERE project_id = ? AND scan_id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: projectID.uuidString)
        try Self.bindText(statement, index: 2, value: scanID.uuidString)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try Self.decodeMineScanRegistration(statement)
    }

    public func save(mineStation: MineScanStation) throws {
        try mineStation.validate()
        let database = connection.handle
        guard try Self.mineProjectExists(id: mineStation.projectID, in: database) else {
            throw MineSurveyStoreError.projectNotFound(mineStation.projectID)
        }
        guard let registration = try Self.mineScanRegistration(id: mineStation.registrationID, in: database),
              registration.projectID == mineStation.projectID,
              registration.scanID == mineStation.scanID
        else {
            throw MineTraverseError.stationRequiresRegistration
        }
        if case let .relocalized(fromStationID) = mineStation.sessionContext {
            guard let previousStation = try Self.mineStation(id: fromStationID, in: database) else {
                throw MineTraverseError.relocalizationStationNotFound(fromStationID)
            }
            guard previousStation.projectID == mineStation.projectID else {
                throw MineTraverseError.relocalizationStationOutsideProject(fromStationID)
            }
        }
        let contextJSON = try Self.encodedJSONString(mineStation.sessionContext)
        let statement = try Self.prepare(database, sql: """
        INSERT INTO mine_scan_stations (
            id, project_id, scan_id, registration_id, code, session_context_json, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            project_id = excluded.project_id, scan_id = excluded.scan_id,
            registration_id = excluded.registration_id, code = excluded.code,
            session_context_json = excluded.session_context_json, updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: mineStation.id.uuidString)
        try Self.bindText(statement, index: 2, value: mineStation.projectID.uuidString)
        try Self.bindText(statement, index: 3, value: mineStation.scanID.uuidString)
        try Self.bindText(statement, index: 4, value: mineStation.registrationID.uuidString)
        try Self.bindText(statement, index: 5, value: mineStation.code)
        try Self.bindText(statement, index: 6, value: contextJSON)
        try Self.bindDouble(statement, index: 7, value: mineStation.createdAt.timeIntervalSince1970)
        try Self.bindDouble(statement, index: 8, value: mineStation.updatedAt.timeIntervalSince1970)
        try Self.stepDone(statement)
    }

    public func mineStations(projectID: UUID) throws -> [MineScanStation] {
        let database = connection.handle
        guard try Self.mineProjectExists(id: projectID, in: database) else { throw MineSurveyStoreError.projectNotFound(projectID) }
        let statement = try Self.prepare(database, sql: """
        SELECT id, project_id, scan_id, registration_id, code, session_context_json, created_at, updated_at
        FROM mine_scan_stations WHERE project_id = ? ORDER BY code COLLATE NOCASE ASC, id ASC;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: projectID.uuidString)
        var result: [MineScanStation] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(try Self.decodeMineStation(statement)) }
        return result
    }

    public func save(mineTraverseLink: MineTraverseLink) throws {
        try mineTraverseLink.validate()
        let database = connection.handle
        guard try Self.mineProjectExists(id: mineTraverseLink.projectID, in: database) else { throw MineSurveyStoreError.projectNotFound(mineTraverseLink.projectID) }
        let stations = try [mineTraverseLink.fromStationID, mineTraverseLink.toStationID].map { id in
            guard let station = try Self.mineStation(id: id, in: database) else { throw MineSurveyStoreError.stationNotFound(id) }
            guard station.projectID == mineTraverseLink.projectID else { throw MineSurveyStoreError.stationOutsideProject(stationID: id, projectID: mineTraverseLink.projectID) }
            return station
        }
        let registrations = try stations.map { station in
            guard let registration = try Self.mineScanRegistration(id: station.registrationID, in: database) else { throw MineTraverseError.stationRequiresRegistration }
            return registration
        }
        let sharedControls = Set(registrations[0].controlPointIDs).intersection(registrations[1].controlPointIDs)
        for checkpointID in mineTraverseLink.checkpointControlPointIDs {
            guard sharedControls.contains(checkpointID) else { throw MineTraverseError.checkpointNotSharedByStations(checkpointID) }
        }
        let checkpointJSON = try Self.encodedJSONString(mineTraverseLink.checkpointControlPointIDs)
        let statement = try Self.prepare(database, sql: """
        INSERT INTO mine_traverse_links (id, project_id, from_station_id, to_station_id, checkpoint_control_point_ids_json, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            project_id = excluded.project_id, from_station_id = excluded.from_station_id,
            to_station_id = excluded.to_station_id, checkpoint_control_point_ids_json = excluded.checkpoint_control_point_ids_json,
            updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: mineTraverseLink.id.uuidString)
        try Self.bindText(statement, index: 2, value: mineTraverseLink.projectID.uuidString)
        try Self.bindText(statement, index: 3, value: mineTraverseLink.fromStationID.uuidString)
        try Self.bindText(statement, index: 4, value: mineTraverseLink.toStationID.uuidString)
        try Self.bindText(statement, index: 5, value: checkpointJSON)
        try Self.bindDouble(statement, index: 6, value: mineTraverseLink.createdAt.timeIntervalSince1970)
        try Self.bindDouble(statement, index: 7, value: mineTraverseLink.updatedAt.timeIntervalSince1970)
        try Self.stepDone(statement)
    }

    public func save(surveyEpoch: SurveyEpoch) throws {
        try surveyEpoch.validate()
        let database = connection.handle
        guard try Self.mineProjectExists(id: surveyEpoch.projectID, in: database) else { throw MineSurveyStoreError.projectNotFound(surveyEpoch.projectID) }
        for stationID in surveyEpoch.stationIDs {
            guard let station = try Self.mineStation(id: stationID, in: database) else { throw MineSurveyStoreError.stationNotFound(stationID) }
            guard station.projectID == surveyEpoch.projectID else { throw MineSurveyStoreError.stationOutsideProject(stationID: stationID, projectID: surveyEpoch.projectID) }
        }
        try Self.transaction(on: database) {
            let statement = try Self.prepare(database, sql: "INSERT INTO survey_epochs (id, project_id, name, kind, captured_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET project_id = excluded.project_id, name = excluded.name, kind = excluded.kind, captured_at = excluded.captured_at;")
            defer { sqlite3_finalize(statement) }
            try Self.bindText(statement, index: 1, value: surveyEpoch.id.uuidString); try Self.bindText(statement, index: 2, value: surveyEpoch.projectID.uuidString); try Self.bindText(statement, index: 3, value: surveyEpoch.name); try Self.bindText(statement, index: 4, value: surveyEpoch.kind.rawValue); try Self.bindDouble(statement, index: 5, value: surveyEpoch.capturedAt.timeIntervalSince1970); try Self.stepDone(statement)
            let delete = try Self.prepare(database, sql: "DELETE FROM survey_epoch_stations WHERE epoch_id = ?;")
            defer { sqlite3_finalize(delete) }; try Self.bindText(delete, index: 1, value: surveyEpoch.id.uuidString); try Self.stepDone(delete)
            for stationID in surveyEpoch.stationIDs {
                let link = try Self.prepare(database, sql: "INSERT INTO survey_epoch_stations (epoch_id, station_id) VALUES (?, ?);")
                defer { sqlite3_finalize(link) }; try Self.bindText(link, index: 1, value: surveyEpoch.id.uuidString); try Self.bindText(link, index: 2, value: stationID.uuidString); try Self.stepDone(link)
            }
        }
    }

    public func save(surveyChangeBoundary: SurveyChangeBoundary) throws {
        try surveyChangeBoundary.validate()
        let database = connection.handle
        guard try Self.mineProjectExists(id: surveyChangeBoundary.projectID, in: database) else { throw MineSurveyStoreError.projectNotFound(surveyChangeBoundary.projectID) }
        let minJSON = try Self.encodedJSONString(surveyChangeBoundary.minimum), maxJSON = try Self.encodedJSONString(surveyChangeBoundary.maximum)
        let statement = try Self.prepare(database, sql: "INSERT INTO survey_change_boundaries (id, project_id, name, minimum_json, maximum_json, created_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET project_id = excluded.project_id, name = excluded.name, minimum_json = excluded.minimum_json, maximum_json = excluded.maximum_json;")
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: surveyChangeBoundary.id.uuidString); try Self.bindText(statement, index: 2, value: surveyChangeBoundary.projectID.uuidString); try Self.bindText(statement, index: 3, value: surveyChangeBoundary.name); try Self.bindText(statement, index: 4, value: minJSON); try Self.bindText(statement, index: 5, value: maxJSON); try Self.bindDouble(statement, index: 6, value: surveyChangeBoundary.createdAt.timeIntervalSince1970); try Self.stepDone(statement)
    }

    public func save(surveyChangeComparison: SurveyChangeComparison) throws {
        try surveyChangeComparison.validate()
        let database = connection.handle
        guard let baseline = try Self.surveyEpoch(id: surveyChangeComparison.baselineEpochID, in: database), baseline.projectID == surveyChangeComparison.projectID, baseline.kind == .baseline else { throw MineSurveyStoreError.surveyEpochNotFound(surveyChangeComparison.baselineEpochID) }
        guard let comparison = try Self.surveyEpoch(id: surveyChangeComparison.comparisonEpochID, in: database), comparison.projectID == surveyChangeComparison.projectID, comparison.kind == .comparison else { throw MineSurveyStoreError.surveyEpochNotFound(surveyChangeComparison.comparisonEpochID) }
        guard let boundaryProjectID = try Self.surveyBoundaryProjectID(id: surveyChangeComparison.boundaryID, in: database), boundaryProjectID == surveyChangeComparison.projectID else { throw MineSurveyStoreError.surveyBoundaryNotFound(surveyChangeComparison.boundaryID) }
        let statement = try Self.prepare(database, sql: "INSERT INTO survey_change_comparisons (id, project_id, baseline_epoch_id, comparison_epoch_id, boundary_id, created_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET project_id = excluded.project_id, baseline_epoch_id = excluded.baseline_epoch_id, comparison_epoch_id = excluded.comparison_epoch_id, boundary_id = excluded.boundary_id;")
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: surveyChangeComparison.id.uuidString); try Self.bindText(statement, index: 2, value: surveyChangeComparison.projectID.uuidString); try Self.bindText(statement, index: 3, value: surveyChangeComparison.baselineEpochID.uuidString); try Self.bindText(statement, index: 4, value: surveyChangeComparison.comparisonEpochID.uuidString); try Self.bindText(statement, index: 5, value: surveyChangeComparison.boundaryID.uuidString); try Self.bindDouble(statement, index: 6, value: surveyChangeComparison.createdAt.timeIntervalSince1970); try Self.stepDone(statement)
    }

    public func saveAlignment(_ alignment: ScanAlignment) throws {
        guard alignment.targetScanID != alignment.sourceScanID else {
            throw AlignmentError.sameScan
        }
        let transformData = try JSONEncoder().encode(alignment.targetFromSource)
        guard let transformJSON = String(data: transformData, encoding: .utf8) else {
            throw SQLiteStoreError.invalidRecord("Could not encode alignment transform")
        }
        let database = connection.handle
        let statement = try Self.prepare(database, sql: """
        INSERT INTO alignments (id, target_scan_id, source_scan_id, transform_json, method, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(target_scan_id, source_scan_id) DO UPDATE SET
            transform_json = excluded.transform_json,
            method = excluded.method,
            updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: alignment.id.uuidString)
        try Self.bindText(statement, index: 2, value: alignment.targetScanID.uuidString)
        try Self.bindText(statement, index: 3, value: alignment.sourceScanID.uuidString)
        try Self.bindText(statement, index: 4, value: transformJSON)
        try Self.bindText(statement, index: 5, value: alignment.method.rawValue)
        try Self.bindDouble(statement, index: 6, value: alignment.createdAt.timeIntervalSince1970)
        try Self.bindDouble(statement, index: 7, value: alignment.updatedAt.timeIntervalSince1970)
        try Self.stepDone(statement)
    }

    public func alignment(targetScanID: UUID, sourceScanID: UUID) throws -> ScanAlignment? {
        let database = connection.handle
        let statement = try Self.prepare(database, sql: """
        SELECT id, target_scan_id, source_scan_id, transform_json, method, created_at, updated_at
        FROM alignments WHERE target_scan_id = ? AND source_scan_id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: targetScanID.uuidString)
        try Self.bindText(statement, index: 2, value: sourceScanID.uuidString)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try Self.decodeAlignment(statement)
    }

    public func deleteAlignment(targetScanID: UUID, sourceScanID: UUID) throws {
        let database = connection.handle
        let statement = try Self.prepare(database, sql: "DELETE FROM alignments WHERE target_scan_id = ? AND source_scan_id = ?;")
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: targetScanID.uuidString)
        try Self.bindText(statement, index: 2, value: sourceScanID.uuidString)
        try Self.stepDone(statement)
    }

    /// Persists the explicit landmark evidence alongside the independent
    /// transform. Both records use the same target/source direction.
    public func save(scanAlignmentLandmarks landmarks: ScanAlignmentLandmarkSet) throws {
        try landmarks.validate()
        let targetJSON = try Self.encodedJSONString(landmarks.targetLandmarks)
        let sourceJSON = try Self.encodedJSONString(landmarks.sourceLandmarks)
        let database = connection.handle
        let statement = try Self.prepare(database, sql: """
        INSERT INTO scan_alignment_landmarks (
            id, target_scan_id, source_scan_id, target_landmarks_json,
            source_landmarks_json, rms_error_meters, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(target_scan_id, source_scan_id) DO UPDATE SET
            id = excluded.id,
            target_landmarks_json = excluded.target_landmarks_json,
            source_landmarks_json = excluded.source_landmarks_json,
            rms_error_meters = excluded.rms_error_meters,
            created_at = excluded.created_at,
            updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: landmarks.id.uuidString)
        try Self.bindText(statement, index: 2, value: landmarks.targetScanID.uuidString)
        try Self.bindText(statement, index: 3, value: landmarks.sourceScanID.uuidString)
        try Self.bindText(statement, index: 4, value: targetJSON)
        try Self.bindText(statement, index: 5, value: sourceJSON)
        try Self.bindDouble(statement, index: 6, value: Double(landmarks.rmsErrorMeters))
        try Self.bindDouble(statement, index: 7, value: landmarks.createdAt.timeIntervalSince1970)
        try Self.bindDouble(statement, index: 8, value: landmarks.updatedAt.timeIntervalSince1970)
        try Self.stepDone(statement)
    }

    /// Commits the transform and the correspondence evidence together. A
    /// partially saved alignment must never look usable for comparison.
    public func save(alignment: ScanAlignment, landmarks: ScanAlignmentLandmarkSet) throws {
        guard
            alignment.targetScanID == landmarks.targetScanID,
            alignment.sourceScanID == landmarks.sourceScanID
        else {
            throw AlignmentError.invalidTransform
        }
        try landmarks.validate()
        let database = connection.handle
        try Self.transaction(on: database) {
            try saveAlignment(alignment)
            try save(scanAlignmentLandmarks: landmarks)
        }
    }

    public func scanAlignmentLandmarks(
        targetScanID: UUID,
        sourceScanID: UUID
    ) throws -> ScanAlignmentLandmarkSet? {
        let database = connection.handle
        let statement = try Self.prepare(database, sql: """
        SELECT id, target_scan_id, source_scan_id, target_landmarks_json,
               source_landmarks_json, rms_error_meters, created_at, updated_at
        FROM scan_alignment_landmarks
        WHERE target_scan_id = ? AND source_scan_id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: targetScanID.uuidString)
        try Self.bindText(statement, index: 2, value: sourceScanID.uuidString)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try Self.decodeScanAlignmentLandmarkSet(statement)
    }

    private static func applyMigrations(to database: OpaquePointer) throws {
        try execute(database, sql: """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at REAL NOT NULL
        );
        """)

        if try schemaVersion(in: database) < 1 {
            try transaction(on: database) {
                try execute(database, sql: """
                CREATE TABLE scans (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    status TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    duration_seconds REAL,
                    remote_id TEXT
                );
                CREATE TABLE scan_assets (
                    id TEXT PRIMARY KEY NOT NULL,
                    scan_id TEXT NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    byte_count INTEGER NOT NULL,
                    sha256 TEXT NOT NULL,
                    spatial_reference TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    UNIQUE(scan_id, relative_path)
                );
                CREATE TABLE sync_records (
                    local_id TEXT PRIMARY KEY NOT NULL,
                    remote_id TEXT,
                    revision TEXT,
                    status TEXT NOT NULL,
                    checksum TEXT,
                    retry_count INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE alerts (
                    id TEXT PRIMARY KEY NOT NULL,
                    category TEXT NOT NULL,
                    title TEXT NOT NULL,
                    message TEXT NOT NULL,
                    is_read INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL
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
                CREATE TABLE alignments (
                    id TEXT PRIMARY KEY NOT NULL,
                    target_scan_id TEXT NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                    source_scan_id TEXT NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                    transform_json TEXT NOT NULL,
                    method TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    UNIQUE(target_scan_id, source_scan_id)
                );
                CREATE TABLE processing_jobs (
                    id TEXT PRIMARY KEY NOT NULL,
                    scan_id TEXT NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    status TEXT NOT NULL,
                    error TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE app_settings (
                    key TEXT PRIMARY KEY NOT NULL,
                    value_json TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                """)
                let migration = try prepare(database, sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (1, ?);")
                defer { sqlite3_finalize(migration) }
                try bindDouble(migration, index: 1, value: Date.now.timeIntervalSince1970)
                try stepDone(migration)
            }
        }

        if try schemaVersion(in: database) < 2 {
            try transaction(on: database) {
                try execute(database, sql: """
                ALTER TABLE spatial_layers ADD COLUMN properties_json TEXT NOT NULL DEFAULT '{}';
                ALTER TABLE spatial_layers ADD COLUMN provenance_json TEXT NOT NULL DEFAULT '{"source":"legacy spatial metadata","metadata":{}}';
                ALTER TABLE spatial_features ADD COLUMN kind_json TEXT NOT NULL DEFAULT '{"type":"custom","customType":"legacy"}';
                ALTER TABLE spatial_features ADD COLUMN spatial_reference TEXT NOT NULL DEFAULT 'scanLocal';
                UPDATE spatial_features
                SET spatial_reference = (
                    SELECT spatial_reference
                    FROM spatial_layers
                    WHERE spatial_layers.id = spatial_features.layer_id
                );
                CREATE INDEX IF NOT EXISTS spatial_layers_by_scan_updated
                    ON spatial_layers(scan_id, updated_at DESC, id ASC);
                CREATE INDEX IF NOT EXISTS spatial_features_by_layer_created
                    ON spatial_features(layer_id, created_at ASC, id ASC);
                """)
                let migration = try prepare(database, sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (2, ?);")
                defer { sqlite3_finalize(migration) }
                try bindDouble(migration, index: 1, value: Date.now.timeIntervalSince1970)
                try stepDone(migration)
            }
        }

        if try schemaVersion(in: database) < 3 {
            try transaction(on: database) {
                try execute(database, sql: """
                CREATE TABLE mine_projects (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    coordinate_reference_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE mine_control_points (
                    id TEXT PRIMARY KEY NOT NULL,
                    project_id TEXT NOT NULL REFERENCES mine_projects(id) ON DELETE CASCADE,
                    code TEXT NOT NULL,
                    mine_position_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    UNIQUE(project_id, code)
                );
                CREATE TABLE mine_scan_registrations (
                    id TEXT PRIMARY KEY NOT NULL,
                    project_id TEXT NOT NULL REFERENCES mine_projects(id) ON DELETE CASCADE,
                    scan_id TEXT NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                    mine_from_ar_world_json TEXT NOT NULL,
                    method TEXT NOT NULL,
                    rms_residual_meters REAL NOT NULL,
                    control_point_ids_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    UNIQUE(project_id, scan_id)
                );
                CREATE INDEX mine_control_points_by_project_code
                    ON mine_control_points(project_id, code COLLATE NOCASE, id ASC);
                CREATE INDEX mine_scan_registrations_by_scan
                    ON mine_scan_registrations(scan_id, project_id);
                """)
                let migration = try prepare(database, sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (3, ?);")
                defer { sqlite3_finalize(migration) }
                try bindDouble(migration, index: 1, value: Date.now.timeIntervalSince1970)
                try stepDone(migration)
            }
        }

        if try schemaVersion(in: database) < 4 {
            try transaction(on: database) {
                try execute(database, sql: """
                CREATE TABLE mine_scan_stations (
                    id TEXT PRIMARY KEY NOT NULL,
                    project_id TEXT NOT NULL REFERENCES mine_projects(id) ON DELETE CASCADE,
                    scan_id TEXT NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                    registration_id TEXT NOT NULL REFERENCES mine_scan_registrations(id) ON DELETE RESTRICT,
                    code TEXT NOT NULL,
                    session_context_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    UNIQUE(project_id, scan_id),
                    UNIQUE(project_id, code)
                );
                CREATE TABLE mine_traverse_links (
                    id TEXT PRIMARY KEY NOT NULL,
                    project_id TEXT NOT NULL REFERENCES mine_projects(id) ON DELETE CASCADE,
                    from_station_id TEXT NOT NULL REFERENCES mine_scan_stations(id) ON DELETE RESTRICT,
                    to_station_id TEXT NOT NULL REFERENCES mine_scan_stations(id) ON DELETE RESTRICT,
                    checkpoint_control_point_ids_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    UNIQUE(project_id, from_station_id, to_station_id)
                );
                CREATE INDEX mine_stations_by_project_code ON mine_scan_stations(project_id, code COLLATE NOCASE, id ASC);
                CREATE INDEX mine_traverse_links_by_project ON mine_traverse_links(project_id, created_at ASC, id ASC);
                """)
                let migration = try prepare(database, sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (4, ?);")
                defer { sqlite3_finalize(migration) }
                try bindDouble(migration, index: 1, value: Date.now.timeIntervalSince1970)
                try stepDone(migration)
            }
        }

        if try schemaVersion(in: database) < 5 {
            try transaction(on: database) {
                try execute(database, sql: """
                CREATE TABLE survey_epochs (id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES mine_projects(id) ON DELETE CASCADE, name TEXT NOT NULL, kind TEXT NOT NULL, captured_at REAL NOT NULL);
                CREATE TABLE survey_epoch_stations (epoch_id TEXT NOT NULL REFERENCES survey_epochs(id) ON DELETE CASCADE, station_id TEXT NOT NULL REFERENCES mine_scan_stations(id) ON DELETE RESTRICT, PRIMARY KEY(epoch_id, station_id));
                CREATE TABLE survey_change_boundaries (id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES mine_projects(id) ON DELETE CASCADE, name TEXT NOT NULL, minimum_json TEXT NOT NULL, maximum_json TEXT NOT NULL, created_at REAL NOT NULL);
                CREATE TABLE survey_change_comparisons (id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES mine_projects(id) ON DELETE CASCADE, baseline_epoch_id TEXT NOT NULL REFERENCES survey_epochs(id) ON DELETE RESTRICT, comparison_epoch_id TEXT NOT NULL REFERENCES survey_epochs(id) ON DELETE RESTRICT, boundary_id TEXT NOT NULL REFERENCES survey_change_boundaries(id) ON DELETE RESTRICT, created_at REAL NOT NULL);
                CREATE INDEX survey_epochs_by_project_capture ON survey_epochs(project_id, captured_at ASC, id ASC);
                """)
                let migration = try prepare(database, sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (5, ?);")
                defer { sqlite3_finalize(migration) }; try bindDouble(migration, index: 1, value: Date.now.timeIntervalSince1970); try stepDone(migration)
            }
        }

        if try schemaVersion(in: database) < 6 {
            try transaction(on: database) {
                try execute(database, sql: """
                CREATE TABLE scan_comparison_drafts (
                    id TEXT PRIMARY KEY NOT NULL,
                    baseline_scan_id TEXT NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                    comparison_scan_id TEXT NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    CHECK (baseline_scan_id <> comparison_scan_id)
                );
                CREATE INDEX scan_comparison_drafts_by_updated
                    ON scan_comparison_drafts(updated_at DESC, id ASC);
                """)
                let migration = try prepare(database, sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (6, ?);")
                defer { sqlite3_finalize(migration) }
                try bindDouble(migration, index: 1, value: Date.now.timeIntervalSince1970)
                try stepDone(migration)
            }
        }

        if try schemaVersion(in: database) < 7 {
            try transaction(on: database) {
                try execute(database, sql: """
                CREATE TABLE scan_comparison_work_areas (
                    id TEXT PRIMARY KEY NOT NULL,
                    draft_id TEXT NOT NULL UNIQUE REFERENCES scan_comparison_drafts(id) ON DELETE CASCADE,
                    reference_scan_id TEXT NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                    minimum_json TEXT NOT NULL,
                    maximum_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                """)
                let migration = try prepare(database, sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (7, ?);")
                defer { sqlite3_finalize(migration) }
                try bindDouble(migration, index: 1, value: Date.now.timeIntervalSince1970)
                try stepDone(migration)
            }
        }

        if try schemaVersion(in: database) < 8 {
            try transaction(on: database) {
                try execute(database, sql: """
                CREATE TABLE scan_alignment_landmarks (
                    id TEXT PRIMARY KEY NOT NULL,
                    target_scan_id TEXT NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                    source_scan_id TEXT NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                    target_landmarks_json TEXT NOT NULL,
                    source_landmarks_json TEXT NOT NULL,
                    rms_error_meters REAL NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    UNIQUE(target_scan_id, source_scan_id),
                    CHECK (target_scan_id <> source_scan_id)
                );
                """)
                let migration = try prepare(database, sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (8, ?);")
                defer { sqlite3_finalize(migration) }
                try bindDouble(migration, index: 1, value: Date.now.timeIntervalSince1970)
                try stepDone(migration)
            }
        }
    }

    private static func schemaVersion(in database: OpaquePointer) throws -> Int {
        let statement = try prepare(database, sql: "SELECT COALESCE(MAX(version), 0) FROM schema_migrations;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteStoreError.executionFailed(message(from: database))
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func decodeScan(_ statement: OpaquePointer) throws -> ScanMetadata {
        guard
            let idString = columnText(statement, index: 0),
            let id = UUID(uuidString: idString),
            let displayName = columnText(statement, index: 1),
            let rawStatus = columnText(statement, index: 2),
            let status = ScanStatus(rawValue: rawStatus)
        else {
            throw SQLiteStoreError.invalidRecord("Invalid scan row")
        }
        let duration = sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 5)
        return ScanMetadata(
            id: id,
            displayName: displayName,
            status: status,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            durationSeconds: duration,
            remoteID: columnText(statement, index: 6)
        )
    }

    private static func decodeAlignment(_ statement: OpaquePointer) throws -> ScanAlignment {
        guard
            let idString = columnText(statement, index: 0),
            let id = UUID(uuidString: idString),
            let targetString = columnText(statement, index: 1),
            let targetScanID = UUID(uuidString: targetString),
            let sourceString = columnText(statement, index: 2),
            let sourceScanID = UUID(uuidString: sourceString),
            let transformJSON = columnText(statement, index: 3),
            let methodRawValue = columnText(statement, index: 4),
            let method = AlignmentMethod(rawValue: methodRawValue)
        else {
            throw SQLiteStoreError.invalidRecord("Invalid alignment row")
        }
        do {
            let transform = try JSONDecoder().decode(Transform4x4.self, from: Data(transformJSON.utf8))
            return ScanAlignment(
                id: id,
                targetScanID: targetScanID,
                sourceScanID: sourceScanID,
                targetFromSource: transform,
                method: method,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            )
        } catch {
            throw SQLiteStoreError.invalidRecord("Invalid alignment transform")
        }
    }

    private static func decodeScanAlignmentLandmarkSet(
        _ statement: OpaquePointer
    ) throws -> ScanAlignmentLandmarkSet {
        guard
            let idText = columnText(statement, index: 0), let id = UUID(uuidString: idText),
            let targetText = columnText(statement, index: 1), let targetScanID = UUID(uuidString: targetText),
            let sourceText = columnText(statement, index: 2), let sourceScanID = UUID(uuidString: sourceText),
            let targetJSON = columnText(statement, index: 3),
            let sourceJSON = columnText(statement, index: 4)
        else {
            throw SQLiteStoreError.invalidRecord("Invalid scan alignment landmarks row")
        }
        do {
            let landmarks = ScanAlignmentLandmarkSet(
                id: id,
                targetScanID: targetScanID,
                sourceScanID: sourceScanID,
                targetLandmarks: try decodedJSON([Point3D].self, from: targetJSON),
                sourceLandmarks: try decodedJSON([Point3D].self, from: sourceJSON),
                rmsErrorMeters: Float(sqlite3_column_double(statement, 5)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            )
            try landmarks.validate()
            return landmarks
        } catch {
            throw SQLiteStoreError.invalidRecord("Invalid scan alignment landmarks row")
        }
    }

    private static func decodeSpatialLayer(_ statement: OpaquePointer) throws -> SpatialLayer {
        guard
            let idString = columnText(statement, index: 0),
            let id = UUID(uuidString: idString),
            let name = columnText(statement, index: 1),
            let spatialReferenceRawValue = columnText(statement, index: 2),
            let spatialReference = SpatialReferenceKind(rawValue: spatialReferenceRawValue),
            let propertiesJSON = columnText(statement, index: 3),
            let provenanceJSON = columnText(statement, index: 4)
        else {
            throw SQLiteStoreError.invalidRecord("Invalid spatial layer row")
        }

        do {
            return SpatialLayer(
                id: id,
                name: name,
                spatialReference: spatialReference,
                properties: try decodedJSON(SpatialProperties.self, from: propertiesJSON),
                provenance: try decodedJSON(SpatialProvenance.self, from: provenanceJSON),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            )
        } catch {
            throw SQLiteStoreError.invalidRecord("Invalid spatial layer record")
        }
    }

    private static func decodeMineProject(_ statement: OpaquePointer) throws -> MineProject {
        guard
            let idString = columnText(statement, index: 0),
            let id = UUID(uuidString: idString),
            let name = columnText(statement, index: 1),
            let coordinateReferenceJSON = columnText(statement, index: 2)
        else {
            throw SQLiteStoreError.invalidRecord("Invalid mine project row")
        }
        do {
            let project = MineProject(
                id: id,
                name: name,
                coordinateReference: try decodedJSON(MineCoordinateReference.self, from: coordinateReferenceJSON),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            )
            try project.validate()
            return project
        } catch {
            throw SQLiteStoreError.invalidRecord("Invalid mine project row")
        }
    }

    private static func decodeMineControlPoint(_ statement: OpaquePointer) throws -> MineControlPoint {
        guard
            let idString = columnText(statement, index: 0),
            let id = UUID(uuidString: idString),
            let projectIDString = columnText(statement, index: 1),
            let projectID = UUID(uuidString: projectIDString),
            let code = columnText(statement, index: 2),
            let positionJSON = columnText(statement, index: 3)
        else {
            throw SQLiteStoreError.invalidRecord("Invalid mine control point row")
        }
        do {
            let controlPoint = MineControlPoint(
                id: id,
                projectID: projectID,
                code: code,
                minePosition: try decodedJSON(Point3D.self, from: positionJSON),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            )
            try controlPoint.validate()
            return controlPoint
        } catch {
            throw SQLiteStoreError.invalidRecord("Invalid mine control point row")
        }
    }

    private static func decodeMineScanRegistration(_ statement: OpaquePointer) throws -> MineScanRegistration {
        guard
            let idString = columnText(statement, index: 0),
            let id = UUID(uuidString: idString),
            let projectIDString = columnText(statement, index: 1),
            let projectID = UUID(uuidString: projectIDString),
            let scanIDString = columnText(statement, index: 2),
            let scanID = UUID(uuidString: scanIDString),
            let transformJSON = columnText(statement, index: 3),
            let methodRawValue = columnText(statement, index: 4),
            let method = MineScanRegistrationMethod(rawValue: methodRawValue),
            let controlPointIDsJSON = columnText(statement, index: 6)
        else {
            throw SQLiteStoreError.invalidRecord("Invalid mine scan registration row")
        }
        do {
            let registration = MineScanRegistration(
                id: id,
                projectID: projectID,
                scanID: scanID,
                mineFromARWorld: try decodedJSON(Transform4x4.self, from: transformJSON),
                method: method,
                rmsResidualMeters: Float(sqlite3_column_double(statement, 5)),
                controlPointIDs: try decodedJSON([UUID].self, from: controlPointIDsJSON),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
            )
            try registration.validate()
            return registration
        } catch {
            throw SQLiteStoreError.invalidRecord("Invalid mine scan registration row")
        }
    }

    private static func decodeMineStation(_ statement: OpaquePointer) throws -> MineScanStation {
        guard
            let idString = columnText(statement, index: 0), let id = UUID(uuidString: idString),
            let projectIDString = columnText(statement, index: 1), let projectID = UUID(uuidString: projectIDString),
            let scanIDString = columnText(statement, index: 2), let scanID = UUID(uuidString: scanIDString),
            let registrationIDString = columnText(statement, index: 3), let registrationID = UUID(uuidString: registrationIDString),
            let code = columnText(statement, index: 4), let contextJSON = columnText(statement, index: 5)
        else { throw SQLiteStoreError.invalidRecord("Invalid mine station row") }
        do {
            let station = MineScanStation(
                id: id, projectID: projectID, scanID: scanID, registrationID: registrationID,
                code: code, sessionContext: try decodedJSON(MineStationSessionContext.self, from: contextJSON),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            )
            try station.validate()
            return station
        } catch { throw SQLiteStoreError.invalidRecord("Invalid mine station row") }
    }

    private static func spatialFeatures(forLayerID layerID: UUID, in database: OpaquePointer) throws -> [SpatialFeature] {
        let statement = try prepare(database, sql: """
        SELECT id, kind_json, geometry_json, properties_json, provenance_json, spatial_reference, created_at, updated_at
        FROM spatial_features
        WHERE layer_id = ?
        ORDER BY created_at ASC, id ASC;
        """)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: layerID.uuidString)

        var features: [SpatialFeature] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            features.append(try decodeSpatialFeature(statement))
        }
        return features
    }

    private static func decodeSpatialFeature(_ statement: OpaquePointer) throws -> SpatialFeature {
        guard
            let idString = columnText(statement, index: 0),
            let id = UUID(uuidString: idString),
            let kindJSON = columnText(statement, index: 1),
            let geometryJSON = columnText(statement, index: 2),
            let propertiesJSON = columnText(statement, index: 3),
            let provenanceJSON = columnText(statement, index: 4),
            let spatialReferenceRawValue = columnText(statement, index: 5),
            let spatialReference = SpatialReferenceKind(rawValue: spatialReferenceRawValue)
        else {
            throw SQLiteStoreError.invalidRecord("Invalid spatial feature row")
        }

        do {
            return SpatialFeature(
                id: id,
                kind: try decodedJSON(SpatialFeatureKind.self, from: kindJSON),
                geometry: try decodedJSON(SpatialGeometry.self, from: geometryJSON),
                properties: try decodedJSON(SpatialProperties.self, from: propertiesJSON),
                provenance: try decodedJSON(SpatialProvenance.self, from: provenanceJSON),
                spatialReference: spatialReference,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            )
        } catch {
            throw SQLiteStoreError.invalidRecord("Invalid spatial feature record")
        }
    }

    private static func encodedJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw SQLiteStoreError.invalidRecord("Could not encode spatial JSON")
        }
        return encoded
    }

    private static func decodedJSON<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(string.utf8))
    }

    private static func scanExists(id: UUID, in database: OpaquePointer) throws -> Bool {
        let statement = try prepare(database, sql: "SELECT 1 FROM scans WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: id.uuidString)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func decodeScanComparisonDraft(_ statement: OpaquePointer) throws -> ScanComparisonDraft {
        guard
            let idText = columnText(statement, index: 0), let id = UUID(uuidString: idText),
            let baselineText = columnText(statement, index: 1), let baselineScanID = UUID(uuidString: baselineText),
            let comparisonText = columnText(statement, index: 2), let comparisonScanID = UUID(uuidString: comparisonText)
        else {
            throw SQLiteStoreError.invalidRecord("Could not decode scan comparison draft")
        }
        let draft = ScanComparisonDraft(
            id: id,
            baselineScanID: baselineScanID,
            comparisonScanID: comparisonScanID,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        )
        try draft.validate()
        return draft
    }

    private static func comparisonDraftBaselineScanID(id: UUID, in database: OpaquePointer) throws -> UUID? {
        let statement = try prepare(database, sql: "SELECT baseline_scan_id FROM scan_comparison_drafts WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: id.uuidString)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = columnText(statement, index: 0) else { return nil }
        return UUID(uuidString: text)
    }

    private static func decodeScanComparisonWorkArea(
        _ statement: OpaquePointer,
        draftID: UUID
    ) throws -> ScanComparisonWorkArea {
        guard
            let idText = columnText(statement, index: 0), let id = UUID(uuidString: idText),
            let referenceText = columnText(statement, index: 1), let referenceScanID = UUID(uuidString: referenceText),
            let minimumJSON = columnText(statement, index: 2),
            let maximumJSON = columnText(statement, index: 3)
        else {
            throw SQLiteStoreError.invalidRecord("Could not decode scan comparison work area")
        }
        let area = ScanComparisonWorkArea(
            id: id,
            draftID: draftID,
            referenceScanID: referenceScanID,
            minimum: try decodedJSON(Point3D.self, from: minimumJSON),
            maximum: try decodedJSON(Point3D.self, from: maximumJSON),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        )
        try area.validate()
        return area
    }

    private static func mineProjectExists(id: UUID, in database: OpaquePointer) throws -> Bool {
        let statement = try prepare(database, sql: "SELECT 1 FROM mine_projects WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: id.uuidString)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func mineControlPointProjectID(id: UUID, in database: OpaquePointer) throws -> UUID? {
        let statement = try prepare(database, sql: "SELECT project_id FROM mine_control_points WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: id.uuidString)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let projectIDString = columnText(statement, index: 0), let projectID = UUID(uuidString: projectIDString) else {
            throw SQLiteStoreError.invalidRecord("Invalid mine control point project reference")
        }
        return projectID
    }

    private static func mineScanRegistration(id: UUID, in database: OpaquePointer) throws -> MineScanRegistration? {
        let statement = try prepare(database, sql: """
        SELECT id, project_id, scan_id, mine_from_ar_world_json, method,
               rms_residual_meters, control_point_ids_json, created_at, updated_at
        FROM mine_scan_registrations WHERE id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: id.uuidString)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeMineScanRegistration(statement)
    }

    private static func mineStation(id: UUID, in database: OpaquePointer) throws -> MineScanStation? {
        let statement = try prepare(database, sql: """
        SELECT id, project_id, scan_id, registration_id, code, session_context_json, created_at, updated_at
        FROM mine_scan_stations WHERE id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: id.uuidString)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeMineStation(statement)
    }

    private static func surveyEpoch(id: UUID, in database: OpaquePointer) throws -> SurveyEpoch? {
        let statement = try prepare(database, sql: "SELECT project_id, name, kind, captured_at FROM survey_epochs WHERE id = ?;")
        defer { sqlite3_finalize(statement) }; try bindText(statement, index: 1, value: id.uuidString)
        guard sqlite3_step(statement) == SQLITE_ROW, let projectText = columnText(statement, index: 0), let projectID = UUID(uuidString: projectText), let name = columnText(statement, index: 1), let kindText = columnText(statement, index: 2), let kind = SurveyEpochKind(rawValue: kindText) else { return nil }
        let stationStatement = try prepare(database, sql: "SELECT station_id FROM survey_epoch_stations WHERE epoch_id = ? ORDER BY station_id ASC;")
        defer { sqlite3_finalize(stationStatement) }; try bindText(stationStatement, index: 1, value: id.uuidString)
        var stationIDs: [UUID] = []; while sqlite3_step(stationStatement) == SQLITE_ROW { if let text = columnText(stationStatement, index: 0), let stationID = UUID(uuidString: text) { stationIDs.append(stationID) } }
        return SurveyEpoch(id: id, projectID: projectID, name: name, kind: kind, stationIDs: stationIDs, capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)))
    }

    private static func surveyBoundaryProjectID(id: UUID, in database: OpaquePointer) throws -> UUID? {
        let statement = try prepare(database, sql: "SELECT project_id FROM survey_change_boundaries WHERE id = ?;")
        defer { sqlite3_finalize(statement) }; try bindText(statement, index: 1, value: id.uuidString)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = columnText(statement, index: 0) else { return nil }
        return UUID(uuidString: text)
    }

    private static func spatialLayerScanID(id: UUID, in database: OpaquePointer) throws -> UUID? {
        let statement = try prepare(database, sql: "SELECT scan_id FROM spatial_layers WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: id.uuidString)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        guard let scanIDString = columnText(statement, index: 0), let scanID = UUID(uuidString: scanIDString) else {
            throw SQLiteStoreError.invalidRecord("Invalid spatial layer scan reference")
        }
        return scanID
    }

    private struct EncodedSpatialFeature {
        let feature: SpatialFeature
        let kindJSON: String
        let geometryJSON: String
        let propertiesJSON: String
        let provenanceJSON: String
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? self.message(from: database)
            sqlite3_free(errorMessage)
            throw SQLiteStoreError.executionFailed(message)
        }
    }

    private static func transaction(on database: OpaquePointer, _ operation: () throws -> Void) throws {
        try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try operation()
            try execute(database, sql: "COMMIT;")
        } catch {
            try? execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    private static func prepare(_ database: OpaquePointer, sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteStoreError.executionFailed(message(from: database))
        }
        return statement
    }

    private static func bindText(_ statement: OpaquePointer, index: Int32, value: String) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw SQLiteStoreError.executionFailed("Could not bind SQLite text")
        }
    }

    private static func bindOptionalText(_ statement: OpaquePointer, index: Int32, value: String?) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw SQLiteStoreError.executionFailed("Could not bind SQLite null")
            }
            return
        }
        try bindText(statement, index: index, value: value)
    }

    private static func bindDouble(_ statement: OpaquePointer, index: Int32, value: Double) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw SQLiteStoreError.executionFailed("Could not bind SQLite number")
        }
    }

    private static func bindOptionalDouble(_ statement: OpaquePointer, index: Int32, value: Double?) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw SQLiteStoreError.executionFailed("Could not bind SQLite null")
            }
            return
        }
        try bindDouble(statement, index: index, value: value)
    }

    private static func bindInt64(_ statement: OpaquePointer, index: Int32, value: Int64) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw SQLiteStoreError.executionFailed("Could not bind SQLite integer")
        }
    }

    private static func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.executionFailed("SQLite statement did not complete")
        }
    }

    private static func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private static func message(from database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close_v2(handle)
    }
}
