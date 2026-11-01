import Foundation

/// Keeps retained camera frames spatially useful without changing the raw
/// camera image/pose basis used by later projection.
public struct KeyframePoseAdmission: Sendable {
    public let minimumTranslationMeters: Float
    public let minimumRotationRadians: Float
    private var lastAccepted: Transform4x4?

    public init(minimumTranslationMeters: Float = 0.25, minimumRotationRadians: Float = .pi / 9) {
        self.minimumTranslationMeters = max(0, minimumTranslationMeters)
        self.minimumRotationRadians = max(0, minimumRotationRadians)
    }

    public mutating func reset() {
        lastAccepted = nil
    }

    /// The first normal-tracking frame is useful. Later frames must differ by
    /// translation or camera heading; rejected frames do not advance the basis.
    public func admits(_ metadata: FrameMetadata) -> Bool {
        guard metadata.tracking == .normal, let lastAccepted else {
            return metadata.tracking == .normal
        }
        return translation(from: lastAccepted, to: metadata.worldFromCamera) >= minimumTranslationMeters
            || rotation(from: lastAccepted, to: metadata.worldFromCamera) >= minimumRotationRadians
    }

    public mutating func recordAccepted(_ metadata: FrameMetadata) {
        lastAccepted = metadata.worldFromCamera
    }

    private func translation(from lhs: Transform4x4, to rhs: Transform4x4) -> Float {
        let dx = rhs.columns[12] - lhs.columns[12]
        let dy = rhs.columns[13] - lhs.columns[13]
        let dz = rhs.columns[14] - lhs.columns[14]
        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    private func rotation(from lhs: Transform4x4, to rhs: Transform4x4) -> Float {
        // ARKit camera forward is its local negative-Z axis, transformed by
        // the documented column-major worldFromCamera rotation.
        let lhsForward = (-lhs.columns[8], -lhs.columns[9], -lhs.columns[10])
        let rhsForward = (-rhs.columns[8], -rhs.columns[9], -rhs.columns[10])
        let dot = lhsForward.0 * rhsForward.0 + lhsForward.1 * rhsForward.1 + lhsForward.2 * rhsForward.2
        return acosf(min(1, max(-1, dot)))
    }
}

public enum CalibratedKeyframeAdmissionDecision: Equatable, Sendable {
    case accepted(CalibratedKeyframeAcceptanceReason)
    case rejected(CalibratedKeyframeRejectionReason)
}

/// Central, versioned evidence policy for reconstruction keyframes.  These
/// limits deliberately favour connected multi-view observations over a large
/// collection of near-identical camera frames.
public struct CalibratedKeyframeEvidenceConfiguration: Codable, Equatable, Sendable {
    public static let `default` = CalibratedKeyframeEvidenceConfiguration()

    public var minimumIntervalSeconds: TimeInterval
    public var maximumUsefulGapSeconds: TimeInterval
    public var minimumTranslationMeters: Float
    public var minimumRotationRadians: Float
    public var minimumConfidenceRatio: Float
    public var minimumOverlapRatio: Float
    public var minimumNewCoverageRatio: Float

    public init(
        minimumIntervalSeconds: TimeInterval = 0.45,
        maximumUsefulGapSeconds: TimeInterval = 1.5,
        minimumTranslationMeters: Float = 0.12,
        minimumRotationRadians: Float = .pi / 18,
        minimumConfidenceRatio: Float = 0.18,
        minimumOverlapRatio: Float = 0.12,
        minimumNewCoverageRatio: Float = 0.08
    ) {
        self.minimumIntervalSeconds = max(0, minimumIntervalSeconds)
        self.maximumUsefulGapSeconds = max(minimumIntervalSeconds, maximumUsefulGapSeconds)
        self.minimumTranslationMeters = max(0, minimumTranslationMeters)
        self.minimumRotationRadians = max(0, minimumRotationRadians)
        self.minimumConfidenceRatio = min(1, max(0, minimumConfidenceRatio))
        self.minimumOverlapRatio = min(1, max(0, minimumOverlapRatio))
        self.minimumNewCoverageRatio = min(1, max(0, minimumNewCoverageRatio))
    }
}

/// Bounded, non-image evidence diagnostics retained in package telemetry. The
/// overlap and novelty values are sampled from calibrated depth-grid points in
/// AR world coordinates; they never invent a camera transform or image asset.
public struct CalibratedKeyframeEvidence: Codable, Equatable, Sendable {
    public var timestamp: TimeInterval
    public var confidenceRatio: Float
    public var overlapRatio: Float
    public var newCoverageRatio: Float
    public var poseBaselineMeters: Float
    public var cadenceSeconds: TimeInterval

