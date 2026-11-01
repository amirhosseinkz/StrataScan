import Foundation
import Testing
@testable import StrataCore

@Suite("Survey change-analysis inputs")
struct SurveyChangeAnalysisTests {
    @Test("A named registered-grid boundary has finite cubic-meter bounds")
    func validatesBoundary() throws {
        let boundary = SurveyChangeBoundary(
            projectID: UUID(), name: "Wall removal", minimum: Point3D(x: 1, y: 2, z: 3), maximum: Point3D(x: 3, y: 5, z: 7)
        )
        try boundary.validate()
        #expect(boundary.boundingVolumeCubicMeters == 24)
    }

    @Test("Boundary and epoch inputs reject ambiguous comparisons")
    func rejectsAmbiguousInputs() {
        let projectID = UUID()
        #expect(throws: SurveyChangeAnalysisError.invalidBoundary) {
            try SurveyChangeBoundary(projectID: projectID, name: "bad", minimum: Point3D(x: 0, y: 0, z: 0), maximum: Point3D(x: 0, y: 1, z: 1)).validate()
        }
        let epoch = UUID()
        #expect(throws: SurveyChangeAnalysisError.sameEpoch) {
            try SurveyChangeComparison(projectID: projectID, baselineEpochID: epoch, comparisonEpochID: epoch, boundaryID: UUID()).validate()
        }
    }

    @Test("A comparison is blocked until both epochs have sufficient boundary coverage")
    func evaluatesCoverageReadiness() {
        let projectID = UUID()
        let baseline = SurveyEpoch(projectID: projectID, name: "Before", kind: .baseline, stationIDs: [UUID()])
        let after = SurveyEpoch(projectID: projectID, name: "After", kind: .comparison, stationIDs: [UUID()])
        let boundaryID = UUID()
        let comparison = SurveyChangeComparison(projectID: projectID, baselineEpochID: baseline.id, comparisonEpochID: after.id, boundaryID: boundaryID)
        let evaluator = SurveyChangeReadinessEvaluator()

        #expect(evaluator.evaluate(comparison: comparison, baseline: baseline, comparisonEpoch: after, coverage: []) == .blocked([.baselineCoverageUnavailable, .comparisonCoverageUnavailable]))
        #expect(evaluator.evaluate(comparison: comparison, baseline: baseline, comparisonEpoch: after, coverage: [
            SurveyBoundaryCoverageEvidence(epochID: baseline.id, boundaryID: boundaryID, status: .sufficient),
            SurveyBoundaryCoverageEvidence(epochID: after.id, boundaryID: boundaryID, status: .insufficient)
        ]) == .blocked([.comparisonCoverageInsufficient]))
        #expect(evaluator.evaluate(comparison: comparison, baseline: baseline, comparisonEpoch: after, coverage: [
            SurveyBoundaryCoverageEvidence(epochID: baseline.id, boundaryID: boundaryID, status: .sufficient),
            SurveyBoundaryCoverageEvidence(epochID: after.id, boundaryID: boundaryID, status: .sufficient)
        ]) == .ready)
    }
}
