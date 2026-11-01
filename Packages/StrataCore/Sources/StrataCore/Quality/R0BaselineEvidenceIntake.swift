import CryptoKit
import Foundation

public struct R0BaselineEvidenceIntakeRequest: Equatable, Sendable {
    public let runID: String
    public let arm: R0BaselineArm
    public let repetition: Int
    public let evidenceLevel: R0EvidenceLevel
    public let durationSeconds: Double?
    public let inspectionEvidenceURL: URL?
    public let benchmarkScorecardURL: URL?

    public init(
        runID: String,
        arm: R0BaselineArm,
        repetition: Int,
        evidenceLevel: R0EvidenceLevel,
        durationSeconds: Double? = nil,
        inspectionEvidenceURL: URL? = nil,
        benchmarkScorecardURL: URL? = nil
    ) {
        self.runID = runID
        self.arm = arm
        self.repetition = repetition
        self.evidenceLevel = evidenceLevel
        self.durationSeconds = durationSeconds
        self.inspectionEvidenceURL = inspectionEvidenceURL
        self.benchmarkScorecardURL = benchmarkScorecardURL
    }
}

public struct R0BaselineEvidenceIntakeReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let intakeVersion = "r0.4-intake-v1"

    public let schemaVersion: Int
    public let intakeVersion: String
    public let campaignID: String
    public let run: R0BaselineRun
    public let dryRun: Bool
    public let mutatedCampaign: Bool
    public let privacyBoundary: String
    public let campaignDisposition: R0BaselineCampaignDisposition

    public func stableJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum R0BaselineEvidenceIntakeError: Error, Equatable, Sendable {
    case unsafeCampaignDirectory
    case missingManifest
    case malformedManifest
    case invalidCampaign
    case invalidRunID
    case invalidRepetition
    case invalidEvidenceLevel
    case durationRequired
    case invalidDuration
    case requiredEvidenceMissing
    case unexpectedEvidence
    case unsafeSource(String)
    case oversizedSource(String)
    case malformedInspectionEvidence
    case incompatibleInspectionEvidence
    case malformedBenchmarkScorecard
    case incompatibleBenchmarkScorecard
    case duplicateRunConflict(String)
    case destinationConflict(String)
}

/// Imports only typed, privacy-safe evidence summaries into the frozen R0 campaign.
/// Raw scan packages, RGB payloads, JPEGs, and exports never cross this boundary.
public struct R0BaselineEvidenceIntake: Sendable {
    public static let evidenceDirectory = "evidence"
    public static let inspectionFilename = "inspection.json"
    public static let scorecardFilename = "scorecard.json"

    public init() {}

    public func ingest(
        campaignDirectory: URL,
        request: R0BaselineEvidenceIntakeRequest,
        dryRun: Bool = false
    ) async throws -> R0BaselineEvidenceIntakeReport {
        try Task.checkCancellation()
        let root = try safeDirectory(campaignDirectory)
        let manifestURL = root.appending(path: R0BaselineCampaignValidator.manifestFilename)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw R0BaselineEvidenceIntakeError.missingManifest
        }
        let manifest: R0BaselineCampaignManifest = try decodeBounded(
            manifestURL,
            maximumBytes: R0BaselineCampaignValidator.maximumManifestBytes,
            failure: .malformedManifest
        )
        try validate(request, against: manifest)
        let currentCampaignReport = try await R0BaselineCampaignValidator().validate(campaignDirectory: root)
        guard currentCampaignReport.protocolValid else {
            throw R0BaselineEvidenceIntakeError.invalidCampaign
        }

        var canonicalAssets: [(kind: R0BaselineAssetKind, filename: String, data: Data)] = []
        if let inspectionURL = request.inspectionEvidenceURL {
            let evidence: ScanInspectionEvidence = try decodeSource(
                inspectionURL,
                failure: .malformedInspectionEvidence
            )
            let declaredStages = Set(evidence.stages.map(\.stage.rawValue))
            let requiredStages = Set(ScanInspectionStage.allCases.map(\.rawValue))
            guard evidence.schemaVersion == 2,
                  evidence.inspectorVersion == "R0.1",
                  evidence.sourcePackageID != nil,
                  declaredStages.count == evidence.stages.count,
                  declaredStages == requiredStages else {
                throw R0BaselineEvidenceIntakeError.incompatibleInspectionEvidence
            }
            canonicalAssets.append((.inspectionEvidence, Self.inspectionFilename, try stableJSON(evidence)))
        }
        if let scorecardURL = request.benchmarkScorecardURL {
            let scorecard: BenchmarkEvaluationScorecard = try decodeSource(
                scorecardURL,
                failure: .malformedBenchmarkScorecard
            )
            guard scorecard.schemaVersion == BenchmarkEvaluationScorecard.currentSchemaVersion,
                  scorecard.evaluatorVersion == BenchmarkEvaluationScorecard.evaluatorVersion,
                  scorecard.fixtureID == manifest.acquisitionProtocol.fixtureID,
                  scorecard.fixtureVersion == manifest.acquisitionProtocol.fixtureVersion else {
                throw R0BaselineEvidenceIntakeError.incompatibleBenchmarkScorecard
            }
            canonicalAssets.append((.benchmarkScorecard, Self.scorecardFilename, try scorecard.stableJSON()))
        }

