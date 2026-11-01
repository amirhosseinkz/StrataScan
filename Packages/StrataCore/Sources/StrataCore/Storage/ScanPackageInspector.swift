import CryptoKit
import Foundation

/// A read-only, deterministic forensic view of a managed scan package. It is a
/// diagnostic boundary: it reports the evidence that exists and never repairs,
/// normalizes, or writes source data.
public enum ScanInspectionStage: String, Codable, CaseIterable, Sendable {
    case packageIntegrity, captureTimeline, rgbdArchive, trajectory, coverage
    case canonicalGeometry, reconstruction, surfaceExtraction, crossStageConsistency, viewer, export
}

public enum ScanInspectionSeverity: String, Codable, CaseIterable, Sendable {
    case info, warning, error, blocker
}

public enum ScanInspectionDisposition: String, Codable, CaseIterable, Sendable {
    case healthy, suspicious, failed, insufficientEvidence, unavailable, notApplicable, unqualified
}

public struct ScanInspectionMetrics: Codable, Equatable, Sendable {
    public var counts: [String: Int]
    public var ratios: [String: Double]
    public var values: [String: String]

    public init(counts: [String: Int] = [:], ratios: [String: Double] = [:], values: [String: String] = [:]) {
        self.counts = counts
        self.ratios = ratios
        self.values = values
    }
}

public struct ScanInspectionFinding: Codable, Equatable, Sendable, Identifiable {
    public var code: String
    public var stage: ScanInspectionStage
    public var severity: ScanInspectionSeverity
    public var evidence: String
    public var conclusion: String
    public var limitation: String
    public var recommendedNextMeasurement: String
    public var metrics: ScanInspectionMetrics

    public var id: String { "\(stage.rawValue).\(code)" }

    public init(
        code: String,
        stage: ScanInspectionStage,
        severity: ScanInspectionSeverity,
        evidence: String,
        conclusion: String,
        limitation: String,
        recommendedNextMeasurement: String,
        metrics: ScanInspectionMetrics = .init()
    ) {
        self.code = code
        self.stage = stage
        self.severity = severity
        self.evidence = evidence
        self.conclusion = conclusion
        self.limitation = limitation
        self.recommendedNextMeasurement = recommendedNextMeasurement
        self.metrics = metrics
    }
}

public struct ScanInspectionStageReport: Codable, Equatable, Sendable {
    public var stage: ScanInspectionStage
    public var disposition: ScanInspectionDisposition
    public var metrics: ScanInspectionMetrics

    public init(stage: ScanInspectionStage, disposition: ScanInspectionDisposition, metrics: ScanInspectionMetrics = .init()) {
        self.stage = stage
        self.disposition = disposition
        self.metrics = metrics
    }
}

/// The deterministic report content. This intentionally excludes the time at
/// which the inspection ran, so it can be compared byte-for-byte in benchmarks.
public struct ScanInspectionEvidence: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var inspectorVersion: String
    public var sourcePackageID: UUID?
    public var manifestSchemaVersion: Int?
    public var manifestStatus: String?
    public var stages: [ScanInspectionStageReport]
    public var findings: [ScanInspectionFinding]
    public var earliestProvenFailureStage: ScanInspectionStage?
    public var earliestSuspiciousStage: ScanInspectionStage?
    public var earliestInsufficientEvidenceStage: ScanInspectionStage?
    public var evidenceLimitations: [String]

    public init(
        schemaVersion: Int = 2,
        inspectorVersion: String = "R0.1",
        sourcePackageID: UUID?,
        manifestSchemaVersion: Int?,
        manifestStatus: String?,
        stages: [ScanInspectionStageReport],
        findings: [ScanInspectionFinding],
        earliestProvenFailureStage: ScanInspectionStage?,
        earliestSuspiciousStage: ScanInspectionStage? = nil,
        earliestInsufficientEvidenceStage: ScanInspectionStage? = nil,
        evidenceLimitations: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.inspectorVersion = inspectorVersion
        self.sourcePackageID = sourcePackageID
        self.manifestSchemaVersion = manifestSchemaVersion
        self.manifestStatus = manifestStatus
        self.stages = stages
        self.findings = findings
        self.earliestProvenFailureStage = earliestProvenFailureStage
        self.earliestSuspiciousStage = earliestSuspiciousStage
        self.earliestInsufficientEvidenceStage = earliestInsufficientEvidenceStage
        self.evidenceLimitations = evidenceLimitations
    }
}

public struct ScanInspectionReport: Codable, Equatable, Sendable {
    /// Run-specific metadata. It is deliberately excluded from `stableJSON()`.
    public var inspectedAt: Date
    public var evidence: ScanInspectionEvidence

    public init(inspectedAt: Date = .now, evidence: ScanInspectionEvidence) {
        self.inspectedAt = inspectedAt
        self.evidence = evidence
    }

    public func stableJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(evidence)
    }
}

public enum ScanPackageInspectorError: Error, Equatable, Sendable {
    case packageNotDirectory
    case unsafePackageRoot
    case ioFailure(String)
}

public struct ScanPackageInspector: Sendable {
    public static let manifestFilename = "manifest.json"
    /// R0.1 diagnostic thresholds, deliberately not product-accuracy gates.
    public static let diagnosticMinimumAcceptedKeyframes = 12
    public static let diagnosticMaximumKeyframeGapSeconds = 2.0
    public static let diagnosticMinimumAcceptedRateHz = 0.5
    public static let diagnosticMinimumValidDepthRatio = 0.50
    public static let diagnosticMinimumMediumConfidenceRatio = 0.50
    public static let diagnosticMaximumRangeRejectionRatio = 0.25
    private static let diagnosticDepthMinimumMeters: Float = 0.10
    private static let diagnosticDepthMaximumMeters: Float = 5.0
    private static let diagnosticDepthHistogramBinMeters: Float = 0.01
    private static let diagnosticTranslationHistogramBinMeters = 0.01
    private static let diagnosticTranslationHistogramMaximumMeters = 10.0
    private static let diagnosticRotationHistogramBinDegrees = 0.5
    private static let diagnosticRotationHistogramMaximumDegrees = 180.0
    private static let diagnosticCoverageStride = 64
    private static let maximumDiagnosticCoverageCells = 100_000
    private static let maximumCanonicalDiagnosticCells = 100_000
    private static let maximumManifestBytes = 1_048_576
    private static let maximumManifestAssetCount = 100_000
    private static let maximumPackageEntries = 100_000
    private static let maximumDiagnosticCoordinateMeters: Float = 1_000_000
    public init() {}

