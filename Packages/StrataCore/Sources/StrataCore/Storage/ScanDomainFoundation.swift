import Foundation

/// The single product-facing state for a persisted scan asset.
///
/// This is deliberately separate from capture-session lifecycle state. It is
/// resolved from persisted metadata, package metadata, and package integrity so
/// feature presentation does not recreate lifecycle rules in each view.
public enum ScanAssetState: String, Codable, CaseIterable, Equatable, Sendable {
    case capturing
    case processing
    case ready
    case modified
    case pendingSync
    case syncing
    case synced
    case incomplete
    case processingFailed
    case syncFailed
    case syncConflict
    case pendingDeletion
    case corrupted
    case deleted
}

/// Resolves the product-facing state of a scan from its persisted sources of truth.
public struct ScanAssetStateResolver: Sendable {
    public init() {}

    public func resolve(
        metadata: ScanMetadata,
        manifest: ScanPackageManifest,
        integrity: PackageIntegrityReport
    ) -> ScanAssetState {
        if metadata.status == .deleted || manifest.status == .deleted {
            return .deleted
        }

        guard metadata.id == manifest.localScanID,
              metadata.id == integrity.scanID,
              integrity.isValid else {
            return .corrupted
        }

        if metadata.status == .corrupted || manifest.status == .corrupted {
            return .corrupted
        }

        guard metadata.status == manifest.status else {
            return .incomplete
        }

        switch manifest.status {
        case .draft:
            return .incomplete
        case .capturing:
            return .capturing
        case .processing:
            return .processing
        case .completed:
            return resolveSynchronization(manifest.sync.status)
        case .failed:
            return .processingFailed
        case .corrupted:
            return .corrupted
        case .deleted:
            return .deleted
        }
    }

    private func resolveSynchronization(_ status: SynchronizationStatus) -> ScanAssetState {
        switch status {
        case .localOnly:
            return .ready
        case .pendingUpload:
            return .pendingSync
        case .uploading:
            return .syncing
        case .synced:
            return .synced
        case .modified:
            return .modified
        case .conflict:
            return .syncConflict
        case .failed:
            return .syncFailed
        case .pendingDeletion:
            return .pendingDeletion
        }
    }
}

/// Whether a particular asset kind is represented by one or more manifest entries.
public enum ScanArtifactAvailability: String, Codable, CaseIterable, Equatable, Sendable {
    case unavailable
    case available
}

/// A factual, kind-specific view of the assets listed in a scan package manifest.
///
/// It intentionally does not state whether an asset can be rendered, exported, or
/// shared. Those are consumer capabilities which must be supplied by the feature
/// that owns a concrete renderer or exporter.
public struct ScanArtifactCapability: Codable, Equatable, Sendable, Identifiable {
    public var kind: AssetKind
    public var assets: [ScanAssetReference]

    public var id: String { kind.rawValue }
    public var availability: ScanArtifactAvailability {
        assets.isEmpty ? .unavailable : .available
    }
    public var assetCount: Int { assets.count }
    public var totalByteCount: Int64 { ScanByteCount.total(of: assets) }

    public init(kind: AssetKind, manifest: ScanPackageManifest) {
        self.kind = kind
        self.assets = manifest.assets.filter { $0.kind == kind }
    }
}

/// A stable capability matrix derived only from the scan package manifest.
public struct ScanCapabilities: Codable, Equatable, Sendable {
    /// Ordered by `AssetKind.allCases` so consumers can render a stable list.
    public var artifacts: [ScanArtifactCapability]

    public init(manifest: ScanPackageManifest) {
        artifacts = AssetKind.allCases.map { kind in
            ScanArtifactCapability(
                kind: kind,
                manifest: manifest
            )
        }
    }

    public func capability(for kind: AssetKind) -> ScanArtifactCapability? {
        artifacts.first { $0.kind == kind }
    }

    public var availableArtifacts: [ScanArtifactCapability] {
        artifacts.filter { $0.availability == .available }
    }
}

/// Factual scan information derived from persisted manifest data.
///
/// Optional counts are omitted when the package has no corresponding artifact;
/// the summary never turns missing capture data into a zero-valued metric.
public struct ScanSummary: Codable, Equatable, Sendable {
    public var durationSeconds: TimeInterval?
    public var frameCount: Int?
    public var pointCount: Int?
    public var meshVertexCount: Int?
    public var meshTriangleCount: Int?
    public var assetCount: Int
    public var totalAssetByteCount: Int64
    public var hasVideo: Bool

