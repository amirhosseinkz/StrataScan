import CryptoKit
import Foundation

public enum CalibratedKeyframeAcceptanceReason: String, Codable, CaseIterable, Sendable {
    case initialFrame
    case cameraMotion
    case surfaceNovelty
    case timeCeiling
    case externalSourceSelection
}

public enum CalibratedKeyframeRejectionReason: String, Codable, CaseIterable, Sendable {
    case minimumInterval
    case tracking
    case missingDepth
    case invalidCalibration
    case invalidDepthGrid
    case missingRGB
    case exposure
    case blur
    case duplicate
    case mappingNotReady
    case lowConfidence
    case insufficientEvidence
}

public enum OptionalKeyframeImageDropReason: String, Codable, CaseIterable, Sendable {
    case writerPressure
    case encodingFailure
    case stagingFailure
    case imageLimit
}

public enum CaptureTelemetryEvent: Sendable {
    case calibratedKeyframeRejected(CalibratedKeyframeRejectionReason)
    case calibratedKeyframeCandidate(CalibratedKeyframeEvidence)
    case optionalKeyframeImageDropped(OptionalKeyframeImageDropReason)
}

public struct CaptureTelemetry: Codable, Equatable, Sendable {
    public var accountingSchemaVersion: Int?
    public var calibratedKeyframeCandidateCount: Int
    public var calibratedKeyframeAcceptanceCounts: [String: Int]
    public var calibratedKeyframeRejectionCounts: [String: Int]
    public var optionalImageDropCounts: [String: Int]
    public var evidenceSamples: [CalibratedKeyframeEvidence]
    public var trackingStateCounts: [String: Int]?
    public var interruptionBeganCount: Int?
    public var interruptionEndedCount: Int?
    public var finalizationCount: Int?

    public init(
        calibratedKeyframeAcceptanceCounts: [String: Int] = [:],
        calibratedKeyframeRejectionCounts: [String: Int] = [:],
        optionalImageDropCounts: [String: Int] = [:],
        calibratedKeyframeCandidateCount: Int = 0,
        evidenceSamples: [CalibratedKeyframeEvidence] = [],
        accountingSchemaVersion: Int? = 1,
        trackingStateCounts: [String: Int]? = [:],
        interruptionBeganCount: Int? = 0,
        interruptionEndedCount: Int? = 0,
        finalizationCount: Int? = 0
    ) {
        self.accountingSchemaVersion = accountingSchemaVersion
        self.calibratedKeyframeAcceptanceCounts = calibratedKeyframeAcceptanceCounts
        self.calibratedKeyframeRejectionCounts = calibratedKeyframeRejectionCounts
        self.optionalImageDropCounts = optionalImageDropCounts
        self.calibratedKeyframeCandidateCount = calibratedKeyframeCandidateCount
        self.evidenceSamples = Array(evidenceSamples.suffix(128))
        self.trackingStateCounts = trackingStateCounts
        self.interruptionBeganCount = interruptionBeganCount
        self.interruptionEndedCount = interruptionEndedCount
        self.finalizationCount = finalizationCount
    }

    private enum CodingKeys: String, CodingKey {
        case calibratedKeyframeCandidateCount
        case calibratedKeyframeAcceptanceCounts
        case calibratedKeyframeRejectionCounts
        case optionalImageDropCounts
        case evidenceSamples
        case accountingSchemaVersion
        case trackingStateCounts
        case interruptionBeganCount
        case interruptionEndedCount
        case finalizationCount
    }