    /// Inspects a finalized package directory. Archive containers are not
    /// expanded by this API: callers must first present a read-only directory
    /// representation, preserving the iOS runtime's dependency-free boundary.
    public func inspect(packageURL: URL, derivedProcessingRoot: URL? = nil) async throws -> ScanInspectionReport {
        try Task.checkCancellation()
        let manager = FileManager.default
        let root = packageURL.standardizedFileURL
        let rootValues = try resourceValues(for: root)
        guard rootValues.isSymbolicLink != true else { throw ScanPackageInspectorError.unsafePackageRoot }
        guard rootValues.isDirectory == true else { throw ScanPackageInspectorError.packageNotDirectory }

        let manifestURL = root.appending(path: Self.manifestFilename)
        guard manager.fileExists(atPath: manifestURL.path) else {
            return reportForMissingManifest()
        }
        let manifestValues = try resourceValues(for: manifestURL)
        guard manifestValues.isRegularFile == true,
              manifestValues.isSymbolicLink != true,
              Self.isContained(manifestURL, under: root),
              let manifestByteCount = manifestValues.fileSize,
              (1...Self.maximumManifestBytes).contains(manifestByteCount)
        else {
            return reportForManifestFailure(
                code: "PKG_MANIFEST_LIMIT",
                evidence: "manifest.json is not a contained regular file or exceeds the bounded read limit."
            )
        }
        let manifest: ScanPackageManifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(ScanPackageManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            return reportForUnreadableManifest()
        }
        guard manifest.assets.count <= Self.maximumManifestAssetCount else {
            return reportForManifestFailure(
                code: "PKG_MANIFEST_ASSET_LIMIT",
                evidence: "The manifest declares more assets than the bounded inspector limit."
            )
        }

        var findings: [ScanInspectionFinding] = []
        var integrity = ScanInspectionMetrics(counts: ["declaredAssetCount": manifest.assets.count])
        var disposition: ScanInspectionDisposition = .healthy
        var declared = Set<String>()
        for asset in manifest.assets.sorted(by: { $0.relativePath < $1.relativePath }) {
            try Task.checkCancellation()
            guard declared.insert(asset.relativePath).inserted else {
                disposition = .failed
                findings.append(finding("PKG_DUPLICATE_PATH", .packageIntegrity, .error, "Manifest declares \(asset.relativePath) more than once.", "Package integrity is invalid.", "The inspector cannot determine which duplicate was intended.", "Produce a package with one asset declaration per path."))
                continue
            }
            guard Self.isSafe(relativePath: asset.relativePath) else {
                disposition = .failed
                findings.append(finding("PKG_UNSAFE_PATH", .packageIntegrity, .blocker, "Manifest declares an unsafe relative path.", "The package cannot be safely replayed.", "No asset content was read through the unsafe path.", "Regenerate the package using contained relative paths."))
                continue
            }
            let fileURL = root.appending(path: asset.relativePath)
            let values = try resourceValues(for: fileURL)
            guard values.isRegularFile == true, values.isSymbolicLink != true, Self.isContained(fileURL, under: root) else {
                disposition = .failed
                findings.append(finding("PKG_CONTAINMENT", .packageIntegrity, .blocker, "Declared asset is missing, not a regular file, or escapes package containment.", "The package is not safe to replay.", "The affected asset was not decoded.", "Regenerate the finalized package."))
                continue
            }
            let bytes = Int64(values.fileSize ?? -1)
            if bytes == 0 {
                disposition = maxDisposition(disposition, .suspicious)
                findings.append(finding("PKG_EMPTY_ASSET", .packageIntegrity, .warning, "Declared asset has zero bytes.", "The asset may be truncated or intentionally empty.", "The manifest does not say whether this asset is optional.", "Compare with the capture-stage record."))
            }
            if bytes != asset.byteCount {
                disposition = .failed
                findings.append(finding("PKG_BYTE_COUNT", .packageIntegrity, .error, "Declared and present byte counts differ.", "Package integrity is invalid.", "Checksum agreement is not trusted after a size mismatch.", "Reacquire the immutable package."))
            }
            if try sha256(of: fileURL) != asset.sha256.lowercased() {
                disposition = .failed
                findings.append(finding("PKG_CHECKSUM", .packageIntegrity, .error, "Declared SHA-256 does not match the asset bytes.", "Package integrity is invalid.", "The inspector does not infer the original bytes.", "Reacquire the immutable package."))
            }
        }
        let present = try regularRelativePaths(under: root)
        let unexpected = present.subtracting(declared).subtracting([Self.manifestFilename])
        integrity.counts["presentRegularFileCount"] = present.count
        integrity.counts["unexpectedRegularFileCount"] = unexpected.count
        if !unexpected.isEmpty {
            disposition = maxDisposition(disposition, .suspicious)
            findings.append(finding("PKG_UNEXPECTED_ASSET", .packageIntegrity, .warning, "Package contains regular files not declared by the manifest.", "Those files are not replayable evidence.", "Their purpose cannot be inferred from names alone.", "Inspect package finalization output."))
        }

        let integrityIsValid = disposition == .healthy || disposition == .suspicious
        let integrityReport = PackageIntegrityReport(scanID: manifest.localScanID, failures: integrityIsValid ? [] : [.manifestUnreadable])
        var archiveMetrics = try inspectArchive(packageURL: root, manifest: manifest, integrity: integrityReport, findings: &findings)
        let canonical = try inspectCanonical(packageURL: root, manifest: manifest, integrity: integrityReport, findings: &findings)
        let rawMesh = inspectRawMesh(
            packageURL: root,
            manifest: manifest,
            firstCaptureTimestamp: Double(archiveMetrics.metrics.values["firstCaptureTimestamp"] ?? ""),
            lastCaptureTimestamp: Double(archiveMetrics.metrics.values["lastCaptureTimestamp"] ?? ""),
            findings: &findings
        )
        archiveMetrics.metrics.values["meshTimelineRelationship"] = rawMesh.metrics.values["timelineRelationship"] ?? "unavailable"
        let timeline = timelineMetrics(manifest: manifest)
        let derived = try await ScanPackageDerivedInspector().inspect(
            packageURL: root,
            manifest: manifest,
            integrity: integrityReport,
            archiveSource: archiveMetrics.source,
            canonicalDisposition: canonical.disposition,
            rawMeshDisposition: rawMesh.disposition,
            suppliedRoot: derivedProcessingRoot
        )
        findings.append(contentsOf: derived.findings)

        if let telemetry = manifest.captureTelemetry {
            let accepted = telemetry.acceptedCalibratedKeyframeCount
            let rejected = telemetry.calibratedKeyframeRejectionCounts.values.reduce(0, +)
            let decisions = accepted + rejected
            if decisions > 0, Double(rejected) / Double(decisions) > 0.75 {
                findings.append(finding("CAPTURE_KEYFRAME_REJECTION_HIGH", .captureTimeline, .warning, "\(rejected) of \(decisions) recorded keyframe decisions were rejected.", "Capture evidence admission is suspicious.", "Candidate and sampled-frame counters are different populations.", "Review rejection-reason distribution and field capture path." , metrics: .init(counts: ["accepted": accepted, "rejected": rejected], ratios: ["rejectionRatio": Double(rejected) / Double(decisions)])))
            }
            if telemetry.calibratedKeyframeCandidateCount == 0, decisions > 0 {
                findings.append(finding("CAPTURE_TELEMETRY_COUNTS_INCONSISTENT", .captureTimeline, .warning, "Candidate count is zero while accepted/rejected decisions are retained.", "Telemetry populations cannot be reconciled.", "Historical telemetry may predate candidate recording.", "Record candidate and decision counters from the same capture release."))
            }
            if telemetry.accountingSchemaVersion == 1,
               telemetry.calibratedKeyframeCandidateCount != decisions {
                findings.append(finding("CAPTURE_TELEMETRY_COUNTS_INCONSISTENT", .captureTimeline, .warning, "Candidate count does not equal accepted plus rejected decisions under telemetry accounting v1.", "Capture admission accounting is inconsistent.", "This is a structural accounting failure, not a sensor-quality conclusion.", "Inspect the essential-event producer and collector ordering."))
            }
            if telemetry.accountingSchemaVersion == nil {
                findings.append(finding("CAPTURE_TELEMETRY_LEGACY_UNAVAILABLE", .captureTimeline, .info, "Lifecycle accounting schema is absent.", "Tracking, interruption, and finalization accounting is unavailable for this legacy manifest.", "Zero is not inferred.", "Capture a package with telemetry accounting v1."))
            } else if telemetry.finalizationCount != 1 {
                findings.append(finding("CAPTURE_FINALIZATION_INCONSISTENT", .captureTimeline, .warning, "Finalization count is not exactly one.", "The finalized package lifecycle cannot be reconciled.", "This does not determine whether sensor evidence was accurate.", "Inspect terminal event draining and package finalization."))
            }
            if manifest.captureStatistics.sampledFrameCount < decisions {
                findings.append(finding("CAPTURE_UNACCOUNTED_SAMPLED_FRAMES", .captureTimeline, .warning, "Decision count exceeds sampled-frame count.", "Counters are not comparable as one accounting equation.", "The capture implementation owns their distinct populations.", "Document the producer population for each counter."))
            }
        } else {
            findings.append(finding("CAPTURE_TELEMETRY_UNAVAILABLE", .captureTimeline, .info, "No capture telemetry is retained.", "Capture decision sufficiency is unavailable.", "Absence is not evidence of healthy capture.", "Capture a package with telemetry enabled."))
        }
        let sourceComposition = archiveMetrics.metrics.values["sourceComposition"]
        if sourceComposition == CaptureEvidenceSource.arkitWorldTracking.rawValue,
           Self.isUnavailableProvenance(manifest.sourceDevice) {
            findings.append(finding("M11_DEVICE_BUILD_PROVENANCE_UNAVAILABLE", .captureTimeline, .info, "Device, OS, or app/build provenance is unavailable.", "The capture producer cannot be fully attributed.", "Legacy absence is not treated as a zero or as corruption.", "Capture with runtime source provenance enabled."))
        }
        if let rate = archiveMetrics.trajectory.ratios["effectiveAcceptedFrameRateHz"], rate < Self.diagnosticMinimumAcceptedRateHz {
            findings.append(finding("CAPTURE_KEYFRAME_RATE_LOW", .captureTimeline, .warning, "Accepted-keyframe rate is \(rate) Hz, below the R0.1 diagnostic threshold of \(Self.diagnosticMinimumAcceptedRateHz) Hz.", "Capture evidence is insufficient for a reliable reconstruction diagnosis.", "The threshold is diagnostic, not survey-grade.", "Repeat the same path with sustained overlapping evidence."))
        }
        if let gap = Double(archiveMetrics.trajectory.values["longestTimestampGapSeconds"] ?? ""), gap > Self.diagnosticMaximumKeyframeGapSeconds {
            findings.append(finding("CAPTURE_LONG_OBSERVATION_GAP", .captureTimeline, .warning, "Longest accepted-keyframe gap is \(gap) seconds.", "Observation continuity is insufficient.", "The metric covers retained keyframes only.", "Measure whether the gap is capture admission, persistence, or telemetry loss."))
        }
        if (archiveMetrics.metrics.counts["recordCount"] ?? 0) < Self.diagnosticMinimumAcceptedKeyframes {
            findings.append(finding("CAPTURE_TRAJECTORY_EVIDENCE_SPARSE", .trajectory, .warning, "Only \(archiveMetrics.metrics.counts["recordCount"] ?? 0) retained calibrated keyframes are available.", "Trajectory and viewpoint diversity are insufficient for R0.1 reconstruction diagnosis.", "Retained poses are readable but not quality-qualified.", "Capture at least \(Self.diagnosticMinimumAcceptedKeyframes) overlapping keyframes for the benchmark path."))
            findings.append(finding("COVERAGE_EVIDENCE_INSUFFICIENT", .coverage, .warning, "Diagnostic cells are based on fewer than \(Self.diagnosticMinimumAcceptedKeyframes) retained keyframes.", "Coverage is insufficient even if repeated cells exist.", "Cell occupancy is diagnostic only.", "Collect diverse viewpoints across the target surface."))
        }

        var stages = ScanInspectionStage.allCases.map { ScanInspectionStageReport(stage: $0, disposition: .unavailable) }
        set(.packageIntegrity, to: disposition, metrics: integrity, in: &stages)
        let isARKitCapture = sourceComposition == CaptureEvidenceSource.arkitWorldTracking.rawValue
        let sourceRequirementsSatisfied = sourceComposition == CaptureEvidenceSource.publicRGBDDataset.rawValue
            || (isARKitCapture
                && rawMesh.metrics.values["timelineRelationship"] == "available"
                && !Self.isUnavailableProvenance(manifest.sourceDevice))
        let structuralQualified = archiveMetrics.metrics.values["m11StructuralQualification"] == "satisfied"
            && sourceRequirementsSatisfied
        let accountingQualified = manifest.captureTelemetry?.accountingSchemaVersion == 1
            && manifest.captureTelemetry?.calibratedKeyframeCandidateCount
                == (manifest.captureTelemetry?.acceptedCalibratedKeyframeCount ?? -1)
                + (manifest.captureTelemetry?.calibratedKeyframeRejectionCounts.values.reduce(0, +) ?? -1)
            && manifest.captureTelemetry?.acceptedCalibratedKeyframeCount
                == archiveMetrics.metrics.counts["recordCount"]
            && manifest.captureTelemetry?.finalizationCount == 1
        let admissionQualified = isARKitCapture
            && structuralQualified
            && accountingQualified
            && (archiveMetrics.metrics.counts["recordCount"] ?? 0) >= Self.diagnosticMinimumAcceptedKeyframes
            && (archiveMetrics.trajectory.ratios["effectiveAcceptedFrameRateHz"] ?? 0) >= Self.diagnosticMinimumAcceptedRateHz
            && (Double(archiveMetrics.trajectory.values["longestTimestampGapSeconds"] ?? "") ?? .infinity) <= Self.diagnosticMaximumKeyframeGapSeconds
            && (archiveMetrics.metrics.ratios["validDepthRatio"] ?? 0) >= Self.diagnosticMinimumValidDepthRatio
            && (archiveMetrics.metrics.ratios["mediumOrHigherConfidenceRatio"] ?? 0) >= Self.diagnosticMinimumMediumConfidenceRatio
            && (archiveMetrics.metrics.ratios["rangeRejectionRatio"] ?? 1) <= Self.diagnosticMaximumRangeRejectionRatio
            && archiveMetrics.trajectory.counts["implausibleJumpCount"] == 0
            && (archiveMetrics.coverage.counts["occupiedDiagnosticCells"] ?? 0) >= 20
            && (archiveMetrics.coverage.counts["repeatedObservationCells"] ?? 0) >= 1
            && archiveMetrics.coverage.counts["connectedRegionCount"] == 1
            && archiveMetrics.coverage.counts["droppedCoverageCellSamples"] == 0
        var timelineWithQualification = timeline
        timelineWithQualification.values["m11StructuralQualification"] = structuralQualified ? "satisfied" : "notSatisfied"
        timelineWithQualification.values["qualificationMeaning"] = "structural capture-evidence contract only"
        timelineWithQualification.values["m1AdmissionQualification"] = isARKitCapture
            ? (admissionQualified ? "eligibleForReconstructionEvaluation" : "insufficientEvidence")
            : "notApplicableExternalSource"
        set(.captureTimeline, to: admissionQualified ? .healthy : .insufficientEvidence, metrics: timelineWithQualification, in: &stages)
        set(.rgbdArchive, to: archiveMetrics.disposition, metrics: archiveMetrics.metrics, in: &stages)
        set(.trajectory, to: findings.contains(where: { $0.stage == .trajectory }) ? .insufficientEvidence : archiveMetrics.trajectoryDisposition, metrics: archiveMetrics.trajectory, in: &stages)
        set(.coverage, to: findings.contains(where: { $0.stage == .coverage }) ? .insufficientEvidence : archiveMetrics.coverageDisposition, metrics: archiveMetrics.coverage, in: &stages)
        var canonicalMetrics = canonical.metrics
        for (key, value) in rawMesh.metrics.counts { canonicalMetrics.counts["rawMesh_\(key)"] = value }
        for (key, value) in rawMesh.metrics.values { canonicalMetrics.values["rawMesh_\(key)"] = value }
        set(.canonicalGeometry, to: canonical.disposition == .failed || rawMesh.disposition == .failed ? .failed : canonical.disposition, metrics: canonicalMetrics, in: &stages)
        set(.reconstruction, to: derived.reconstruction.disposition, metrics: derived.reconstruction.metrics, in: &stages)
        set(.surfaceExtraction, to: derived.surface.disposition, metrics: derived.surface.metrics, in: &stages)
        set(.crossStageConsistency, to: derived.consistency.disposition, metrics: derived.consistency.metrics, in: &stages)
        set(.viewer, to: derived.viewer.disposition, metrics: derived.viewer.metrics, in: &stages)
        set(.export, to: derived.export.disposition, metrics: derived.export.metrics, in: &stages)

        let stageOrder = Dictionary(uniqueKeysWithValues: ScanInspectionStage.allCases.enumerated().map { ($0.element, $0.offset) })
        let orderedFindings = findings.sorted {
            (stageOrder[$0.stage] ?? .max, $0.code) < (stageOrder[$1.stage] ?? .max, $1.code)
        }
        let failure = stages.first(where: { $0.disposition == .failed })?.stage
        let suspicious = stages.first(where: { $0.disposition == .suspicious })?.stage
        let insufficient = stages.first(where: { $0.disposition == .insufficientEvidence })?.stage
        let limitations = [
            "Trajectory and coverage metrics are bounded retained-keyframe diagnostics; they do not establish scene completeness or accuracy.",
            "Absence of capture telemetry is reported as unavailable and is not treated as healthy.",
            "M1.1 structural qualification does not establish sensor, pose, reconstruction, coverage, device, or competitive quality.",
            "Derived processing state is only inspected when an explicit derived-processing root is supplied.",
            "Viewer and export eligibility report source validity and fallback behavior; they do not establish survey accuracy or competitive visual quality."
        ]
        return ScanInspectionReport(evidence: .init(
            sourcePackageID: manifest.localScanID,
            manifestSchemaVersion: manifest.schemaVersion,
            manifestStatus: manifest.status.rawValue,
            stages: stages,
            findings: orderedFindings,
            earliestProvenFailureStage: failure,
            earliestSuspiciousStage: suspicious,
            earliestInsufficientEvidenceStage: insufficient,
            evidenceLimitations: limitations
        ))
    }

