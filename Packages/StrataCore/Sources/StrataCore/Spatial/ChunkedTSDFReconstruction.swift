import CryptoKit
import Foundation

public enum TSDFDepthSampleRejection: String, Codable, Sendable {
    case nonFinite
    case belowMinimum
    case aboveMaximum
    case lowConfidence
    case neighborInconsistent
    case invalidRay
}

public enum TSDFReconstructionError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidOutputLocation
    case sourceMismatch
    case configurationMismatch
    case unexpectedFrameIndex(expected: Int, actual: Int)
    case sourceFrameMismatch(expected: Int, actual: Int)
    case invalidFile(String)
    case ioFailure(String)
}

public struct TSDFReconstructionSource: Codable, Equatable, Sendable {
    public var scanID: UUID
    public var keyframeIndexSHA256: String
    public var calibratedArchiveSHA256: String
    public var keyframeCount: Int

    public init(
        scanID: UUID,
        keyframeIndexSHA256: String,
        calibratedArchiveSHA256: String,
        keyframeCount: Int
    ) {
        self.scanID = scanID
        self.keyframeIndexSHA256 = keyframeIndexSHA256
        self.calibratedArchiveSHA256 = calibratedArchiveSHA256
        self.keyframeCount = keyframeCount
    }
}

public enum TSDFReconstructionQualityProfile: String, Codable, Equatable, Sendable {
    case legacyV1
    case balancedV1
}

public struct TSDFReconstructionConfiguration: Codable, Equatable, Sendable {
    public static let `default` = TSDFReconstructionConfiguration(
        uncheckedVoxelSizeMeters: 0.04,
        truncationDistanceMeters: 0.12,
        submapVoxelDimension: 16,
        depthPixelStride: 2,
        maximumRaysPerFrame: 8_000,
        maximumUniqueVoxelUpdatesPerFrame: 64_000,
        maximumRaySteps: 15,
        minimumConfidence: 1,
        minimumDepthMeters: 0.10,
        maximumDepthMeters: 5,
        maximumVoxelWeight: 64,
        qualityProfile: .legacyV1,
        minimumConsistentNeighborCount: 0,
        absoluteNeighborToleranceMeters: 0.08,
        relativeNeighborTolerance: 0.025,
        preservesSparseObservations: true
    )
    public static let productionBalanced = TSDFReconstructionConfiguration(
        uncheckedVoxelSizeMeters: 0.04,
        truncationDistanceMeters: 0.12,
        submapVoxelDimension: 16,
        depthPixelStride: 2,
        maximumRaysPerFrame: 8_000,
        maximumUniqueVoxelUpdatesPerFrame: 64_000,
        maximumRaySteps: 15,
        minimumConfidence: 1,
        minimumDepthMeters: 0.10,
        maximumDepthMeters: 5,
        maximumVoxelWeight: 64,
        qualityProfile: .balancedV1,
        minimumConsistentNeighborCount: 2,
        absoluteNeighborToleranceMeters: 0.08,
        relativeNeighborTolerance: 0.025,
        preservesSparseObservations: true
    )

    public var voxelSizeMeters: Float
    public var truncationDistanceMeters: Float
    public var submapVoxelDimension: Int
    public var depthPixelStride: Int
    public var maximumRaysPerFrame: Int
    public var maximumUniqueVoxelUpdatesPerFrame: Int
    public var maximumRaySteps: Int
    public var minimumConfidence: UInt8
    public var minimumDepthMeters: Float
    public var maximumDepthMeters: Float
    public var maximumVoxelWeight: Float
    public var qualityProfile: TSDFReconstructionQualityProfile
    public var minimumConsistentNeighborCount: Int
    public var absoluteNeighborToleranceMeters: Float
    public var relativeNeighborTolerance: Float
    public var preservesSparseObservations: Bool

    public init(
        voxelSizeMeters: Float = 0.04,
        truncationDistanceMeters: Float = 0.12,
        submapVoxelDimension: Int = 16,
        depthPixelStride: Int = 4,
        maximumRaysPerFrame: Int = 8_000,
        maximumUniqueVoxelUpdatesPerFrame: Int = 64_000,
        maximumRaySteps: Int = 15,
        minimumConfidence: UInt8 = 1,
        minimumDepthMeters: Float = 0.10,
        maximumDepthMeters: Float = 12,
        maximumVoxelWeight: Float = 64,
        qualityProfile: TSDFReconstructionQualityProfile = .legacyV1,
        minimumConsistentNeighborCount: Int = 0,
        absoluteNeighborToleranceMeters: Float = 0.08,
        relativeNeighborTolerance: Float = 0.025,
        preservesSparseObservations: Bool = true
    ) throws {
        guard voxelSizeMeters.isFinite,
              voxelSizeMeters > 0,
              truncationDistanceMeters.isFinite,
              truncationDistanceMeters >= voxelSizeMeters,
              submapVoxelDimension >= 2,
              submapVoxelDimension <= 128,
              depthPixelStride >= 1,
              (1...1_000_000).contains(maximumRaysPerFrame),
              (1...2_000_000).contains(maximumUniqueVoxelUpdatesPerFrame),
              (1...1_024).contains(maximumRaySteps),
              minimumDepthMeters.isFinite,
              maximumDepthMeters.isFinite,
              minimumDepthMeters > 0,
              maximumDepthMeters >= minimumDepthMeters,
              maximumVoxelWeight.isFinite,
              maximumVoxelWeight >= 1,
              (0...8).contains(minimumConsistentNeighborCount),
              absoluteNeighborToleranceMeters.isFinite,
              absoluteNeighborToleranceMeters >= 0,
              relativeNeighborTolerance.isFinite,
              relativeNeighborTolerance >= 0,
              qualityProfile != .balancedV1 || minimumConsistentNeighborCount >= 2
        else {
            throw TSDFReconstructionError.invalidConfiguration
        }
        self.init(
            uncheckedVoxelSizeMeters: voxelSizeMeters,
            truncationDistanceMeters: truncationDistanceMeters,
            submapVoxelDimension: submapVoxelDimension,
            depthPixelStride: depthPixelStride,
            maximumRaysPerFrame: maximumRaysPerFrame,
            maximumUniqueVoxelUpdatesPerFrame: maximumUniqueVoxelUpdatesPerFrame,
            maximumRaySteps: maximumRaySteps,
            minimumConfidence: minimumConfidence,
            minimumDepthMeters: minimumDepthMeters,
            maximumDepthMeters: maximumDepthMeters,
            maximumVoxelWeight: maximumVoxelWeight,
            qualityProfile: qualityProfile,
            minimumConsistentNeighborCount: minimumConsistentNeighborCount,
            absoluteNeighborToleranceMeters: absoluteNeighborToleranceMeters,
            relativeNeighborTolerance: relativeNeighborTolerance,
            preservesSparseObservations: preservesSparseObservations
        )
    }

