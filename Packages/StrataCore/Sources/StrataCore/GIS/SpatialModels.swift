import Foundation

public typealias SpatialProperties = [String: SpatialPropertyValue]

public enum SpatialValidationError: Error, Equatable, Sendable {
    case emptyRequiredText(field: String)
    case invalidTimestampOrder
    case nonFiniteCoordinate
    case invalidGeographicLongitude(Float)
    case invalidGeographicLatitude(Float)
    case insufficientPolylineVertices(count: Int)
    case insufficientPolygonVertices(count: Int)
    case unclosedPolygon
    case invalidPropertyKey(path: String)
    case nonFinitePropertyNumber(path: String)
    case incompatibleGeometry(featureKind: SpatialFeatureKind, geometry: SpatialGeometryKind)
    case coordinateTransformDestinationMismatch(expected: SpatialReferenceKind, actual: SpatialReferenceKind)
    case duplicateFeatureID(UUID)
    case layerFeatureSpatialReferenceMismatch(featureID: UUID, layer: SpatialReferenceKind, feature: SpatialReferenceKind)
}

public indirect enum SpatialPropertyValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case array([SpatialPropertyValue])
    case object(SpatialProperties)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SpatialPropertyValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(SpatialProperties.self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a JSON-compatible property value.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public func validate() throws {
        try validate(at: "properties")
    }

    fileprivate func validate(at path: String) throws {
        switch self {
        case .string, .boolean, .null:
            return
        case .number(let value):
            guard value.isFinite else {
                throw SpatialValidationError.nonFinitePropertyNumber(path: path)
            }
        case .array(let values):
            for (index, value) in values.enumerated() {
                try value.validate(at: "\(path)[\(index)]")
            }
        case .object(let values):
            try validateSpatialProperties(values, path: path)
        }
    }
}

public struct SpatialCoordinateTransformProvenance: Codable, Equatable, Sendable {
    public var name: String
    public var sourceSpatialReference: SpatialReferenceKind
    public var targetSpatialReference: SpatialReferenceKind
    public var description: String?

    public init(
        name: String,
        sourceSpatialReference: SpatialReferenceKind,
        targetSpatialReference: SpatialReferenceKind,
        description: String? = nil
    ) {
        self.name = name
        self.sourceSpatialReference = sourceSpatialReference
        self.targetSpatialReference = targetSpatialReference
        self.description = description
    }

    public func validate(for spatialReference: SpatialReferenceKind) throws {
        try validateRequiredText(name, field: "coordinate transform name")
        if let description {
            try validateRequiredText(description, field: "coordinate transform description")
        }
        guard targetSpatialReference == spatialReference else {
            throw SpatialValidationError.coordinateTransformDestinationMismatch(
                expected: spatialReference,
                actual: targetSpatialReference
            )
        }
    }
}

public struct SpatialProvenance: Codable, Equatable, Sendable {
    public var source: String
    public var author: String?
    public var observedAt: Date?
    public var coordinateTransform: SpatialCoordinateTransformProvenance?
    public var metadata: SpatialProperties

    public init(
        source: String,
        author: String? = nil,
        observedAt: Date? = nil,
        coordinateTransform: SpatialCoordinateTransformProvenance? = nil,
        metadata: SpatialProperties = [:]
    ) {
        self.source = source
        self.author = author
        self.observedAt = observedAt
        self.coordinateTransform = coordinateTransform
        self.metadata = metadata
    }

    public func validate(for spatialReference: SpatialReferenceKind) throws {
        try validateRequiredText(source, field: "provenance source")
        if let author {
            try validateRequiredText(author, field: "provenance author")
        }
        if let coordinateTransform {
            try coordinateTransform.validate(for: spatialReference)
        }
        try validateSpatialProperties(metadata, path: "provenance.metadata")
    }
}

public enum SpatialGeometryKind: String, Codable, CaseIterable, Sendable {
    case point
    case polyline
    case polygon
}

public enum SpatialGeometry: Codable, Equatable, Sendable {
    case point(Point3D)
    case polyline([Point3D])
    case polygon([Point3D])

    public var kind: SpatialGeometryKind {
        switch self {
        case .point:
            return .point
        case .polyline:
            return .polyline
        case .polygon:
            return .polygon
        }
    }

