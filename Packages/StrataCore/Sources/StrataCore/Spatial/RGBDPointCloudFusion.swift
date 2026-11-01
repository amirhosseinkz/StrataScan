import Foundation

/// An RGB value that came from a camera sample. It deliberately has no alpha
/// channel because RGB-D fusion does not invent transparency or a fallback
/// color for geometry without an image sample.
public struct PointCloudColor: Codable, Equatable, Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// One depth-derived AR-world point with an optional RGB camera observation.
/// A `nil` color means the caller had no verified image sample for this point;
/// it must not be replaced by a presentation fallback.
public struct RGBDPointSample: Equatable, Sendable {
    public var position: Point3D
    public var confidence: UInt8
    public var color: PointCloudColor?

    public init(position: Point3D, confidence: UInt8, color: PointCloudColor? = nil) {
        self.position = position
        self.confidence = confidence
        self.color = color
    }

    public init(depthPoint: DepthPoint, color: PointCloudColor? = nil) {
        self.init(position: depthPoint.position, confidence: depthPoint.confidence, color: color)
    }
}

/// A color-bearing point suitable for a standard RGB PLY record. It can only
/// be created from a fused point that has observed camera color.
public struct ColoredPointCloudPoint: Codable, Equatable, Sendable {
    public var position: Point3D
    public var confidence: UInt8
    public var color: PointCloudColor

    public init(position: Point3D, confidence: UInt8, color: PointCloudColor) {
        self.position = position
        self.confidence = confidence
        self.color = color
    }
}

/// The bounded aggregation held for one AR-world voxel. `position` is the
/// arithmetic mean of spatially-consistent accepted depth points in that voxel.
/// `color` is nil when no accepted input carried real RGB; otherwise it is the
/// mean of only those observed RGB samples.
public struct FusedRGBDPoint: Codable, Equatable, Sendable {
    public var position: Point3D
    public var confidence: UInt8
    public var color: PointCloudColor?
    public var sampleCount: Int
    public var coloredSampleCount: Int

    public init(
        position: Point3D,
        confidence: UInt8,
        color: PointCloudColor?,
        sampleCount: Int,
        coloredSampleCount: Int
    ) {
        self.position = position
        self.confidence = confidence
        self.color = color
        self.sampleCount = sampleCount
        self.coloredSampleCount = coloredSampleCount
    }

    /// Avoids manufacturing RGB records for uncolored geometry.
    public var coloredPoint: ColoredPointCloudPoint? {
        guard let color else { return nil }
        return ColoredPointCloudPoint(position: position, confidence: confidence, color: color)
    }
}

public enum RGBDPointCloudFusionError: Error, Equatable, Sendable {
    case invalidVoxelSizeMeters(Float)
    case invalidMaximumVoxelCount(Int)
    case invalidMaximumSamplesPerBatch(Int)
    case invalidMaximumSamplesPerVoxel(Int)
}

/// Fixed, deliberately conservative resource limits for an in-memory fusion
/// pass. They prevent a damaged or unusually long capture from creating an
/// unbounded sparse voxel map.
public struct RGBDPointCloudFusionConfiguration: Equatable, Sendable {
    public static let maximumAllowedVoxelCount = 250_000
    public static let maximumAllowedSamplesPerBatch = 10_000
    public static let maximumAllowedSamplesPerVoxel = 1_024

    public static let `default` = RGBDPointCloudFusionConfiguration(
        uncheckedVoxelSizeMeters: 0.03,
        maximumVoxelCount: 100_000,
        maximumSamplesPerBatch: 3_000,
        maximumSamplesPerVoxel: 256
    )

    public var voxelSizeMeters: Float
    public var maximumVoxelCount: Int
    public var maximumSamplesPerBatch: Int
    public var maximumSamplesPerVoxel: Int

    public init(
        voxelSizeMeters: Float = 0.03,
        maximumVoxelCount: Int = 100_000,
        maximumSamplesPerBatch: Int = 3_000,
        maximumSamplesPerVoxel: Int = 256
    ) throws {
        guard voxelSizeMeters.isFinite, voxelSizeMeters > 0 else {
            throw RGBDPointCloudFusionError.invalidVoxelSizeMeters(voxelSizeMeters)
        }
        guard (1...Self.maximumAllowedVoxelCount).contains(maximumVoxelCount) else {
            throw RGBDPointCloudFusionError.invalidMaximumVoxelCount(maximumVoxelCount)
        }
        guard (1...Self.maximumAllowedSamplesPerBatch).contains(maximumSamplesPerBatch) else {
            throw RGBDPointCloudFusionError.invalidMaximumSamplesPerBatch(maximumSamplesPerBatch)
        }
        guard (1...Self.maximumAllowedSamplesPerVoxel).contains(maximumSamplesPerVoxel) else {
            throw RGBDPointCloudFusionError.invalidMaximumSamplesPerVoxel(maximumSamplesPerVoxel)
        }

        self.voxelSizeMeters = voxelSizeMeters
        self.maximumVoxelCount = maximumVoxelCount
        self.maximumSamplesPerBatch = maximumSamplesPerBatch
        self.maximumSamplesPerVoxel = maximumSamplesPerVoxel
    }

