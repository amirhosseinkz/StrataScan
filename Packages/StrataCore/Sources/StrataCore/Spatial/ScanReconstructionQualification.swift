import Foundation

/// A deterministic, derived explanation of which reconstruction and export
/// artifacts are currently trustworthy enough to use. It deliberately records
/// source facts and gate outcomes rather than inventing an accuracy score.
public enum ScanReconstructionQualificationIssueCode: String, Codable, CaseIterable, Equatable, Sendable {
    case packageIntegrityUnavailable
    case captureEvidenceUnavailable
    case captureEvidenceInsufficient
    case canonicalSpatialSourceUnavailable
    case processedSurfaceUnavailable
    case processedSurfaceInvalid
    case rejectedDepthSamples
    case droppedVoxelUpdates
    case rayLimitReached
}

public enum ScanReconstructionQualificationIssueSeverity: String, Codable, Equatable, Sendable {
    case information
    case warning
    case blocking
}

public struct ScanReconstructionQualificationIssue: Codable, Equatable, Sendable, Identifiable {
    public var code: ScanReconstructionQualificationIssueCode
    public var severity: ScanReconstructionQualificationIssueSeverity
    /// A source count when the issue has one; never a normalized quality score.
    public var count: Int?

    public init(
        code: ScanReconstructionQualificationIssueCode,
        severity: ScanReconstructionQualificationIssueSeverity,
        count: Int? = nil
    ) {
        self.code = code
        self.severity = severity
        self.count = count
    }

    public var id: String { code.rawValue }
}

public struct ScanReconstructionExportReadiness: Codable, Equatable, Sendable, Identifiable {
    public var format: ScanInterchangeFormat
    public var isReady: Bool
    public var blockingIssueCodes: [ScanReconstructionQualificationIssueCode]

    public init(
        format: ScanInterchangeFormat,
        isReady: Bool,
        blockingIssueCodes: [ScanReconstructionQualificationIssueCode]
    ) {
        self.format = format
        self.isReady = isReady
        self.blockingIssueCodes = blockingIssueCodes
    }

    public var id: String { format.rawValue }
}

/// A compact reconstruction and export gate derived from immutable capture
/// telemetry and verified derived-surface validation. The report is not stored
/// in a scan package, so it cannot become stale or mutate source evidence.
public struct ScanReconstructionQualificationReport: Codable, Equatable, Sendable {
    public var captureEvidence: CaptureEvidenceQualification?
    public var reconstructionStatistics: TSDFReconstructionStatistics?
    public var surfaceValidation: TSDFSurfaceValidationReport?
    public var issues: [ScanReconstructionQualificationIssue]
    public var exports: [ScanReconstructionExportReadiness]

    public init(
        captureEvidence: CaptureEvidenceQualification?,
        packageIntegrityIsValid: Bool,
        canonicalSpatialSourceAvailable: Bool,
        processedSurfaceAvailable: Bool,
        surfaceValidation: TSDFSurfaceValidationReport? = nil
    ) {
        self.captureEvidence = captureEvidence
        reconstructionStatistics = surfaceValidation?.sourceStatistics
        self.surfaceValidation = surfaceValidation

        var issues: [ScanReconstructionQualificationIssue] = []
        if !packageIntegrityIsValid {
            issues.append(.init(code: .packageIntegrityUnavailable, severity: .blocking))
        }
        if let captureEvidence {
            if !captureEvidence.isEvidenceSufficientForProcessing {
                issues.append(.init(code: .captureEvidenceInsufficient, severity: .blocking))
            }
        } else {
            issues.append(.init(code: .captureEvidenceUnavailable, severity: .blocking))
        }
        if !canonicalSpatialSourceAvailable {
            issues.append(.init(code: .canonicalSpatialSourceUnavailable, severity: .blocking))
        }
        if !processedSurfaceAvailable {
            issues.append(.init(code: .processedSurfaceUnavailable, severity: .blocking))
        }
        if let surfaceValidation, !surfaceValidation.isValid {
            issues.append(.init(code: .processedSurfaceInvalid, severity: .blocking))
        }
        if let statistics = surfaceValidation?.sourceStatistics {
            if statistics.rejectedDepthSampleCount > 0 {
                issues.append(.init(
                    code: .rejectedDepthSamples,
                    severity: .information,
                    count: statistics.rejectedDepthSampleCount
                ))
            }
            if statistics.droppedVoxelUpdateCount > 0 {
                issues.append(.init(
                    code: .droppedVoxelUpdates,
                    severity: .warning,
                    count: statistics.droppedVoxelUpdateCount
                ))
            }
            if statistics.rayLimitReachedFrameCount > 0 {
                issues.append(.init(
                    code: .rayLimitReached,
                    severity: .warning,
                    count: statistics.rayLimitReachedFrameCount
                ))
            }
        }
        self.issues = issues

        let pointExportBlockers = issues.compactMap { issue -> ScanReconstructionQualificationIssueCode? in
            switch issue.code {
            case .packageIntegrityUnavailable, .canonicalSpatialSourceUnavailable:
                return issue.code
            default:
                return nil
            }
        }
        let surfaceExportBlockers = issues.compactMap { issue -> ScanReconstructionQualificationIssueCode? in
            switch issue.code {
            case .packageIntegrityUnavailable,
                    .captureEvidenceUnavailable,
                    .captureEvidenceInsufficient,
                    .processedSurfaceUnavailable,
                    .processedSurfaceInvalid:
                return issue.code
            default:
                return nil
            }
        }
        exports = [
            .init(format: .ply, isReady: pointExportBlockers.isEmpty, blockingIssueCodes: pointExportBlockers),
            .init(format: .opf, isReady: pointExportBlockers.isEmpty, blockingIssueCodes: pointExportBlockers),
            .init(format: .glb, isReady: surfaceExportBlockers.isEmpty, blockingIssueCodes: surfaceExportBlockers),
            .init(format: .cesium3DTiles, isReady: surfaceExportBlockers.isEmpty, blockingIssueCodes: surfaceExportBlockers)
        ]
    }

    public var isProcessedSurfaceEligible: Bool {
        !issues.contains { $0.severity == .blocking }
    }
}