    public func validate(for spatialReference: SpatialReferenceKind) throws {
        switch self {
        case .point(let point):
            try validateCoordinate(point, for: spatialReference)
        case .polyline(let points):
            guard points.count >= 2 else {
                throw SpatialValidationError.insufficientPolylineVertices(count: points.count)
            }
            for point in points {
                try validateCoordinate(point, for: spatialReference)
            }
        case .polygon(let points):
            guard points.count >= 4 else {
                throw SpatialValidationError.insufficientPolygonVertices(count: points.count)
            }
            guard let first = points.first, let last = points.last, first == last else {
                throw SpatialValidationError.unclosedPolygon
            }
            for point in points {
                try validateCoordinate(point, for: spatialReference)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case coordinates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(SpatialGeometryKind.self, forKey: .type)

        switch kind {
        case .point:
            self = .point(try container.decode(Point3D.self, forKey: .coordinates))
        case .polyline:
            self = .polyline(try container.decode([Point3D].self, forKey: .coordinates))
        case .polygon:
            self = .polygon(try container.decode([Point3D].self, forKey: .coordinates))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)

        switch self {
        case .point(let point):
            try container.encode(point, forKey: .coordinates)
        case .polyline(let points), .polygon(let points):
            try container.encode(points, forKey: .coordinates)
        }
    }
}

public enum SpatialFeatureKind: Codable, Equatable, Sendable {
    case measurement
    case hazard
    case asset
    case boundary
    case note
    case custom(String)

    public func validate() throws {
        if case .custom(let type) = self {
            try validateRequiredText(type, field: "custom feature type")
        }
    }

    fileprivate func supports(geometry: SpatialGeometryKind) -> Bool {
        switch self {
        case .measurement:
            return geometry == .polyline
        case .hazard:
            return geometry == .point || geometry == .polygon
        case .asset, .note:
            return geometry == .point
        case .boundary:
            return geometry == .polyline || geometry == .polygon
        case .custom:
            return true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case customType
    }

    private enum Discriminator: String, Codable {
        case measurement
        case hazard
        case asset
        case boundary
        case note
        case custom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        switch try container.decode(Discriminator.self, forKey: .type) {
        case .measurement:
            self = .measurement
        case .hazard:
            self = .hazard
        case .asset:
            self = .asset
        case .boundary:
            self = .boundary
        case .note:
            self = .note
        case .custom:
            self = .custom(try container.decode(String.self, forKey: .customType))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .measurement:
            try container.encode(Discriminator.measurement, forKey: .type)
        case .hazard:
            try container.encode(Discriminator.hazard, forKey: .type)
        case .asset:
            try container.encode(Discriminator.asset, forKey: .type)
        case .boundary:
            try container.encode(Discriminator.boundary, forKey: .type)
        case .note:
            try container.encode(Discriminator.note, forKey: .type)
        case .custom(let type):
            try container.encode(Discriminator.custom, forKey: .type)
            try container.encode(type, forKey: .customType)
        }
    }
}

public struct SpatialFeature: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: SpatialFeatureKind
    public var geometry: SpatialGeometry
    public var properties: SpatialProperties
    public var provenance: SpatialProvenance
    public var spatialReference: SpatialReferenceKind
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: SpatialFeatureKind,
        geometry: SpatialGeometry,
        properties: SpatialProperties = [:],
        provenance: SpatialProvenance,
        spatialReference: SpatialReferenceKind,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.geometry = geometry
        self.properties = properties
        self.provenance = provenance
        self.spatialReference = spatialReference
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public func validate() throws {
        guard createdAt <= updatedAt else {
            throw SpatialValidationError.invalidTimestampOrder
        }
        try kind.validate()
        try geometry.validate(for: spatialReference)
        guard kind.supports(geometry: geometry.kind) else {
            throw SpatialValidationError.incompatibleGeometry(featureKind: kind, geometry: geometry.kind)
        }
        try validateSpatialProperties(properties, path: "properties")
        try provenance.validate(for: spatialReference)
    }
}

public struct SpatialLayer: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var spatialReference: SpatialReferenceKind
    public var features: [SpatialFeature]
    public var properties: SpatialProperties
    public var provenance: SpatialProvenance
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        spatialReference: SpatialReferenceKind,
        features: [SpatialFeature] = [],
        properties: SpatialProperties = [:],
        provenance: SpatialProvenance,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.spatialReference = spatialReference
        self.features = features
        self.properties = properties
        self.provenance = provenance
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public func validate() throws {
        try validateRequiredText(name, field: "layer name")
        guard createdAt <= updatedAt else {
            throw SpatialValidationError.invalidTimestampOrder
        }
        try validateSpatialProperties(properties, path: "properties")
        try provenance.validate(for: spatialReference)

        var featureIDs = Set<UUID>()
        for feature in features {
            guard featureIDs.insert(feature.id).inserted else {
                throw SpatialValidationError.duplicateFeatureID(feature.id)
            }
            guard feature.spatialReference == spatialReference else {
                throw SpatialValidationError.layerFeatureSpatialReferenceMismatch(
                    featureID: feature.id,
                    layer: spatialReference,
                    feature: feature.spatialReference
                )
            }
            try feature.validate()
        }
    }
}

private func validateCoordinate(_ point: Point3D, for spatialReference: SpatialReferenceKind) throws {
    guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
        throw SpatialValidationError.nonFiniteCoordinate
    }
    guard spatialReference == .geographicWGS84 else {
        return
    }
    guard (-180...180).contains(point.x) else {
        throw SpatialValidationError.invalidGeographicLongitude(point.x)
    }
    guard (-90...90).contains(point.y) else {
        throw SpatialValidationError.invalidGeographicLatitude(point.y)
    }
}

private func validateRequiredText(_ value: String, field: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw SpatialValidationError.emptyRequiredText(field: field)
    }
}

private func validateSpatialProperties(_ properties: SpatialProperties, path: String) throws {
    for key in properties.keys.sorted() {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpatialValidationError.invalidPropertyKey(path: path)
        }
        guard let value = properties[key] else {
            continue
        }
        try value.validate(at: "\(path).\(key)")
    }
}