    /// Telemetry is stored in the scan manifest and must remain readable for
    /// packages written before evidence samples were introduced.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountingSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .accountingSchemaVersion)
        calibratedKeyframeAcceptanceCounts = try container.decodeIfPresent(
                [String: Int].self,
                forKey: .calibratedKeyframeAcceptanceCounts
            ) ?? [:]
        calibratedKeyframeRejectionCounts = try container.decodeIfPresent(
                [String: Int].self,
                forKey: .calibratedKeyframeRejectionCounts
            ) ?? [:]
        optionalImageDropCounts = try container.decodeIfPresent(
                [String: Int].self,
                forKey: .optionalImageDropCounts
            ) ?? [:]
        calibratedKeyframeCandidateCount = try container.decodeIfPresent(
                Int.self,
                forKey: .calibratedKeyframeCandidateCount
            ) ?? 0
        evidenceSamples = Array((try container.decodeIfPresent(
                [CalibratedKeyframeEvidence].self,
                forKey: .evidenceSamples
            ) ?? []).suffix(128))
        trackingStateCounts = try container.decodeIfPresent([String: Int].self, forKey: .trackingStateCounts)
        interruptionBeganCount = try container.decodeIfPresent(Int.self, forKey: .interruptionBeganCount)
        interruptionEndedCount = try container.decodeIfPresent(Int.self, forKey: .interruptionEndedCount)
        finalizationCount = try container.decodeIfPresent(Int.self, forKey: .finalizationCount)
    }

    public var acceptedCalibratedKeyframeCount: Int {
        calibratedKeyframeAcceptanceCounts.values.reduce(0, +)
    }

    public var droppedOptionalImageCount: Int {
        optionalImageDropCounts.values.reduce(0, +)
    }

    public mutating func record(_ reason: CalibratedKeyframeAcceptanceReason) {
        calibratedKeyframeAcceptanceCounts[reason.rawValue, default: 0] += 1
        if accountingSchemaVersion == 1 { calibratedKeyframeCandidateCount += 1 }
    }

    public mutating func record(_ event: CaptureTelemetryEvent) {
        switch event {
        case let .calibratedKeyframeRejected(reason):
            calibratedKeyframeRejectionCounts[reason.rawValue, default: 0] += 1
            if accountingSchemaVersion == 1 { calibratedKeyframeCandidateCount += 1 }
        case let .optionalKeyframeImageDropped(reason):
            optionalImageDropCounts[reason.rawValue, default: 0] += 1
        case let .calibratedKeyframeCandidate(evidence):
            evidenceSamples.append(evidence)
            if evidenceSamples.count > 128 { evidenceSamples.removeFirst(evidenceSamples.count - 128) }
        }
    }

    public mutating func recordTracking(_ state: FrameTrackingState) {
        trackingStateCounts?[state.rawValue, default: 0] += 1
    }

    public mutating func recordInterruptionBegan() {
        if interruptionBeganCount != nil { interruptionBeganCount? += 1 }
    }

    public mutating func recordInterruptionEnded() {
        if interruptionEndedCount != nil { interruptionEndedCount? += 1 }
    }

    public mutating func recordFinalization() {
        if finalizationCount != nil { finalizationCount = 1 }
    }

    public var isEmpty: Bool {
        calibratedKeyframeAcceptanceCounts.isEmpty
            && calibratedKeyframeRejectionCounts.isEmpty
            && optionalImageDropCounts.isEmpty
            && calibratedKeyframeCandidateCount == 0
            && (trackingStateCounts?.isEmpty ?? true)
            && (interruptionBeganCount ?? 0) == 0
            && (interruptionEndedCount ?? 0) == 0
            && (finalizationCount ?? 0) == 0
    }

    /// A transparent evidence summary for review and package inspection. It is
    /// not a physical accuracy score and intentionally reports unavailable
    /// fields when a legacy package did not retain the needed telemetry.
    public var evidenceQualification: CaptureEvidenceQualification {
        CaptureEvidenceQualification(telemetry: self)
    }
}

public struct CaptureEvidenceQualification: Codable, Equatable, Sendable {
    public var candidateCount: Int
    public var acceptedCount: Int
    public var rejectionCounts: [String: Int]
    public var meanCadenceSeconds: TimeInterval?
    public var meanConfidenceRatio: Float?
    public var meanOverlapRatio: Float?
    public var meanNewCoverageRatio: Float?
    public var isEvidenceSufficientForProcessing: Bool

    public init(telemetry: CaptureTelemetry) {
        candidateCount = telemetry.calibratedKeyframeCandidateCount
        acceptedCount = telemetry.acceptedCalibratedKeyframeCount
        rejectionCounts = telemetry.calibratedKeyframeRejectionCounts
        let samples = telemetry.evidenceSamples
        meanCadenceSeconds = Self.mean(samples.map(\.cadenceSeconds))
        meanConfidenceRatio = Self.mean(samples.map(\.confidenceRatio))
        meanOverlapRatio = Self.mean(samples.map(\.overlapRatio))
        meanNewCoverageRatio = Self.mean(samples.map(\.newCoverageRatio))
        // This is deliberately a minimal eligibility check. Surface validation
        // remains authoritative and can still reject the derived result.
        isEvidenceSufficientForProcessing = acceptedCount >= 2
            && (meanConfidenceRatio ?? 0) >= 0.18
            && ((meanOverlapRatio ?? 0) >= 0.12 || (meanNewCoverageRatio ?? 0) >= 0.08)
    }

    private static func mean<T: BinaryFloatingPoint>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / T(values.count)
    }
}

public struct CalibratedRGBDKeyframeSample: Sendable {
    public var metadata: FrameMetadata
    public var depth: DepthFrameSample
    public var acceptanceReason: CalibratedKeyframeAcceptanceReason
    public var evidence: CalibratedKeyframeEvidence?
    public var evidenceContract: CaptureEvidenceContract?

    public init(
        metadata: FrameMetadata,
        depth: DepthFrameSample,
        acceptanceReason: CalibratedKeyframeAcceptanceReason,
        evidence: CalibratedKeyframeEvidence? = nil,
        evidenceContract: CaptureEvidenceContract? = nil
    ) {
        self.metadata = metadata
        self.depth = depth
        self.acceptanceReason = acceptanceReason
        self.evidence = evidence
        self.evidenceContract = evidenceContract
    }
}

