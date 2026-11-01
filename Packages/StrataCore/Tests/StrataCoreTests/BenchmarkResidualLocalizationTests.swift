import Foundation
import Testing
@testable import StrataCore

@Suite("Benchmark residual localization")
struct BenchmarkResidualLocalizationTests {
    @Test("reports source and candidate disagreement without causal attribution")
    func attributesSourceError() throws {
        let report = try BenchmarkResidualAnalyzer().analyze(
            identity: identity,
            observations: observations(sourceResidual: 0.16, candidateResidual: 0.20)
        )

        #expect(report.attribution == .sourceAndCandidateDisagreeWithReference)
        #expect(report.aggregate(for: .sourceDepth)?.p95Meters == 0.16)
        #expect(report.aggregate(for: .candidateSurface)?.p95Meters == 0.20)
        #expect(!report.depthBands.isEmpty)
        #expect(!report.confidenceBands.isEmpty)
        #expect(!report.worstSpatialCells.isEmpty)
    }

    @Test("candidate disagreement does not prove fusion or extraction caused it")
    func attributesFusionError() throws {
        let report = try BenchmarkResidualAnalyzer().analyze(
            identity: identity,
            observations: observations(sourceResidual: 0.02, candidateResidual: 0.20)
        )

        #expect(report.attribution == .candidateDisagreesWithReference)
    }

    @Test("uses the reconstruction-admitted source population when supplied")
    func usesAdmittedSourcePopulation() throws {
        var values = observations(sourceResidual: 0.20, candidateResidual: 0.20)
        for index in 0..<72 {
            values.append(BenchmarkResidualObservation(
                domain: .admittedSourceDepth,
                position: BenchmarkVector3(x: Double(index) / 100, y: 0, z: 1),
                residualMeters: 0.02,
                sourceDepthOrCameraRangeMeters: 1,
                confidence: 2
            ))
        }
        let report = try BenchmarkResidualAnalyzer().analyze(
            identity: identity,
            observations: values,
            reconstructionAdmissionConfiguration: .productionBalanced
        )

        #expect(report.aggregate(for: .sourceDepth)?.p95Meters == 0.20)
        #expect(report.aggregate(for: .admittedSourceDepth)?.p95Meters == 0.02)
        #expect(report.attribution == .candidateDisagreesWithReference)
        #expect(report.reconstructionAdmissionConfiguration == .productionBalanced)
    }

    @Test("records whether distances use samples or continuous surfaces")
    func recordsReferenceDistanceMode() throws {
        let report = try BenchmarkResidualAnalyzer().analyze(
            identity: identity,
            observations: observations(sourceResidual: 0.02, candidateResidual: 0.04),
            referenceDistanceMode: .continuousTriangleSurface
        )

        #expect(report.referenceDistanceMode == .continuousTriangleSurface)
        #expect(report.limitations.contains { $0.contains("continuous declared triangle surfaces") })
    }

    @Test("reports a candidate within the frozen surface threshold")
    func candidatePasses() throws {
        let report = try BenchmarkResidualAnalyzer().analyze(
            identity: identity,
            observations: observations(sourceResidual: 0.02, candidateResidual: 0.04)
        )

        #expect(report.attribution == .candidateWithinThreshold)
    }

    @Test("uses deterministic negative spatial cell keys and stable JSON")
    func deterministicCells() throws {
        let values = observations(sourceResidual: 0.02, candidateResidual: 0.20)
        let first = try BenchmarkResidualAnalyzer().analyze(identity: identity, observations: values)
        let second = try BenchmarkResidualAnalyzer().analyze(identity: identity, observations: values)

        #expect(try first.stableJSON() == second.stableJSON())
        #expect(first.global.map(\.domain.rawValue) == first.global.map(\.domain.rawValue).sorted())
        #expect(first.worstSpatialCells.contains { $0.x < 0 })
    }

    @Test("rejects invalid and unbounded observations")
    func rejectsInvalidInput() {
        #expect(throws: BenchmarkEvaluationError.self) {
            try BenchmarkResidualAnalyzer().analyze(
                identity: identity,
                observations: [BenchmarkResidualObservation(
                    domain: .candidateSurface,
                    position: BenchmarkVector3(x: 0, y: 0, z: 0),
                    residualMeters: .nan
                )]
            )
        }

        #expect(throws: BenchmarkEvaluationError.self) {
            try BenchmarkResidualLocalizationConfiguration(
                cellSizeMeters: 0.25,
                surfaceThresholdMeters: 0.08,
                depthBandUpperBoundsMeters: [1, 2, 3],
                maximumReferenceSamples: 999
            )
        }
    }

    private var identity: BenchmarkResidualLocalizationIdentity {
        BenchmarkResidualLocalizationIdentity(
            fixtureID: "fixture",
            fixtureVersion: 1,
            fixtureManifestSHA256: String(repeating: "a", count: 64),
            referenceGeometrySHA256: String(repeating: "b", count: 64),
            sourcePackageSHA256: String(repeating: "c", count: 64),
            sourceArchiveSHA256: String(repeating: "d", count: 64),
            reconstructionConfigurationSHA256: String(repeating: "e", count: 64),
            candidateGeometrySHA256: String(repeating: "f", count: 64),
            buildCommit: "test"
        )
    }

    private func observations(sourceResidual: Double, candidateResidual: Double) -> [BenchmarkResidualObservation] {
        var values: [BenchmarkResidualObservation] = []
        for index in 0..<72 {
            let x = index < 36 ? -0.1 : 0.3
            values.append(BenchmarkResidualObservation(
                domain: .sourceDepth,
                position: BenchmarkVector3(x: x, y: 0.1, z: 0.1),
                residualMeters: sourceResidual,
                sourceDepthOrCameraRangeMeters: index < 36 ? 0.8 : 1.4,
                confidence: UInt8(index % 3)
            ))
            values.append(BenchmarkResidualObservation(
                domain: .candidateSurface,
                position: BenchmarkVector3(x: x, y: 0.1, z: 0.1),
                residualMeters: candidateResidual,
                sourceDepthOrCameraRangeMeters: index < 36 ? 0.8 : 1.4
            ))
            values.append(BenchmarkResidualObservation(
                domain: .missingReference,
                position: BenchmarkVector3(x: x, y: 0.1, z: 0.1),
                residualMeters: candidateResidual
            ))
        }
        return values
    }
}