    private init(
        uncheckedVoxelSizeMeters voxelSizeMeters: Float,
        truncationDistanceMeters: Float,
        submapVoxelDimension: Int,
        depthPixelStride: Int,
        maximumRaysPerFrame: Int,
        maximumUniqueVoxelUpdatesPerFrame: Int,
        maximumRaySteps: Int,
        minimumConfidence: UInt8,
        minimumDepthMeters: Float,
        maximumDepthMeters: Float,
        maximumVoxelWeight: Float,
        qualityProfile: TSDFReconstructionQualityProfile,
        minimumConsistentNeighborCount: Int,
        absoluteNeighborToleranceMeters: Float,
        relativeNeighborTolerance: Float,
        preservesSparseObservations: Bool
    ) {
        self.voxelSizeMeters = voxelSizeMeters
        self.truncationDistanceMeters = truncationDistanceMeters
        self.submapVoxelDimension = submapVoxelDimension
        self.depthPixelStride = depthPixelStride
        self.maximumRaysPerFrame = maximumRaysPerFrame
        self.maximumUniqueVoxelUpdatesPerFrame = maximumUniqueVoxelUpdatesPerFrame
        self.maximumRaySteps = maximumRaySteps
        self.minimumConfidence = minimumConfidence
        self.minimumDepthMeters = minimumDepthMeters
        self.maximumDepthMeters = maximumDepthMeters
        self.maximumVoxelWeight = maximumVoxelWeight
        self.qualityProfile = qualityProfile
        self.minimumConsistentNeighborCount = minimumConsistentNeighborCount
        self.absoluteNeighborToleranceMeters = absoluteNeighborToleranceMeters
        self.relativeNeighborTolerance = relativeNeighborTolerance
        self.preservesSparseObservations = preservesSparseObservations
    }

    private enum CodingKeys: String, CodingKey {
        case voxelSizeMeters, truncationDistanceMeters, submapVoxelDimension
        case depthPixelStride, maximumRaysPerFrame, maximumUniqueVoxelUpdatesPerFrame
        case maximumRaySteps, minimumConfidence, minimumDepthMeters, maximumDepthMeters
        case maximumVoxelWeight, qualityProfile, minimumConsistentNeighborCount
        case absoluteNeighborToleranceMeters, relativeNeighborTolerance
        case preservesSparseObservations
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            voxelSizeMeters: values.decode(Float.self, forKey: .voxelSizeMeters),
            truncationDistanceMeters: values.decode(Float.self, forKey: .truncationDistanceMeters),
            submapVoxelDimension: values.decode(Int.self, forKey: .submapVoxelDimension),
            depthPixelStride: values.decode(Int.self, forKey: .depthPixelStride),
            maximumRaysPerFrame: values.decode(Int.self, forKey: .maximumRaysPerFrame),
            maximumUniqueVoxelUpdatesPerFrame: values.decode(Int.self, forKey: .maximumUniqueVoxelUpdatesPerFrame),
            maximumRaySteps: values.decode(Int.self, forKey: .maximumRaySteps),
            minimumConfidence: values.decode(UInt8.self, forKey: .minimumConfidence),
            minimumDepthMeters: values.decode(Float.self, forKey: .minimumDepthMeters),
            maximumDepthMeters: values.decode(Float.self, forKey: .maximumDepthMeters),
            maximumVoxelWeight: values.decode(Float.self, forKey: .maximumVoxelWeight),
            qualityProfile: values.decodeIfPresent(
                TSDFReconstructionQualityProfile.self,
                forKey: .qualityProfile
            ) ?? .legacyV1,
            minimumConsistentNeighborCount: values.decodeIfPresent(
                Int.self,
                forKey: .minimumConsistentNeighborCount
            ) ?? 0,
            absoluteNeighborToleranceMeters: values.decodeIfPresent(
                Float.self,
                forKey: .absoluteNeighborToleranceMeters
            ) ?? 0.08,
            relativeNeighborTolerance: values.decodeIfPresent(
                Float.self,
                forKey: .relativeNeighborTolerance
            ) ?? 0.025,
            preservesSparseObservations: values.decodeIfPresent(
                Bool.self,
                forKey: .preservesSparseObservations
            ) ?? true
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(voxelSizeMeters, forKey: .voxelSizeMeters)
        try values.encode(truncationDistanceMeters, forKey: .truncationDistanceMeters)
        try values.encode(submapVoxelDimension, forKey: .submapVoxelDimension)
        try values.encode(depthPixelStride, forKey: .depthPixelStride)
        try values.encode(maximumRaysPerFrame, forKey: .maximumRaysPerFrame)
        try values.encode(maximumUniqueVoxelUpdatesPerFrame, forKey: .maximumUniqueVoxelUpdatesPerFrame)
        try values.encode(maximumRaySteps, forKey: .maximumRaySteps)
        try values.encode(minimumConfidence, forKey: .minimumConfidence)
        try values.encode(minimumDepthMeters, forKey: .minimumDepthMeters)
        try values.encode(maximumDepthMeters, forKey: .maximumDepthMeters)
        try values.encode(maximumVoxelWeight, forKey: .maximumVoxelWeight)
        try values.encode(qualityProfile, forKey: .qualityProfile)
        try values.encode(minimumConsistentNeighborCount, forKey: .minimumConsistentNeighborCount)
        try values.encode(absoluteNeighborToleranceMeters, forKey: .absoluteNeighborToleranceMeters)
        try values.encode(relativeNeighborTolerance, forKey: .relativeNeighborTolerance)
        try values.encode(preservesSparseObservations, forKey: .preservesSparseObservations)
    }
}

public extension TSDFReconstructionConfiguration {
    /// Applies the exact per-pixel admission policy used before production TSDF
    /// ray integration. Benchmark diagnostics call this same implementation so
    /// an "admitted source" population cannot drift from reconstruction.
    func depthSampleRejection(
        depth: Float,
        confidence: UInt8,
        x: Int,
        y: Int,
        sample: DepthFrameSample
    ) -> TSDFDepthSampleRejection? {
        guard depth.isFinite else { return .nonFinite }
        guard depth >= minimumDepthMeters else { return .belowMinimum }
        guard depth <= maximumDepthMeters else { return .aboveMaximum }
        guard confidence >= minimumConfidence else { return .lowConfidence }
        guard minimumConsistentNeighborCount > 0 else { return nil }

        let tolerance = absoluteNeighborToleranceMeters + relativeNeighborTolerance * depth
        var plausibleNeighborCount = 0
        var consistentNeighborCount = 0
        for offsetY in -1...1 {
            for offsetX in -1...1 where offsetX != 0 || offsetY != 0 {
                let neighborX = x + offsetX
                let neighborY = y + offsetY
                guard neighborX >= 0,
                      neighborX < sample.width,
                      neighborY >= 0,
                      neighborY < sample.height
                else { continue }
                let index = neighborY * sample.width + neighborX
                let neighborDepth = sample.depthMeters[index]
                guard neighborDepth.isFinite,
                      neighborDepth >= minimumDepthMeters,
                      neighborDepth <= maximumDepthMeters,
                      sample.confidence[index] >= minimumConfidence
                else { continue }
                plausibleNeighborCount += 1
                if abs(neighborDepth - depth) <= tolerance {
                    consistentNeighborCount += 1
                }
            }
        }
        if plausibleNeighborCount == 0, preservesSparseObservations { return nil }
        return consistentNeighborCount >= minimumConsistentNeighborCount
            ? nil
            : .neighborInconsistent
    }
}

public struct TSDFSubmapKey: Codable, Equatable, Hashable, Comparable, Sendable {
    public var x: Int64
    public var y: Int64
    public var z: Int64

    public init(x: Int64, y: Int64, z: Int64) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.z < rhs.z
    }
}

public struct TSDFGlobalVoxelCoordinate: Codable, Equatable, Hashable, Comparable, Sendable {
    public var x: Int64
    public var y: Int64
    public var z: Int64

    public init(x: Int64, y: Int64, z: Int64) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.z < rhs.z
    }
}

