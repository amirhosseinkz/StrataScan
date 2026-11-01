import Foundation
import Testing
@testable import StrataCore

@Suite("R0 baseline evidence intake", .serialized)
struct R0BaselineEvidenceIntakeTests {
    @Test("Retained evidence is normalized, private fields are discarded, and replay is idempotent")
    func retainedEvidenceIsPrivateAndIdempotent() async throws {
        let root = try temporaryDirectory("retained")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeManifest(campaign(), to: root)
        let inspection = root.appending(path: "source-inspection.json")
        try writeInspection(to: inspection, addingPrivateField: true)
        let request = R0BaselineEvidenceIntakeRequest(
            runID: "historical-failure", arm: .retainedFailure, repetition: 1,
            evidenceLevel: .e1, inspectionEvidenceURL: inspection
        )

        let first = try await R0BaselineEvidenceIntake().ingest(
            campaignDirectory: root, request: request
        )
        let second = try await R0BaselineEvidenceIntake().ingest(
            campaignDirectory: root, request: request
        )

        #expect(first.mutatedCampaign)
        #expect(!second.mutatedCampaign)
        #expect(first.run.assets.count == 1)
        let imported = try String(contentsOf: root.appending(path: first.run.assets[0].relativePath), encoding: .utf8)
        #expect(!imported.contains("privateAbsolutePath"))
        let report = try await R0BaselineCampaignValidator().validate(campaignDirectory: root)
        #expect(report.requirements.contains(where: {
            $0.id == "RETAINED_FAILURE_INSPECTED" && $0.disposition == .satisfied
        }))
        #expect(report.disposition == .incompleteEvidence)
    }

    @Test("Dry run proves intake without mutating the campaign or evidence directory")
    func dryRunDoesNotMutate() async throws {
        let root = try temporaryDirectory("dry-run")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeManifest(campaign(), to: root)
        let manifestURL = root.appending(path: R0BaselineCampaignValidator.manifestFilename)
        let before = try Data(contentsOf: manifestURL)
        let inspection = root.appending(path: "inspection.json")
        try writeInspection(to: inspection)

        let report = try await R0BaselineEvidenceIntake().ingest(
            campaignDirectory: root,
            request: .init(
                runID: "dry-run", arm: .retainedFailure, repetition: 1,
                evidenceLevel: .e1, inspectionEvidenceURL: inspection
            ),
            dryRun: true
        )

        #expect(report.dryRun)
        #expect(!report.mutatedCampaign)
        #expect(try Data(contentsOf: manifestURL) == before)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "evidence").path))
    }

    @Test("Controlled intake freezes the protocol and a synthetic campaign reaches the exit-review contract")
    func syntheticEndToEndDryRun() async throws {
        let root = try temporaryDirectory("synthetic")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeManifest(campaign(), to: root)
        let inspection = root.appending(path: "inspection.json")
        let failedScorecard = root.appending(path: "failed-scorecard.json")
        let passedScorecard = root.appending(path: "passed-scorecard.json")
        try writeInspection(to: inspection)
        try scorecard(.failed).stableJSON().write(to: failedScorecard, options: .atomic)
        try scorecard(.passed).stableJSON().write(to: passedScorecard, options: .atomic)

        _ = try await R0BaselineEvidenceIntake().ingest(
            campaignDirectory: root,
            request: .init(
                runID: "retained", arm: .retainedFailure, repetition: 1,
                evidenceLevel: .e1, inspectionEvidenceURL: inspection
            )
        )
        for repetition in 1...3 {
            let strata = try await R0BaselineEvidenceIntake().ingest(
                campaignDirectory: root,
                request: .init(
                    runID: "stratascan-r0\(repetition)", arm: .strataScan, repetition: repetition,
                    evidenceLevel: .e2, durationSeconds: 90,
                    inspectionEvidenceURL: inspection, benchmarkScorecardURL: failedScorecard
                )
            )
            #expect(strata.run.protocolID == "r0-close-range-v1")
            #expect(strata.run.operatorPathID == "planar-corner-loop-v1")
            _ = try await R0BaselineEvidenceIntake().ingest(
                campaignDirectory: root,
                request: .init(
                    runID: "competitor-r0\(repetition)", arm: .competitor, repetition: repetition,
                    evidenceLevel: .e2, durationSeconds: 90,
                    benchmarkScorecardURL: passedScorecard
                )
            )
        }

        let report = try await R0BaselineCampaignValidator().validate(campaignDirectory: root)
        #expect(report.disposition == .readyForR0ExitReview)
        #expect(report.earliestProvenFailureStage == .captureTimeline)
        #expect(report.requirements.allSatisfy { $0.disposition == .satisfied })
    }

    @Test("Unsafe sources, invalid identifiers, and cancellation cannot mutate the campaign")
    func rejectsUnsafeInputsAndCancellation() async throws {
        let root = try temporaryDirectory("unsafe")
        let external = try temporaryDirectory("external")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        try writeManifest(campaign(), to: root)
        let externalInspection = external.appending(path: "inspection.json")
        try writeInspection(to: externalInspection)
        let symlink = root.appending(path: "linked-inspection.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: externalInspection)

        await #expect(throws: R0BaselineEvidenceIntakeError.self) {
            try await R0BaselineEvidenceIntake().ingest(
                campaignDirectory: root,
                request: .init(
                    runID: "unsafe-source", arm: .retainedFailure, repetition: 1,
                    evidenceLevel: .e1, inspectionEvidenceURL: symlink
                )
            )
        }
        await #expect(throws: R0BaselineEvidenceIntakeError.self) {
            try await R0BaselineEvidenceIntake().ingest(
                campaignDirectory: root,
                request: .init(
                    runID: "../escape", arm: .retainedFailure, repetition: 1,
                    evidenceLevel: .e1, inspectionEvidenceURL: externalInspection
                )
            )
        }
        let task = Task {
            try await R0BaselineEvidenceIntake().ingest(
                campaignDirectory: root,
                request: .init(
                    runID: "cancelled", arm: .retainedFailure, repetition: 1,
                    evidenceLevel: .e1, inspectionEvidenceURL: externalInspection
                )
            )
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let manifest = try JSONDecoder().decode(
            R0BaselineCampaignManifest.self,
            from: Data(contentsOf: root.appending(path: R0BaselineCampaignValidator.manifestFilename))
        )
        #expect(manifest.runs.isEmpty)
    }

    private func campaign() -> R0BaselineCampaignManifest {
        R0BaselineCampaignManifest(
            campaignID: "r0-close-range-v1", minimumRepetitions: 3,
            acquisitionProtocol: .init(
                protocolID: "r0-close-range-v1", fixtureID: "planar-corner-v1", fixtureVersion: 1,
                deviceClass: "iPhone-Pro-LiDAR-v1", operatorPathID: "planar-corner-loop-v1",
                targetDurationSeconds: 90, durationToleranceSeconds: 5,
                lightingID: "controlled-indoor-v1", reviewProtocolID: "blind-fixed-views-v1"
            ),
            blindReview: .init(
                enabled: true, randomizedArmLabels: true,
                concealedAppIdentityUntilScoring: true, assessorSeparatedFromCapture: true
            ),
            runs: []
        )
    }

    private func inspection() -> ScanInspectionEvidence {
        ScanInspectionEvidence(
            sourcePackageID: UUID(uuidString: "F8DE6C9D-09C3-4504-B93C-63F8697EF86C"),
            manifestSchemaVersion: 1, manifestStatus: "complete",
            stages: ScanInspectionStage.allCases.map {
                .init(stage: $0, disposition: $0 == .captureTimeline ? .failed : .healthy)
            },
            findings: [], earliestProvenFailureStage: .captureTimeline,
            evidenceLimitations: ["synthetic contract evidence"]
        )
    }

    private func writeInspection(to url: URL, addingPrivateField: Bool = false) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(inspection())) as? [String: Any]
        )
        if addingPrivateField { object["privateAbsolutePath"] = "/private/user/capture/package.zip" }
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }

    private func scorecard(_ disposition: BenchmarkScorecardDisposition) -> BenchmarkEvaluationScorecard {
        BenchmarkEvaluationScorecard(
            schemaVersion: BenchmarkEvaluationScorecard.currentSchemaVersion,
            evaluatorVersion: BenchmarkEvaluationScorecard.evaluatorVersion,
            fixtureID: "planar-corner-v1", fixtureVersion: 1,
            fixtureManifestSHA256: String(repeating: "a", count: 64),
            referenceGeometrySHA256: String(repeating: "b", count: 64),
            sourcePackageSHA256: String(repeating: "c", count: 64),
            reconstructionConfigurationSHA256: String(repeating: "d", count: 64),
            candidateGeometrySHA256: String(repeating: "e", count: 64),
            buildCommit: "synthetic", disposition: disposition,
            thresholds: .initialCloseRange, metrics: [], warnings: [], fixedViews: []
        )
    }

    private func writeManifest(_ manifest: R0BaselineCampaignManifest, to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: root.appending(path: R0BaselineCampaignValidator.manifestFilename), options: .atomic
        )
    }

    private func temporaryDirectory(_ suffix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "stratascan-r0-intake-\(suffix)-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
