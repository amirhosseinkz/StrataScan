import Foundation

/// Records whether a station started independently, was deliberately
/// relocalized from another station, or resumed after an interruption. This is
/// provenance only; it never authorizes an implicit geometry merge.
public enum MineStationSessionContext: Codable, Equatable, Sendable {
    case independentARSession
    case relocalized(fromStationID: UUID)
    case interrupted
}

/// A named, registered position in a mine survey project.
public struct MineScanStation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var scanID: UUID
    public var registrationID: UUID
    public var code: String
    public var sessionContext: MineStationSessionContext
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        scanID: UUID,
        registrationID: UUID,
        code: String,
        sessionContext: MineStationSessionContext = .independentARSession,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.scanID = scanID
        self.registrationID = registrationID
        self.code = code
        self.sessionContext = sessionContext
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        try MineSurveyValidation.requiredText(code, field: "mine station code")
        guard createdAt <= updatedAt else { throw MineSurveyError.invalidTimestampOrder }
        if case let .relocalized(fromStationID) = sessionContext, fromStationID == id {
            throw MineTraverseError.stationCannotRelocalizeFromItself
        }
    }
}

/// A reviewable relationship between two registered stations. The current
/// foundation supports surveyed checkpoints only, so the link has evidence a
/// reviewer can inspect rather than a hidden automatic merge.
public struct MineTraverseLink: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var fromStationID: UUID
    public var toStationID: UUID
    public var checkpointControlPointIDs: [UUID]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        fromStationID: UUID,
        toStationID: UUID,
        checkpointControlPointIDs: [UUID],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.fromStationID = fromStationID
        self.toStationID = toStationID
        self.checkpointControlPointIDs = checkpointControlPointIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        guard fromStationID != toStationID else { throw MineTraverseError.sameStation }
        try MineSurveyValidation.distinctControlPointIDs(checkpointControlPointIDs)
        guard createdAt <= updatedAt else { throw MineSurveyError.invalidTimestampOrder }
    }
}

public enum MineTraverseError: Error, Equatable, Sendable {
    case sameStation
    case stationCannotRelocalizeFromItself
    case stationRequiresRegistration
    case relocalizationStationNotFound(UUID)
    case relocalizationStationOutsideProject(UUID)
    case traverseStationNotFound(UUID)
    case traverseStationOutsideProject(UUID)
    case checkpointNotSharedByStations(UUID)
}