    private func inspectArchive(packageURL: URL, manifest: ScanPackageManifest, integrity: PackageIntegrityReport, findings: inout [ScanInspectionFinding]) throws -> (metrics: ScanInspectionMetrics, disposition: ScanInspectionDisposition, hasArchive: Bool, trajectory: ScanInspectionMetrics, trajectoryDisposition: ScanInspectionDisposition, coverage: ScanInspectionMetrics, coverageDisposition: ScanInspectionDisposition, source: TSDFReconstructionSource?) {
        let expected = manifest.assets.contains { $0.relativePath == CalibratedRGBDKeyframeArchiveWriter.indexRelativePath }
        guard expected else {
            findings.append(finding("RGBD_ARCHIVE_UNAVAILABLE", .rgbdArchive, .info, "No calibrated RGB-D archive index is declared.", "RGB-D replay cannot be evaluated.", "This may be a legacy or semantic-only package.", "Capture a retained calibrated RGB-D archive."))
            return (.init(), .unavailable, false, .init(values: ["poseEvidence": "unavailable"]), .unavailable, .init(values: ["depthEvidence": "unavailable"]), .unavailable, nil)
        }
        do {
            let archive = try CalibratedRGBDKeyframeArchiveReader().open(packageURL: packageURL, manifest: manifest, integrity: integrity)
            let indexes = archive.records.map(\.index)
            if Set(indexes).count != indexes.count {
                findings.append(finding("RGBD_DUPLICATE_RECORD", .rgbdArchive, .error, "Archive contains duplicate record indexes.", "RGB-D ordering is invalid.", "Payload identity cannot be established.", "Regenerate the archive."))
                return (.init(counts: ["recordCount": indexes.count]), .failed, true, .init(), .failed, .init(), .failed, nil)
            }
            let depthBinCount = Int(ceil((Self.diagnosticDepthMaximumMeters - Self.diagnosticDepthMinimumMeters) / Self.diagnosticDepthHistogramBinMeters)) + 1
            var depthHistogram = [Int](repeating: 0, count: depthBinCount)
            let translationBinCount = Int(ceil(Self.diagnosticTranslationHistogramMaximumMeters / Self.diagnosticTranslationHistogramBinMeters)) + 1
            var translationHistogram = [Int](repeating: 0, count: translationBinCount)
            let rotationBinCount = Int(ceil(Self.diagnosticRotationHistogramMaximumDegrees / Self.diagnosticRotationHistogramBinDegrees)) + 1
            var rotationHistogram = [Int](repeating: 0, count: rotationBinCount)
            var confidence = [Int](repeating: 0, count: 4)
            var valid = 0, invalid = 0, medium = 0, rangeRejected = 0
            var minimumDepth: Float?
            var maximumDepth: Float?
            var firstPosition: Point3D?
            var previousPosition: Point3D?
            var previousTransform: Transform4x4?
            var lastPosition: Point3D?
            var firstTimestamp: Double?
            var previousTimestamp: Double?
            var lastTimestamp: Double?
            var pathLength = 0.0
            var translationCount = 0
            var stationaryPoseCount = 0
            var currentStationarySequence = 0
            var longestStationarySequence = 0
            var implausibleJumpCount = 0
            var timestampGapCount = 0
            var longestTimestampGap = 0.0
            var occupied = [DiagnosticCoverageCell: Int]()
            var lastObservedFrame = [DiagnosticCoverageCell: Int]()
            var firstObservationCamera = [DiagnosticCoverageCell: Point3D]()
            var firstObservationPoint = [DiagnosticCoverageCell: Point3D]()
            var diverseViewCells = Set<DiagnosticCoverageCell>()
            var observationGapReturnCells = Set<DiagnosticCoverageCell>()
            var cameraCells = [DiagnosticCoverageCell: Int]()
            var revisitOpportunityCount = 0
            var droppedCoverageCells = 0
            var completeContractRecordCount = 0
            var legacyUnavailableRecordCount = 0
            var contractIssueCounts: [CaptureEvidenceContractIssue: Int] = [:]
            var depthSourceCounts: [CaptureDepthSource: Int] = [:]
            var captureSourceCounts: [CaptureEvidenceSource: Int] = [:]
            var exposureMeasuredCount = 0
            var exposureUnavailableCount = 0
            var nonMonotonicTimestampCount = 0
            for index in archive.records.indices {
                try Task.checkCancellation()
                let record = archive.records[index]
                if record.schemaVersion == 1 {
                    legacyUnavailableRecordCount += 1
                } else if let contract = record.evidenceContract {
                    captureSourceCounts[contract.source, default: 0] += 1
                    depthSourceCounts[contract.depthSource, default: 0] += 1
                    if contract.exposure.availability == .measured {
                        exposureMeasuredCount += 1
                    } else {
                        exposureUnavailableCount += 1
                    }
                    if let issue = contract.validationIssue(
                        metadata: record.metadata,
                        depthWidth: record.depthWidth,
                        depthHeight: record.depthHeight
                    ) {
                        contractIssueCounts[issue, default: 0] += 1
                        continue
                    }
                    completeContractRecordCount += 1
                }
                let keyframe = try archive.readKeyframe(at: index)
                let c = record.metadata.worldFromCamera.columns
                guard c.count == 16, c.allSatisfy(\.isFinite) else { throw ScanPackageInspectorError.ioFailure("non-finite pose") }
                let cameraPosition = Point3D(x: c[12], y: c[13], z: c[14])
                let timestamp = record.metadata.timestamp
                guard timestamp.isFinite else { throw ScanPackageInspectorError.ioFailure("non-finite timestamp") }
                if firstPosition == nil { firstPosition = cameraPosition }
                if firstTimestamp == nil { firstTimestamp = timestamp }
                if let previousPosition {
                    let delta = distance(previousPosition, cameraPosition)
                    pathLength += delta
                    translationCount += 1
                    if delta < 0.01 {
                        stationaryPoseCount += 1
                        currentStationarySequence += 1
                        longestStationarySequence = max(longestStationarySequence, currentStationarySequence)
                    } else {
                        currentStationarySequence = 0
                    }
                    if delta > 2 { implausibleJumpCount += 1 }
                    add(delta, to: &translationHistogram, binWidth: Self.diagnosticTranslationHistogramBinMeters)
                }
                if let previousTransform {
                    add(rotationDeltaDegrees(previousTransform, record.metadata.worldFromCamera), to: &rotationHistogram, binWidth: Self.diagnosticRotationHistogramBinDegrees)
                }
                if let previousTimestamp {
                    let gap = timestamp - previousTimestamp
                    if gap < 0 {
                        nonMonotonicTimestampCount += 1
                    }
                    timestampGapCount += 1
                    longestTimestampGap = max(longestTimestampGap, max(0, gap))
                }
                previousPosition = cameraPosition
                previousTransform = record.metadata.worldFromCamera
                lastPosition = cameraPosition
                previousTimestamp = timestamp
                lastTimestamp = timestamp
                let cameraCell = DiagnosticCoverageCell(point: cameraPosition, sizeMeters: 0.5)
                if let previousOrdinal = cameraCells[cameraCell], index - previousOrdinal >= 5 {
                    revisitOpportunityCount += 1
                }
                cameraCells[cameraCell] = index
                let intrinsics = keyframe.depth.calibration.scaled(toWidth: keyframe.depth.width, height: keyframe.depth.height)
                guard intrinsics.fx.isFinite,
                      intrinsics.fy.isFinite,
                      intrinsics.cx.isFinite,
                      intrinsics.cy.isFinite,
                      intrinsics.fx > 0,
                      intrinsics.fy > 0
                else {
                    throw ScanPackageInspectorError.ioFailure("invalid depth intrinsics")
                }
                for sample in keyframe.depth.depthMeters.enumerated() {
                    if sample.offset % 8_192 == 0 { try Task.checkCancellation() }
                    let level = min(3, Int(keyframe.depth.confidence[sample.offset]))
                    confidence[level] += 1
                    guard sample.element.isFinite, sample.element > 0 else { invalid += 1; continue }
                    if sample.element < Self.diagnosticDepthMinimumMeters || sample.element > Self.diagnosticDepthMaximumMeters { rangeRejected += 1; continue }
                    valid += 1
                    minimumDepth = min(minimumDepth ?? sample.element, sample.element)
                    maximumDepth = max(maximumDepth ?? sample.element, sample.element)
                    add(sample.element, to: &depthHistogram, minimum: Self.diagnosticDepthMinimumMeters, binWidth: Self.diagnosticDepthHistogramBinMeters)
                    if level >= 1 { medium += 1 }
                    if sample.offset % Self.diagnosticCoverageStride == 0 {
                        let x = sample.offset % keyframe.depth.width
                        let y = sample.offset / keyframe.depth.width
                        let cameraPoint = Point3D(
                            x: -((Float(x) - intrinsics.cx) / intrinsics.fx) * sample.element,
                            y: -((Float(y) - intrinsics.cy) / intrinsics.fy) * sample.element,
                            z: -sample.element
                        )
                        let worldPoint = record.metadata.worldFromCamera.applying(to: cameraPoint)
                        guard Self.isBoundedDiagnosticPoint(worldPoint) else {
                            droppedCoverageCells += 1
                            continue
                        }
                        let cell = DiagnosticCoverageCell(point: worldPoint, sizeMeters: 0.25)
                        if occupied[cell] != nil || occupied.count < Self.maximumDiagnosticCoverageCells {
                            // Pixels in one frame are not independent revisits.
                            if lastObservedFrame[cell] != index {
                                if let lastFrame = lastObservedFrame[cell], index - lastFrame > 1 {
                                    observationGapReturnCells.insert(cell)
                                }
                                if let firstCamera = firstObservationCamera[cell],
                                   let firstPoint = firstObservationPoint[cell],
                                   distance(firstCamera, cameraPosition) >= 0.1 {
                                    let a = Point3D(x: firstCamera.x - firstPoint.x,
                                        y: firstCamera.y - firstPoint.y, z: firstCamera.z - firstPoint.z)
                                    let b = Point3D(x: cameraPosition.x - firstPoint.x,
                                        y: cameraPosition.y - firstPoint.y, z: cameraPosition.z - firstPoint.z)
                                    let denominator = distance(firstCamera, firstPoint) * distance(cameraPosition, firstPoint)
                                    let dotProduct = Double(a.x) * Double(b.x)
                                        + Double(a.y) * Double(b.y) + Double(a.z) * Double(b.z)
                                    if denominator > 0, dotProduct / denominator < 0.9659258 {
                                        diverseViewCells.insert(cell)
                                    }
                                } else if firstObservationCamera[cell] == nil {
                                    firstObservationCamera[cell] = cameraPosition
                                    firstObservationPoint[cell] = worldPoint
                                }
                                occupied[cell, default: 0] += 1
                                lastObservedFrame[cell] = index
                            }
                        } else {
                            droppedCoverageCells += 1
                        }
                    }
                }
            }
            let total = max(1, valid + invalid + rangeRejected)
            let finitePositive = max(1, valid + rangeRejected)
            let validDepthRatio = Double(valid) / Double(total)
            let mediumConfidenceRatio = valid == 0 ? 0 : Double(medium) / Double(valid)
            let rangeRejectionRatio = Double(rangeRejected) / Double(finitePositive)
            let issueCount = contractIssueCounts.values.reduce(0, +)
            let structuralContractSatisfied = !indexes.isEmpty
                && completeContractRecordCount == indexes.count
                && legacyUnavailableRecordCount == 0
                && issueCount == 0
                && nonMonotonicTimestampCount == 0
            var archiveCounts = ["recordCount": indexes.count, "validDepthSamples": valid, "invalidDepthSamples": invalid, "rangeRejectedSamples": rangeRejected, "confidence0": confidence[0], "confidence1": confidence[1], "confidence2": confidence[2], "confidence3": confidence[3], "completeSynchronizedEvidenceRecords": completeContractRecordCount, "legacyUnavailableEvidenceRecords": legacyUnavailableRecordCount, "invalidEvidenceContractRecords": issueCount, "measuredExposureRecords": exposureMeasuredCount, "unavailableExposureRecords": exposureUnavailableCount, "nonMonotonicTimestampCount": nonMonotonicTimestampCount]
            for source in CaptureDepthSource.allCases {
                archiveCounts["depthSource_\(source.rawValue)"] = depthSourceCounts[source, default: 0]
            }
            let sourceComposition = captureSourceCounts.count == 1
                ? captureSourceCounts.keys.first?.rawValue ?? "unavailable"
                : (captureSourceCounts.isEmpty ? "unavailable" : "mixed")
            let archiveMetric = ScanInspectionMetrics(
                counts: archiveCounts,
                ratios: ["validDepthRatio": validDepthRatio, "mediumOrHigherConfidenceRatio": mediumConfidenceRatio, "rangeRejectionRatio": rangeRejectionRatio],
                values: [
                    "depthMinimumMeters": "\(minimumDepth ?? 0)",
                    "depthMedianMeters": "\(histogramPercentile(depthHistogram, fraction: 0.5, minimum: Double(Self.diagnosticDepthMinimumMeters), binWidth: Double(Self.diagnosticDepthHistogramBinMeters)))",
                    "depthP95Meters": "\(histogramPercentile(depthHistogram, fraction: 0.95, minimum: Double(Self.diagnosticDepthMinimumMeters), binWidth: Double(Self.diagnosticDepthHistogramBinMeters)))",
                    "depthMaximumMeters": "\(maximumDepth ?? 0)",
                    "quantileResolutionMeters": "\(Self.diagnosticDepthHistogramBinMeters)",
                    "recordSchemaVersion": legacyUnavailableRecordCount > 0 ? "mixedOrLegacy" : "\(CalibratedRGBDKeyframeRecord.currentSchemaVersion)",
                    "captureEvidenceContractVersion": structuralContractSatisfied ? "\(CaptureEvidenceContract.currentSchemaVersion)" : "unavailableOrInvalid",
                    "inertialPolicy": structuralContractSatisfied ? CaptureInertialEvidencePolicy.arkitVIOOnly.rawValue : "legacyUnavailable",
                    "m11StructuralQualification": structuralContractSatisfied ? "satisfied" : "notSatisfied",
                    "sourceComposition": sourceComposition,
                    "firstCaptureTimestamp": "\(firstTimestamp ?? 0)",
                    "lastCaptureTimestamp": "\(lastTimestamp ?? 0)"
                ]
            )
            let netDisplacement = if let firstPosition, let lastPosition { distance(firstPosition, lastPosition) } else { 0.0 }
            let duration = if let firstTimestamp, let lastTimestamp { max(0.0, lastTimestamp - firstTimestamp) } else { 0.0 }
            let trajectory = ScanInspectionMetrics(
                counts: ["poseCount": indexes.count, "duplicateOrStationaryPoseCount": stationaryPoseCount, "longestStationarySequence": longestStationarySequence, "implausibleJumpCount": implausibleJumpCount, "revisitOpportunityCount": revisitOpportunityCount],
                ratios: [
                    "pathLengthMeters": pathLength,
                    "netDisplacementMeters": netDisplacement,
                    "medianFrameTranslationMeters": histogramPercentile(translationHistogram, fraction: 0.5, minimum: 0, binWidth: Self.diagnosticTranslationHistogramBinMeters),
                    "p95FrameTranslationMeters": histogramPercentile(translationHistogram, fraction: 0.95, minimum: 0, binWidth: Self.diagnosticTranslationHistogramBinMeters),
                    "medianFrameRotationDegrees": histogramPercentile(rotationHistogram, fraction: 0.5, minimum: 0, binWidth: Self.diagnosticRotationHistogramBinDegrees),
                    "p95FrameRotationDegrees": histogramPercentile(rotationHistogram, fraction: 0.95, minimum: 0, binWidth: Self.diagnosticRotationHistogramBinDegrees),
                    "effectiveAcceptedFrameRateHz": timestampGapCount == 0 ? 0 : Double(timestampGapCount) / max(0.001, duration)
                ],
                values: [
                    "longestTimestampGapSeconds": "\(longestTimestampGap)",
                    "firstPositionMeters": Self.pointDescription(firstPosition),
                    "finalPositionMeters": Self.pointDescription(lastPosition),
                    "translationQuantileResolutionMeters": "\(Self.diagnosticTranslationHistogramBinMeters)",
                    "rotationQuantileResolutionDegrees": "\(Self.diagnosticRotationHistogramBinDegrees)"
                ]
            )
            let repeated = occupied.values.filter { $0 > 1 }.count
            let connectedRegionCount = connectedRegionCount(in: Set(occupied.keys))
            let coverageBounds = diagnosticBounds(for: occupied.keys, cellSizeMeters: 0.25)
            let coverage = ScanInspectionMetrics(
                counts: ["occupiedDiagnosticCells": occupied.count, "singleObservationCells": occupied.values.filter { $0 == 1 }.count, "repeatedObservationCells": repeated, "viewDiverseCells": diverseViewCells.count, "observationGapReturnCells": observationGapReturnCells.count, "connectedRegionCount": connectedRegionCount, "droppedCoverageCellSamples": droppedCoverageCells],
                ratios: ["repeatedCellRatio": occupied.isEmpty ? 0 : Double(repeated) / Double(occupied.count)],
                values: ["classification": archive.records.count >= Self.diagnosticMinimumAcceptedKeyframes && occupied.count >= 20 && repeated > 0 ? "diagnostic evidence present; unqualified" : "insufficient diagnostic evidence; not an accuracy claim", "observationUnit": "distinct retained frame", "viewDiversityRule": "at least 0.1 m baseline and over 15 degrees relative to first cell observation", "revisitQualification": "unavailable; an observation gap does not prove physical departure or reacquisition", "cellSizeMeters": "0.25", "depthSampleStride": "\(Self.diagnosticCoverageStride)", "minimum": coverageBounds.minimum, "maximum": coverageBounds.maximum]
            )
            if valid == 0 { findings.append(finding("RGBD_VALID_DEPTH_EMPTY", .rgbdArchive, .error, "No finite in-range depth sample survived bounded replay.", "The retained RGB-D evidence cannot support reconstruction.", "This does not identify whether sensing or persistence produced the invalid samples.", "Inspect the first retained frame and capture telemetry.")) }
            else if validDepthRatio < Self.diagnosticMinimumValidDepthRatio { findings.append(finding("RGBD_VALID_DEPTH_LOW", .rgbdArchive, .warning, "Valid in-range depth ratio is \(validDepthRatio).", "Depth evidence is suspicious under the R0.1 diagnostic threshold.", "The threshold is diagnostic, not a survey-accuracy gate.", "Compare depth validity by frame and scene range.")) }
            if valid > 0, mediumConfidenceRatio < Self.diagnosticMinimumMediumConfidenceRatio { findings.append(finding("RGBD_CONFIDENCE_LOW", .rgbdArchive, .warning, "Medium-or-higher confidence ratio is \(mediumConfidenceRatio).", "Retained depth confidence is suspicious.", "Confidence alone does not prove geometric error.", "Compare confidence with the same-path benchmark capture.")) }
            if rangeRejectionRatio > Self.diagnosticMaximumRangeRejectionRatio { findings.append(finding("RGBD_RANGE_REJECTION_HIGH", .rgbdArchive, .warning, "Out-of-range depth ratio is \(rangeRejectionRatio).", "A material share of retained depth is outside the bounded diagnostic range.", "The range is an R0.1 diagnostic bound, not a device capability claim.", "Measure the target distance distribution during capture.")) }
            if implausibleJumpCount > 0 { findings.append(finding("TRAJECTORY_IMPLAUSIBLE_JUMP", .trajectory, .warning, "At least one consecutive retained pose changes by more than 2 m.", "Pose continuity is suspicious.", "ARKit tracking state alone cannot identify the cause.", "Review the matching retained frames and tracking telemetry.")) }
            if occupied.count < 20 { findings.append(finding("COVERAGE_SPARSE", .coverage, .warning, "Fewer than 20 occupied 25 cm diagnostic cells were observed.", "Evidence is sparse for continuous-surface reconstruction.", "This is not a completeness or accuracy score.", "Capture additional overlapping viewpoints.")) }
            if connectedRegionCount > 1 { findings.append(finding("COVERAGE_DISCONNECTED", .coverage, .warning, "Diagnostic coverage contains \(connectedRegionCount) disconnected cell regions.", "Retained observations do not form one continuous sampled region.", "Stride and cell size can separate thin surfaces.", "Inspect disconnected regions against retained images and canonical geometry.")) }
            if droppedCoverageCells > 0 { findings.append(finding("COVERAGE_DIAGNOSTIC_BOUND_REACHED", .coverage, .warning, "The bounded diagnostic cell table reached its configured limit.", "Coverage diagnostics are truncated but package replay remains valid.", "No completeness inference can be made beyond the retained cells.", "Use the canonical stream or an offline benchmark for exhaustive coverage.")) }
            if legacyUnavailableRecordCount > 0 { findings.append(finding("M11_CAPTURE_EVIDENCE_LEGACY_UNAVAILABLE", .rgbdArchive, .info, "\(legacyUnavailableRecordCount) schema-v1 records predate the authoritative evidence contract.", "Their payloads remain replayable, but M1.1 synchronization and provenance evidence is unavailable.", "Missing fields are not fabricated and the package is not corrupt for this reason.", "Use a newly captured schema-v2 package for structural M1.1 qualification.")) }
            if nonMonotonicTimestampCount > 0 { findings.append(finding("M11_TIMESTAMP_NON_MONOTONIC", .rgbdArchive, .error, "Accepted record timestamps are not monotonic.", "The capture timeline is structurally inconsistent.", "No timestamp repair was attempted.", "Inspect producer ordering before reconstruction.")) }
            for issue in CaptureEvidenceContractIssue.allCases where contractIssueCounts[issue, default: 0] > 0 {
                findings.append(finding("M11_CONTRACT_\(issue.rawValue.uppercased())", .rgbdArchive, .error, "\(contractIssueCounts[issue, default: 0]) records have inconsistent \(issue.rawValue) evidence.", "The authoritative capture record is structurally invalid.", "The inspector does not infer or repair missing evidence.", "Correct the capture producer and reacquire the observation."))
            }
            let archiveSuspicious = valid == 0 || validDepthRatio < Self.diagnosticMinimumValidDepthRatio || mediumConfidenceRatio < Self.diagnosticMinimumMediumConfidenceRatio || rangeRejectionRatio > Self.diagnosticMaximumRangeRejectionRatio
            let archiveDisposition: ScanInspectionDisposition = issueCount > 0 || nonMonotonicTimestampCount > 0
                ? .failed
                : (indexes.isEmpty || archiveSuspicious || legacyUnavailableRecordCount > 0 ? .suspicious : .healthy)
            return (archiveMetric, archiveDisposition, true, trajectory, implausibleJumpCount > 0 ? .suspicious : .healthy, coverage, occupied.count < 20 || connectedRegionCount > 1 || droppedCoverageCells > 0 ? .suspicious : .healthy, archive.reconstructionSource)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            findings.append(finding("RGBD_ARCHIVE_INVALID", .rgbdArchive, .error, "The existing calibrated RGB-D archive reader rejected the archive.", "RGB-D replay is not valid.", "The inspector does not repair archive records or payloads.", "Inspect the first rejected archive record and package integrity."))
            return (.init(), .failed, true, .init(), .failed, .init(), .failed, nil)
        }
    }

