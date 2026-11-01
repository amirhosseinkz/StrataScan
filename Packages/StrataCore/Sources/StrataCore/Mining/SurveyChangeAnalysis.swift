import Foundation

/// A labelled survey moment. The terminology is generic so the same model can
/// describe demolition, stockpile, construction, or inspection change without
/// exposing an industry-specific workflow in the app UI.
public enum SurveyEpochKind: String, Codable, CaseIterable, Sendable {
    case baseline
    case comparison
}

public struct SurveyEpoch: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var name: String
    public var kind: SurveyEpochKind
    public var stationIDs: [UUID]
    public var capturedAt: Date

    public init(id: UUID = UUID(), projectID: UUID, name: String, kind: SurveyEpochKind, stationIDs: [UUID], capturedAt: Date = .now) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.kind = kind
        self.stationIDs = stationIDs
        self.capturedAt = capturedAt
    }

    public func validate() throws {
        try MineSurveyValidation.requiredText(name, field: "survey epoch name")
        guard !stationIDs.isEmpty, Set(stationIDs).count == stationIDs.count else {
            throw SurveyChangeAnalysisError.invalidStationSet
        }
    }
}

/// An explicit, axis-aligned analysis boundary in an already registered project
/// grid. It is an input to a future calculation, not a calculated result.
public struct SurveyChangeBoundary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var name: String
    public var minimum: Point3D
    public var maximum: Point3D
    public var createdAt: Date

    public init(id: UUID = UUID(), projectID: UUID, name: String, minimum: Point3D, maximum: Point3D, createdAt: Date = .now) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.minimum = minimum
        self.maximum = maximum
        self.createdAt = createdAt
    }

    public func validate() throws {
        try MineSurveyValidation.requiredText(name, field: "change boundary name")
        try MineSurveyValidation.finite(minimum)
        try MineSurveyValidation.finite(maximum)
        guard minimum.x < maximum.x, minimum.y < maximum.y, minimum.z < maximum.z else {
            throw SurveyChangeAnalysisError.invalidBoundary
        }
    }

    /// The finite bounding volume, in cubic meters. This is not an excavation
    /// volume and must never be presented as one.
    public var boundingVolumeCubicMeters: Float {
        (maximum.x - minimum.x) * (maximum.y - minimum.y) * (maximum.z - minimum.z)
    }
}

public struct SurveyChangeComparison: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var baselineEpochID: UUID
    public var comparisonEpochID: UUID
    public var boundaryID: UUID
    public var createdAt: Date

    public init(id: UUID = UUID(), projectID: UUID, baselineEpochID: UUID, comparisonEpochID: UUID, boundaryID: UUID, createdAt: Date = .now) {
        self.id = id; self.projectID = projectID; self.baselineEpochID = baselineEpochID
        self.comparisonEpochID = comparisonEpochID; self.boundaryID = boundaryID; self.createdAt = createdAt
    }

    public func validate() throws {
        guard baselineEpochID != comparisonEpochID else { throw SurveyChangeAnalysisError.sameEpoch }
    }
}

public enum SurveyChangeAnalysisError: Error, Equatable, Sendable {
    case invalidStationSet
    case invalidBoundary
    case sameEpoch
}
