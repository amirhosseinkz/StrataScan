import CryptoKit
import Foundation

public enum R0BaselineArm: String, Codable, CaseIterable, Sendable {
    case retainedFailure = "retained-failure"
    case strataScan = "stratascan"
    case competitor
}

public enum R0EvidenceLevel: String, Codable, CaseIterable, Sendable {
    case e0 = "E0", e1 = "E1", e2 = "E2", e3 = "E3", e4 = "E4", e5 = "E5"

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

public enum R0BaselineAssetKind: String, Codable, Sendable {
    case inspectionEvidence = "inspection-evidence"
    case benchmarkScorecard = "benchmark-scorecard"
}

public struct R0BaselineAsset: Codable, Equatable, Sendable {
    public let kind: R0BaselineAssetKind
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String

    public init(kind: R0BaselineAssetKind, relativePath: String, byteCount: Int64, sha256: String) {
        self.kind = kind
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct R0AcquisitionProtocol: Codable, Equatable, Sendable {
    public let protocolID: String
    public let fixtureID: String
    public let fixtureVersion: Int
    public let deviceClass: String
    public let operatorPathID: String
    public let targetDurationSeconds: Double
    public let durationToleranceSeconds: Double
    public let lightingID: String
    public let reviewProtocolID: String

    public init(
        protocolID: String,
        fixtureID: String,
        fixtureVersion: Int,
        deviceClass: String,
        operatorPathID: String,
        targetDurationSeconds: Double,
        durationToleranceSeconds: Double,
        lightingID: String,
        reviewProtocolID: String
    ) {
        self.protocolID = protocolID
        self.fixtureID = fixtureID
        self.fixtureVersion = fixtureVersion
        self.deviceClass = deviceClass
        self.operatorPathID = operatorPathID
        self.targetDurationSeconds = targetDurationSeconds
        self.durationToleranceSeconds = durationToleranceSeconds
        self.lightingID = lightingID
        self.reviewProtocolID = reviewProtocolID
    }
}

public struct R0BlindReviewProtocol: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let randomizedArmLabels: Bool
    public let concealedAppIdentityUntilScoring: Bool
    public let assessorSeparatedFromCapture: Bool

    public init(
        enabled: Bool,
        randomizedArmLabels: Bool,
        concealedAppIdentityUntilScoring: Bool,
        assessorSeparatedFromCapture: Bool
    ) {
        self.enabled = enabled
        self.randomizedArmLabels = randomizedArmLabels
        self.concealedAppIdentityUntilScoring = concealedAppIdentityUntilScoring
        self.assessorSeparatedFromCapture = assessorSeparatedFromCapture
    }

    var isFrozenBlindProtocol: Bool {
        enabled && randomizedArmLabels && concealedAppIdentityUntilScoring && assessorSeparatedFromCapture
    }
}

public struct R0BaselineRun: Codable, Equatable, Sendable {
    public let runID: String
    public let arm: R0BaselineArm
    public let repetition: Int
    public let evidenceLevel: R0EvidenceLevel
    public let protocolID: String?
    public let deviceClass: String?
    public let operatorPathID: String?
    public let durationSeconds: Double?
    public let lightingID: String?
    public let reviewProtocolID: String?
    public let assets: [R0BaselineAsset]

    public init(
        runID: String,
        arm: R0BaselineArm,
        repetition: Int,
        evidenceLevel: R0EvidenceLevel,
        protocolID: String? = nil,
        deviceClass: String? = nil,
        operatorPathID: String? = nil,
        durationSeconds: Double? = nil,
        lightingID: String? = nil,
        reviewProtocolID: String? = nil,
        assets: [R0BaselineAsset]
    ) {
        self.runID = runID
        self.arm = arm
        self.repetition = repetition
        self.evidenceLevel = evidenceLevel
        self.protocolID = protocolID
        self.deviceClass = deviceClass
        self.operatorPathID = operatorPathID
        self.durationSeconds = durationSeconds
        self.lightingID = lightingID
        self.reviewProtocolID = reviewProtocolID
        self.assets = assets
    }
}

public struct R0BaselineCampaignManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let campaignID: String
    public let minimumRepetitions: Int
    public let acquisitionProtocol: R0AcquisitionProtocol
    public let blindReview: R0BlindReviewProtocol
    public let runs: [R0BaselineRun]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        campaignID: String,
        minimumRepetitions: Int,
        acquisitionProtocol: R0AcquisitionProtocol,
        blindReview: R0BlindReviewProtocol,
        runs: [R0BaselineRun]
    ) {
        self.schemaVersion = schemaVersion
        self.campaignID = campaignID
        self.minimumRepetitions = minimumRepetitions
        self.acquisitionProtocol = acquisitionProtocol
        self.blindReview = blindReview
        self.runs = runs
    }
}