public enum CalibratedRGBDPixelFormat: String, Codable, Sendable {
    case depthFloat32LittleEndian
    case confidenceUInt8
    case rgbUInt8DepthGrid
}

public enum CaptureEvidenceSource: String, Codable, CaseIterable, Hashable, Sendable {
    case arkitWorldTracking
    case publicRGBDDataset
}

public enum CaptureDepthSource: String, Codable, CaseIterable, Hashable, Sendable {
    case sceneDepth
    case smoothedSceneDepth
    case externalDepth
}

public enum CaptureRGBSource: String, Codable, CaseIterable, Sendable {
    case capturedImageNearestNeighborToDepthGrid
    case externalColorResampledToDepthGrid
}

public enum CaptureSynchronizationMethod: String, Codable, CaseIterable, Sendable {
    case sameARFrame
    case sourceTimestampMatched
}

public enum CaptureExposureAvailability: String, Codable, CaseIterable, Sendable {
    case measured
    case unavailable
}

public enum CaptureMeshTimelineRelationship: String, Codable, CaseIterable, Sendable {
    case independentTimestampedFinalRegistry
    case notApplicableExternalSource
}

public enum CaptureInertialEvidencePolicy: String, Codable, CaseIterable, Sendable {
    case arkitVIOOnly
}

public struct CaptureEvidenceTimestamps: Codable, Equatable, Sendable {
    public var capture: TimeInterval
    public var cameraImage: TimeInterval
    public var depth: TimeInterval
    public var confidence: TimeInterval
    public var pose: TimeInterval
    public var maximumSourceDeltaSeconds: TimeInterval

    public init(
        capture: TimeInterval,
        cameraImage: TimeInterval,
        depth: TimeInterval,
        confidence: TimeInterval,
        pose: TimeInterval,
        maximumSourceDeltaSeconds: TimeInterval
    ) {
        self.capture = capture
        self.cameraImage = cameraImage
        self.depth = depth
        self.confidence = confidence
        self.pose = pose
        self.maximumSourceDeltaSeconds = maximumSourceDeltaSeconds
    }
}

public struct CaptureExposureEvidence: Codable, Equatable, Sendable {
    public var availability: CaptureExposureAvailability
    public var exposureDurationSeconds: TimeInterval?
    public var exposureTargetOffsetEV: Float?
    public var sampledLuminanceMean: Float?
    public var sampledLuminanceVariance: Float?
    public var sampledAdjacentDifference: Float?

    public init(
        availability: CaptureExposureAvailability,
        exposureDurationSeconds: TimeInterval? = nil,
        exposureTargetOffsetEV: Float? = nil,
        sampledLuminanceMean: Float? = nil,
        sampledLuminanceVariance: Float? = nil,
        sampledAdjacentDifference: Float? = nil
    ) {
        self.availability = availability
        self.exposureDurationSeconds = exposureDurationSeconds
        self.exposureTargetOffsetEV = exposureTargetOffsetEV
        self.sampledLuminanceMean = sampledLuminanceMean
        self.sampledLuminanceVariance = sampledLuminanceVariance
        self.sampledAdjacentDifference = sampledAdjacentDifference
    }

    public static let unavailable = CaptureExposureEvidence(availability: .unavailable)
}

