import Foundation

public enum GeoJSONGeometry: Codable, Equatable, Sendable {
    case point([Double])
    case lineString([[Double]])
    case polygon([[[Double]]])

    public var type: String {
        switch self {
        case .point:
            return "Point"
        case .lineString:
            return "LineString"
        case .polygon:
            return "Polygon"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case coordinates
    }

    private enum GeometryType: String, Codable {
        case point = "Point"
        case lineString = "LineString"
        case polygon = "Polygon"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        switch try container.decode(GeometryType.self, forKey: .type) {
        case .point:
            self = .point(try container.decode([Double].self, forKey: .coordinates))
        case .lineString:
            self = .lineString(try container.decode([[Double]].self, forKey: .coordinates))
        case .polygon:
            self = .polygon(try container.decode([[[Double]]].self, forKey: .coordinates))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .point(let coordinates):
            try container.encode(GeometryType.point, forKey: .type)
            try container.encode(coordinates, forKey: .coordinates)
        case .lineString(let coordinates):
            try container.encode(GeometryType.lineString, forKey: .type)
            try container.encode(coordinates, forKey: .coordinates)
        case .polygon(let coordinates):
            try container.encode(GeometryType.polygon, forKey: .type)
            try container.encode(coordinates, forKey: .coordinates)
        }
    }
}

public struct GeoJSONFeatureMetadata: Codable, Equatable, Sendable {
    public var kind: SpatialFeatureKind
    public var spatialReference: SpatialReferenceKind
    public var provenance: SpatialProvenance
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        kind: SpatialFeatureKind,
        spatialReference: SpatialReferenceKind,
        provenance: SpatialProvenance,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.kind = kind
        self.spatialReference = spatialReference
        self.provenance = provenance
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct GeoJSONLayerMetadata: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var spatialReference: SpatialReferenceKind
    public var provenance: SpatialProvenance
    public var properties: SpatialProperties
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        name: String,
        spatialReference: SpatialReferenceKind,
        provenance: SpatialProvenance,
        properties: SpatialProperties,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.spatialReference = spatialReference
        self.provenance = provenance
        self.properties = properties
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct GeoJSONFeature: Codable, Equatable, Sendable, Identifiable {
    public var type: String
    public var id: UUID
    public var geometry: GeoJSONGeometry
    public var properties: SpatialProperties
    public var metadata: GeoJSONFeatureMetadata

    public init(
        id: UUID,
        geometry: GeoJSONGeometry,
        properties: SpatialProperties,
        metadata: GeoJSONFeatureMetadata
    ) {
        type = "Feature"
        self.id = id
        self.geometry = geometry
        self.properties = properties
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case geometry
        case properties
        case metadata = "strataScan"
    }
}

public struct GeoJSONFeatureCollection: Codable, Equatable, Sendable {
    public var type: String
    public var features: [GeoJSONFeature]
    public var spatialReference: SpatialReferenceKind
    public var metadata: GeoJSONLayerMetadata

    public init(
        features: [GeoJSONFeature],
        spatialReference: SpatialReferenceKind,
        metadata: GeoJSONLayerMetadata
    ) {
        type = "FeatureCollection"
        self.features = features
        self.spatialReference = spatialReference
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case features
        case spatialReference = "strataScanSpatialReference"
        case metadata = "strataScan"
    }
}

public extension SpatialLayer {
    func geoJSONFeatureCollection() throws -> GeoJSONFeatureCollection {
        try validate()

        return GeoJSONFeatureCollection(
            features: features.map { feature in
                GeoJSONFeature(
                    id: feature.id,
                    geometry: feature.geometry.geoJSONGeometry,
                    properties: feature.properties,
                    metadata: GeoJSONFeatureMetadata(
                        kind: feature.kind,
                        spatialReference: feature.spatialReference,
                        provenance: feature.provenance,
                        createdAt: feature.createdAt,
                        updatedAt: feature.updatedAt
                    )
                )
            },
            spatialReference: spatialReference,
            metadata: GeoJSONLayerMetadata(
                id: id,
                name: name,
                spatialReference: spatialReference,
                provenance: provenance,
                properties: properties,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        )
    }

    func geoJSONData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys]
        if prettyPrinted {
            formatting.insert(.prettyPrinted)
        }
        encoder.outputFormatting = formatting
        return try encoder.encode(geoJSONFeatureCollection())
    }
}

private extension SpatialGeometry {
    var geoJSONGeometry: GeoJSONGeometry {
        switch self {
        case .point(let point):
            return .point(geoJSONPosition(from: point))
        case .polyline(let points):
            return .lineString(points.map(geoJSONPosition(from:)))
        case .polygon(let points):
            return .polygon([points.map(geoJSONPosition(from:))])
        }
    }
}

// GeoJSON positions retain Point3D's stored x, y, and z values without transformation.
private func geoJSONPosition(from point: Point3D) -> [Double] {
    [Double(point.x), Double(point.y), Double(point.z)]
}