public enum R0BaselineRequirementDisposition: String, Codable, Sendable {
    case satisfied, missing, invalid
}

public struct R0BaselineRequirement: Codable, Equatable, Sendable {
    public let id: String
    public let disposition: R0BaselineRequirementDisposition
    public let detail: String
}

public struct R0BaselineArmSummary: Codable, Equatable, Sendable {
    public let arm: R0BaselineArm
    public let declaredRunCount: Int
    public let validRunCount: Int
    public let e2OrHigherRunCount: Int
    public let passedScorecardCount: Int
    public let failedScorecardCount: Int
    public let insufficientScorecardCount: Int
}

public struct R0BaselineFinding: Codable, Equatable, Sendable {
    public let code: String
    public let conclusion: String
    public let evidence: String
    public let limitation: String?
}

public enum R0BaselineCampaignDisposition: String, Codable, Sendable {
    case incompleteEvidence = "incomplete-evidence"
    case readyForR0ExitReview = "ready-for-r0-exit-review"
}

public struct R0BaselineCampaignReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let validatorVersion = "r0.4-v1"

    public let schemaVersion: Int
    public let validatorVersion: String
    public let campaignID: String
    public let protocolValid: Bool
    public let disposition: R0BaselineCampaignDisposition
    public let requirements: [R0BaselineRequirement]
    public let arms: [R0BaselineArmSummary]
    public let earliestProvenFailureStage: ScanInspectionStage?
    public let findings: [R0BaselineFinding]
    public let limitations: [String]

    public func stableJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum R0BaselineCampaignError: Error, Equatable, Sendable {
    case unsafeCampaignDirectory
    case missingManifest
    case oversizedManifest
    case malformedManifest
    case invalidManifest(String)
    case unsafeAsset(String)
    case assetIntegrityMismatch(String)
    case malformedEvidence(String)
}

public struct R0BaselineCampaignValidator: Sendable {
    public static let manifestFilename = "campaign.json"
    public static let maximumManifestBytes: Int64 = 1_048_576
    public static let maximumEvidenceBytes: Int64 = 8_388_608
    public static let maximumRuns = 64

    public init() {}

    public func validate(campaignDirectory: URL) async throws -> R0BaselineCampaignReport {
        try Task.checkCancellation()
        let root = try safeDirectory(campaignDirectory)
        let manifestURL = root.appendingPathComponent(Self.manifestFilename)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw R0BaselineCampaignError.missingManifest
        }
        let manifest: R0BaselineCampaignManifest = try decodeBounded(
            manifestURL,
            maximumBytes: Self.maximumManifestBytes,
            failure: .malformedManifest
        )
        try validateManifest(manifest)

        var evidenceByRun: [String: ScanInspectionEvidence] = [:]
        var scorecardByRun: [String: BenchmarkEvaluationScorecard] = [:]
        var invalidRuns = Set<String>()

        for run in manifest.runs.sorted(by: { $0.runID < $1.runID }) {
            try Task.checkCancellation()
            for asset in run.assets {
                do {
                    let url = try containedRegularFile(root: root, relativePath: asset.relativePath)
                    let size = try fileSize(url)
                    guard size == asset.byteCount, sha256(url) == asset.sha256.lowercased() else {
                        throw R0BaselineCampaignError.assetIntegrityMismatch(run.runID)
                    }
                    switch asset.kind {
                    case .inspectionEvidence:
                        evidenceByRun[run.runID] = try decodeBounded(
                            url,
                            maximumBytes: Self.maximumEvidenceBytes,
                            failure: .malformedEvidence(run.runID)
                        )
                    case .benchmarkScorecard:
                        scorecardByRun[run.runID] = try decodeBounded(
                            url,
                            maximumBytes: Self.maximumEvidenceBytes,
                            failure: .malformedEvidence(run.runID)
                        )
                    }
                } catch {
                    invalidRuns.insert(run.runID)
                }
            }
            let requiredKind: R0BaselineAssetKind = run.arm == .retainedFailure
                ? .inspectionEvidence : .benchmarkScorecard
            if !run.assets.contains(where: { $0.kind == requiredKind }) {
                invalidRuns.insert(run.runID)
            }
        }