/// The authoritative evidence attached to every schema-v2 calibrated keyframe.
/// Payload bytes remain external and checksum-bound by the package manifest.
public struct CaptureEvidenceContract: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var source: CaptureEvidenceSource
    public var depthSource: CaptureDepthSource
    public var rgbSource: CaptureRGBSource
    public var synchronization: CaptureSynchronizationMethod
    public var timestamps: CaptureEvidenceTimestamps
    public var cameraImageWidth: Int
    public var cameraImageHeight: Int
    public var depthWidth: Int
    public var depthHeight: Int
    public var confidenceWidth: Int
    public var confidenceHeight: Int
    public var rgbWidth: Int
    public var rgbHeight: Int
    public var intrinsicsBasis: String
    public var orientationPolicy: String
    public var exposure: CaptureExposureEvidence
    public var acceptanceEvidence: CalibratedKeyframeEvidence?
    public var meshTimelineRelationship: CaptureMeshTimelineRelationship
    public var inertialPolicy: CaptureInertialEvidencePolicy
    public var ownership: String

    public init(
        source: CaptureEvidenceSource,
        depthSource: CaptureDepthSource,
        rgbSource: CaptureRGBSource,
        synchronization: CaptureSynchronizationMethod,
        timestamps: CaptureEvidenceTimestamps,
        cameraImageWidth: Int,
        cameraImageHeight: Int,
        depthWidth: Int,
        depthHeight: Int,
        exposure: CaptureExposureEvidence,
        acceptanceEvidence: CalibratedKeyframeEvidence?
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.source = source
        self.depthSource = depthSource
        self.rgbSource = rgbSource
        self.synchronization = synchronization
        self.timestamps = timestamps
        self.cameraImageWidth = cameraImageWidth
        self.cameraImageHeight = cameraImageHeight
        self.depthWidth = depthWidth
        self.depthHeight = depthHeight
        confidenceWidth = depthWidth
        confidenceHeight = depthHeight
        rgbWidth = depthWidth
        rgbHeight = depthHeight
        intrinsicsBasis = "nativeCameraImage"
        orientationPolicy = "presentationOnly; calibrationAndPayloadRemainNative"
        self.exposure = exposure
        self.acceptanceEvidence = acceptanceEvidence
        meshTimelineRelationship = source == .arkitWorldTracking
            ? .independentTimestampedFinalRegistry
            : .notApplicableExternalSource
        inertialPolicy = .arkitVIOOnly
        ownership = "essential"
    }

    public func validationIssue(
        metadata: FrameMetadata,
        depthWidth expectedDepthWidth: Int,
        depthHeight expectedDepthHeight: Int
    ) -> CaptureEvidenceContractIssue? {
        let timestampValues = [
            timestamps.capture, timestamps.cameraImage, timestamps.depth,
            timestamps.confidence, timestamps.pose, timestamps.maximumSourceDeltaSeconds
        ]
        guard schemaVersion == Self.currentSchemaVersion,
              intrinsicsBasis == "nativeCameraImage",
              orientationPolicy == "presentationOnly; calibrationAndPayloadRemainNative",
              inertialPolicy == .arkitVIOOnly,
              ownership == "essential"
        else { return .policy }
        guard cameraImageWidth == metadata.imageWidth,
              cameraImageHeight == metadata.imageHeight,
              depthWidth == expectedDepthWidth,
              depthHeight == expectedDepthHeight,
              confidenceWidth == expectedDepthWidth,
              confidenceHeight == expectedDepthHeight,
              rgbWidth == expectedDepthWidth,
              rgbHeight == expectedDepthHeight
        else { return .dimensions }
        guard timestampValues.allSatisfy(\.isFinite),
              timestamps.maximumSourceDeltaSeconds >= 0,
              timestamps.capture == metadata.timestamp,
              timestamps.cameraImage == metadata.timestamp,
              timestamps.depth == timestamps.capture,
              timestamps.confidence == timestamps.depth,
              abs(timestamps.pose - timestamps.capture) <= timestamps.maximumSourceDeltaSeconds
        else { return .timestamps }
        switch synchronization {
        case .sameARFrame:
            guard let evidence = acceptanceEvidence,
                  evidence.timestamp == metadata.timestamp,
                  evidence.confidenceRatio.isFinite && (0...1).contains(evidence.confidenceRatio),
                  evidence.overlapRatio.isFinite && (0...1).contains(evidence.overlapRatio),
                  evidence.newCoverageRatio.isFinite && (0...1).contains(evidence.newCoverageRatio),
                  evidence.poseBaselineMeters.isFinite && evidence.poseBaselineMeters >= 0,
                  evidence.cadenceSeconds.isFinite && evidence.cadenceSeconds >= 0,
                  source == .arkitWorldTracking,
                  depthSource != .externalDepth,
                  rgbSource == .capturedImageNearestNeighborToDepthGrid,
                  meshTimelineRelationship == .independentTimestampedFinalRegistry,
                  timestamps.maximumSourceDeltaSeconds == 0,
                  timestamps.pose == timestamps.capture,
                  exposure.availability == .measured
            else { return .source }
        case .sourceTimestampMatched:
            guard acceptanceEvidence == nil,
                  source == .publicRGBDDataset,
                  depthSource == .externalDepth,
                  rgbSource == .externalColorResampledToDepthGrid,
                  meshTimelineRelationship == .notApplicableExternalSource,
                  exposure.availability == .unavailable
            else { return .source }
        }
        switch exposure.availability {
        case .unavailable:
            guard exposure.exposureDurationSeconds == nil,
                  exposure.exposureTargetOffsetEV == nil,
                  exposure.sampledLuminanceMean == nil,
                  exposure.sampledLuminanceVariance == nil,
                  exposure.sampledAdjacentDifference == nil
            else { return .exposure }
        case .measured:
            guard let duration = exposure.exposureDurationSeconds,
                  let offset = exposure.exposureTargetOffsetEV,
                  let mean = exposure.sampledLuminanceMean,
                  let variance = exposure.sampledLuminanceVariance,
                  let difference = exposure.sampledAdjacentDifference,
                  duration.isFinite && duration > 0,
                  offset.isFinite,
                  mean.isFinite && (0...1).contains(mean),
                  variance.isFinite && variance >= 0,
                  difference.isFinite && difference >= 0
            else { return .exposure }
        }
        return nil
    }
}

public enum CaptureEvidenceContractIssue: String, Codable, CaseIterable, Hashable, Sendable {
    case policy
    case dimensions
    case timestamps
    case acceptance
    case source
    case exposure
}

public struct CalibratedRGBDKeyframeRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var index: Int
    public var metadata: FrameMetadata
    public var acceptanceReason: CalibratedKeyframeAcceptanceReason
    public var depthWidth: Int
    public var depthHeight: Int
    public var rgbWidth: Int
    public var rgbHeight: Int
    public var depthFormat: CalibratedRGBDPixelFormat
    public var confidenceFormat: CalibratedRGBDPixelFormat
    public var rgbFormat: CalibratedRGBDPixelFormat
    public var depthPath: String
    public var confidencePath: String
    public var rgbPath: String
    /// Nil only for schema-v1 packages written before M1.1.
    public var evidenceContract: CaptureEvidenceContract?

    public init(
        index: Int,
        metadata: FrameMetadata,
        acceptanceReason: CalibratedKeyframeAcceptanceReason,
        depthWidth: Int,
        depthHeight: Int,
        depthPath: String,
        confidencePath: String,
        rgbPath: String,
        evidenceContract: CaptureEvidenceContract? = nil
    ) {
        schemaVersion = evidenceContract == nil ? 1 : Self.currentSchemaVersion
        self.index = index
        self.metadata = metadata
        self.acceptanceReason = acceptanceReason
        self.depthWidth = depthWidth
        self.depthHeight = depthHeight
        rgbWidth = depthWidth
        rgbHeight = depthHeight
        depthFormat = .depthFloat32LittleEndian
        confidenceFormat = .confidenceUInt8
        rgbFormat = .rgbUInt8DepthGrid
        self.depthPath = depthPath
        self.confidencePath = confidencePath
        self.rgbPath = rgbPath
        self.evidenceContract = evidenceContract
    }
}

public struct CalibratedRGBDKeyframe: Sendable {
    public var record: CalibratedRGBDKeyframeRecord
    public var depth: DepthFrameSample

    public init(record: CalibratedRGBDKeyframeRecord, depth: DepthFrameSample) {
        self.record = record
        self.depth = depth
    }
}

public enum CalibratedRGBDKeyframeArchiveError: Error, Equatable, Sendable {
    case alreadyClosed
    case invalidSample
    case packageIntegrityFailed
    case indexMissing
    case undeclaredAsset(String)
    case invalidRecord(Int)
    case invalidPayload(String)
    case ioFailure(String)
}

public struct CalibratedRGBDKeyframeArchiveSummary: Equatable, Sendable {
    public var recordCount: Int

    public init(recordCount: Int) {
        self.recordCount = recordCount
    }
}