public struct TSDFVoxel: Equatable, Sendable {
    public var signedDistance: Float
    public var weight: Float
    public var color: PointCloudColor?
    /// Number of distinct accepted keyframes that contributed to this voxel.
    /// Legacy in-memory fixtures predate support accounting and use two so they
    /// retain their historical extraction behavior; reconstructed voxels carry
    /// the exact count accumulated from per-frame deltas.
    public var supportingFrameCount: Int

    public init(
        signedDistance: Float,
        weight: Float,
        color: PointCloudColor? = nil,
        supportingFrameCount: Int = 2
    ) {
        self.signedDistance = signedDistance
        self.weight = weight
        self.color = color
        self.supportingFrameCount = supportingFrameCount
    }
}

public struct TSDFSubmap: Sendable {
    public var key: TSDFSubmapKey
    public var voxelDimension: Int
    public var voxelsByLocalIndex: [Int: TSDFVoxel]

    public init(key: TSDFSubmapKey, voxelDimension: Int, voxelsByLocalIndex: [Int: TSDFVoxel]) {
        self.key = key
        self.voxelDimension = voxelDimension
        self.voxelsByLocalIndex = voxelsByLocalIndex
    }
}

public struct TSDFDepthRejectionStatistics: Codable, Equatable, Sendable {
    public var nonFinite: Int
    public var belowMinimumDepth: Int
    public var aboveMaximumDepth: Int
    public var lowConfidence: Int
    public var neighborInconsistent: Int
    public var invalidRay: Int

    public init(
        nonFinite: Int = 0,
        belowMinimumDepth: Int = 0,
        aboveMaximumDepth: Int = 0,
        lowConfidence: Int = 0,
        neighborInconsistent: Int = 0,
        invalidRay: Int = 0
    ) {
        self.nonFinite = nonFinite
        self.belowMinimumDepth = belowMinimumDepth
        self.aboveMaximumDepth = aboveMaximumDepth
        self.lowConfidence = lowConfidence
        self.neighborInconsistent = neighborInconsistent
        self.invalidRay = invalidRay
    }

    fileprivate mutating func add(_ other: Self) -> Bool {
        let values = [
            nonFinite.addingReportingOverflow(other.nonFinite),
            belowMinimumDepth.addingReportingOverflow(other.belowMinimumDepth),
            aboveMaximumDepth.addingReportingOverflow(other.aboveMaximumDepth),
            lowConfidence.addingReportingOverflow(other.lowConfidence),
            neighborInconsistent.addingReportingOverflow(other.neighborInconsistent),
            invalidRay.addingReportingOverflow(other.invalidRay)
        ]
        guard values.allSatisfy({ !$0.overflow }) else { return false }
        nonFinite = values[0].partialValue
        belowMinimumDepth = values[1].partialValue
        aboveMaximumDepth = values[2].partialValue
        lowConfidence = values[3].partialValue
        neighborInconsistent = values[4].partialValue
        invalidRay = values[5].partialValue
        return true
    }
}

public struct TSDFReconstructionStatistics: Codable, Equatable, Sendable {
    public var processedFrameCount: Int
    public var integratedRayCount: Int
    public var updatedVoxelContributionCount: Int
    public var rejectedDepthSampleCount: Int
    public var droppedVoxelUpdateCount: Int
    public var rayLimitReachedFrameCount: Int
    public var depthRejections: TSDFDepthRejectionStatistics?

    public init(
        processedFrameCount: Int = 0,
        integratedRayCount: Int = 0,
        updatedVoxelContributionCount: Int = 0,
        rejectedDepthSampleCount: Int = 0,
        droppedVoxelUpdateCount: Int = 0,
        rayLimitReachedFrameCount: Int = 0,
        depthRejections: TSDFDepthRejectionStatistics? = .init()
    ) {
        self.processedFrameCount = processedFrameCount
        self.integratedRayCount = integratedRayCount
        self.updatedVoxelContributionCount = updatedVoxelContributionCount
        self.rejectedDepthSampleCount = rejectedDepthSampleCount
        self.droppedVoxelUpdateCount = droppedVoxelUpdateCount
        self.rayLimitReachedFrameCount = rayLimitReachedFrameCount
        self.depthRejections = depthRejections
    }

    fileprivate mutating func add(_ other: TSDFReconstructionStatistics) -> Bool {
        let values = [
            processedFrameCount.addingReportingOverflow(other.processedFrameCount),
            integratedRayCount.addingReportingOverflow(other.integratedRayCount),
            updatedVoxelContributionCount.addingReportingOverflow(other.updatedVoxelContributionCount),
            rejectedDepthSampleCount.addingReportingOverflow(other.rejectedDepthSampleCount),
            droppedVoxelUpdateCount.addingReportingOverflow(other.droppedVoxelUpdateCount),
            rayLimitReachedFrameCount.addingReportingOverflow(other.rayLimitReachedFrameCount)
        ]
        guard values.allSatisfy({ !$0.overflow }) else { return false }
        var combinedRejections = depthRejections ?? .init()
        guard combinedRejections.add(other.depthRejections ?? .init()) else { return false }
        processedFrameCount = values[0].partialValue
        integratedRayCount = values[1].partialValue
        updatedVoxelContributionCount = values[2].partialValue
        rejectedDepthSampleCount = values[3].partialValue
        droppedVoxelUpdateCount = values[4].partialValue
        rayLimitReachedFrameCount = values[5].partialValue
        depthRejections = combinedRejections
        return true
    }
}

public struct TSDFReconstructionState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var source: TSDFReconstructionSource
    public var configuration: TSDFReconstructionConfiguration
    public var nextFrameIndex: Int
    public var submapKeys: [TSDFSubmapKey]
    public var statistics: TSDFReconstructionStatistics

    public init(
        source: TSDFReconstructionSource,
        configuration: TSDFReconstructionConfiguration,
        nextFrameIndex: Int = 1,
        submapKeys: [TSDFSubmapKey] = [],
        statistics: TSDFReconstructionStatistics = .init()
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.source = source
        self.configuration = configuration
        self.nextFrameIndex = nextFrameIndex
        self.submapKeys = submapKeys
        self.statistics = statistics
    }
}

public struct TSDFCompletedPrefixIdentity: Codable, Equatable, Sendable {
    public var source: TSDFReconstructionSource
    public var configuration: TSDFReconstructionConfiguration
    public var completedFrameCount: Int
    public var sha256: String

    public init(
        source: TSDFReconstructionSource,
        configuration: TSDFReconstructionConfiguration,
        completedFrameCount: Int,
        sha256: String
    ) {
        self.source = source
        self.configuration = configuration
        self.completedFrameCount = completedFrameCount
        self.sha256 = sha256
    }
}

public struct TSDFExtractionSnapshot: Codable, Equatable, Sendable {
    public var prefix: TSDFCompletedPrefixIdentity
    public var submapKeys: [TSDFSubmapKey]
    public var statistics: TSDFReconstructionStatistics

    public init(
        prefix: TSDFCompletedPrefixIdentity,
        submapKeys: [TSDFSubmapKey],
        statistics: TSDFReconstructionStatistics
    ) {
        self.prefix = prefix
        self.submapKeys = submapKeys
        self.statistics = statistics
    }
}

public struct TSDFSubmapNeighborhood: Sendable {
    public var key: TSDFSubmapKey
    public var voxelDimension: Int
    public var haloWidth: Int
    public var voxelsByGlobalCoordinate: [TSDFGlobalVoxelCoordinate: TSDFVoxel]