    private func timelineMetrics(manifest: ScanPackageManifest) -> ScanInspectionMetrics {
        var counts = ["sampledFrameCount": manifest.captureStatistics.sampledFrameCount]
        if let telemetry = manifest.captureTelemetry {
            counts["keyframeCandidates"] = telemetry.calibratedKeyframeCandidateCount
            counts["keyframeAccepted"] = telemetry.acceptedCalibratedKeyframeCount
            counts["keyframeRejected"] = telemetry.calibratedKeyframeRejectionCounts.values.reduce(0, +)
            counts["optionalImageDropped"] = telemetry.droppedOptionalImageCount
            if let began = telemetry.interruptionBeganCount { counts["interruptionBegan"] = began }
            if let ended = telemetry.interruptionEndedCount { counts["interruptionEnded"] = ended }
            if let finalized = telemetry.finalizationCount { counts["finalizationCount"] = finalized }
            if let tracking = telemetry.trackingStateCounts {
                for state in FrameTrackingState.allCases {
                    counts["tracking_\(state.rawValue)"] = tracking[state.rawValue, default: 0]
                }
            }
        }
        var values: [String: String] = [:]
        if manifest.captureTelemetry == nil { values["telemetry"] = "unavailable" }
        values["deviceBuildProvenance"] = Self.isUnavailableProvenance(manifest.sourceDevice) ? "unavailable" : "available"
        return .init(counts: counts, values: values)
    }