    private init(
        uncheckedVoxelSizeMeters: Float,
        maximumVoxelCount: Int,
        maximumSamplesPerBatch: Int,
        maximumSamplesPerVoxel: Int
    ) {
        voxelSizeMeters = uncheckedVoxelSizeMeters
        self.maximumVoxelCount = maximumVoxelCount
        self.maximumSamplesPerBatch = maximumSamplesPerBatch
        self.maximumSamplesPerVoxel = maximumSamplesPerVoxel
    }
}

/// The outcome of a bounded append. Counts describe collection behavior only;
/// they are not a coverage, completeness, or accuracy measurement.
public struct RGBDPointCloudFusionAppendResult: Equatable, Sendable {
    public var acceptedSampleCount: Int
    public var createdVoxelCount: Int
    public var updatedVoxelCount: Int
    public var rejectedInvalidSampleCount: Int
    public var rejectedByBatchLimitCount: Int
    public var rejectedByVoxelLimitCount: Int
    public var rejectedByVoxelSampleLimitCount: Int
    /// Samples that landed in an existing voxel but were too far from that
    /// voxel's accepted AR-world surface to contribute safely.
    public var rejectedInconsistentSampleCount: Int

    public init(
        acceptedSampleCount: Int = 0,
        createdVoxelCount: Int = 0,
        updatedVoxelCount: Int = 0,
        rejectedInvalidSampleCount: Int = 0,
        rejectedByBatchLimitCount: Int = 0,
        rejectedByVoxelLimitCount: Int = 0,
        rejectedByVoxelSampleLimitCount: Int = 0,
        rejectedInconsistentSampleCount: Int = 0
    ) {
        self.acceptedSampleCount = acceptedSampleCount
        self.createdVoxelCount = createdVoxelCount
        self.updatedVoxelCount = updatedVoxelCount
        self.rejectedInvalidSampleCount = rejectedInvalidSampleCount
        self.rejectedByBatchLimitCount = rejectedByBatchLimitCount
        self.rejectedByVoxelLimitCount = rejectedByVoxelLimitCount
        self.rejectedByVoxelSampleLimitCount = rejectedByVoxelSampleLimitCount
        self.rejectedInconsistentSampleCount = rejectedInconsistentSampleCount
    }
}

/// A serial-owner accumulator for bounded AR-world RGB-D voxel fusion. It
/// neither changes input coordinates nor synthesizes colors. Callers own its
/// synchronization (for example, from a capture collector actor).
public struct RGBDPointCloudFusion: Sendable {
    public let configuration: RGBDPointCloudFusionConfiguration

    private var voxels: [VoxelKey: Voxel] = [:]

    public init(configuration: RGBDPointCloudFusionConfiguration = .default) {
        self.configuration = configuration
        voxels.reserveCapacity(configuration.maximumVoxelCount)
    }

    public var voxelCount: Int { voxels.count }

    /// Fuses at most `maximumSamplesPerBatch` values. Input positions must
    /// already be in AR-world meters; this type intentionally performs no pose
    /// or axis conversion.
    @discardableResult
    public mutating func append(_ samples: [RGBDPointSample]) -> RGBDPointCloudFusionAppendResult {
        var result = RGBDPointCloudFusionAppendResult()
        let acceptedInputCount = min(samples.count, configuration.maximumSamplesPerBatch)
        result.rejectedByBatchLimitCount = samples.count - acceptedInputCount

        for sample in samples.prefix(acceptedInputCount) {
            guard let key = voxelKey(for: sample.position) else {
                result.rejectedInvalidSampleCount += 1
                continue
            }

            if var existing = voxels[key] {
                guard existing.sampleCount < configuration.maximumSamplesPerVoxel else {
                    result.rejectedByVoxelSampleLimitCount += 1
                    continue
                }
                guard existing.isSpatiallyConsistent(
                    with: sample,
                    maximumDistanceSquared: maximumConsensusDistanceSquared
                ) else {
                    result.rejectedInconsistentSampleCount += 1
                    continue
                }
                existing.append(sample)
                voxels[key] = existing
                result.acceptedSampleCount += 1
                result.updatedVoxelCount += 1
                continue
            }

            guard voxels.count < configuration.maximumVoxelCount else {
                result.rejectedByVoxelLimitCount += 1
                continue
            }
            voxels[key] = Voxel(sample: sample)
            result.acceptedSampleCount += 1
            result.createdVoxelCount += 1
        }

        return result
    }