    public init(
        key: TSDFSubmapKey,
        voxelDimension: Int,
        haloWidth: Int = 1,
        voxelsByGlobalCoordinate: [TSDFGlobalVoxelCoordinate: TSDFVoxel]
    ) {
        self.key = key
        self.voxelDimension = voxelDimension
        self.haloWidth = haloWidth
        self.voxelsByGlobalCoordinate = voxelsByGlobalCoordinate
    }
}

public protocol TSDFSurfaceExtractionSource: Sendable {
    func makeExtractionSnapshot() async throws -> TSDFExtractionSnapshot
    func loadSubmapWithOneVoxelHalo(
        _ key: TSDFSubmapKey,
        from snapshot: TSDFExtractionSnapshot
    ) async throws -> TSDFSubmapNeighborhood
}

private struct TSDFCompletedFrame: Codable, Sendable {
    var schemaVersion: Int
    var frameIndex: Int
    var source: TSDFReconstructionSource
    var configuration: TSDFReconstructionConfiguration
    var submapKeys: [TSDFSubmapKey]
    var statistics: TSDFReconstructionStatistics
}

private struct TSDFCompletedPrefixSeed: Codable, Sendable {
    var source: TSDFReconstructionSource
    var configuration: TSDFReconstructionConfiguration
    var completedFrameCount: Int
}

private struct TSDFContributionAccumulator: Sendable {
    var signedDistanceWeightSum: Float = 0
    var weight: Float = 0
    var redWeightSum: Float = 0
    var greenWeightSum: Float = 0
    var blueWeightSum: Float = 0
    var colorWeight: Float = 0
    var supportingFrameCount: Int = 0

    mutating func add(signedDistance: Float, weight: Float, color: PointCloudColor?) {
        signedDistanceWeightSum += signedDistance * weight
        self.weight += weight
        if let color {
            redWeightSum += Float(color.red) * weight
            greenWeightSum += Float(color.green) * weight
            blueWeightSum += Float(color.blue) * weight
            colorWeight += weight
        }
    }

    mutating func add(_ contribution: TSDFContribution) {
        signedDistanceWeightSum += contribution.signedDistance * contribution.weight
        weight += contribution.weight
        if let color = contribution.color, contribution.colorWeight > 0 {
            redWeightSum += Float(color.red) * contribution.colorWeight
            greenWeightSum += Float(color.green) * contribution.colorWeight
            blueWeightSum += Float(color.blue) * contribution.colorWeight
            colorWeight += contribution.colorWeight
        }
        supportingFrameCount += max(1, contribution.supportingFrameCount)
    }

    var contribution: TSDFContribution {
        let color = colorWeight > 0
            ? PointCloudColor(
                red: UInt8(clamping: Int((redWeightSum / colorWeight).rounded())),
                green: UInt8(clamping: Int((greenWeightSum / colorWeight).rounded())),
                blue: UInt8(clamping: Int((blueWeightSum / colorWeight).rounded()))
            )
            : nil
        return TSDFContribution(
            signedDistance: signedDistanceWeightSum / max(weight, .leastNonzeroMagnitude),
            weight: weight,
            color: color,
            colorWeight: colorWeight,
            supportingFrameCount: supportingFrameCount
        )
    }
}

private struct TSDFContribution: Sendable {
    var signedDistance: Float
    var weight: Float
    var color: PointCloudColor?
    var colorWeight: Float
    var supportingFrameCount: Int
}