    private func inspectCanonical(packageURL: URL, manifest: ScanPackageManifest, integrity: PackageIntegrityReport, findings: inout [ScanInspectionFinding]) throws -> (metrics: ScanInspectionMetrics, disposition: ScanInspectionDisposition) {
        let declared = manifest.assets.filter { $0.relativePath == CanonicalSpatialChunkStore.relativePath }
        guard !declared.isEmpty else {
            findings.append(finding("CANONICAL_STREAM_MISSING", .canonicalGeometry, .warning, "No canonical spatial stream is declared.", "No complete accepted spatial source is available.", "A preview PLY is not a substitute for canonical data.", "Inspect capture finalization."))
            return (.init(counts: ["declaredCanonicalStreams": 0]), .unavailable)
        }
        guard declared.count == 1 else {
            findings.append(finding("CANONICAL_STREAM_CORRUPT", .canonicalGeometry, .error, "More than one canonical stream is declared.", "Canonical source identity is ambiguous.", "No stream was selected.", "Regenerate the finalized package."))
            return (.init(counts: ["declaredCanonicalStreams": declared.count]), .failed)
        }
        do {
            let reader = CanonicalSpatialChunkReader()
            let descriptor = try reader.open(packageURL: packageURL, manifest: manifest, integrity: integrity)
            var occupied = Set<String>()
            var diagnosticPoints = Set<DiagnosticCoverageCell>()
            var colored = 0
            var duplicateDiagnosticPoints = 0
            var droppedOccupiedCells = 0
            try reader.forEachBatch(in: descriptor) { samples in
                for sample in samples {
                    try Task.checkCancellation()
                    if sample.color != nil { colored += 1 }
                    guard Self.isBoundedDiagnosticPoint(sample.position) else {
                        droppedOccupiedCells += 1
                        continue
                    }
                    let cell = "\(Int(floor(sample.position.x / descriptor.chunkSizeMeters))),\(Int(floor(sample.position.y / descriptor.chunkSizeMeters))),\(Int(floor(sample.position.z / descriptor.chunkSizeMeters)))"
                    if occupied.contains(cell) || occupied.count < Self.maximumCanonicalDiagnosticCells {
                        occupied.insert(cell)
                    } else {
                        droppedOccupiedCells += 1
                    }
                    let diagnosticPoint = DiagnosticCoverageCell(point: sample.position, sizeMeters: 0.001)
                    if diagnosticPoints.count < Self.maximumCanonicalDiagnosticCells || diagnosticPoints.contains(diagnosticPoint) {
                        if !diagnosticPoints.insert(diagnosticPoint).inserted { duplicateDiagnosticPoints += 1 }
                    }
                }
            }
            let preview = manifest.assets.first { $0.relativePath == "pointcloud/cloud.ply" }
            var previewVertexCount = 0
            var previewDisposition: ScanInspectionDisposition = .unqualified
            if let preview {
                do {
                    previewVertexCount = try PointCloudPLYReader().read(
                        from: packageURL.appending(path: preview.relativePath),
                        maximumPointCount: 0
                    ).header.vertexCount
                    if previewVertexCount == 0, descriptor.recordCount > 0 {
                        previewDisposition = .suspicious
                        findings.append(finding("CANONICAL_PREVIEW_EMPTY", .canonicalGeometry, .warning, "Compatibility preview declares zero vertices while canonical data contains \(descriptor.recordCount) records.", "The preview cannot represent the canonical source.", "Canonical replay remains valid.", "Regenerate the bounded preview from the canonical stream."))
                    } else if previewVertexCount > descriptor.recordCount {
                        previewDisposition = .suspicious
                        findings.append(finding("CANONICAL_PREVIEW_COUNT_EXCEEDS_SOURCE", .canonicalGeometry, .warning, "Compatibility preview declares more vertices than the canonical source.", "Preview provenance is inconsistent with the canonical stream.", "Point identity is not compared by this bounded count check.", "Regenerate the preview from the immutable canonical stream."))
                    }
                } catch {
                    previewDisposition = .suspicious
                    findings.append(finding("CANONICAL_PREVIEW_INVALID", .canonicalGeometry, .warning, "The declared compatibility PLY failed its bounded production reader.", "The preview is not usable evidence.", "Canonical replay remains independently valid.", "Regenerate the compatibility preview."))
                }
            }
            let metrics = ScanInspectionMetrics(
                counts: ["declaredCanonicalStreams": 1, "recordCount": descriptor.recordCount, "occupiedChunkCells": occupied.count, "droppedOccupiedCellSamples": droppedOccupiedCells, "coloredRecordCount": colored, "diagnosticDuplicatePointCount": duplicateDiagnosticPoints, "previewAssetPresent": preview == nil ? 0 : 1, "previewVertexCount": previewVertexCount],
                ratios: ["coloredRecordRatio": descriptor.recordCount == 0 ? 0 : Double(colored) / Double(descriptor.recordCount), "diagnosticDuplicatePointRatio": descriptor.recordCount == 0 ? 0 : Double(duplicateDiagnosticPoints) / Double(descriptor.recordCount), "previewToCanonicalCountRatio": descriptor.recordCount == 0 ? 0 : Double(previewVertexCount) / Double(descriptor.recordCount)],
                values: ["streamPath": descriptor.sourceReference.relativePath, "chunkSizeMeters": "\(descriptor.chunkSizeMeters)", "minimum": "\(descriptor.bounds.minimum.x),\(descriptor.bounds.minimum.y),\(descriptor.bounds.minimum.z)", "maximum": "\(descriptor.bounds.maximum.x),\(descriptor.bounds.maximum.y),\(descriptor.bounds.maximum.z)", "previewRole": preview == nil ? "absent" : "compatibility preview; not canonical evidence"]
            )
            if droppedOccupiedCells > 0 {
                findings.append(finding("CANONICAL_DIAGNOSTIC_BOUND_REACHED", .canonicalGeometry, .warning, "Canonical occupied-cell diagnostics reached their configured coordinate or table bound.", "Canonical replay remains valid but diagnostic occupancy is truncated.", "This does not imply that canonical records were dropped from persistence.", "Use the canonical stream in a dedicated offline benchmark for exhaustive occupancy analysis."))
            }
            findings.append(finding("CANONICAL_GEOMETRY_VALID_UNQUALIFIED", .canonicalGeometry, .info, "Canonical stream passed the existing integrity-checked bounded reader.", "Canonical geometry is readable and internally valid.", "This does not qualify capture coverage or reconstructed quality.", "Compare canonical bounds and density with a benchmark reference.", metrics: metrics))
            return (metrics, maxDisposition(.unqualified, previewDisposition))
        } catch is CancellationError {
            throw CancellationError()
        } catch CanonicalSpatialChunkReadError.emptySource {
            findings.append(finding("CANONICAL_STREAM_EMPTY", .canonicalGeometry, .error, "Canonical reader found no records.", "Canonical geometry is unavailable.", "No bounds can be inferred.", "Inspect capture persistence."))
            return (.init(counts: ["declaredCanonicalStreams": 1, "recordCount": 0]), .failed)
        } catch {
            findings.append(finding("CANONICAL_STREAM_CORRUPT", .canonicalGeometry, .error, "Existing canonical reader rejected the declared stream.", "Canonical geometry cannot be trusted.", "The inspector does not repair canonical data.", "Inspect the stream and manifest checksums."))
            return (.init(counts: ["declaredCanonicalStreams": 1]), .failed)
        }
    }