        let controlledRuns = manifest.runs.filter { $0.arm != .retainedFailure }
        let matchedControlled = controlledRuns.filter {
            !invalidRuns.contains($0.runID) && matches($0, protocol: manifest.acquisitionProtocol)
        }
        let strataRuns = matchedControlled.filter { $0.arm == .strataScan }
        let competitorRuns = matchedControlled.filter { $0.arm == .competitor }
        let strataE2 = strataRuns.filter { $0.evidenceLevel.rank >= R0EvidenceLevel.e2.rank }
        let competitorE2 = competitorRuns.filter { $0.evidenceLevel.rank >= R0EvidenceLevel.e2.rank }

        var requirements: [R0BaselineRequirement] = []
        requirements.append(requirement(
            id: "BLIND_PROTOCOL_FROZEN",
            satisfied: manifest.blindReview.isFrozenBlindProtocol,
            detail: "Review must randomize and conceal arm identity and separate capture from assessment."
        ))
        requirements.append(requirement(
            id: "RETAINED_FAILURE_INSPECTED",
            satisfied: manifest.runs.contains {
                $0.arm == .retainedFailure && !invalidRuns.contains($0.runID) && evidenceByRun[$0.runID] != nil
            },
            detail: "At least one retained StrataScan failure must have checksum-valid inspector evidence."
        ))
        requirements.append(requirement(
            id: "STRATASCAN_E2_REPETITIONS",
            satisfied: strataE2.count >= manifest.minimumRepetitions,
            detail: "Need at least \(manifest.minimumRepetitions) matched E2 StrataScan runs; found \(strataE2.count)."
        ))
        requirements.append(requirement(
            id: "COMPETITOR_E2_REPETITIONS",
            satisfied: competitorE2.count >= manifest.minimumRepetitions,
            detail: "Need at least \(manifest.minimumRepetitions) matched E2 competitor runs; found \(competitorE2.count)."
        ))
        let scorecardsComparable = comparableScorecards(
            runIDs: (strataE2 + competitorE2).map(\.runID),
            scorecards: scorecardByRun,
            protocol: manifest.acquisitionProtocol
        )
        requirements.append(requirement(
            id: "SCORECARDS_COMPLETE_AND_COMPARABLE",
            satisfied: scorecardsComparable,
            detail: "Every controlled E2 run must have a scorecard for the frozen fixture and evaluator contract."
        ))

        let provenStage = repeatedProvenFailure(
            runs: manifest.runs,
            evidence: evidenceByRun,
            invalidRuns: invalidRuns,
            minimumRepetitions: manifest.minimumRepetitions
        )
        requirements.append(requirement(
            id: "EARLIEST_FAILURE_EVIDENCED",
            satisfied: provenStage != nil,
            detail: provenStage.map { "Repeated E2 evidence isolates \($0.rawValue)." }
                ?? "No pipeline stage is proven as the earliest repeated E2 failure."
        ))