    public init(timestamp: TimeInterval, confidenceRatio: Float, overlapRatio: Float, newCoverageRatio: Float, poseBaselineMeters: Float, cadenceSeconds: TimeInterval) {
        self.timestamp = timestamp
        self.confidenceRatio = confidenceRatio
        self.overlapRatio = overlapRatio
        self.newCoverageRatio = newCoverageRatio
        self.poseBaselineMeters = poseBaselineMeters
        self.cadenceSeconds = cadenceSeconds
    }
}

/// Selects reconstruction keyframes from copied values. Camera motion and
/// depth-grid novelty are independent ways to add useful evidence; the time
/// ceiling guarantees a bounded refresh when neither threshold is crossed.
public struct CalibratedKeyframeAdmission: Sendable {
    public let configuration: CalibratedKeyframeEvidenceConfiguration
    public let minimumTranslationMeters: Float
    public let minimumRotationRadians: Float
    public let maximumIntervalSeconds: TimeInterval
    public let minimumNovelDepthFraction: Float
    private var lastAcceptedMetadata: FrameMetadata?
    private var lastAcceptedDepthFingerprint: DepthFingerprint?
    private var recentFingerprints: [DepthFingerprint] = []
    public private(set) var lastEvidence: CalibratedKeyframeEvidence?

    public init(
        minimumTranslationMeters: Float = 0.25,
        minimumRotationRadians: Float = .pi / 9,
        maximumIntervalSeconds: TimeInterval = 8,
        minimumNovelDepthFraction: Float = 0.25
    ) {
        configuration = .init(
            minimumIntervalSeconds: 0.45,
            maximumUsefulGapSeconds: maximumIntervalSeconds,
            minimumTranslationMeters: minimumTranslationMeters,
            minimumRotationRadians: minimumRotationRadians,
            minimumConfidenceRatio: 0.18,
            minimumOverlapRatio: 0.12,
            minimumNewCoverageRatio: minimumNovelDepthFraction
        )
        self.minimumTranslationMeters = max(0, minimumTranslationMeters)
        self.minimumRotationRadians = max(0, minimumRotationRadians)
        self.maximumIntervalSeconds = max(0, maximumIntervalSeconds)
        self.minimumNovelDepthFraction = min(1, max(0, minimumNovelDepthFraction))
    }

    public init(configuration: CalibratedKeyframeEvidenceConfiguration = .default) {
        self.configuration = configuration
        minimumTranslationMeters = configuration.minimumTranslationMeters
        minimumRotationRadians = configuration.minimumRotationRadians
        maximumIntervalSeconds = configuration.maximumUsefulGapSeconds
        minimumNovelDepthFraction = configuration.minimumNewCoverageRatio
    }

    public mutating func reset() {
        lastAcceptedMetadata = nil
        lastAcceptedDepthFingerprint = nil
        recentFingerprints.removeAll(keepingCapacity: true)
        lastEvidence = nil
    }