    private func inspectRawMesh(
        packageURL: URL,
        manifest: ScanPackageManifest,
        firstCaptureTimestamp: TimeInterval?,
        lastCaptureTimestamp: TimeInterval?,
        findings: inout [ScanInspectionFinding]
    ) -> (metrics: ScanInspectionMetrics, disposition: ScanInspectionDisposition) {
        let assets = manifest.assets.filter { $0.kind == .meshRaw }
        guard let asset = assets.first, assets.count == 1 else {
            findings.append(finding("RAW_MESH_MISSING", .canonicalGeometry, .info, "No unique raw-mesh asset is declared.", "Raw diagnostic geometry is unavailable.", "This does not invalidate canonical RGB-D geometry.", "Inspect capture asset finalization."))
            return (.init(counts: ["declaredAssets": assets.count], values: ["timelineRelationship": "unavailable"]), .unavailable)
        }
        do {
            let url = packageURL.appending(path: asset.relativePath)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (1...64 * 1_024 * 1_024).contains(values.fileSize ?? 0) else { throw ScanPackageInspectorError.ioFailure("invalid raw mesh") }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let snapshots = try decoder.decode([MeshSnapshot].self, from: Data(contentsOf: url))
            let anchors = snapshots.count
            let vertices = snapshots.reduce(0) { $0 + $1.vertices.count }
            let faces = snapshots.reduce(0) { $0 + $1.faces.count }
            let empty = snapshots.filter { $0.vertices.isEmpty || $0.faces.isEmpty }.count
            let timestamped = snapshots.filter {
                guard let timestamp = $0.captureTimestamp else { return false }
                return timestamp.isFinite
                    && $0.provenance == .finalSessionSnapshot
                    && (firstCaptureTimestamp.map { timestamp >= $0 } ?? true)
            }.count
            let timelineRelationship = !snapshots.isEmpty && timestamped == snapshots.count
                ? "available"
                : "unavailable"
            let timelineMetrics = ScanInspectionMetrics(
                counts: ["anchorCount": anchors, "vertexCount": vertices, "faceCount": faces, "emptyAnchorCount": empty, "timestampedFinalSnapshotCount": timestamped],
                values: [
                    "timelineRelationship": timelineRelationship,
                    "lastAcceptedCaptureTimestamp": lastCaptureTimestamp.map { "\($0)" } ?? "unavailable"
                ]
            )
            if timelineRelationship == "unavailable" {
                findings.append(finding("M11_MESH_TIMELINE_UNAVAILABLE", .canonicalGeometry, .info, "Raw mesh snapshots lack complete final-session timestamp provenance.", "The independently stored mesh cannot be related deterministically to the capture timeline.", "Legacy mesh remains readable diagnostic geometry.", "Capture a schema-v2 final mesh registry."))
            }
            if vertices == 0 || faces == 0 {
                findings.append(finding("RAW_MESH_EMPTY", .canonicalGeometry, .warning, "Raw mesh has \(anchors) anchors but \(vertices) vertices and \(faces) faces.", "Raw mesh is not usable diagnostic geometry.", "It is not a processed reconstruction.", "Inspect final anchor registry capture."))
                return (timelineMetrics, .unqualified)
            }
            findings.append(finding("RAW_MESH_DIAGNOSTIC_ONLY", .canonicalGeometry, .info, "Raw mesh decoded as \(anchors) snapshots.", "Raw ARKit mesh is retained only as diagnostic geometry.", "It is not processed reconstruction evidence.", "Compare its bounds to canonical and promoted data."))
            return (timelineMetrics, .unqualified)
        } catch {
            findings.append(finding("RAW_MESH_NONFINITE_GEOMETRY", .canonicalGeometry, .error, "Raw mesh could not be decoded through MeshSnapshot persistence models.", "Raw diagnostic geometry is invalid.", "Canonical data may still be valid.", "Inspect raw mesh asset and checksum."))
            return (.init(values: ["timelineRelationship": "unavailable"]), .failed)
        }
    }