        let relativeRoot = "\(Self.evidenceDirectory)/\(request.runID)"
        let assets = canonicalAssets.map { item in
            R0BaselineAsset(
                kind: item.kind,
                relativePath: "\(relativeRoot)/\(item.filename)",
                byteCount: Int64(item.data.count),
                sha256: digest(item.data)
            )
        }
        let run = makeRun(request: request, protocol: manifest.acquisitionProtocol, assets: assets)
        if let existing = manifest.runs.first(where: { $0.runID == request.runID }) {
            guard existing == run else {
                throw R0BaselineEvidenceIntakeError.duplicateRunConflict(request.runID)
            }
            let evidenceMatches = try canonicalAssets.allSatisfy { item in
                let destination = root.appending(path: relativeRoot).appending(path: item.filename)
                return try regularFileData(destination) == item.data
            }
            guard evidenceMatches else {
                throw R0BaselineEvidenceIntakeError.destinationConflict(request.runID)
            }
            let campaignReport = try await R0BaselineCampaignValidator().validate(campaignDirectory: root)
            return makeReport(
                manifest: manifest,
                run: run,
                dryRun: dryRun,
                mutated: false,
                disposition: campaignReport.disposition
            )
        }

        let proposed = R0BaselineCampaignManifest(
            schemaVersion: manifest.schemaVersion,
            campaignID: manifest.campaignID,
            minimumRepetitions: manifest.minimumRepetitions,
            acquisitionProtocol: manifest.acquisitionProtocol,
            blindReview: manifest.blindReview,
            runs: (manifest.runs + [run]).sorted(by: { $0.runID < $1.runID })
        )
        if dryRun {
            let campaignReport = try await R0BaselineCampaignValidator().validate(campaignDirectory: root)
            return makeReport(
                manifest: manifest,
                run: run,
                dryRun: true,
                mutated: false,
                disposition: campaignReport.disposition
            )
        }

        try Task.checkCancellation()
        let expectedEvidenceRoot = root.appending(path: Self.evidenceDirectory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: expectedEvidenceRoot, withIntermediateDirectories: true)
        let evidenceRoot = try safeDirectory(expectedEvidenceRoot)
        guard evidenceRoot == expectedEvidenceRoot.standardizedFileURL else {
            throw R0BaselineEvidenceIntakeError.unsafeCampaignDirectory
        }
        let finalDirectory = evidenceRoot.appending(path: request.runID, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: finalDirectory.path) else {
            throw R0BaselineEvidenceIntakeError.destinationConflict(request.runID)
        }
        let staging = evidenceRoot.appending(
            path: ".staging-\(request.runID)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var stagingExists = true
        defer {
            if stagingExists { try? FileManager.default.removeItem(at: staging) }
        }
        for item in canonicalAssets.sorted(by: { $0.filename < $1.filename }) {
            try Task.checkCancellation()
            try item.data.write(to: staging.appending(path: item.filename), options: [.atomic, .completeFileProtection])
        }
        try FileManager.default.moveItem(at: staging, to: finalDirectory)
        stagingExists = false
        do {
            try stableJSON(proposed).write(to: manifestURL, options: [.atomic, .completeFileProtection])
        } catch {
            try? FileManager.default.removeItem(at: finalDirectory)
            throw error
        }

        let campaignReport = try await R0BaselineCampaignValidator().validate(campaignDirectory: root)
        return makeReport(
            manifest: proposed,
            run: run,
            dryRun: false,
            mutated: true,
            disposition: campaignReport.disposition
        )
    }

