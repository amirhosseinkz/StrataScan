import Foundation

/// A future surface-analysis stage may write this bounded evidence. Until it
/// does, the comparison remains blocked; missing evidence is never treated as
/// coverage.
public struct SurveyBoundaryCoverageEvidence: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case sufficient
        case insufficient
    }

    public var epochID: UUID
    public var boundaryID: UUID
    public var status: Status
    public var evaluatedAt: Date

    public init(epochID: UUID, boundaryID: UUID, status: Status, evaluatedAt: Date = .now) {
        self.epochID = epochID
        self.boundaryID = boundaryID
        self.status = status
        self.evaluatedAt = evaluatedAt
    }
}

public enum SurveyChangeReadinessBlocker: Equatable, Sendable {
    case baselineStationsMissing
    case comparisonStationsMissing
    case baselineCoverageUnavailable
    case comparisonCoverageUnavailable
    case baselineCoverageInsufficient
    case comparisonCoverageInsufficient
}

public enum SurveyChangeReadiness: Equatable, Sendable {
    case ready
    case blocked([SurveyChangeReadinessBlocker])
}

/// Evaluates only the prerequisites for a future change-volume engine. It does
/// not inspect geometry, calculate volume, or infer evidence from a scan name.
public struct SurveyChangeReadinessEvaluator: Sendable {
    public init() {}

    public func evaluate(
        comparison: SurveyChangeComparison,
        baseline: SurveyEpoch,
        comparisonEpoch: SurveyEpoch,
        coverage: [SurveyBoundaryCoverageEvidence]
    ) -> SurveyChangeReadiness {
        var blockers: [SurveyChangeReadinessBlocker] = []
        if baseline.stationIDs.isEmpty { blockers.append(.baselineStationsMissing) }
        if comparisonEpoch.stationIDs.isEmpty { blockers.append(.comparisonStationsMissing) }
        appendCoverageBlocker(epochID: baseline.id, boundaryID: comparison.boundaryID, coverage: coverage, unavailable: .baselineCoverageUnavailable, insufficient: .baselineCoverageInsufficient, to: &blockers)
        appendCoverageBlocker(epochID: comparisonEpoch.id, boundaryID: comparison.boundaryID, coverage: coverage, unavailable: .comparisonCoverageUnavailable, insufficient: .comparisonCoverageInsufficient, to: &blockers)
        return blockers.isEmpty ? .ready : .blocked(blockers)
    }

    private func appendCoverageBlocker(
        epochID: UUID,
        boundaryID: UUID,
        coverage: [SurveyBoundaryCoverageEvidence],
        unavailable: SurveyChangeReadinessBlocker,
        insufficient: SurveyChangeReadinessBlocker,
        to blockers: inout [SurveyChangeReadinessBlocker]
    ) {
        guard let evidence = coverage.first(where: { $0.epochID == epochID && $0.boundaryID == boundaryID }) else {
            blockers.append(unavailable)
            return
        }
        if evidence.status == .insufficient { blockers.append(insufficient) }
    }
}