/// Writes independently replayable calibrated RGB, depth, and confidence grids.
/// Each append is bounded to one selected frame; total capture length is not
/// truncated by an in-memory keyframe collection.
public actor CalibratedRGBDKeyframeArchiveWriter {
    public static let indexRelativePath = "capture/keyframes/index.ndjson"

    private let workingDirectory: URL
    private var indexHandle: FileHandle?
    private var recordCount = 0
    private var finalSummary: CalibratedRGBDKeyframeArchiveSummary?

    public init(workingDirectory: URL, fileManager: FileManager = .default) throws {
        self.workingDirectory = workingDirectory
        let indexURL = workingDirectory.appending(path: Self.indexRelativePath)
        do {
            try fileManager.createDirectory(
                at: indexURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: indexURL, options: .atomic)
            indexHandle = try FileHandle(forWritingTo: indexURL)
        } catch {
            throw CalibratedRGBDKeyframeArchiveError.ioFailure(error.localizedDescription)
        }
    }

    @discardableResult
    public func append(_ sample: CalibratedRGBDKeyframeSample) throws -> CalibratedRGBDKeyframeRecord {
        guard let indexHandle, finalSummary == nil else {
            throw CalibratedRGBDKeyframeArchiveError.alreadyClosed
        }
        guard Self.isValid(sample) else {
            throw CalibratedRGBDKeyframeArchiveError.invalidSample
        }

        let index = recordCount + 1
        let stem = "capture/keyframes/keyframe-\(String(format: "%06d", index))"
        let depthPath = "\(stem).depth-f32le"
        let confidencePath = "\(stem).confidence-u8"
        let rgbPath = "\(stem).rgb-u8"
        guard let evidenceContract = sample.evidenceContract else {
            throw CalibratedRGBDKeyframeArchiveError.invalidSample
        }
        let record = CalibratedRGBDKeyframeRecord(
            index: index,
            metadata: sample.metadata,
            acceptanceReason: sample.acceptanceReason,
            depthWidth: sample.depth.width,
            depthHeight: sample.depth.height,
            depthPath: depthPath,
            confidencePath: confidencePath,
            rgbPath: rgbPath,
            evidenceContract: evidenceContract
        )
        let payloadURLs = [depthPath, confidencePath, rgbPath].map { workingDirectory.appending(path: $0) }

        do {
            try Self.depthData(sample.depth.depthMeters).write(to: payloadURLs[0], options: .atomic)
            try Data(sample.depth.confidence).write(to: payloadURLs[1], options: .atomic)
            try Self.rgbData(sample.depth.observedColors).write(to: payloadURLs[2], options: .atomic)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var line = try encoder.encode(record)
            line.append(0x0A)
            try indexHandle.write(contentsOf: line)
            recordCount = index
            return record
        } catch {
            payloadURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            throw CalibratedRGBDKeyframeArchiveError.ioFailure(error.localizedDescription)
        }
    }

    public func finish() throws -> CalibratedRGBDKeyframeArchiveSummary {
        if let finalSummary {
            return finalSummary
        }
        guard let indexHandle else {
            throw CalibratedRGBDKeyframeArchiveError.alreadyClosed
        }
        do {
            try indexHandle.synchronize()
            try indexHandle.close()
            self.indexHandle = nil
            let summary = CalibratedRGBDKeyframeArchiveSummary(recordCount: recordCount)
            finalSummary = summary
            return summary
        } catch {
            throw CalibratedRGBDKeyframeArchiveError.ioFailure(error.localizedDescription)
        }
    }

    public func cancel() {
        try? indexHandle?.close()
        indexHandle = nil
    }

    fileprivate static func isValid(_ sample: CalibratedRGBDKeyframeSample) -> Bool {
        guard isValidBase(sample), let contract = sample.evidenceContract else {
            return false
        }
        return isValid(contract, sample: sample)
    }

    fileprivate static func isValidReplay(
        _ sample: CalibratedRGBDKeyframeSample,
        schemaVersion: Int
    ) -> Bool {
        guard isValidBase(sample) else { return false }
        if schemaVersion == 1 {
            return sample.evidenceContract == nil && sample.evidence == nil
        }
        guard schemaVersion == CalibratedRGBDKeyframeRecord.currentSchemaVersion,
              let contract = sample.evidenceContract
        else { return false }
        return isValid(contract, sample: sample)
    }

    private static func isValidBase(_ sample: CalibratedRGBDKeyframeSample) -> Bool {
        let metadata = sample.metadata
        let depth = sample.depth
        let (pixelCount, overflow) = depth.width.multipliedReportingOverflow(by: depth.height)
        return !overflow
            && depth.width > 0
            && depth.height > 0
            && pixelCount > 0
            && depth.depthMeters.count == pixelCount
            && depth.confidence.count == pixelCount
            && depth.observedColors.count == pixelCount
            && depth.observedColors.allSatisfy { $0 != nil }
            && metadata.timestamp.isFinite
            && (metadata.videoTimestamp?.isFinite ?? true)
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
            && metadata.intrinsics.cx >= 0
            && metadata.intrinsics.cy >= 0
            && metadata.intrinsics.cx <= Float(metadata.imageWidth)
            && metadata.intrinsics.cy <= Float(metadata.imageHeight)
            && metadata.tracking == .normal
            && depth.confidence.allSatisfy { $0 <= 2 }
    }

    private static func isValid(
        _ contract: CaptureEvidenceContract,
        sample: CalibratedRGBDKeyframeSample
    ) -> Bool {
        contract.validationIssue(
            metadata: sample.metadata,
            depthWidth: sample.depth.width,
            depthHeight: sample.depth.height
        ) == nil && contract.acceptanceEvidence == sample.evidence
    }

    private static func depthData(_ values: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(values.count * MemoryLayout<UInt32>.size)
        for value in values {
            data.appendLittleEndianKeyframe(value.bitPattern)
        }
        return data
    }

    private static func rgbData(_ colors: [PointCloudColor?]) -> Data {
        var data = Data()
        data.reserveCapacity(colors.count * 3)
        for color in colors {
            guard let color else { continue }
            data.append(color.red)
            data.append(color.green)
            data.append(color.blue)
        }
        return data
    }
}

/// An integrity-validated archive index that decodes at most one keyframe's
/// payloads per call. It has no ARKit, CoreVideo, image-decoder, or network
/// dependency.
public struct CalibratedRGBDKeyframeReplayArchive: Sendable {
    public let scanID: UUID
    public let sourceIndexSHA256: String
    public let sourceArchiveSHA256: String
    public let records: [CalibratedRGBDKeyframeRecord]
    private let packageURL: URL
    private let assetReferencesByPath: [String: ScanAssetReference]

    fileprivate init(
        scanID: UUID,
        sourceIndexSHA256: String,
        sourceArchiveSHA256: String,
        records: [CalibratedRGBDKeyframeRecord],
        packageURL: URL,
        assetReferencesByPath: [String: ScanAssetReference]
    ) {
        self.scanID = scanID
        self.sourceIndexSHA256 = sourceIndexSHA256
        self.sourceArchiveSHA256 = sourceArchiveSHA256
        self.records = records
        self.packageURL = packageURL
        self.assetReferencesByPath = assetReferencesByPath
    }