/// Owns one derived reconstruction workspace. Source package files are read by
/// the caller and never modified by this actor.
public actor ChunkedTSDFReconstructor {
    private static let stateFilename = "reconstruction-state.json"
    private static let deltaMagic = Data("STRTSDFD".utf8)
    private static let deltaVersion: UInt32 = 1
    private static let deltaHeaderByteCount = 20
    private static let deltaRecordByteCount = 24

    private let outputDirectory: URL
    private let framesDirectory: URL
    private let submapsDirectory: URL
    private let source: TSDFReconstructionSource
    private let configuration: TSDFReconstructionConfiguration
    private var state: TSDFReconstructionState
    private var verifiedExtractionPrefix: TSDFCompletedPrefixIdentity?
    private var verifiedDeltaSHA256ByPath: [String: String] = [:]
    private var verifiedMarkerSHA256ByPath: [String: String] = [:]

    public init(
        outputDirectory: URL,
        source: TSDFReconstructionSource,
        configuration: TSDFReconstructionConfiguration = .default,
        fileManager: FileManager = .default
    ) throws {
        self.outputDirectory = outputDirectory
        framesDirectory = outputDirectory.appending(path: "frames", directoryHint: .isDirectory)
        submapsDirectory = outputDirectory.appending(path: "submaps", directoryHint: .isDirectory)
        self.source = source
        self.configuration = configuration
        do {
            try fileManager.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: submapsDirectory, withIntermediateDirectories: true)
            let stateURL = outputDirectory.appending(path: Self.stateFilename)
            if fileManager.fileExists(atPath: stateURL.path) {
                let decoded = try JSONDecoder().decode(
                    TSDFReconstructionState.self,
                    from: Data(contentsOf: stateURL)
                )
                guard decoded.schemaVersion == TSDFReconstructionState.currentSchemaVersion else {
                    throw TSDFReconstructionError.invalidFile(Self.stateFilename)
                }
                guard decoded.source == source else { throw TSDFReconstructionError.sourceMismatch }
                guard decoded.configuration == configuration else {
                    throw TSDFReconstructionError.configurationMismatch
                }
            }
            state = try Self.recoveredState(
                framesDirectory: framesDirectory,
                source: source,
                configuration: configuration,
                fileManager: fileManager
            )
            try Self.writeState(state, to: stateURL)
        } catch let error as TSDFReconstructionError {
            throw error
        } catch {
            throw TSDFReconstructionError.ioFailure(error.localizedDescription)
        }
    }

    public func currentState() -> TSDFReconstructionState {
        state
    }

    public func makeExtractionSnapshot() throws -> TSDFExtractionSnapshot {
        let completedFrameCount = state.nextFrameIndex - 1
        let seed = TSDFCompletedPrefixSeed(
            source: source,
            configuration: configuration,
            completedFrameCount: completedFrameCount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var hasher = SHA256()
        hasher.update(data: try encoder.encode(seed))
        var deltaHashes: [String: String] = [:]
        var markerHashes: [String: String] = [:]

        if completedFrameCount > 0 {
            for frameIndex in 1...completedFrameCount {
                try Task.checkCancellation()
                let marker = try validatedMarker(frameIndex: frameIndex)
                guard marker.submapKeys == marker.submapKeys.sorted(),
                      Set(marker.submapKeys).count == marker.submapKeys.count
                else {
                    throw TSDFReconstructionError.invalidFile(
                        completionMarkerURL(frameIndex: frameIndex).lastPathComponent
                    )
                }
                let markerData = try encoder.encode(marker)
                markerHashes[completionMarkerURL(frameIndex: frameIndex).path] = Self.sha256(markerData)
                hasher.update(data: markerData)
                for key in marker.submapKeys {
                    let deltaURL = deltaURL(submapKey: key, frameIndex: frameIndex)
                    let data = try data(at: deltaURL)
                    _ = try readDelta(data, filename: deltaURL.lastPathComponent)
                    let digest = Self.sha256(data)
                    deltaHashes[deltaURL.path] = digest
                    hasher.update(data: Data(deltaURL.lastPathComponent.utf8))
                    hasher.update(data: Data(digest.utf8))
                }
            }
        }

        let identity = TSDFCompletedPrefixIdentity(
            source: source,
            configuration: configuration,
            completedFrameCount: completedFrameCount,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
        verifiedExtractionPrefix = identity
        verifiedDeltaSHA256ByPath = deltaHashes
        verifiedMarkerSHA256ByPath = markerHashes
        return TSDFExtractionSnapshot(
            prefix: identity,
            submapKeys: state.submapKeys,
            statistics: state.statistics
        )
    }

    public func loadSubmapWithOneVoxelHalo(
        _ key: TSDFSubmapKey,
        from snapshot: TSDFExtractionSnapshot
    ) throws -> TSDFSubmapNeighborhood {
        if verifiedExtractionPrefix != snapshot.prefix {
            guard try makeExtractionSnapshot().prefix == snapshot.prefix else {
                throw TSDFReconstructionError.sourceMismatch
            }
        }
        let dimension = Int64(configuration.submapVoxelDimension)
        guard let coreX = Self.checkedMultiply(key.x, dimension),
              let coreY = Self.checkedMultiply(key.y, dimension),
              let coreZ = Self.checkedMultiply(key.z, dimension),
              let minimumX = Self.checkedAdd(coreX, -1),
              let minimumY = Self.checkedAdd(coreY, -1),
              let minimumZ = Self.checkedAdd(coreZ, -1),
              let maximumX = Self.checkedAdd(coreX, dimension),
              let maximumY = Self.checkedAdd(coreY, dimension),
              let maximumZ = Self.checkedAdd(coreZ, dimension)
        else {
            throw TSDFReconstructionError.invalidConfiguration
        }
        let relevantKeys = Set(snapshot.submapKeys.filter {
            Self.isSameOrAdjacent($0.x, key.x)
                && Self.isSameOrAdjacent($0.y, key.y)
                && Self.isSameOrAdjacent($0.z, key.z)
        })
        var accumulators: [TSDFGlobalVoxelCoordinate: TSDFContributionAccumulator] = [:]

        if snapshot.prefix.completedFrameCount > 0 {
            for frameIndex in 1...snapshot.prefix.completedFrameCount {
                try Task.checkCancellation()
                let marker = try validatedMarker(frameIndex: frameIndex)
                let markerData = try encoderData(marker)
                guard verifiedMarkerSHA256ByPath[completionMarkerURL(frameIndex: frameIndex).path]
                    == Self.sha256(markerData)
                else {
                    throw TSDFReconstructionError.invalidFile(
                        completionMarkerURL(frameIndex: frameIndex).lastPathComponent
                    )
                }
                for submapKey in marker.submapKeys where relevantKeys.contains(submapKey) {
                    let deltaURL = deltaURL(submapKey: submapKey, frameIndex: frameIndex)
                    let data = try data(at: deltaURL)
                    guard verifiedDeltaSHA256ByPath[deltaURL.path] == Self.sha256(data) else {
                        throw TSDFReconstructionError.invalidFile(deltaURL.lastPathComponent)
                    }
                    for (localIndex, contribution) in try readDelta(
                        data,
                        filename: deltaURL.lastPathComponent
                    ) {
                        guard let coordinate = Self.globalCoordinate(
                            submapKey: submapKey,
                            localIndex: localIndex,
                            dimension: configuration.submapVoxelDimension
                        ),
                              coordinate.x >= minimumX,
                              coordinate.x <= maximumX,
                              coordinate.y >= minimumY,
                              coordinate.y <= maximumY,
                              coordinate.z >= minimumZ,
                              coordinate.z <= maximumZ
                        else { continue }
                        var accumulator = accumulators[coordinate] ?? .init()
                        accumulator.add(contribution)
                        accumulators[coordinate] = accumulator
                    }
                }
            }
        }

        return TSDFSubmapNeighborhood(
            key: key,
            voxelDimension: configuration.submapVoxelDimension,
            voxelsByGlobalCoordinate: accumulators.mapValues { accumulator in
                let contribution = accumulator.contribution
                return TSDFVoxel(
                    signedDistance: contribution.signedDistance,
                    weight: min(contribution.weight, configuration.maximumVoxelWeight),
                    color: contribution.color,
                    supportingFrameCount: contribution.supportingFrameCount
                )
            }
        )
    }

    @discardableResult
    public func integrate(
        _ keyframe: CalibratedRGBDKeyframe,
        frameIndex: Int
    ) throws -> TSDFReconstructionState {
        if frameIndex < state.nextFrameIndex {
            return state
        }
        guard frameIndex == state.nextFrameIndex else {
            throw TSDFReconstructionError.unexpectedFrameIndex(
                expected: state.nextFrameIndex,
                actual: frameIndex
            )
        }
        guard frameIndex <= source.keyframeCount,
              keyframe.record.index == frameIndex
        else {
            throw TSDFReconstructionError.sourceFrameMismatch(
                expected: frameIndex,
                actual: keyframe.record.index
            )
        }
        try Task.checkCancellation()
        let result = try contributions(for: keyframe.depth)
        var keys: [TSDFSubmapKey] = []
        for key in result.contributionsBySubmap.keys.sorted(by: Self.submapKeyLessThan) {
            try Task.checkCancellation()
            guard let contributions = result.contributionsBySubmap[key] else { continue }
            try writeDelta(contributions, submapKey: key, frameIndex: frameIndex)
            keys.append(key)
        }

        let marker = TSDFCompletedFrame(
            schemaVersion: TSDFReconstructionState.currentSchemaVersion,
            frameIndex: frameIndex,
            source: source,
            configuration: configuration,
            submapKeys: keys,
            statistics: result.statistics
        )
        try Self.writeJSON(marker, to: completionMarkerURL(frameIndex: frameIndex))
        verifiedExtractionPrefix = nil
        verifiedDeltaSHA256ByPath = [:]
        verifiedMarkerSHA256ByPath = [:]
        state = try Self.recoveredState(
            framesDirectory: framesDirectory,
            source: source,
            configuration: configuration,
            fileManager: .default
        )
        try Self.writeState(state, to: outputDirectory.appending(path: Self.stateFilename))
        return state
    }

    public func loadSubmap(_ key: TSDFSubmapKey) throws -> TSDFSubmap {
        let directory = submapDirectory(for: key)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return TSDFSubmap(key: key, voxelDimension: configuration.submapVoxelDimension, voxelsByLocalIndex: [:])
        }
        let files: [URL]
        do {
            let candidates = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
            var completedFrames = Set<Int>()
            for url in candidates where url.pathExtension == "delta" {
                guard let frameIndex = Self.deltaFrameIndex(from: url.lastPathComponent),
                      frameIndex < state.nextFrameIndex,
                      !completedFrames.contains(frameIndex)
                else { continue }
                let marker = try JSONDecoder().decode(
                    TSDFCompletedFrame.self,
                    from: Data(contentsOf: completionMarkerURL(frameIndex: frameIndex))
                )
                if marker.submapKeys.contains(key) {
                    completedFrames.insert(frameIndex)
                }
            }
            files = candidates.filter { url in
                guard let frameIndex = Self.deltaFrameIndex(from: url.lastPathComponent) else {
                    return false
                }
                return completedFrames.contains(frameIndex)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw TSDFReconstructionError.ioFailure(error.localizedDescription)
        }

        var accumulators: [Int: TSDFContributionAccumulator] = [:]
        for file in files {
            for (localIndex, contribution) in try readDelta(file) {
                var accumulator = accumulators[localIndex] ?? .init()
                accumulator.add(contribution)
                accumulators[localIndex] = accumulator
            }
        }
        let voxels = accumulators.mapValues { accumulator in
            let contribution = accumulator.contribution
            return TSDFVoxel(
                signedDistance: contribution.signedDistance,
                weight: min(contribution.weight, configuration.maximumVoxelWeight),
                color: contribution.color,
                supportingFrameCount: contribution.supportingFrameCount
            )
        }
        return TSDFSubmap(
            key: key,
            voxelDimension: configuration.submapVoxelDimension,
            voxelsByLocalIndex: voxels
        )
    }

    private func contributions(
        for sample: DepthFrameSample
    ) throws -> (
        contributionsBySubmap: [TSDFSubmapKey: [Int: TSDFContribution]],
        statistics: TSDFReconstructionStatistics
    ) {
        let intrinsics = sample.calibration.scaled(toWidth: sample.width, height: sample.height)
        guard sample.width > 0,
              sample.height > 0,
              sample.depthMeters.count == sample.width * sample.height,
              sample.confidence.count == sample.width * sample.height,
              intrinsics.fx.isFinite,
              intrinsics.fy.isFinite,
              intrinsics.fx > 0,
              intrinsics.fy > 0,
              sample.worldFromCamera.columns.allSatisfy(\.isFinite)
        else {
            throw TSDFReconstructionError.invalidFile("keyframe-\(sample.timestamp)")
        }

        let origin = Point3D(
            x: sample.worldFromCamera.columns[12],
            y: sample.worldFromCamera.columns[13],
            z: sample.worldFromCamera.columns[14]
        )
        var accumulators: [TSDFGlobalVoxelCoordinate: TSDFContributionAccumulator] = [:]
        accumulators.reserveCapacity(min(configuration.maximumUniqueVoxelUpdatesPerFrame, 16_384))
        var statistics = TSDFReconstructionStatistics(processedFrameCount: 1)
        var reachedRayLimit = false
        var processedRayCount = 0

        rayRows: for y in stride(from: 0, to: sample.height, by: configuration.depthPixelStride) {
            for x in stride(from: 0, to: sample.width, by: configuration.depthPixelStride) {
                try Task.checkCancellation()
                if processedRayCount >= configuration.maximumRaysPerFrame {
                    reachedRayLimit = true
                    break rayRows
                }
                let pixelIndex = y * sample.width + x
                let depth = sample.depthMeters[pixelIndex]
                let confidence = sample.confidence[pixelIndex]
                if let rejection = depthRejection(
                    depth: depth,
                    confidence: confidence,
                    x: x,
                    y: y,
                    sample: sample
                ) {
                    record(rejection, in: &statistics)
                    continue
                }
                processedRayCount += 1
                let cameraPoint = Point3D(
                    x: -((Float(x) - intrinsics.cx) / intrinsics.fx) * depth,
                    y: -((Float(y) - intrinsics.cy) / intrinsics.fy) * depth,
                    z: -depth
                )
                let surface = sample.worldFromCamera.applying(to: cameraPoint)
                let dx = surface.x - origin.x
                let dy = surface.y - origin.y
                let dz = surface.z - origin.z
                let surfaceDistance = sqrt(dx * dx + dy * dy + dz * dz)
                guard surfaceDistance.isFinite, surfaceDistance > 0 else {
                    record(.invalidRay, in: &statistics)
                    continue
                }
                let direction = Point3D(
                    x: dx / surfaceDistance,
                    y: dy / surfaceDistance,
                    z: dz / surfaceDistance
                )
                let radiusSteps = min(
                    (configuration.maximumRaySteps - 1) / 2,
                    Int(ceil(configuration.truncationDistanceMeters / configuration.voxelSizeMeters))
                )
                var didUpdateRay = false
                for step in (-radiusSteps)...radiusSteps {
                    let distance = surfaceDistance + Float(step) * configuration.voxelSizeMeters
                    guard distance > 0 else { continue }
                    let position = Point3D(
                        x: origin.x + direction.x * distance,
                        y: origin.y + direction.y * distance,
                        z: origin.z + direction.z * distance
                    )
                    guard let coordinate = voxelCoordinate(for: position) else { continue }
                    if accumulators[coordinate] == nil,
                       accumulators.count >= configuration.maximumUniqueVoxelUpdatesPerFrame {
                        statistics.droppedVoxelUpdateCount += 1
                        continue
                    }
                    let center = voxelCenter(for: coordinate)
                    let centerDistance = (center.x - origin.x) * direction.x
                        + (center.y - origin.y) * direction.y
                        + (center.z - origin.z) * direction.z
                    let signedDistanceMeters = surfaceDistance - centerDistance
                    let normalizedDistance = min(
                        1,
                        max(-1, signedDistanceMeters / configuration.truncationDistanceMeters)
                    )
                    let color = abs(signedDistanceMeters) <= configuration.voxelSizeMeters * 0.51
                        ? sample.observedColor(at: PixelCoordinate(x: x, y: y))
                        : nil
                    var accumulator = accumulators[coordinate] ?? .init()
                    accumulator.add(
                        signedDistance: normalizedDistance,
                        weight: Float(confidence) + 1,
                        color: color
                    )
                    accumulators[coordinate] = accumulator
                    didUpdateRay = true
                }
                if didUpdateRay {
                    statistics.integratedRayCount += 1
                }
            }
        }
        if reachedRayLimit {
            statistics.rayLimitReachedFrameCount = 1
        }

        var grouped: [TSDFSubmapKey: [Int: TSDFContribution]] = [:]
        for coordinate in accumulators.keys.sorted() {
            guard let accumulator = accumulators[coordinate] else { continue }
            let address = submapAddress(for: coordinate)
            grouped[address.key, default: [:]][address.localIndex] = accumulator.contribution
        }
        statistics.updatedVoxelContributionCount = accumulators.count
        return (grouped, statistics)
    }

    private func depthRejection(
        depth: Float,
        confidence: UInt8,
        x: Int,
        y: Int,
        sample: DepthFrameSample
    ) -> TSDFDepthSampleRejection? {
        configuration.depthSampleRejection(
            depth: depth,
            confidence: confidence,
            x: x,
            y: y,
            sample: sample
        )
    }

    private func record(
        _ rejection: TSDFDepthSampleRejection,
        in statistics: inout TSDFReconstructionStatistics
    ) {
        statistics.rejectedDepthSampleCount += 1
        var rejections = statistics.depthRejections ?? .init()
        switch rejection {
        case .nonFinite:
            rejections.nonFinite += 1
        case .belowMinimum:
            rejections.belowMinimumDepth += 1
        case .aboveMaximum:
            rejections.aboveMaximumDepth += 1
        case .lowConfidence:
            rejections.lowConfidence += 1
        case .neighborInconsistent:
            rejections.neighborInconsistent += 1
        case .invalidRay:
            rejections.invalidRay += 1
        }
        statistics.depthRejections = rejections
    }

    private func voxelCoordinate(for position: Point3D) -> TSDFGlobalVoxelCoordinate? {
        func coordinate(_ value: Float) -> Int64? {
            let scaled = floor(Double(value) / Double(configuration.voxelSizeMeters))
            guard scaled.isFinite,
                  scaled >= Double(Int64.min),
                  scaled < Double(Int64.max)
            else { return nil }
            return Int64(scaled)
        }
        guard let x = coordinate(position.x),
              let y = coordinate(position.y),
              let z = coordinate(position.z)
        else { return nil }
        return TSDFGlobalVoxelCoordinate(x: x, y: y, z: z)
    }

    private func voxelCenter(for coordinate: TSDFGlobalVoxelCoordinate) -> Point3D {
        let size = Double(configuration.voxelSizeMeters)
        return Point3D(
            x: Float((Double(coordinate.x) + 0.5) * size),
            y: Float((Double(coordinate.y) + 0.5) * size),
            z: Float((Double(coordinate.z) + 0.5) * size)
        )
    }

    private func submapAddress(
        for coordinate: TSDFGlobalVoxelCoordinate
    ) -> (key: TSDFSubmapKey, localIndex: Int) {
        let dimension = Int64(configuration.submapVoxelDimension)
        let submapX = Self.floorDivision(coordinate.x, by: dimension)
        let submapY = Self.floorDivision(coordinate.y, by: dimension)
        let submapZ = Self.floorDivision(coordinate.z, by: dimension)
        let localX = Int(coordinate.x - submapX * dimension)
        let localY = Int(coordinate.y - submapY * dimension)
        let localZ = Int(coordinate.z - submapZ * dimension)
        return (
            TSDFSubmapKey(x: submapX, y: submapY, z: submapZ),
            (localZ * configuration.submapVoxelDimension + localY)
                * configuration.submapVoxelDimension + localX
        )
    }

    private func writeDelta(
        _ contributions: [Int: TSDFContribution],
        submapKey: TSDFSubmapKey,
        frameIndex: Int
    ) throws {
        let directory = submapDirectory(for: submapKey)
        let destination = directory.appending(
            path: "frame-\(String(format: "%06d", frameIndex)).delta"
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var data = Self.deltaMagic
            data.appendLittleEndianTSDF(Self.deltaVersion)
            data.appendLittleEndianTSDF(UInt32(configuration.submapVoxelDimension))
            data.appendLittleEndianTSDF(UInt32(contributions.count))
            for localIndex in contributions.keys.sorted() {
                guard let contribution = contributions[localIndex],
                      let localIndexValue = UInt32(exactly: localIndex)
                else {
                    throw TSDFReconstructionError.invalidFile(destination.lastPathComponent)
                }
                data.appendLittleEndianTSDF(localIndexValue)
                data.appendLittleEndianTSDF(contribution.signedDistance.bitPattern)
                let boundedWeight = min(contribution.weight, configuration.maximumVoxelWeight)
                let boundedColorWeight = min(contribution.colorWeight, boundedWeight)
                data.appendLittleEndianTSDF(boundedWeight.bitPattern)
                data.append(contribution.color?.red ?? 0)
                data.append(contribution.color?.green ?? 0)
                data.append(contribution.color?.blue ?? 0)
                data.append(contribution.color == nil ? 0 : 1)
                data.appendLittleEndianTSDF(boundedColorWeight.bitPattern)
                data.appendLittleEndianTSDF(0)
            }
            try data.write(to: destination, options: .atomic)
        } catch let error as TSDFReconstructionError {
            throw error
        } catch {
            throw TSDFReconstructionError.ioFailure(error.localizedDescription)
        }
    }

    private func readDelta(_ url: URL) throws -> [(Int, TSDFContribution)] {
        try readDelta(data(at: url), filename: url.lastPathComponent)
    }

    private func readDelta(
        _ data: Data,
        filename: String
    ) throws -> [(Int, TSDFContribution)] {
        guard data.count >= Self.deltaHeaderByteCount,
              data.prefix(Self.deltaMagic.count) == Self.deltaMagic,
              data.readUInt32LittleEndianTSDF(at: 8) == Self.deltaVersion,
              data.readUInt32LittleEndianTSDF(at: 12) == UInt32(configuration.submapVoxelDimension),
              let countValue = data.readUInt32LittleEndianTSDF(at: 16),
              let count = Int(exactly: countValue),
              data.count == Self.deltaHeaderByteCount + count * Self.deltaRecordByteCount
        else {
            throw TSDFReconstructionError.invalidFile(filename)
        }
        var result: [(Int, TSDFContribution)] = []
        result.reserveCapacity(count)
        var previousIndex: Int?
        for recordIndex in 0..<count {
            let offset = Self.deltaHeaderByteCount + recordIndex * Self.deltaRecordByteCount
            guard let localValue = data.readUInt32LittleEndianTSDF(at: offset),
                  let localIndex = Int(exactly: localValue),
                   let distanceBits = data.readUInt32LittleEndianTSDF(at: offset + 4),
                   let weightBits = data.readUInt32LittleEndianTSDF(at: offset + 8),
                   let colorWeightBits = data.readUInt32LittleEndianTSDF(at: offset + 16),
                   data.readUInt32LittleEndianTSDF(at: offset + 20) == 0,
                   localIndex >= 0,
                  localIndex < configuration.submapVoxelDimension
                    * configuration.submapVoxelDimension
                    * configuration.submapVoxelDimension,
                  previousIndex.map({ localIndex > $0 }) ?? true
            else {
                throw TSDFReconstructionError.invalidFile(filename)
            }
            let signedDistance = Float(bitPattern: distanceBits)
            let weight = Float(bitPattern: weightBits)
            let colorWeight = Float(bitPattern: colorWeightBits)
            let colorFlag = data[offset + 15]
            guard signedDistance.isFinite,
                   (-1...1).contains(signedDistance),
                   weight.isFinite,
                   weight > 0,
                   weight <= configuration.maximumVoxelWeight,
                   colorWeight.isFinite,
                   colorFlag <= 1,
                   colorWeight <= weight,
                   colorFlag == 1 ? colorWeight > 0 : colorWeight == 0
            else {
                throw TSDFReconstructionError.invalidFile(filename)
            }
            let hasColor = colorFlag == 1
            let color = hasColor
                ? PointCloudColor(
                    red: data[offset + 12],
                    green: data[offset + 13],
                    blue: data[offset + 14]
                )
                : nil
            result.append((localIndex, TSDFContribution(
                signedDistance: signedDistance,
                weight: weight,
                color: color,
                colorWeight: colorWeight,
                // Delta files are emitted once per voxel per accepted frame.
                supportingFrameCount: 1
            )))
            previousIndex = localIndex
        }
        return result
    }

    private func data(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw TSDFReconstructionError.ioFailure(error.localizedDescription)
        }
    }

    private func validatedMarker(frameIndex: Int) throws -> TSDFCompletedFrame {
        let url = completionMarkerURL(frameIndex: frameIndex)
        let marker: TSDFCompletedFrame
        do {
            marker = try JSONDecoder().decode(TSDFCompletedFrame.self, from: Data(contentsOf: url))
        } catch {
            throw TSDFReconstructionError.invalidFile(url.lastPathComponent)
        }
        guard marker.schemaVersion == TSDFReconstructionState.currentSchemaVersion,
              marker.frameIndex == frameIndex,
              marker.source == source
        else {
            throw TSDFReconstructionError.sourceMismatch
        }
        guard marker.configuration == configuration else {
            throw TSDFReconstructionError.configurationMismatch
        }
        return marker
    }

    private func completionMarkerURL(frameIndex: Int) -> URL {
        framesDirectory.appending(path: "frame-\(String(format: "%06d", frameIndex)).complete.json")
    }

    private func deltaURL(submapKey: TSDFSubmapKey, frameIndex: Int) -> URL {
        submapDirectory(for: submapKey).appending(
            path: "frame-\(String(format: "%06d", frameIndex)).delta"
        )
    }

    private func submapDirectory(for key: TSDFSubmapKey) -> URL {
        submapsDirectory.appending(
            path: "x_\(key.x)_y_\(key.y)_z_\(key.z)",
            directoryHint: .isDirectory
        )
    }

    private static func recoveredState(
        framesDirectory: URL,
        source: TSDFReconstructionSource,
        configuration: TSDFReconstructionConfiguration,
        fileManager: FileManager
    ) throws -> TSDFReconstructionState {
        let urls = try fileManager.contentsOfDirectory(at: framesDirectory, includingPropertiesForKeys: nil)
        var markersByIndex: [Int: URL] = [:]
        for url in urls {
            let name = url.lastPathComponent
            guard name.hasPrefix("frame-"), name.hasSuffix(".complete.json") else { continue }
            let start = name.index(name.startIndex, offsetBy: 6)
            let end = name.index(name.endIndex, offsetBy: -14)
            guard start < end, let index = Int(name[start..<end]), index > 0 else { continue }
            guard markersByIndex.updateValue(url, forKey: index) == nil else {
                throw TSDFReconstructionError.invalidFile(name)
            }
        }
        var nextIndex = 1
        var statistics = TSDFReconstructionStatistics()
        var submapKeys = Set<TSDFSubmapKey>()
        while let url = markersByIndex[nextIndex] {
            let marker = try JSONDecoder().decode(TSDFCompletedFrame.self, from: Data(contentsOf: url))
            guard marker.schemaVersion == TSDFReconstructionState.currentSchemaVersion,
                  marker.frameIndex == nextIndex,
                  marker.source == source
            else {
                throw TSDFReconstructionError.sourceMismatch
            }
            guard marker.configuration == configuration else {
                throw TSDFReconstructionError.configurationMismatch
            }
            guard Self.validStatistics(marker.statistics), statistics.add(marker.statistics) else {
                throw TSDFReconstructionError.invalidFile(url.lastPathComponent)
            }
            submapKeys.formUnion(marker.submapKeys)
            nextIndex += 1
        }
        return TSDFReconstructionState(
            source: source,
            configuration: configuration,
            nextFrameIndex: nextIndex,
            submapKeys: submapKeys.sorted(by: submapKeyLessThan),
            statistics: statistics
        )
    }

    private static func writeState(_ state: TSDFReconstructionState, to url: URL) throws {
        try writeJSON(state, to: url)
    }

    private static func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func floorDivision(_ value: Int64, by divisor: Int64) -> Int64 {
        let quotient = value / divisor
        let remainder = value % divisor
        return remainder < 0 ? quotient - 1 : quotient
    }

    private static func deltaFrameIndex(from filename: String) -> Int? {
        guard filename.hasPrefix("frame-"), filename.hasSuffix(".delta") else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: 6)
        let end = filename.index(filename.endIndex, offsetBy: -6)
        guard start < end else { return nil }
        return Int(filename[start..<end])
    }

    private static func submapKeyLessThan(_ lhs: TSDFSubmapKey, _ rhs: TSDFSubmapKey) -> Bool {
        lhs < rhs
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func encoderData<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func validStatistics(_ statistics: TSDFReconstructionStatistics) -> Bool {
        statistics.processedFrameCount >= 0
            && statistics.integratedRayCount >= 0
            && statistics.updatedVoxelContributionCount >= 0
            && statistics.rejectedDepthSampleCount >= 0
            && statistics.droppedVoxelUpdateCount >= 0
            && statistics.rayLimitReachedFrameCount >= 0
    }

    private static func checkedMultiply(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? nil : result.partialValue
    }

    private static func checkedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }

    private static func isSameOrAdjacent(_ lhs: Int64, _ rhs: Int64) -> Bool {
        if lhs == rhs { return true }
        return checkedAdd(rhs, -1) == lhs || checkedAdd(rhs, 1) == lhs
    }

    private static func globalCoordinate(
        submapKey: TSDFSubmapKey,
        localIndex: Int,
        dimension: Int
    ) -> TSDFGlobalVoxelCoordinate? {
        guard localIndex >= 0, dimension > 0 else { return nil }
        let plane = dimension * dimension
        let localZ = localIndex / plane
        let remainder = localIndex % plane
        let localY = remainder / dimension
        let localX = remainder % dimension
        let dimension64 = Int64(dimension)
        guard localZ < dimension,
              let baseX = checkedMultiply(submapKey.x, dimension64),
              let baseY = checkedMultiply(submapKey.y, dimension64),
              let baseZ = checkedMultiply(submapKey.z, dimension64),
              let x = checkedAdd(baseX, Int64(localX)),
              let y = checkedAdd(baseY, Int64(localY)),
              let z = checkedAdd(baseZ, Int64(localZ))
        else { return nil }
        return TSDFGlobalVoxelCoordinate(x: x, y: y, z: z)
    }
}

