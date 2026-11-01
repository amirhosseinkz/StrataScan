import Foundation
import Testing
@testable import StrataCore

@Suite("Reconstruction quality sweep")
struct ReconstructionQualitySweepTests {
    @Test("Plan changes only the declared production fusion factor")
    func planChangesOnlyDeclaredFactor() throws {
        let plan = try makePlan().validated()
        let baseline = try plan.configuration(for: 2)
        let candidate = try plan.configuration(for: 3)

        #expect(baseline == .productionBalanced)
        #expect(candidate.minimumConsistentNeighborCount == 3)
        var expected = TSDFReconstructionConfiguration.productionBalanced
        expected.minimumConsistentNeighborCount = 3
        #expect(candidate == expected)
    }

    @Test("Analyzer recommends the strongest non-regressing all-scene improvement")
    func recommendsAllSceneImprovement() throws {
        let plan = makePlan()
        let baseline = variant(value: 2, p95Scale: 1, outlierScale: 1)
        let weaker = variant(value: 3, p95Scale: 0.95, outlierScale: 0.96)
        let stronger = variant(value: 4, p95Scale: 0.85, outlierScale: 0.9)

        let report = try ReconstructionQualitySweepAnalyzer().analyze(
            plan: plan,
            variants: [stronger, baseline, weaker]
        )

        #expect(report.recommendedValue == 4)
        #expect(report.productionDefaultChanged == false)
        #expect(report.dispositions.first(where: { $0.value == 4 })?.eligible == true)
    }

    @Test("Millimeter tolerance factor preserves every other production setting")
    func toleranceChangesOnlyDeclaredFactor() throws {
        let base = makePlan()
        let plan = ReconstructionQualitySweepPlan(
            campaignID: "r05-tolerance-test",
            factor: .absoluteNeighborToleranceMillimeters,
            baselineValue: 80,
            values: [40, 80],
            buildCommit: base.buildCommit,
            scenes: base.scenes
        )
        let candidate = try plan.configuration(for: 40)
        var expected = TSDFReconstructionConfiguration.productionBalanced
        expected.absoluteNeighborToleranceMeters = 0.04

        #expect(candidate == expected)
    }

    @Test("A primary regression in one scene rejects the variant")
    func rejectsOneSceneRegression() throws {
        let plan = makePlan()
        let baseline = variant(value: 2, p95Scale: 1, outlierScale: 1)
        var scenes = variant(value: 3, p95Scale: 0.9, outlierScale: 0.9).scenes
        scenes[2] = scene(id: "scene-c", p95: 0.31, outlier: 0.18)
        let regressed = ReconstructionQualitySweepVariantResult(
            value: 3,
            configurationSHA256: String(repeating: "b", count: 64),
            scenes: scenes
        )

        let report = try ReconstructionQualitySweepAnalyzer().analyze(
            plan: plan,
            variants: [baseline, regressed, variant(value: 4, p95Scale: 1, outlierScale: 1)]
        )

        #expect(report.recommendedValue == nil)
        #expect(report.dispositions.first(where: { $0.value == 3 })?.rejection == .primaryMetricRegression)
    }

    @Test("Sparse preservation factor changes only the declared policy")
    func sparsePolicyChangesOnlyDeclaredFactor() throws {
        let base = makePlan()
        let plan = ReconstructionQualitySweepPlan(
            campaignID: "r05-sparse-policy-test",
            factor: .preservesSparseObservations,
            baselineValue: 1,
            values: [0, 1],
            buildCommit: base.buildCommit,
            scenes: base.scenes
        )
        let candidate = try plan.configuration(for: 0)
        var expected = TSDFReconstructionConfiguration.productionBalanced
        expected.preservesSparseObservations = false

        #expect(candidate == expected)
    }

    @Test("Duplicate scene results fail safely")
    func rejectsDuplicateSceneResults() throws {
        let plan = makePlan()
        let duplicate = scene(id: "scene-a", p95: 0.2, outlier: 0.2)
        let baseline = ReconstructionQualitySweepVariantResult(
            value: 2,
            configurationSHA256: String(repeating: "a", count: 64),
            scenes: [duplicate, duplicate, scene(id: "scene-c", p95: 0.3, outlier: 0.2)]
        )

        #expect(throws: ReconstructionQualitySweepError.invalidPlan) {
            try ReconstructionQualitySweepAnalyzer().analyze(
                plan: plan,
                variants: [baseline, variant(value: 3, p95Scale: 1, outlierScale: 1), variant(value: 4, p95Scale: 1, outlierScale: 1)]
            )
        }
    }

    private func makePlan() -> ReconstructionQualitySweepPlan {
        ReconstructionQualitySweepPlan(
            campaignID: "r05-test",
            factor: .minimumConsistentNeighborCount,
            baselineValue: 2,
            values: [2, 3, 4],
            buildCommit: "test-commit",
            scenes: [
                planScene(id: "scene-a", uuid: "00000000-0000-0000-0000-000000000001"),
                planScene(id: "scene-b", uuid: "00000000-0000-0000-0000-000000000002"),
                planScene(id: "scene-c", uuid: "00000000-0000-0000-0000-000000000003")
            ]
        )
    }

    private func planScene(id: String, uuid: String) -> ReconstructionQualitySweepScene {
        ReconstructionQualitySweepScene(
            sceneID: id,
            scanID: UUID(uuidString: uuid)!,
            packageStoreRoot: "/private/tmp/packages",
            fixtureDirectory: "/private/tmp/fixture"
        )
    }

    private func variant(value: Int, p95Scale: Double, outlierScale: Double) -> ReconstructionQualitySweepVariantResult {
        ReconstructionQualitySweepVariantResult(
            value: value,
            configurationSHA256: String(repeating: "a", count: 64),
            scenes: [
                scene(id: "scene-a", p95: 0.2 * p95Scale, outlier: 0.3 * outlierScale),
                scene(id: "scene-b", p95: 0.4 * p95Scale, outlier: 0.4 * outlierScale),
                scene(id: "scene-c", p95: 0.3 * p95Scale, outlier: 0.2 * outlierScale)
            ]
        )
    }

    private func scene(id: String, p95: Double, outlier: Double) -> ReconstructionQualitySweepSceneResult {
        let scanID: UUID
        switch id {
        case "scene-a":
            scanID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        case "scene-b":
            scanID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        default:
            scanID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        }
        return ReconstructionQualitySweepSceneResult(
            sceneID: id,
            scanID: scanID,
            candidateGeometrySHA256: String(repeating: "c", count: 64),
            promotedVertexCount: 100,
            promotedTriangleCount: 200,
            metrics: ReconstructionQualitySweepMetrics(
                surfaceP95Meters: p95,
                outlierRatio: outlier,
                observedCompleteness: 0.8,
                disconnectedComponentRatio: 0.1,
                maximumDimensionRelativeError: 0.1,
                colorCoverage: 0.7,
                outputIntegrityPassed: true
            )
        )
    }
}