        var findings: [R0BaselineFinding] = []
        if !invalidRuns.isEmpty {
            findings.append(R0BaselineFinding(
                code: "RUN_EVIDENCE_INVALID",
                conclusion: "One or more declared runs have unsafe, missing, corrupt, or malformed evidence.",
                evidence: invalidRuns.sorted().joined(separator: ", "),
                limitation: "Invalid runs are excluded from every repetition, comparison, and root-cause count."
            ))
        }
        let failedStrataScorecards = strataE2.compactMap { scorecardByRun[$0.runID] }
            .filter { $0.disposition == .failed }.count
        if failedStrataScorecards >= manifest.minimumRepetitions, provenStage == nil {
            findings.append(R0BaselineFinding(
                code: "OUTPUT_FAILURE_REPEATED_ROOT_CAUSE_UNISOLATED",
                conclusion: "The measured output repeatedly misses the frozen scorecard, but no upstream stage is yet proven causal.",
                evidence: "\(failedStrataScorecards) matched E2 StrataScan scorecards failed.",
                limitation: "Output failure alone does not identify capture, trajectory, fusion, extraction, viewer, or export as root cause."
            ))
        }
        if !controlledRuns.isEmpty && matchedControlled.count != controlledRuns.count {
            findings.append(R0BaselineFinding(
                code: "CONTROLLED_RUN_PROTOCOL_MISMATCH",
                conclusion: "One or more controlled runs are not comparable under the frozen protocol.",
                evidence: "\(controlledRuns.count - matchedControlled.count) controlled runs failed protocol or asset validation.",
                limitation: "Mismatched runs cannot support competitive or causal claims."
            ))
        }
        if let provenStage {
            findings.append(R0BaselineFinding(
                code: "EARLIEST_FAILURE_REPEATED",
                conclusion: "The earliest repeated E2 failure is \(provenStage.rawValue).",
                evidence: "At least \(manifest.minimumRepetitions) valid inspector reports agree on the stage.",
                limitation: "This qualifies the work-order decision, not product quality or competitive parity."
            ))
        }

        let arms = R0BaselineArm.allCases.map { arm in
            let declared = manifest.runs.filter { $0.arm == arm }
            let valid = declared.filter { !invalidRuns.contains($0.runID) }
            let scorecards = valid.compactMap { scorecardByRun[$0.runID] }
            return R0BaselineArmSummary(
                arm: arm,
                declaredRunCount: declared.count,
                validRunCount: valid.count,
                e2OrHigherRunCount: valid.filter { $0.evidenceLevel.rank >= R0EvidenceLevel.e2.rank }.count,
                passedScorecardCount: scorecards.filter { $0.disposition == .passed }.count,
                failedScorecardCount: scorecards.filter { $0.disposition == .failed }.count,
                insufficientScorecardCount: scorecards.filter { $0.disposition == .insufficientEvidence }.count
            )
        }
        let ready = requirements.allSatisfy { $0.disposition == .satisfied }
        var limitations: [String] = []
        if strataE2.count < manifest.minimumRepetitions || competitorE2.count < manifest.minimumRepetitions {
            limitations.append("Physical E2 matched-path evidence is incomplete; simulator or synthetic evidence cannot replace it.")
        }
        if provenStage == nil {
            limitations.append("No earliest causal pipeline failure is proven; tuning a downstream module would be speculative.")
        }