    public mutating func evaluate(
        metadata: FrameMetadata,
        depth: DepthFrameSample?
    ) -> CalibratedKeyframeAdmissionDecision {
        lastEvidence = nil
        guard metadata.tracking == .normal else {
            return .rejected(.tracking)
        }
        switch metadata.worldMapping {
        case .limited, .extending, .mapped:
            break
        case .notAvailable:
            return .rejected(.mappingNotReady)
        }
        guard let depth else {
            return .rejected(.missingDepth)
        }
        guard isValidCalibration(metadata, depth: depth) else {
            return .rejected(.invalidCalibration)
        }
        let (pixelCount, overflow) = depth.width.multipliedReportingOverflow(by: depth.height)
        guard !overflow,
              depth.width > 0,
              depth.height > 0,
              depth.depthMeters.count == pixelCount,
              depth.confidence.count == pixelCount
        else {
            return .rejected(.invalidDepthGrid)
        }
        guard depth.observedColors.count == pixelCount,
              depth.observedColors.allSatisfy({ $0 != nil })
        else {
            return .rejected(.missingRGB)
        }

        let fingerprint = DepthFingerprint(sample: depth, metadata: metadata)
        guard fingerprint.confidenceRatio >= configuration.minimumConfidenceRatio else {
            return .rejected(.lowConfidence)
        }
        guard let previousMetadata = lastAcceptedMetadata,
              lastAcceptedDepthFingerprint != nil
        else {
            lastEvidence = .init(timestamp: metadata.timestamp, confidenceRatio: fingerprint.confidenceRatio, overlapRatio: 0, newCoverageRatio: 1, poseBaselineMeters: 0, cadenceSeconds: 0)
            recordAccepted(metadata: metadata, fingerprint: fingerprint)
            return .accepted(.initialFrame)
        }

        let elapsed = metadata.timestamp - previousMetadata.timestamp
        let baseline = translation(from: previousMetadata.worldFromCamera, to: metadata.worldFromCamera)
        guard elapsed.isFinite, elapsed > 0, baseline.isFinite else {
            return .rejected(.invalidCalibration)
        }
        let overlap = recentFingerprints.map { fingerprint.overlapFraction(comparedWith: $0) }.max() ?? 0
        let novelty = fingerprint.newCoverageFraction(comparedWith: recentFingerprints)
        lastEvidence = .init(timestamp: metadata.timestamp, confidenceRatio: fingerprint.confidenceRatio, overlapRatio: overlap, newCoverageRatio: novelty, poseBaselineMeters: baseline, cadenceSeconds: max(0, elapsed))
        guard overlap >= configuration.minimumOverlapRatio || novelty >= configuration.minimumNewCoverageRatio else {
            return .rejected(.insufficientEvidence)
        }
        if baseline >= minimumTranslationMeters
            || rotation(from: previousMetadata.worldFromCamera, to: metadata.worldFromCamera) >= minimumRotationRadians {
            recordAccepted(metadata: metadata, fingerprint: fingerprint)
            return .accepted(.cameraMotion)
        }
        if novelty >= minimumNovelDepthFraction {
            recordAccepted(metadata: metadata, fingerprint: fingerprint)
            return .accepted(.surfaceNovelty)
        }
        if elapsed.isFinite, elapsed >= maximumIntervalSeconds, overlap >= configuration.minimumOverlapRatio {
            recordAccepted(metadata: metadata, fingerprint: fingerprint)
            return .accepted(.timeCeiling)
        }
        return .rejected(.duplicate)
    }

    private func isValidCalibration(_ metadata: FrameMetadata, depth: DepthFrameSample) -> Bool {
        metadata.timestamp.isFinite
            && metadata.timestamp == depth.timestamp
            && metadata.imageWidth > 0
            && metadata.imageHeight > 0
            && metadata.imageWidth == metadata.intrinsics.imageWidth
            && metadata.imageHeight == metadata.intrinsics.imageHeight
            && metadata.intrinsics == depth.calibration
            && metadata.worldFromCamera == depth.worldFromCamera
            && metadata.worldFromCamera.columns.allSatisfy(\.isFinite)
            && metadata.intrinsics.fx.isFinite
            && metadata.intrinsics.fy.isFinite
            && metadata.intrinsics.cx.isFinite
            && metadata.intrinsics.cy.isFinite
            && metadata.intrinsics.fx > 0
            && metadata.intrinsics.fy > 0
    }

    private mutating func recordAccepted(metadata: FrameMetadata, fingerprint: DepthFingerprint) {
        lastAcceptedMetadata = metadata
        lastAcceptedDepthFingerprint = fingerprint
        recentFingerprints.append(fingerprint)
        if recentFingerprints.count > 6 { recentFingerprints.removeFirst(recentFingerprints.count - 6) }
    }