    public func readKeyframe(at offset: Int) throws -> CalibratedRGBDKeyframe {
        guard records.indices.contains(offset) else {
            throw CalibratedRGBDKeyframeArchiveError.invalidRecord(offset + 1)
        }
        let record = records[offset]
        let pixelCount = record.depthWidth * record.depthHeight
        guard let depthReference = assetReferencesByPath[record.depthPath],
              let confidenceReference = assetReferencesByPath[record.confidencePath],
              let rgbReference = assetReferencesByPath[record.rgbPath]
        else {
            throw CalibratedRGBDKeyframeArchiveError.undeclaredAsset(record.depthPath)
        }
        let depthData = try Self.payload(
            at: record.depthPath,
            packageURL: packageURL,
            reference: depthReference
        )
        let confidenceData = try Self.payload(
            at: record.confidencePath,
            packageURL: packageURL,
            reference: confidenceReference
        )
        let rgbData = try Self.payload(
            at: record.rgbPath,
            packageURL: packageURL,
            reference: rgbReference
        )
        guard depthData.count == pixelCount * 4,
              confidenceData.count == pixelCount,
              rgbData.count == pixelCount * 3
        else {
            throw CalibratedRGBDKeyframeArchiveError.invalidPayload(record.depthPath)
        }

        var depthValues: [Float] = []
        depthValues.reserveCapacity(pixelCount)
        var colors: [PointCloudColor?] = []
        colors.reserveCapacity(pixelCount)
        for pixelIndex in 0..<pixelCount {
            guard let bits = depthData.readUInt32LittleEndianKeyframe(at: pixelIndex * 4) else {
                throw CalibratedRGBDKeyframeArchiveError.invalidPayload(record.depthPath)
            }
            depthValues.append(Float(bitPattern: bits))
            let rgbOffset = pixelIndex * 3
            colors.append(PointCloudColor(
                red: rgbData[rgbOffset],
                green: rgbData[rgbOffset + 1],
                blue: rgbData[rgbOffset + 2]
            ))
        }
        let depth = DepthFrameSample(
            width: record.depthWidth,
            height: record.depthHeight,
            depthMeters: depthValues,
            confidence: Array(confidenceData),
            observedColors: colors,
            calibration: record.metadata.intrinsics,
            worldFromCamera: record.metadata.worldFromCamera,
            timestamp: record.metadata.timestamp
        )
        let replaySample = CalibratedRGBDKeyframeSample(
            metadata: record.metadata,
            depth: depth,
            acceptanceReason: record.acceptanceReason,
            evidence: record.evidenceContract?.acceptanceEvidence,
            evidenceContract: record.evidenceContract
        )
        guard CalibratedRGBDKeyframeArchiveWriter.isValidReplay(
            replaySample,
            schemaVersion: record.schemaVersion
        ) else {
            throw CalibratedRGBDKeyframeArchiveError.invalidRecord(record.index)
        }
        return CalibratedRGBDKeyframe(record: record, depth: depth)
    }