extension ChunkedTSDFReconstructor: TSDFSurfaceExtractionSource {}

public struct TSDFReconstructionProgress: Equatable, Sendable {
    public var completedFrameCount: Int
    public var totalFrameCount: Int

    public init(completedFrameCount: Int, totalFrameCount: Int) {
        self.completedFrameCount = completedFrameCount
        self.totalFrameCount = totalFrameCount
    }
}

/// Opens an integrity-valid archive and advances one keyframe at a time so peak
/// replay memory is bounded by one source frame and one frame's TSDF updates.
public struct CalibratedRGBDTSDFPipeline: Sendable {
    public init() {}

    public func run(
        packageURL: URL,
        manifest: ScanPackageManifest,
        integrity: PackageIntegrityReport,
        outputDirectory: URL,
        configuration: TSDFReconstructionConfiguration = .default,
        progress: (@Sendable (TSDFReconstructionProgress) async throws -> Void)? = nil
    ) async throws -> TSDFReconstructionState {
        let packagePath = Self.canonicalPath(for: packageURL)
        let outputPath = Self.canonicalPath(for: outputDirectory)
        guard outputPath != packagePath,
              !outputPath.hasPrefix(packagePath + "/")
        else {
            throw TSDFReconstructionError.invalidOutputLocation
        }
        let archive = try CalibratedRGBDKeyframeArchiveReader().open(
            packageURL: packageURL,
            manifest: manifest,
            integrity: integrity
        )
        let source = archive.reconstructionSource
        let reconstructor = try ChunkedTSDFReconstructor(
            outputDirectory: outputDirectory,
            source: source,
            configuration: configuration
        )
        var state = await reconstructor.currentState()
        try await progress?(TSDFReconstructionProgress(
            completedFrameCount: state.nextFrameIndex - 1,
            totalFrameCount: archive.records.count
        ))
        while state.nextFrameIndex <= archive.records.count {
            try Task.checkCancellation()
            let frameIndex = state.nextFrameIndex
            let keyframe = try archive.readKeyframe(at: frameIndex - 1)
            state = try await reconstructor.integrate(keyframe, frameIndex: frameIndex)
            try await progress?(TSDFReconstructionProgress(
                completedFrameCount: state.nextFrameIndex - 1,
                totalFrameCount: archive.records.count
            ))
        }
        return state
    }

    private static func canonicalPath(for url: URL) -> String {
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existingAncestor.path),
              existingAncestor.pathComponents.count > 1 {
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor.deleteLastPathComponent()
        }
        var resolved = existingAncestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            resolved.append(path: component)
        }
        return resolved.standardizedFileURL.path
    }
}

public extension CalibratedRGBDKeyframeReplayArchive {
    var reconstructionSource: TSDFReconstructionSource {
        TSDFReconstructionSource(
            scanID: scanID,
            keyframeIndexSHA256: sourceIndexSHA256,
            calibratedArchiveSHA256: sourceArchiveSHA256,
            keyframeCount: records.count
        )
    }
}

private extension Data {
    mutating func appendLittleEndianTSDF(_ value: UInt32) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    func readUInt32LittleEndianTSDF(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