    private func translation(from lhs: Transform4x4, to rhs: Transform4x4) -> Float {
        let dx = rhs.columns[12] - lhs.columns[12]
        let dy = rhs.columns[13] - lhs.columns[13]
        let dz = rhs.columns[14] - lhs.columns[14]
        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    private func rotation(from lhs: Transform4x4, to rhs: Transform4x4) -> Float {
        let lhsForward = (-lhs.columns[8], -lhs.columns[9], -lhs.columns[10])
        let rhsForward = (-rhs.columns[8], -rhs.columns[9], -rhs.columns[10])
        let dot = lhsForward.0 * rhsForward.0 + lhsForward.1 * rhsForward.1 + lhsForward.2 * rhsForward.2
        return acosf(min(1, max(-1, dot)))
    }
}

private struct DepthFingerprint: Sendable {
    private static let maximumSampleCount = 64
    private var width: Int
    private var height: Int
    private var values: [Float?]

    private var worldPoints: [Point3D?]
    private(set) var confidenceRatio: Float

    init(sample: DepthFrameSample, metadata: FrameMetadata) {
        width = sample.width
        height = sample.height
        let pixelCount = sample.width * sample.height
        let sampleCount = min(Self.maximumSampleCount, pixelCount)
        var confident = 0
        var points: [Point3D?] = []
        values = (0..<sampleCount).map { sampleIndex in
            let pixelIndex = sampleCount == 1
                ? 0
                : sampleIndex * (pixelCount - 1) / (sampleCount - 1)
            let value = sample.depthMeters[pixelIndex]
            guard value.isFinite, value > 0, value <= 5, sample.confidence[pixelIndex] >= 1 else {
                points.append(nil); return nil
            }
            confident += 1
            let x = pixelIndex % sample.width
            let y = pixelIndex / sample.width
            let intrinsics = sample.calibration.scaled(toWidth: sample.width, height: sample.height)
            let camera = Point3D(x: -((Float(x) - intrinsics.cx) / intrinsics.fx) * value, y: -((Float(y) - intrinsics.cy) / intrinsics.fy) * value, z: -value)
            points.append(metadata.worldFromCamera.applying(to: camera))
            return value
        }
        worldPoints = points
        confidenceRatio = sampleCount == 0 ? 0 : Float(confident) / Float(sampleCount)
    }

    func novelFraction(comparedWith previous: DepthFingerprint) -> Float {
        guard width == previous.width, height == previous.height else {
            return 1
        }
        var comparableCount = 0
        var changedCount = 0
        for (current, prior) in zip(values, previous.values) {
            guard let current, let prior else { continue }
            comparableCount += 1
            let tolerance = 0.08 + 0.025 * max(current, prior)
            if abs(current - prior) > tolerance {
                changedCount += 1
            }
        }
        guard comparableCount > 0 else { return 0 }
        return Float(changedCount) / Float(comparableCount)
    }

    func overlapFraction(comparedWith previous: DepthFingerprint) -> Float {
        guard !worldPoints.isEmpty, !previous.worldPoints.isEmpty else { return 0 }
        var valid = 0
        var overlapping = 0
        for point in worldPoints.compactMap({ $0 }) {
            valid += 1
            if previous.worldPoints.compactMap({ $0 }).contains(where: { candidate in
                let dx = point.x - candidate.x; let dy = point.y - candidate.y; let dz = point.z - candidate.z
                return dx * dx + dy * dy + dz * dz <= 0.15 * 0.15
            }) { overlapping += 1 }
        }
        return valid == 0 ? 0 : Float(overlapping) / Float(valid)
    }

    func newCoverageFraction(comparedWith history: [DepthFingerprint]) -> Float {
        guard !history.isEmpty else { return 1 }
        var valid = 0
        var newPoints = 0
        for point in worldPoints.compactMap({ $0 }) {
            valid += 1
            let matchesHistory = history.contains { $0.worldPoints.compactMap({ $0 }).contains { candidate in
                let dx = point.x - candidate.x; let dy = point.y - candidate.y; let dz = point.z - candidate.z
                return dx * dx + dy * dy + dz * dz <= 0.15 * 0.15
            }}
            if !matchesHistory { newPoints += 1 }
        }
        return valid == 0 ? 0 : Float(newPoints) / Float(valid)
    }
}
