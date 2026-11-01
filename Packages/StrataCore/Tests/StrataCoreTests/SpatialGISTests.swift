import Foundation
import Testing
@testable import StrataCore

@Suite("Spatial GIS")
struct SpatialGISTests {
    @Test("GeoJSON export preserves positions and declared reference")
    func exportsRawCoordinatesAndMetadata() throws {
        let layerID = try #require(UUID(uuidString: "681654B7-8B91-4CBF-85FC-21F4F54580AD"))
        let featureID = try #require(UUID(uuidString: "6EB9402A-0E92-4A61-8CC1-5F9D8D52F0E8"))
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let position = Point3D(x: -122.4194, y: 37.7749, z: 12.5)
        let provenance = SpatialProvenance(
            source: "manual survey",
            author: "A. Rivera",
            observedAt: timestamp,
            metadata: ["device": .string("GNSS receiver")]
        )
        let feature = SpatialFeature(
            id: featureID,
            kind: .asset,
            geometry: .point(position),
            properties: [
                "assetID": .string("hydrant-17"),
                "priority": .number(2)
            ],
            provenance: provenance,
            spatialReference: .geographicWGS84,
            createdAt: timestamp
        )
        let layer = SpatialLayer(
            id: layerID,
            name: "Utilities",
            spatialReference: .geographicWGS84,
            features: [feature],
            properties: ["project": .string("North site")],
            provenance: provenance,
            createdAt: timestamp
        )

        let collection = try layer.geoJSONFeatureCollection()

        #expect(collection.type == "FeatureCollection")
        #expect(collection.spatialReference == .geographicWGS84)
        #expect(collection.features.count == 1)
        let exportedCollectionFeature = try #require(collection.features.first)
        #expect(exportedCollectionFeature.geometry == .point([Double(position.x), Double(position.y), Double(position.z)]))
        #expect(exportedCollectionFeature.metadata.spatialReference == .geographicWGS84)
        #expect(exportedCollectionFeature.metadata.provenance == provenance)

        let data = try layer.geoJSONData()
        let document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let features = try #require(document["features"] as? [[String: Any]])
        let exportedFeature = try #require(features.first)
        let geometry = try #require(exportedFeature["geometry"] as? [String: Any])
        let coordinates = try #require(geometry["coordinates"] as? [Double])

        #expect(document["strataScanSpatialReference"] as? String == "geographicWGS84")
        #expect(coordinates == [Double(position.x), Double(position.y), Double(position.z)])
    }

    @Test("A layer rejects a feature in a different coordinate space")
    func rejectsMismatchedSpatialReferences() throws {
        let featureID = try #require(UUID(uuidString: "8BA2E4E2-5BC5-445A-95D8-73B0A7E6BCB8"))
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let provenance = SpatialProvenance(source: "ARKit", observedAt: timestamp)
        let feature = SpatialFeature(
            id: featureID,
            kind: .asset,
            geometry: .point(Point3D(x: 1, y: 2, z: 3)),
            provenance: provenance,
            spatialReference: .arWorld,
            createdAt: timestamp
        )
        let layer = SpatialLayer(
            id: try #require(UUID(uuidString: "0954FF38-4D3B-436C-BBC1-3852B4DD3D64")),
            name: "Local annotations",
            spatialReference: .scanLocal,
            features: [feature],
            provenance: provenance,
            createdAt: timestamp
        )

        #expect(throws: SpatialValidationError.layerFeatureSpatialReferenceMismatch(
            featureID: featureID,
            layer: .scanLocal,
            feature: .arWorld
        )) {
            try layer.geoJSONFeatureCollection()
        }
    }

    @Test("Geometry, semantic kind, and transform provenance are validated")
    func validatesGISConstraints() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let provenance = SpatialProvenance(source: "manual survey", observedAt: timestamp)
        let openHazard = SpatialFeature(
            id: try #require(UUID(uuidString: "68D82E92-6B0B-4CDA-80C9-67D20D6A90D2")),
            kind: .hazard,
            geometry: .polygon([
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 2, y: 0, z: 0),
                Point3D(x: 2, y: 2, z: 0),
                Point3D(x: 0, y: 2, z: 0)
            ]),
            provenance: provenance,
            spatialReference: .scanLocal,
            createdAt: timestamp
        )
        let lineAsset = SpatialFeature(
            id: try #require(UUID(uuidString: "A6E72E40-D0CB-45AF-9D53-0A1BD63C8E71")),
            kind: .asset,
            geometry: .polyline([
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 1, y: 0, z: 0)
            ]),
            provenance: provenance,
            spatialReference: .scanLocal,
            createdAt: timestamp
        )
        let incorrectTransform = SpatialFeature(
            id: try #require(UUID(uuidString: "A7CE6C5D-A0A5-4862-87FD-DB6FAF07E52E")),
            kind: .note,
            geometry: .point(Point3D(x: 1, y: 2, z: 3)),
            provenance: SpatialProvenance(
                source: "survey import",
                coordinateTransform: SpatialCoordinateTransformProvenance(
                    name: "worldFromLocal-v1",
                    sourceSpatialReference: .scanLocal,
                    targetSpatialReference: .arWorld
                )
            ),
            spatialReference: .scanLocal,
            createdAt: timestamp
        )

        #expect(throws: SpatialValidationError.unclosedPolygon) {
            try openHazard.validate()
        }
        #expect(throws: SpatialValidationError.incompatibleGeometry(featureKind: .asset, geometry: .polyline)) {
            try lineAsset.validate()
        }
        #expect(throws: SpatialValidationError.coordinateTransformDestinationMismatch(expected: .scanLocal, actual: .arWorld)) {
            try incorrectTransform.validate()
        }
    }

    @Test("Measurement, hazard, note, and custom features accept their supported geometry")
    func acceptsSupportedFeatureKinds() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let provenance = SpatialProvenance(source: "manual survey", observedAt: timestamp)
        let closedPolygon = [
            Point3D(x: 0, y: 0, z: 0),
            Point3D(x: 1, y: 0, z: 0),
            Point3D(x: 1, y: 1, z: 0),
            Point3D(x: 0, y: 0, z: 0)
        ]
        let features = [
            SpatialFeature(
                id: try #require(UUID(uuidString: "A9AE5A51-5E1A-4A94-8478-902E22F4E4A7")),
                kind: .measurement,
                geometry: .polyline([Point3D(x: 0, y: 0, z: 0), Point3D(x: 1, y: 0, z: 0)]),
                provenance: provenance,
                spatialReference: .scanLocal,
                createdAt: timestamp
            ),
            SpatialFeature(
                id: try #require(UUID(uuidString: "F7B05B29-4EFA-4A72-AE6F-9D4B228BEB69")),
                kind: .hazard,
                geometry: .polygon(closedPolygon),
                provenance: provenance,
                spatialReference: .scanLocal,
                createdAt: timestamp
            ),
            SpatialFeature(
                id: try #require(UUID(uuidString: "D0EF7318-20A9-439F-98A3-6F7C70A9A151")),
                kind: .note,
                geometry: .point(Point3D(x: 1, y: 1, z: 0)),
                provenance: provenance,
                spatialReference: .scanLocal,
                createdAt: timestamp
            ),
            SpatialFeature(
                id: try #require(UUID(uuidString: "B6F3D355-C4C3-4B94-9CC2-B8202F4D34EC")),
                kind: .custom("inspection area"),
                geometry: .polygon(closedPolygon),
                provenance: provenance,
                spatialReference: .scanLocal,
                createdAt: timestamp
            )
        ]

        for feature in features {
            try feature.validate()
        }
    }
}