    private func reportForMissingManifest() -> ScanInspectionReport {
        reportForManifestFailure(code: "PKG_MANIFEST_MISSING", evidence: "Package directory has no manifest.json.")
    }

    private func reportForUnreadableManifest() -> ScanInspectionReport {
        reportForManifestFailure(code: "PKG_MANIFEST_UNREADABLE", evidence: "manifest.json cannot be decoded as a scan package manifest.")
    }

    private func reportForManifestFailure(code: String, evidence: String) -> ScanInspectionReport {
        let finding = finding(code, .packageIntegrity, .blocker, evidence, "Package identity and assets cannot be established.", "No payload was decoded.", "Provide a finalized package with a valid manifest.")
        let stages = ScanInspectionStage.allCases.map { ScanInspectionStageReport(stage: $0, disposition: $0 == .packageIntegrity ? .failed : .unavailable) }
        return ScanInspectionReport(evidence: .init(sourcePackageID: nil, manifestSchemaVersion: nil, manifestStatus: nil, stages: stages, findings: [finding], earliestProvenFailureStage: .packageIntegrity, evidenceLimitations: ["Manifest is unavailable; remaining stages cannot be inspected."]))
    }

    private static func isSafe(relativePath: String) -> Bool {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\\") else { return false }
        return !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private static func isContained(_ url: URL, under root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        return candidate.hasPrefix(base + "/")
    }

    private func resourceValues(for url: URL) throws -> URLResourceValues {
        do { return try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) }
        catch { throw ScanPackageInspectorError.ioFailure(error.localizedDescription) }
    }