    private func validate(
        _ request: R0BaselineEvidenceIntakeRequest,
        against manifest: R0BaselineCampaignManifest
    ) throws {
        guard isSafeRunID(request.runID) else { throw R0BaselineEvidenceIntakeError.invalidRunID }
        guard request.repetition > 0 else { throw R0BaselineEvidenceIntakeError.invalidRepetition }
        if request.arm == .retainedFailure {
            guard request.evidenceLevel == .e1 else { throw R0BaselineEvidenceIntakeError.invalidEvidenceLevel }
            guard request.inspectionEvidenceURL != nil else {
                throw R0BaselineEvidenceIntakeError.requiredEvidenceMissing
            }
            guard request.benchmarkScorecardURL == nil, request.durationSeconds == nil else {
                throw R0BaselineEvidenceIntakeError.unexpectedEvidence
            }
        } else {
            guard request.evidenceLevel.rank >= R0EvidenceLevel.e2.rank else {
                throw R0BaselineEvidenceIntakeError.invalidEvidenceLevel
            }
            guard request.benchmarkScorecardURL != nil else {
                throw R0BaselineEvidenceIntakeError.requiredEvidenceMissing
            }
            guard let duration = request.durationSeconds else {
                throw R0BaselineEvidenceIntakeError.durationRequired
            }
            guard duration.isFinite,
                  abs(duration - manifest.acquisitionProtocol.targetDurationSeconds)
                    <= manifest.acquisitionProtocol.durationToleranceSeconds else {
                throw R0BaselineEvidenceIntakeError.invalidDuration
            }
            if request.arm == .strataScan, request.inspectionEvidenceURL == nil {
                throw R0BaselineEvidenceIntakeError.requiredEvidenceMissing
            }
            if request.arm == .competitor, request.inspectionEvidenceURL != nil {
                throw R0BaselineEvidenceIntakeError.unexpectedEvidence
            }
        }
    }

    private func makeRun(
        request: R0BaselineEvidenceIntakeRequest,
        protocol contract: R0AcquisitionProtocol,
        assets: [R0BaselineAsset]
    ) -> R0BaselineRun {
        let controlled = request.arm != .retainedFailure
        return R0BaselineRun(
            runID: request.runID,
            arm: request.arm,
            repetition: request.repetition,
            evidenceLevel: request.evidenceLevel,
            protocolID: controlled ? contract.protocolID : nil,
            deviceClass: controlled ? contract.deviceClass : nil,
            operatorPathID: controlled ? contract.operatorPathID : nil,
            durationSeconds: controlled ? request.durationSeconds : nil,
            lightingID: controlled ? contract.lightingID : nil,
            reviewProtocolID: controlled ? contract.reviewProtocolID : nil,
            assets: assets.sorted(by: { $0.kind.rawValue < $1.kind.rawValue })
        )
    }

    private func makeReport(
        manifest: R0BaselineCampaignManifest,
        run: R0BaselineRun,
        dryRun: Bool,
        mutated: Bool,
        disposition: R0BaselineCampaignDisposition
    ) -> R0BaselineEvidenceIntakeReport {
        R0BaselineEvidenceIntakeReport(
            schemaVersion: R0BaselineEvidenceIntakeReport.currentSchemaVersion,
            intakeVersion: R0BaselineEvidenceIntakeReport.intakeVersion,
            campaignID: manifest.campaignID,
            run: run,
            dryRun: dryRun,
            mutatedCampaign: mutated,
            privacyBoundary: "typed reports only; raw packages, RGB payloads, JPEGs, and exports excluded",
            campaignDisposition: disposition
        )
    }

    private func decodeSource<T: Decodable>(
        _ url: URL,
        failure: R0BaselineEvidenceIntakeError
    ) throws -> T {
        let canonical = url.standardizedFileURL
        let resolved = canonical.resolvingSymlinksInPath()
        guard canonical == resolved else { throw R0BaselineEvidenceIntakeError.unsafeSource(url.path) }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw R0BaselineEvidenceIntakeError.unsafeSource(url.path)
        }
        guard Int64(values.fileSize ?? -1) <= R0BaselineCampaignValidator.maximumEvidenceBytes else {
            throw R0BaselineEvidenceIntakeError.oversizedSource(url.path)
        }
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: resolved, options: .mappedIfSafe)) }
        catch { throw failure }
    }

    private func decodeBounded<T: Decodable>(
        _ url: URL,
        maximumBytes: Int64,
        failure: R0BaselineEvidenceIntakeError
    ) throws -> T {
        let canonical = url.standardizedFileURL
        let resolved = canonical.resolvingSymlinksInPath()
        let values = try resolved.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard canonical == resolved,
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0,
              Int64(size) <= maximumBytes else { throw failure }
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: resolved, options: .mappedIfSafe)) }
        catch { throw failure }
    }

    private func safeDirectory(_ url: URL) throws -> URL {
        let canonical = url.standardizedFileURL
        let resolved = canonical.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard canonical == resolved,
              FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw R0BaselineEvidenceIntakeError.unsafeCampaignDirectory
        }
        return resolved
    }

    private func regularFileData(_ url: URL) throws -> Data {
        let canonical = url.standardizedFileURL
        let resolved = canonical.resolvingSymlinksInPath()
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard canonical == resolved, values.isRegularFile == true, values.isSymbolicLink != true else {
            throw R0BaselineEvidenceIntakeError.destinationConflict(url.path)
        }
        return try Data(contentsOf: resolved, options: .mappedIfSafe)
    }

    private func stableJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isSafeRunID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 96 && value != "." && value != ".." &&
            value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }
}