    /// Returns a stable world-space ordering so a persisted fusion result is
    /// repeatable for the same accepted samples.
    public func fusedPoints() -> [FusedRGBDPoint] {
        voxels
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { $0.value.point }
    }

    /// Exposes only cells that have observed RGB. This is the safe input for a
    /// colored PLY writer; uncolored cells are never assigned a stand-in color.
    public func coloredPoints() -> [ColoredPointCloudPoint] {
        fusedPoints().compactMap(\.coloredPoint)
    }

    public mutating func removeAll(keepingCapacity: Bool = false) {
        voxels.removeAll(keepingCapacity: keepingCapacity)
    }

    private func voxelKey(for position: Point3D) -> VoxelKey? {
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite,
              let x = gridCoordinate(for: position.x),
              let y = gridCoordinate(for: position.y),
              let z = gridCoordinate(for: position.z)
        else {
            return nil
        }
        return VoxelKey(x: x, y: y, z: z)
    }

    private func gridCoordinate(for value: Float) -> Int64? {
        let scaled = floor(Double(value) / Double(configuration.voxelSizeMeters))
        guard scaled.isFinite,
              scaled >= Double(Int64.min),
              // `Double(Int64.max)` rounds to 2^63, which is one value beyond
              // the largest representable signed 64-bit integer.
              scaled < Double(Int64.max)
        else {
            return nil
        }
        return Int64(scaled)
    }

    /// A point at the opposite side of a voxel is normally a competing depth
    /// surface rather than a repeat observation of the same surface. Keep the
    /// gate inside the voxel so this remains a bounded, local decision and does
    /// not alter AR-world coordinates or require neighbourhood geometry.
    private var maximumConsensusDistanceSquared: Double {
        let distance = Double(configuration.voxelSizeMeters) * 0.75
        return distance * distance
    }
}

private struct VoxelKey: Hashable, Comparable, Sendable {
    let x: Int64
    let y: Int64
    let z: Int64

    static func < (lhs: VoxelKey, rhs: VoxelKey) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.z < rhs.z
    }
}

private struct Voxel: Sendable {
    private var sumX: Double
    private var sumY: Double
    private var sumZ: Double
    private var sumRed: UInt64
    private var sumGreen: UInt64
    private var sumBlue: UInt64
    private(set) var sampleCount: Int
    private var colorSampleCount: Int
    private var maximumConfidence: UInt8

    init(sample: RGBDPointSample) {
        sumX = Double(sample.position.x)
        sumY = Double(sample.position.y)
        sumZ = Double(sample.position.z)
        sampleCount = 1
        maximumConfidence = sample.confidence
        if let color = sample.color {
            sumRed = UInt64(color.red)
            sumGreen = UInt64(color.green)
            sumBlue = UInt64(color.blue)
            colorSampleCount = 1
        } else {
            sumRed = 0
            sumGreen = 0
            sumBlue = 0
            colorSampleCount = 0
        }
    }

    mutating func append(_ sample: RGBDPointSample) {
        sumX += Double(sample.position.x)
        sumY += Double(sample.position.y)
        sumZ += Double(sample.position.z)
        sampleCount += 1
        maximumConfidence = max(maximumConfidence, sample.confidence)
        if let color = sample.color {
            sumRed += UInt64(color.red)
            sumGreen += UInt64(color.green)
            sumBlue += UInt64(color.blue)
            colorSampleCount += 1
        }
    }

    /// A first accepted sample is intentionally enough to form a voxel. This
    /// avoids requiring repeated depth returns for a valid thin or briefly
    /// observed surface. Subsequent samples must agree with the current local
    /// centroid before they can shift geometry or observed RGB.
    func isSpatiallyConsistent(
        with sample: RGBDPointSample,
        maximumDistanceSquared: Double
    ) -> Bool {
        let count = Double(sampleCount)
        let deltaX = Double(sample.position.x) - sumX / count
        let deltaY = Double(sample.position.y) - sumY / count
        let deltaZ = Double(sample.position.z) - sumZ / count
        let distanceSquared = deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ
        return distanceSquared <= maximumDistanceSquared
    }

    var point: FusedRGBDPoint {
        let count = Double(sampleCount)
        let color: PointCloudColor?
        if colorSampleCount > 0 {
            let colorCount = UInt64(colorSampleCount)
            color = PointCloudColor(
                red: UInt8(sumRed / colorCount),
                green: UInt8(sumGreen / colorCount),
                blue: UInt8(sumBlue / colorCount)
            )
        } else {
            color = nil
        }

        return FusedRGBDPoint(
            position: Point3D(
                x: Float(sumX / count),
                y: Float(sumY / count),
                z: Float(sumZ / count)
            ),
            confidence: maximumConfidence,
            color: color,
            sampleCount: sampleCount,
            coloredSampleCount: colorSampleCount
        )
    }
}
