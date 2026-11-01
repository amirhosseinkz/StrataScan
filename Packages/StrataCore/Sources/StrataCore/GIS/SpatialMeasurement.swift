import Foundation

/// Errors emitted when a spatial feature cannot truthfully produce a meter value.
public enum SpatialMeasurementError: Error, Equatable, Sendable {
    case notMeasurementFeature
    case unsupportedSpatialReference(SpatialReferenceKind)
    case invalidMeasurementGeometry(SpatialGeometryKind)
}

/// Evaluates manual linear measurements in the native meter-based scan spaces.
///
/// This deliberately does not infer a linear unit for geographic coordinates.
/// A geographic feature needs an explicit georeferencing workflow before it can
/// be compared to ARKit or scan-local meter measurements.
public enum SpatialMeasurementEvaluator {
    /// Returns the sum of Euclidean segments in meters for a valid measurement.
    public static func linearDistanceMeters(for feature: SpatialFeature) throws -> Double {
        guard feature.kind == .measurement else {
            throw SpatialMeasurementError.notMeasurementFeature
        }
        guard feature.spatialReference == .scanLocal || feature.spatialReference == .arWorld else {
            throw SpatialMeasurementError.unsupportedSpatialReference(feature.spatialReference)
        }
        guard case let .polyline(points) = feature.geometry else {
            throw SpatialMeasurementError.invalidMeasurementGeometry(feature.geometry.kind)
        }

        try feature.validate()

        return zip(points, points.dropFirst()).reduce(into: 0) { distance, segment in
            let dx = Double(segment.1.x) - Double(segment.0.x)
            let dy = Double(segment.1.y) - Double(segment.0.y)
            let dz = Double(segment.1.z) - Double(segment.0.z)
            distance += (dx * dx + dy * dy + dz * dz).squareRoot()
        }
    }
}