        return R0BaselineCampaignReport(
            schemaVersion: R0BaselineCampaignReport.currentSchemaVersion,
            validatorVersion: R0BaselineCampaignReport.validatorVersion,
            campaignID: manifest.campaignID,
            protocolValid: manifest.blindReview.isFrozenBlindProtocol,
            disposition: ready ? .readyForR0ExitReview : .incompleteEvidence,
            requirements: requirements,
            arms: arms,
            earliestProvenFailureStage: provenStage,
            findings: findings.sorted(by: { $0.code < $1.code }),
            limitations: limitations
        )
    }

    private func validateManifest(_ manifest: R0BaselineCampaignManifest) throws {
        guard manifest.schemaVersion == R0BaselineCampaignManifest.currentSchemaVersion,
              !manifest.campaignID.isEmpty,
              (2...10).contains(manifest.minimumRepetitions),
              manifest.runs.count <= Self.maximumRuns,
              !manifest.acquisitionProtocol.protocolID.isEmpty,
              !manifest.acquisitionProtocol.fixtureID.isEmpty,
              manifest.acquisitionProtocol.fixtureVersion > 0,
              !manifest.acquisitionProtocol.deviceClass.isEmpty,
              !manifest.acquisitionProtocol.operatorPathID.isEmpty,
              manifest.acquisitionProtocol.targetDurationSeconds.isFinite,
              manifest.acquisitionProtocol.targetDurationSeconds > 0,
              manifest.acquisitionProtocol.durationToleranceSeconds.isFinite,
              manifest.acquisitionProtocol.durationToleranceSeconds >= 0,
              !manifest.acquisitionProtocol.lightingID.isEmpty,
              !manifest.acquisitionProtocol.reviewProtocolID.isEmpty else {
            throw R0BaselineCampaignError.invalidManifest("campaign contract")
        }
        guard Set(manifest.runs.map(\.runID)).count == manifest.runs.count else {
            throw R0BaselineCampaignError.invalidManifest("duplicate run ID")
        }
        for run in manifest.runs {
            guard !run.runID.isEmpty, run.repetition > 0, run.assets.count <= 2,
                  Set(run.assets.map(\.kind)).count == run.assets.count else {
                throw R0BaselineCampaignError.invalidManifest("run \(run.runID)")
            }
            for asset in run.assets {
                guard asset.byteCount >= 0, isSHA256(asset.sha256) else {
                    throw R0BaselineCampaignError.invalidManifest("asset \(run.runID)")
                }
            }
        }
    }

    private func matches(_ run: R0BaselineRun, protocol contract: R0AcquisitionProtocol) -> Bool {
        guard run.protocolID == contract.protocolID,
              run.deviceClass == contract.deviceClass,
              run.operatorPathID == contract.operatorPathID,
              run.lightingID == contract.lightingID,
              run.reviewProtocolID == contract.reviewProtocolID,
              let duration = run.durationSeconds, duration.isFinite else { return false }
        return abs(duration - contract.targetDurationSeconds) <= contract.durationToleranceSeconds
    }

    private func comparableScorecards(
        runIDs: [String],
        scorecards: [String: BenchmarkEvaluationScorecard],
        protocol contract: R0AcquisitionProtocol
    ) -> Bool {
        guard !runIDs.isEmpty else { return false }
        let values = runIDs.compactMap { scorecards[$0] }
        guard values.count == runIDs.count else { return false }
        return values.allSatisfy {
            $0.fixtureID == contract.fixtureID &&
            $0.fixtureVersion == contract.fixtureVersion &&
            $0.evaluatorVersion == BenchmarkEvaluationScorecard.evaluatorVersion
        }
    }

    private func repeatedProvenFailure(
        runs: [R0BaselineRun],
        evidence: [String: ScanInspectionEvidence],
        invalidRuns: Set<String>,
        minimumRepetitions: Int
    ) -> ScanInspectionStage? {
        let stages = runs.filter {
            $0.arm != .competitor && !invalidRuns.contains($0.runID) &&
            $0.evidenceLevel.rank >= R0EvidenceLevel.e2.rank
        }.compactMap { evidence[$0.runID]?.earliestProvenFailureStage }
        let counts = Dictionary(grouping: stages, by: { $0 }).mapValues(\.count)
        return ScanInspectionStage.allCases.first { (counts[$0] ?? 0) >= minimumRepetitions }
    }

    private func requirement(id: String, satisfied: Bool, detail: String) -> R0BaselineRequirement {
        R0BaselineRequirement(id: id, disposition: satisfied ? .satisfied : .missing, detail: detail)
    }

    private func safeDirectory(_ url: URL) throws -> URL {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw R0BaselineCampaignError.unsafeCampaignDirectory }
        return canonical
    }

    private func containedRegularFile(root: URL, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
            throw R0BaselineCampaignError.unsafeAsset(relativePath)
        }
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/"), resolved == candidate else {
            throw R0BaselineCampaignError.unsafeAsset(relativePath)
        }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw R0BaselineCampaignError.unsafeAsset(relativePath)
        }
        return resolved
    }

    private func decodeBounded<T: Decodable>(
        _ url: URL,
        maximumBytes: Int64,
        failure: R0BaselineCampaignError
    ) throws -> T {
        let size = try fileSize(url)
        guard size <= maximumBytes else {
            if url.lastPathComponent == Self.manifestFilename { throw R0BaselineCampaignError.oversizedManifest }
            throw failure
        }
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url, options: .mappedIfSafe)) }
        catch { throw failure }
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
    }

    private func sha256(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
}
