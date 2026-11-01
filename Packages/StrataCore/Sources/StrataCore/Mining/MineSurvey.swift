import Foundation

/// A named engineering coordinate reference supplied by a mine's survey team.
/// It deliberately has no implicit relationship to ARKit, GPS, or WGS 84.
public struct MineCoordinateReference: Codable, Equatable, Sendable {
    public var name: String
    public var horizontalDatum: String?
    public var verticalDatum: String?

    public init(name: String, horizontalDatum: String? = nil, verticalDatum: String? = nil) {
        self.name = name
        self.horizontalDatum = horizontalDatum
        self.verticalDatum = verticalDatum
    }

    public func validate() throws {
        try MineSurveyValidation.requiredText(name, field: "mine coordinate reference name")
        if let horizontalDatum {
            try MineSurveyValidation.requiredText(horizontalDatum, field: "mine horizontal datum")
        }
        if let verticalDatum {
            try MineSurveyValidation.requiredText(verticalDatum, field: "mine vertical datum")
        }
    }
}

/// Project-level, survey-controlled context. This is SQLite metadata only and
/// never mutates a scan package or silently georeferences its source geometry.
public struct MineProject: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var coordinateReference: MineCoordinateReference
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        coordinateReference: MineCoordinateReference,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.coordinateReference = coordinateReference
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        try MineSurveyValidation.requiredText(name, field: "mine project name")
        try coordinateReference.validate()
        guard createdAt <= updatedAt else {
            throw MineSurveyError.invalidTimestampOrder
        }
    }
}

/// A surveyed control point in a MineProject's explicitly named meter grid.
public struct MineControlPoint: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var code: String
    public var minePosition: Point3D
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        code: String,
        minePosition: Point3D,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.code = code
        self.minePosition = minePosition
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        try MineSurveyValidation.requiredText(code, field: "mine control point code")
        try MineSurveyValidation.finite(minePosition)
        guard createdAt <= updatedAt else {
            throw MineSurveyError.invalidTimestampOrder
        }
    }
}

/// An AR-world observation made at a surveyed control point while capturing a
/// single raw scan. It is evidence for registration, not an independently
/// transformed copy of scan geometry.
public struct MineControlObservation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var controlPointID: UUID
    public var arWorldPosition: Point3D

    public init(id: UUID = UUID(), controlPointID: UUID, arWorldPosition: Point3D) {
        self.id = id
        self.controlPointID = controlPointID
        self.arWorldPosition = arWorldPosition
    }

    public func validate() throws {
        try MineSurveyValidation.finite(arWorldPosition)
    }
}

public enum MineScanRegistrationMethod: String, Codable, CaseIterable, Sendable {
    case surveyedControl
}

/// A non-destructive rigid registration from a raw scan's ARKit world meters
/// into the MineProject's named meter grid. The direction is part of the API.
public struct MineScanRegistration: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var scanID: UUID
    public var mineFromARWorld: Transform4x4
    public var method: MineScanRegistrationMethod
    public var rmsResidualMeters: Float
    public var controlPointIDs: [UUID]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        scanID: UUID,
        mineFromARWorld: Transform4x4,
        method: MineScanRegistrationMethod,
        rmsResidualMeters: Float,
        controlPointIDs: [UUID],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.scanID = scanID
        self.mineFromARWorld = mineFromARWorld
        self.method = method
        self.rmsResidualMeters = rmsResidualMeters
        self.controlPointIDs = controlPointIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        guard mineFromARWorld.columns.allSatisfy(\.isFinite) else {
            throw MineSurveyError.nonFiniteTransform
        }
        guard rmsResidualMeters.isFinite, rmsResidualMeters >= 0 else {
            throw MineSurveyError.invalidResidual
        }
        try MineSurveyValidation.distinctControlPointIDs(controlPointIDs)
        guard createdAt <= updatedAt else {
            throw MineSurveyError.invalidTimestampOrder
        }
    }
}

public enum MineSurveyError: Error, Equatable, Sendable {
    case emptyRequiredText(field: String)
    case invalidTimestampOrder
    case nonFiniteCoordinate
    case nonFiniteTransform
    case invalidResidual
    case insufficientControlPoints(count: Int)
    case duplicateControlPointObservation(UUID)
    case unknownControlPoint(UUID)
    case controlPointOutsideProject(controlPointID: UUID, projectID: UUID)
    case degenerateControlGeometry
}

