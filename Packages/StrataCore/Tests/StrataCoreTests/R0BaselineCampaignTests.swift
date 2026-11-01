import CryptoKit
import Foundation
import Testing
@testable import StrataCore

@Suite("R0 baseline campaign", .serialized)
struct R0BaselineCampaignTests {
    @Test("Frozen protocol without physical runs stays explicitly incomplete")
    func emptyCampaignIsProtocolReadyButEvidenceIncomplete() async throws {
        let root = try temporaryDirectory("empty")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeManifest(campaign(runs: []), to: root)

        let first = try await R0BaselineCampaignValidator().validate(campaignDirectory: root)
        let second = try await R0BaselineCampaignValidator().validate(campaignDirectory: root)

        #expect(first.protocolValid)
        #expect(first.disposition == .incompleteEvidence)
        #expect(first.earliestProvenFailureStage == nil)
        #expect(try first.stableJSON() == second.stableJSON())
        #expect(first.limitations.contains(where: { $0.contains("Physical E2") }))
    }

    @Test("Repeated matched E2 evidence can qualify an earliest failure for exit review")
    func repeatedE2EvidenceQualifiesRootCause() async throws {
        let root = try temporaryDirectory("qualified")
        defer { try? FileManager.default.removeItem(at: root) }
        var runs: [R0BaselineRun] = []
        let retained = try evidenceAsset(
            evidence(stage: .captureTimeline), name: "retained-inspection.json", root: root
        )
        runs.append(R0BaselineRun(
            runID: "retained", arm: .retainedFailure, repetition: 1,
            evidenceLevel: .e1, assets: [retained]
        ))
        for repetition in 1...2 {
            let inspection = try evidenceAsset(
                evidence(stage: .captureTimeline),
                name: "strata-\(repetition)-inspection.json",
                root: root
            )
            let strataScorecard = try scorecardAsset(
                scorecard(disposition: .failed),
                name: "strata-\(repetition)-scorecard.json",
                root: root
            )
            runs.append(controlledRun(
                id: "strata-\(repetition)", arm: .strataScan, repetition: repetition,
                assets: [inspection, strataScorecard]
            ))
            let competitorScorecard = try scorecardAsset(
                scorecard(disposition: .passed),
                name: "competitor-\(repetition)-scorecard.json",
                root: root
            )
            runs.append(controlledRun(
                id: "competitor-\(repetition)", arm: .competitor, repetition: repetition,
                assets: [competitorScorecard]
            ))
        }
        try writeManifest(campaign(runs: runs), to: root)

        let report = try await R0BaselineCampaignValidator().validate(campaignDirectory: root)

        #expect(report.disposition == .readyForR0ExitReview)
        #expect(report.earliestProvenFailureStage == .captureTimeline)
        #expect(report.requirements.allSatisfy { $0.disposition == .satisfied })
        #expect(report.findings.contains(where: { $0.code == "EARLIEST_FAILURE_REPEATED" }))
    }

    @Test("Repeated failed scorecards do not fabricate a causal stage")
    func failedOutputsDoNotFabricateRootCause() async throws {
        let root = try temporaryDirectory("output-only")
        defer { try? FileManager.default.removeItem(at: root) }
        var runs: [R0BaselineRun] = []
        for repetition in 1...2 {
            runs.append(controlledRun(
                id: "strata-\(repetition)", arm: .strataScan, repetition: repetition,
                assets: [try scorecardAsset(scorecard(disposition: .failed), name: "s\(repetition).json", root: root)]
            ))
            runs.append(controlledRun(
                id: "competitor-\(repetition)", arm: .competitor, repetition: repetition,
                assets: [try scorecardAsset(scorecard(disposition: .passed), name: "c\(repetition).json", root: root)]
            ))
        }
        try writeManifest(campaign(runs: runs), to: root)

        let report = try await R0BaselineCampaignValidator().validate(campaignDirectory: root)

        #expect(report.disposition == .incompleteEvidence)
        #expect(report.earliestProvenFailureStage == nil)
        #expect(report.findings.contains(where: { $0.code == "OUTPUT_FAILURE_REPEATED_ROOT_CAUSE_UNISOLATED" }))
    }