    public init(manifest: ScanPackageManifest) {
        let assets = manifest.assets
        durationSeconds = Self.validDuration(manifest.durationSeconds)
        frameCount = Self.contains(.frameMetadata, in: assets) ? manifest.captureStatistics.sampledFrameCount : nil
        pointCount = Self.contains(.pointCloud, in: assets) ? manifest.captureStatistics.depthPointCount : nil
        meshVertexCount = Self.contains(.meshRaw, in: assets) ? manifest.captureStatistics.meshVertexCount : nil
        meshTriangleCount = Self.contains(.meshRaw, in: assets) ? manifest.captureStatistics.meshFaceCount : nil
        assetCount = assets.count
        totalAssetByteCount = ScanByteCount.total(of: assets)
        hasVideo = Self.contains(.video, in: assets)
    }

    private static func contains(_ kind: AssetKind, in assets: [ScanAssetReference]) -> Bool {
        assets.contains { $0.kind == kind }
    }

    private static func validDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration >= 0 else { return nil }
        return duration
    }
}

/// Capture-quality signals that are available from a completed capture.
///
/// `nil` means a signal was not recorded. Invalid values are normalized to `nil`
/// so they cannot be treated as measured quality.
public struct ScanQualitySignals: Codable, Equatable, Sendable {
    public var trackingInterruptions: Int?
    public var lowConfidenceDepthFraction: Double?
    public var coverageFraction: Double?

    public init(
        trackingInterruptions: Int? = nil,
        lowConfidenceDepthFraction: Double? = nil,
        coverageFraction: Double? = nil
    ) {
        self.trackingInterruptions = Self.validInterruptionCount(trackingInterruptions)
        self.lowConfidenceDepthFraction = Self.validFraction(lowConfidenceDepthFraction)
        self.coverageFraction = Self.validFraction(coverageFraction)
    }

    fileprivate var validatedTrackingInterruptions: Int? {
        Self.validInterruptionCount(trackingInterruptions)
    }

    fileprivate var validatedLowConfidenceDepthFraction: Double? {
        Self.validFraction(lowConfidenceDepthFraction)
    }

    fileprivate var validatedCoverageFraction: Double? {
        Self.validFraction(coverageFraction)
    }

    private static func validInterruptionCount(_ count: Int?) -> Int? {
        guard let count, count >= 0 else { return nil }
        return count
    }

    private static func validFraction(_ fraction: Double?) -> Double? {
        guard let fraction, fraction.isFinite, (0 ... 1).contains(fraction) else { return nil }
        return fraction
    }
}

public enum ScanQualityMetricKind: String, Codable, CaseIterable, Equatable, Sendable {
    case tracking
    case depthConfidence
    case coverage
}

public enum ScanQualityLevel: String, Codable, CaseIterable, Equatable, Sendable {
    case excellent
    case good
    case fair
    case poor
}

/// A score is present only when its source signal was available and valid.
public struct ScanQualityMetric: Codable, Equatable, Sendable, Identifiable {
    public var kind: ScanQualityMetricKind
    public var score: Int?
    public var level: ScanQualityLevel?

    public var id: ScanQualityMetricKind { kind }

    public init(kind: ScanQualityMetricKind, score: Int?, level: ScanQualityLevel?) {
        self.kind = kind
        self.score = score
        self.level = level
    }
}

public enum ScanQualityWarning: String, Codable, CaseIterable, Equatable, Sendable {
    case trackingInterrupted
    case lowDepthConfidence
    case limitedCoverage
}

public enum ScanQualityRecommendation: String, Codable, CaseIterable, Equatable, Sendable {
    case improveTracking
    case captureHigherConfidenceDepth
    case captureAdditionalCoverage
}

/// A deterministic, product-quality heuristic, not a scientific accuracy claim.
public struct ScanQualityReport: Codable, Equatable, Sendable {
    public var overallScore: Int?
    public var overallLevel: ScanQualityLevel?
    public var metrics: [ScanQualityMetric]
    public var warnings: [ScanQualityWarning]
    public var recommendations: [ScanQualityRecommendation]