    private static func isUnavailableProvenance(_ source: SourceDeviceInfo) -> Bool {
        let required = [
            source.modelIdentifier,
            source.operatingSystemVersion,
            source.appVersion,
            source.operatingSystemBuild ?? "unknown",
            source.appBuildCommit ?? "unknown"
        ]
        guard !required.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.lowercased() == "unknown"
        }) else { return true }
        let commit = source.appBuildCommit ?? ""
        return !source.modelIdentifier.hasPrefix("iPhone")
            || !source.modelIdentifier.contains(",")
            || !(source.operatingSystemBuild?.contains("Build") ?? false)
            || !(7...64).contains(commit.count)
            || !commit.allSatisfy(\.isHexDigit)
    }

    private func regularRelativePaths(under root: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        var result = Set<String>()
        var visitedEntryCount = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            visitedEntryCount += 1
            guard visitedEntryCount <= Self.maximumPackageEntries else {
                throw ScanPackageInspectorError.ioFailure("package entry limit exceeded")
            }
            let values = try resourceValues(for: url)
            if values.isRegularFile == true, values.isSymbolicLink != true, Self.isContained(url, under: root) {
                let relativeComponents = url.standardizedFileURL.pathComponents.dropFirst(root.pathComponents.count)
                result.insert(relativeComponents.joined(separator: "/"))
            }
        }
        return result
    }

    private static func isBoundedDiagnosticPoint(_ point: Point3D) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite &&
        abs(point.x) <= maximumDiagnosticCoordinateMeters &&
        abs(point.y) <= maximumDiagnosticCoordinateMeters &&
        abs(point.z) <= maximumDiagnosticCoordinateMeters
    }

    private func sha256(of url: URL) throws -> String {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch is CancellationError { throw CancellationError() }
        catch { throw ScanPackageInspectorError.ioFailure(error.localizedDescription) }
    }

    private func finding(_ code: String, _ stage: ScanInspectionStage, _ severity: ScanInspectionSeverity, _ evidence: String, _ conclusion: String, _ limitation: String, _ next: String, metrics: ScanInspectionMetrics = .init()) -> ScanInspectionFinding {
        .init(code: code, stage: stage, severity: severity, evidence: evidence, conclusion: conclusion, limitation: limitation, recommendedNextMeasurement: next, metrics: metrics)
    }

    private func set(_ stage: ScanInspectionStage, to disposition: ScanInspectionDisposition, metrics: ScanInspectionMetrics, in reports: inout [ScanInspectionStageReport]) {
        guard let index = reports.firstIndex(where: { $0.stage == stage }) else { return }
        reports[index] = .init(stage: stage, disposition: disposition, metrics: metrics)
    }

    private func maxDisposition(_ lhs: ScanInspectionDisposition, _ rhs: ScanInspectionDisposition) -> ScanInspectionDisposition {
        let rank: [ScanInspectionDisposition: Int] = [.notApplicable: 0, .unavailable: 1, .healthy: 2, .unqualified: 3, .insufficientEvidence: 4, .suspicious: 5, .failed: 6]
        return (rank[lhs] ?? 0) >= (rank[rhs] ?? 0) ? lhs : rhs
    }

    private func add(_ value: Float, to histogram: inout [Int], minimum: Float, binWidth: Float) {
        guard !histogram.isEmpty, binWidth > 0 else { return }
        let offset = Int(floor((value - minimum) / binWidth))
        histogram[min(histogram.count - 1, max(0, offset))] += 1
    }

    private func add(_ value: Double, to histogram: inout [Int], binWidth: Double) {
        guard !histogram.isEmpty, binWidth > 0 else { return }
        let offset = Int(floor(value / binWidth))
        histogram[min(histogram.count - 1, max(0, offset))] += 1
    }

    private func histogramPercentile(_ histogram: [Int], fraction: Double, minimum: Double, binWidth: Double) -> Double {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return 0 }
        let target = min(total - 1, max(0, Int(Double(total - 1) * fraction)))
        var accumulated = 0
        for (index, count) in histogram.enumerated() {
            accumulated += count
            if accumulated > target { return minimum + Double(index) * binWidth }
        }
        return minimum + Double(max(0, histogram.count - 1)) * binWidth
    }

    private func distance(_ lhs: Point3D, _ rhs: Point3D) -> Double {
        let x = Double(lhs.x - rhs.x)
        let y = Double(lhs.y - rhs.y)
        let z = Double(lhs.z - rhs.z)
        return hypot(hypot(x, y), z)
    }

    private func rotationDeltaDegrees(_ lhs: Transform4x4, _ rhs: Transform4x4) -> Double {
        let a = lhs.columns
        let b = rhs.columns
        guard a.count == 16, b.count == 16 else { return 0 }
        var trace = 0.0
        for column in 0..<3 {
            for row in 0..<3 {
                trace += Double(a[column * 4 + row] * b[column * 4 + row])
            }
        }
        let cosine = min(1.0, max(-1.0, (trace - 1.0) / 2.0))
        return acos(cosine) * 180.0 / .pi
    }

    private func connectedRegionCount(in cells: Set<DiagnosticCoverageCell>) -> Int {
        var remaining = cells
        var regionCount = 0
        while let start = remaining.popFirst() {
            regionCount += 1
            var pending = [start]
            while let cell = pending.popLast() {
                for neighbor in cell.faceNeighbors where remaining.remove(neighbor) != nil {
                    pending.append(neighbor)
                }
            }
        }
        return regionCount
    }

    private func diagnosticBounds<C: Collection>(for cells: C, cellSizeMeters: Float) -> (minimum: String, maximum: String) where C.Element == DiagnosticCoverageCell {
        guard let first = cells.first else { return ("unavailable", "unavailable") }
        var minimum = first
        var maximum = first
        for cell in cells.dropFirst() {
            minimum.x = min(minimum.x, cell.x)
            minimum.y = min(minimum.y, cell.y)
            minimum.z = min(minimum.z, cell.z)
            maximum.x = max(maximum.x, cell.x)
            maximum.y = max(maximum.y, cell.y)
            maximum.z = max(maximum.z, cell.z)
        }
        let lower = Point3D(x: Float(minimum.x) * cellSizeMeters, y: Float(minimum.y) * cellSizeMeters, z: Float(minimum.z) * cellSizeMeters)
        let upper = Point3D(x: Float(maximum.x + 1) * cellSizeMeters, y: Float(maximum.y + 1) * cellSizeMeters, z: Float(maximum.z + 1) * cellSizeMeters)
        return (Self.pointDescription(lower), Self.pointDescription(upper))
    }

    private static func pointDescription(_ point: Point3D?) -> String {
        guard let point else { return "unavailable" }
        return "\(point.x),\(point.y),\(point.z)"
    }
}

private struct DiagnosticCoverageCell: Hashable {
    var x: Int
    var y: Int
    var z: Int

    init(point: Point3D, sizeMeters: Float) {
        x = Int(floor(point.x / sizeMeters))
        y = Int(floor(point.y / sizeMeters))
        z = Int(floor(point.z / sizeMeters))
    }

    var faceNeighbors: [DiagnosticCoverageCell] {
        [
            .init(x: x - 1, y: y, z: z), .init(x: x + 1, y: y, z: z),
            .init(x: x, y: y - 1, z: z), .init(x: x, y: y + 1, z: z),
            .init(x: x, y: y, z: z - 1), .init(x: x, y: y, z: z + 1)
        ]
    }

    private init(x: Int, y: Int, z: Int) {
        self.x = x
        self.y = y
        self.z = z
    }
}