    @Test("Mismatched paths and durations are excluded from controlled comparison")
    func excludesProtocolMismatch() async throws {
        let root = try temporaryDirectory("mismatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = try scorecardAsset(scorecard(disposition: .passed), name: "scorecard.json", root: root)
        let mismatched = R0BaselineRun(
            runID: "mismatched", arm: .strataScan, repetition: 1, evidenceLevel: .e2,
            protocolID: "r0-close-range-v1", deviceClass: "iPhone-Pro-LiDAR-v1",
            operatorPathID: "different-path", durationSeconds: 150, lightingID: "controlled-indoor-v1",
            reviewProtocolID: "blind-fixed-views-v1", assets: [asset]
        )
        try writeManifest(campaign(runs: [mismatched]), to: root)

        let report = try await R0BaselineCampaignValidator().validate(campaignDirectory: root)

        #expect(report.disposition == .incompleteEvidence)
        #expect(report.findings.contains(where: { $0.code == "CONTROLLED_RUN_PROTOCOL_MISMATCH" }))
        #expect(report.arms.first(where: { $0.arm == .strataScan })?.e2OrHigherRunCount == 1)
    }

    @Test("Symlinked evidence is rejected and cancellation propagates")
    func rejectsSymlinkAndPropagatesCancellation() async throws {
        let root = try temporaryDirectory("symlink")
        let external = try temporaryDirectory("external")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: external) }
        let data = try scorecard(disposition: .passed).stableJSON()
        let externalFile = external.appending(path: "scorecard.json")
        try data.write(to: externalFile)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "scorecard.json"), withDestinationURL: externalFile
        )
        let asset = R0BaselineAsset(
            kind: .benchmarkScorecard, relativePath: "scorecard.json",
            byteCount: Int64(data.count), sha256: digest(data)
        )
        try writeManifest(campaign(runs: [controlledRun(id: "unsafe", arm: .strataScan, repetition: 1, assets: [asset])]), to: root)

        let report = try await R0BaselineCampaignValidator().validate(campaignDirectory: root)
        #expect(report.findings.contains(where: { $0.code == "RUN_EVIDENCE_INVALID" }))
        #expect(report.arms.first(where: { $0.arm == .strataScan })?.validRunCount == 0)

        let task = Task { try await R0BaselineCampaignValidator().validate(campaignDirectory: root) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func campaign(runs: [R0BaselineRun]) -> R0BaselineCampaignManifest {
        R0BaselineCampaignManifest(
            campaignID: "r0-close-range-v1",
            minimumRepetitions: 2,
            acquisitionProtocol: R0AcquisitionProtocol(
                protocolID: "r0-close-range-v1", fixtureID: "planar-corner-v1", fixtureVersion: 1,
                deviceClass: "iPhone-Pro-LiDAR-v1", operatorPathID: "planar-corner-loop-v1",
                targetDurationSeconds: 90, durationToleranceSeconds: 5,
                lightingID: "controlled-indoor-v1", reviewProtocolID: "blind-fixed-views-v1"
            ),
            blindReview: R0BlindReviewProtocol(
                enabled: true, randomizedArmLabels: true,
                concealedAppIdentityUntilScoring: true, assessorSeparatedFromCapture: true
            ),
            runs: runs
        )
    }

    private func controlledRun(
        id: String, arm: R0BaselineArm, repetition: Int, assets: [R0BaselineAsset]
    ) -> R0BaselineRun {
        R0BaselineRun(
            runID: id, arm: arm, repetition: repetition, evidenceLevel: .e2,
            protocolID: "r0-close-range-v1", deviceClass: "iPhone-Pro-LiDAR-v1",
            operatorPathID: "planar-corner-loop-v1", durationSeconds: 90,
            lightingID: "controlled-indoor-v1", reviewProtocolID: "blind-fixed-views-v1",
            assets: assets
        )
    }

    private func evidence(stage: ScanInspectionStage) -> ScanInspectionEvidence {
        ScanInspectionEvidence(
            sourcePackageID: UUID(), manifestSchemaVersion: 1, manifestStatus: "complete",
            stages: [], findings: [], earliestProvenFailureStage: stage, evidenceLimitations: []
        )
    }

    private func scorecard(disposition: BenchmarkScorecardDisposition) -> BenchmarkEvaluationScorecard {
        BenchmarkEvaluationScorecard(
            schemaVersion: BenchmarkEvaluationScorecard.currentSchemaVersion,
            evaluatorVersion: BenchmarkEvaluationScorecard.evaluatorVersion,
            fixtureID: "planar-corner-v1", fixtureVersion: 1,
            fixtureManifestSHA256: String(repeating: "a", count: 64),
            referenceGeometrySHA256: String(repeating: "b", count: 64),
            sourcePackageSHA256: String(repeating: "c", count: 64),
            reconstructionConfigurationSHA256: String(repeating: "d", count: 64),
            candidateGeometrySHA256: String(repeating: "e", count: 64),
            buildCommit: "test", disposition: disposition,
            thresholds: .initialCloseRange, metrics: [], warnings: [], fixedViews: []
        )
    }

    private func evidenceAsset(
        _ evidence: ScanInspectionEvidence, name: String, root: URL
    ) throws -> R0BaselineAsset {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(evidence)
        try data.write(to: root.appending(path: name), options: .atomic)
        return R0BaselineAsset(kind: .inspectionEvidence, relativePath: name, byteCount: Int64(data.count), sha256: digest(data))
    }

    private func scorecardAsset(
        _ scorecard: BenchmarkEvaluationScorecard, name: String, root: URL
    ) throws -> R0BaselineAsset {
        let data = try scorecard.stableJSON()
        try data.write(to: root.appending(path: name), options: .atomic)
        return R0BaselineAsset(kind: .benchmarkScorecard, relativePath: name, byteCount: Int64(data.count), sha256: digest(data))
    }

    private func writeManifest(_ manifest: R0BaselineCampaignManifest, to root: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: root.appending(path: R0BaselineCampaignValidator.manifestFilename), options: .atomic
        )
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "stratascan-r0-baseline-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