/// Estimates only a rigid, unit-preserving relationship. It does not infer a
/// mine coordinate system, scale correction, GPS relation, or quality policy.
public struct MineSurveyRegistrationEngine: Sendable {
    public init() {}

    public func estimate(
        projectID: UUID,
        scanID: UUID,
        observations: [MineControlObservation],
        controlPoints: [MineControlPoint],
        createdAt: Date = .now
    ) throws -> MineScanRegistration {
        let controlsByID = Dictionary(uniqueKeysWithValues: controlPoints.map { ($0.id, $0) })
        var seenControlPointIDs = Set<UUID>()
        var sourcePoints: [Point3D] = []
        var targetPoints: [Point3D] = []

        for observation in observations {
            try observation.validate()
            guard seenControlPointIDs.insert(observation.controlPointID).inserted else {
                throw MineSurveyError.duplicateControlPointObservation(observation.controlPointID)
            }
            guard let controlPoint = controlsByID[observation.controlPointID] else {
                throw MineSurveyError.unknownControlPoint(observation.controlPointID)
            }
            guard controlPoint.projectID == projectID else {
                throw MineSurveyError.controlPointOutsideProject(
                    controlPointID: controlPoint.id,
                    projectID: projectID
                )
            }
            try controlPoint.validate()
            sourcePoints.append(observation.arWorldPosition)
            targetPoints.append(controlPoint.minePosition)
        }

        guard sourcePoints.count >= 3 else {
            throw MineSurveyError.insufficientControlPoints(count: sourcePoints.count)
        }
        guard Self.areNonCollinear(sourcePoints), Self.areNonCollinear(targetPoints) else {
            throw MineSurveyError.degenerateControlGeometry
        }

        let estimate: AlignmentEstimate
        do {
            estimate = try LandmarkAlignmentEngine().estimate(source: sourcePoints, target: targetPoints)
        } catch {
            throw MineSurveyError.degenerateControlGeometry
        }
        let registration = MineScanRegistration(
            projectID: projectID,
            scanID: scanID,
            mineFromARWorld: estimate.targetFromSource,
            method: .surveyedControl,
            rmsResidualMeters: estimate.rmsError,
            controlPointIDs: observations.map(\.controlPointID),
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try registration.validate()
        return registration
    }

    private static func areNonCollinear(_ points: [Point3D]) -> Bool {
        guard let first = points.first else { return false }
        for secondIndex in 1..<points.count {
            let second = points[secondIndex]
            let firstVector = subtract(second, first)
            guard squaredLength(firstVector) > 0.000_000_1 else { continue }
            for thirdIndex in (secondIndex + 1)..<points.count {
                let secondVector = subtract(points[thirdIndex], first)
                let cross = crossProduct(firstVector, secondVector)
                if squaredLength(cross) > 0.000_000_1 {
                    return true
                }
            }
        }
        return false
    }

    private static func subtract(_ left: Point3D, _ right: Point3D) -> Point3D {
        Point3D(x: left.x - right.x, y: left.y - right.y, z: left.z - right.z)
    }

    private static func crossProduct(_ left: Point3D, _ right: Point3D) -> Point3D {
        Point3D(
            x: left.y * right.z - left.z * right.y,
            y: left.z * right.x - left.x * right.z,
            z: left.x * right.y - left.y * right.x
        )
    }

    private static func squaredLength(_ point: Point3D) -> Float {
        point.x * point.x + point.y * point.y + point.z * point.z
    }
}

enum MineSurveyValidation {
    static func requiredText(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MineSurveyError.emptyRequiredText(field: field)
        }
    }

    static func finite(_ point: Point3D) throws {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
            throw MineSurveyError.nonFiniteCoordinate
        }
    }

    static func distinctControlPointIDs(_ ids: [UUID]) throws {
        guard ids.count >= 3 else {
            throw MineSurveyError.insufficientControlPoints(count: ids.count)
        }
        var seen = Set<UUID>()
        for id in ids where !seen.insert(id).inserted {
            throw MineSurveyError.duplicateControlPointObservation(id)
        }
    }
}