    private static func payload(
        at relativePath: String,
        packageURL: URL,
        reference: ScanAssetReference
    ) throws -> Data {
        do {
            let packagePath = packageURL.resolvingSymlinksInPath().standardizedFileURL.path
            let url = packageURL.appending(path: relativePath)
            let payloadPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard payloadPath.hasPrefix(packagePath + "/") else {
                throw CalibratedRGBDKeyframeArchiveError.invalidPayload(relativePath)
            }
            let data = try Data(contentsOf: url)
            guard Int64(data.count) == reference.byteCount,
                  Self.sha256(data) == reference.sha256.lowercased()
            else {
                throw CalibratedRGBDKeyframeArchiveError.invalidPayload(relativePath)
            }
            return data
        } catch let error as CalibratedRGBDKeyframeArchiveError {
            throw error
        } catch {
            throw CalibratedRGBDKeyframeArchiveError.ioFailure(error.localizedDescription)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct CalibratedRGBDKeyframeArchiveReader: Sendable {
    public init() {}

    public func open(
        packageURL: URL,
        manifest: ScanPackageManifest,
        integrity: PackageIntegrityReport
    ) throws -> CalibratedRGBDKeyframeReplayArchive {
        guard integrity.isValid, integrity.scanID == manifest.localScanID else {
            throw CalibratedRGBDKeyframeArchiveError.packageIntegrityFailed
        }
        var declaredAssets: [String: ScanAssetReference] = [:]
        for asset in manifest.assets {
            guard declaredAssets.updateValue(asset, forKey: asset.relativePath) == nil else {
                throw CalibratedRGBDKeyframeArchiveError.packageIntegrityFailed
            }
        }
        guard let indexAsset = declaredAssets[CalibratedRGBDKeyframeArchiveWriter.indexRelativePath],
              indexAsset.kind == .manifestAttachment,
              indexAsset.spatialReference == .arWorld
        else {
            throw CalibratedRGBDKeyframeArchiveError.indexMissing
        }

        let indexData = try Self.verifiedData(
            at: CalibratedRGBDKeyframeArchiveWriter.indexRelativePath,
            packageURL: packageURL,
            reference: indexAsset
        )
        let records: [CalibratedRGBDKeyframeRecord]
        do {
            records = try indexData.split(separator: 0x0A).map {
                try JSONDecoder().decode(CalibratedRGBDKeyframeRecord.self, from: Data($0))
            }
        } catch {
            throw CalibratedRGBDKeyframeArchiveError.invalidRecord(0)
        }

        var seenPaths = Set<String>()
        for (offset, record) in records.enumerated() {
            let expectedIndex = offset + 1
            let (pixelCount, overflow) = record.depthWidth.multipliedReportingOverflow(by: record.depthHeight)
            let (_, depthOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
            let (_, rgbOverflow) = pixelCount.multipliedReportingOverflow(by: 3)
            guard (1...CalibratedRGBDKeyframeRecord.currentSchemaVersion).contains(record.schemaVersion),
                  (record.schemaVersion == 1) == (record.evidenceContract == nil),
                  record.index == expectedIndex,
                  record.depthWidth > 0,
                  record.depthHeight > 0,
                  record.rgbWidth == record.depthWidth,
                  record.rgbHeight == record.depthHeight,
                  record.depthFormat == .depthFloat32LittleEndian,
                  record.confidenceFormat == .confidenceUInt8,
                  record.rgbFormat == .rgbUInt8DepthGrid,
                  !overflow,
                  !depthOverflow,
                  !rgbOverflow,
                  pixelCount > 0
            else {
                throw CalibratedRGBDKeyframeArchiveError.invalidRecord(expectedIndex)
            }
            for path in [record.depthPath, record.confidencePath, record.rgbPath] {
                guard Self.isSafe(path), seenPaths.insert(path).inserted else {
                    throw CalibratedRGBDKeyframeArchiveError.invalidRecord(expectedIndex)
                }
                guard let asset = declaredAssets[path],
                      asset.kind == .manifestAttachment,
                      asset.spatialReference == .arWorld
                else {
                    throw CalibratedRGBDKeyframeArchiveError.undeclaredAsset(path)
                }
            }
        }
        return CalibratedRGBDKeyframeReplayArchive(
            scanID: manifest.localScanID,
            sourceIndexSHA256: indexAsset.sha256,
            sourceArchiveSHA256: Self.archiveSHA256(
                scanID: manifest.localScanID,
                indexAsset: indexAsset,
                records: records,
                declaredAssets: declaredAssets
            ),
            records: records,
            packageURL: packageURL,
            assetReferencesByPath: declaredAssets
        )
    }

    public func read(
        packageURL: URL,
        manifest: ScanPackageManifest,
        integrity: PackageIntegrityReport
    ) throws -> [CalibratedRGBDKeyframe] {
        let archive = try open(packageURL: packageURL, manifest: manifest, integrity: integrity)
        return try archive.records.indices.map { try archive.readKeyframe(at: $0) }
    }

    private static func isSafe(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\")
        else {
            return false
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private static func archiveSHA256(
        scanID: UUID,
        indexAsset: ScanAssetReference,
        records: [CalibratedRGBDKeyframeRecord],
        declaredAssets: [String: ScanAssetReference]
    ) -> String {
        var data = Data("StrataScanCalibratedRGBDArchiveV1\n".utf8)
        data.append(contentsOf: scanID.uuidString.lowercased().utf8)
        data.append(0x0A)
        for path in [indexAsset.relativePath] + records.flatMap({
            [$0.depthPath, $0.confidencePath, $0.rgbPath]
        }) {
            guard let asset = declaredAssets[path] else { continue }
            data.append(contentsOf: path.utf8)
            data.append(0)
            data.append(contentsOf: String(asset.byteCount).utf8)
            data.append(0)
            data.append(contentsOf: asset.sha256.lowercased().utf8)
            data.append(0x0A)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func verifiedData(
        at relativePath: String,
        packageURL: URL,
        reference: ScanAssetReference
    ) throws -> Data {
        do {
            let packagePath = packageURL.resolvingSymlinksInPath().standardizedFileURL.path
            let url = packageURL.appending(path: relativePath)
            let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard filePath.hasPrefix(packagePath + "/") else {
                throw CalibratedRGBDKeyframeArchiveError.invalidPayload(relativePath)
            }
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard Int64(data.count) == reference.byteCount,
                  digest == reference.sha256.lowercased()
            else {
                throw CalibratedRGBDKeyframeArchiveError.invalidPayload(relativePath)
            }
            return data
        } catch let error as CalibratedRGBDKeyframeArchiveError {
            throw error
        } catch {
            throw CalibratedRGBDKeyframeArchiveError.ioFailure(error.localizedDescription)
        }
    }
}

private extension Data {
    mutating func appendLittleEndianKeyframe(_ value: UInt32) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    func readUInt32LittleEndianKeyframe(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