    public init(
        overallScore: Int?,
        overallLevel: ScanQualityLevel?,
        metrics: [ScanQualityMetric],
        warnings: [ScanQualityWarning],
        recommendations: [ScanQualityRecommendation]
    ) {
        self.overallScore = overallScore
        self.overallLevel = overallLevel
        self.metrics = metrics
        self.warnings = warnings
        self.recommendations = recommendations
    }
}

/// Evaluates only recorded tracking, depth-confidence, and coverage signals.
public struct ScanQualityEvaluator: Sendable {
    public init() {}

    public func evaluate(_ signals: ScanQualitySignals) -> ScanQualityReport {
        let trackingScore = signals.validatedTrackingInterruptions.map(trackingScore(for:))
        let depthScore = signals.validatedLowConfidenceDepthFraction.map(depthConfidenceScore(for:))
        let coverageScore = signals.validatedCoverageFraction.map(coverageScore(for:))
        let metrics = [
            metric(kind: .tracking, score: trackingScore),
            metric(kind: .depthConfidence, score: depthScore),
            metric(kind: .coverage, score: coverageScore)
        ]
        let availableScores = metrics.compactMap(\.score)
        let overallScore = overallScore(from: availableScores)

        var warnings = [ScanQualityWarning]()
        var recommendations = [ScanQualityRecommendation]()
        appendTrackingAdvice(for: trackingScore, warnings: &warnings, recommendations: &recommendations)
        appendDepthAdvice(for: depthScore, warnings: &warnings, recommendations: &recommendations)
        appendCoverageAdvice(for: coverageScore, warnings: &warnings, recommendations: &recommendations)

        return ScanQualityReport(
            overallScore: overallScore,
            overallLevel: overallScore.map(level(for:)),
            metrics: metrics,
            warnings: warnings,
            recommendations: recommendations
        )
    }

    public func evaluate(signals: ScanQualitySignals) -> ScanQualityReport {
        evaluate(signals)
    }

    private func metric(kind: ScanQualityMetricKind, score: Int?) -> ScanQualityMetric {
        ScanQualityMetric(kind: kind, score: score, level: score.map(level(for:)))
    }

    private func trackingScore(for interruptions: Int) -> Int {
        switch interruptions {
        case 0:
            100
        case 1:
            80
        case 2 ... 3:
            60
        default:
            30
        }
    }

    private func depthConfidenceScore(for lowConfidenceFraction: Double) -> Int {
        Int(((1 - lowConfidenceFraction) * 100).rounded())
    }

    private func coverageScore(for coverageFraction: Double) -> Int {
        Int((coverageFraction * 100).rounded())
    }

    private func overallScore(from scores: [Int]) -> Int? {
        guard !scores.isEmpty else { return nil }
        let total = scores.reduce(0, +)
        return Int((Double(total) / Double(scores.count)).rounded())
    }

    private func level(for score: Int) -> ScanQualityLevel {
        switch score {
        case 85 ... 100:
            .excellent
        case 70 ... 84:
            .good
        case 50 ... 69:
            .fair
        default:
            .poor
        }
    }

    private func appendTrackingAdvice(
        for score: Int?,
        warnings: inout [ScanQualityWarning],
        recommendations: inout [ScanQualityRecommendation]
    ) {
        guard let score, score < 70 else { return }
        warnings.append(.trackingInterrupted)
        recommendations.append(.improveTracking)
    }

    private func appendDepthAdvice(
        for score: Int?,
        warnings: inout [ScanQualityWarning],
        recommendations: inout [ScanQualityRecommendation]
    ) {
        guard let score, score < 70 else { return }
        warnings.append(.lowDepthConfidence)
        recommendations.append(.captureHigherConfidenceDepth)
    }

    private func appendCoverageAdvice(
        for score: Int?,
        warnings: inout [ScanQualityWarning],
        recommendations: inout [ScanQualityRecommendation]
    ) {
        guard let score, score < 70 else { return }
        warnings.append(.limitedCoverage)
        recommendations.append(.captureAdditionalCoverage)
    }
}

private enum ScanByteCount {
    static func total(of assets: [ScanAssetReference]) -> Int64 {
        assets.reduce(0) { total, asset in
            let byteCount = max(asset.byteCount, 0)
            return total > Int64.max - byteCount ? Int64.max : total + byteCount
        }
    }
}
