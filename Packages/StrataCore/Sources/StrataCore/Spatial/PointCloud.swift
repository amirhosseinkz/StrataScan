import Foundation

public struct PixelCoordinate: Codable, Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public struct CameraIntrinsics: Codable, Equatable, Sendable {
    public var imageWidth: Int
    public var imageHeight: Int
    public var fx: Float
    public var fy: Float
    public var cx: Float
    public var cy: Float

    public init(imageWidth: Int, imageHeight: Int, fx: Float, fy: Float, cx: Float, cy: Float) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
    }

    /// ARKit depth maps may have a different size than `capturedImage`. Intrinsics
    /// are scaled into depth-pixel coordinates before unprojection.
    public func scaled(toWidth width: Int, height: Int) -> CameraIntrinsics {
        guard imageWidth > 0, imageHeight > 0 else { return self }
        let horizontalScale = Float(width) / Float(imageWidth)
        let verticalScale = Float(height) / Float(imageHeight)
        return CameraIntrinsics(
            imageWidth: width,
            imageHeight: height,
            fx: fx * horizontalScale,
            fy: fy * verticalScale,
            cx: cx * horizontalScale,
            cy: cy * verticalScale
        )
    }
}

public struct DepthFrameSample: Sendable {
    public var width: Int
    public var height: Int
    public var depthMeters: [Float]
    public var confidence: [UInt8]
    /// Copied RGB observations in the depth-map pixel grid. This is optional
    /// because a raw depth frame remains valid when camera pixels cannot be
    /// safely sampled. It is never synthesized from a fallback material.
    public var observedColors: [PointCloudColor?]
    public var calibration: CameraIntrinsics
    public var worldFromCamera: Transform4x4
    public var timestamp: TimeInterval

    public init(
        width: Int,
        height: Int,
        depthMeters: [Float],
        confidence: [UInt8],
        observedColors: [PointCloudColor?] = [],
        calibration: CameraIntrinsics,
        worldFromCamera: Transform4x4,
        timestamp: TimeInterval
    ) {
        self.width = width
        self.height = height
        self.depthMeters = depthMeters
        self.confidence = confidence
        self.observedColors = observedColors
        self.calibration = calibration
        self.worldFromCamera = worldFromCamera
        self.timestamp = timestamp
    }

    /// Returns an observed camera colour only when the packet included a
    /// complete depth-grid-sized colour copy. A malformed optional colour
    /// attachment cannot invalidate or recolour the depth geometry.
    public func observedColor(at coordinate: PixelCoordinate) -> PointCloudColor? {
        guard coordinate.x >= 0,
              coordinate.x < width,
              coordinate.y >= 0,
              coordinate.y < height,
              observedColors.count == width * height
        else {
            return nil
        }
        return observedColors[coordinate.y * width + coordinate.x]
    }
}

public struct DepthPoint: Codable, Equatable, Sendable {
    public var position: Point3D
    public var confidence: UInt8
    public var timestamp: TimeInterval
    public var sourcePixel: PixelCoordinate

    public init(position: Point3D, confidence: UInt8, timestamp: TimeInterval, sourcePixel: PixelCoordinate) {
        self.position = position
        self.confidence = confidence
        self.timestamp = timestamp
        self.sourcePixel = sourcePixel
    }
}

public enum DepthPointCloudError: Error, Equatable, Sendable {
    case invalidDimensions
    case invalidSampleCount
    case invalidIntrinsics
}

/// Rejects depth observations that cannot be corroborated by nearby depth
/// pixels before they are unprojected into a persisted point cloud. This is an
/// input-quality gate, not a reconstruction step: it only removes implausible
/// observations and never interpolates, moves, or invents a point.
public struct DepthSampleQualityGate: Sendable {
    public var minimumDepthMeters: Float
    public var maximumDepthMeters: Float
    public var minimumConsistentNeighborCount: Int
    public var absoluteNeighborDepthToleranceMeters: Float
    public var relativeNeighborDepthTolerance: Float

    public init(
        minimumDepthMeters: Float = 0.10,
        maximumDepthMeters: Float = 12,
        minimumConsistentNeighborCount: Int = 2,
        absoluteNeighborDepthToleranceMeters: Float = 0.08,
        relativeNeighborDepthTolerance: Float = 0.025
    ) {
        let safeMinimumDepth = minimumDepthMeters.isFinite
            ? max(0.001, minimumDepthMeters)
            : 0.10
        self.minimumDepthMeters = safeMinimumDepth
        self.maximumDepthMeters = maximumDepthMeters.isFinite
            ? max(safeMinimumDepth, maximumDepthMeters)
            : 12
        self.minimumConsistentNeighborCount = min(8, max(0, minimumConsistentNeighborCount))
        self.absoluteNeighborDepthToleranceMeters = absoluteNeighborDepthToleranceMeters.isFinite
            ? max(0.001, absoluteNeighborDepthToleranceMeters)
            : 0.08
        self.relativeNeighborDepthTolerance = relativeNeighborDepthTolerance.isFinite
            ? max(0, relativeNeighborDepthTolerance)
            : 0.025
    }

    public func admits(
        depthMeters: Float,
        at coordinate: PixelCoordinate,
        in sample: DepthFrameSample,
        minimumConfidence: UInt8
    ) -> Bool {
        guard isPlausible(depthMeters) else {
            return false
        }
        guard minimumConsistentNeighborCount > 0 else {
            return true
        }

        let tolerance = absoluteNeighborDepthToleranceMeters
            + relativeNeighborDepthTolerance * depthMeters
        var consistentNeighborCount = 0
        var hasPlausibleNeighbor = false
        for offset in Self.neighborOffsets {
            let neighborX = coordinate.x + offset.x
            let neighborY = coordinate.y + offset.y
            guard neighborX >= 0,
                  neighborX < sample.width,
                  neighborY >= 0,
                  neighborY < sample.height
            else {
                continue
            }

            let neighborIndex = neighborY * sample.width + neighborX
            let neighborDepth = sample.depthMeters[neighborIndex]
            guard sample.confidence[neighborIndex] >= minimumConfidence,
                  isPlausible(neighborDepth)
            else {
                continue
            }
            hasPlausibleNeighbor = true
            guard abs(neighborDepth - depthMeters) <= tolerance else {
                continue
            }
            consistentNeighborCount += 1
            if consistentNeighborCount >= minimumConsistentNeighborCount {
                return true
            }
        }
        // A sparse packet does not provide enough neighboring evidence to
        // classify a real isolated surface as noise. Preserve it rather than
        // turning an otherwise valid minimal scan into an empty package. Dense
        // packets still reject a depth value that disagrees with its measured
        // local context.
        return !hasPlausibleNeighbor
    }

    private func isPlausible(_ depthMeters: Float) -> Bool {
        depthMeters.isFinite
            && depthMeters >= minimumDepthMeters
            && depthMeters <= maximumDepthMeters
    }

    private static let neighborOffsets = [
        PixelCoordinate(x: -1, y: -1),
        PixelCoordinate(x: 0, y: -1),
        PixelCoordinate(x: 1, y: -1),
        PixelCoordinate(x: -1, y: 0),
        PixelCoordinate(x: 1, y: 0),
        PixelCoordinate(x: -1, y: 1),
        PixelCoordinate(x: 0, y: 1),
        PixelCoordinate(x: 1, y: 1)
    ]
}

/// Converts a single copied depth packet into bounded world-space points. It
/// follows ARKit's camera convention: inverse intrinsics times image pixel,
/// multiplied by negative depth, then `worldFromCamera`.
public struct DepthPointCloudGenerator: Sendable {
    public var minimumConfidence: UInt8
    public var samplingStride: Int
    public var maximumPointsPerFrame: Int
    public var qualityGate: DepthSampleQualityGate

    public init(
        minimumConfidence: UInt8 = 1,
        samplingStride: Int = 4,
        maximumPointsPerFrame: Int = 8_000,
        qualityGate: DepthSampleQualityGate = .init()
    ) {
        self.minimumConfidence = minimumConfidence
        self.samplingStride = max(1, samplingStride)
        self.maximumPointsPerFrame = max(1, maximumPointsPerFrame)
        self.qualityGate = qualityGate
    }

    public func generate(from sample: DepthFrameSample) throws -> [DepthPoint] {
        guard sample.width > 0, sample.height > 0 else {
            throw DepthPointCloudError.invalidDimensions
        }
        let count = sample.width * sample.height
        guard sample.depthMeters.count == count, sample.confidence.count == count else {
            throw DepthPointCloudError.invalidSampleCount
        }
        let intrinsics = sample.calibration.scaled(toWidth: sample.width, height: sample.height)
        guard intrinsics.fx != 0, intrinsics.fy != 0 else {
            throw DepthPointCloudError.invalidIntrinsics
        }

        var points: [DepthPoint] = []
        points.reserveCapacity(min(maximumPointsPerFrame, count))
        for y in stride(from: 0, to: sample.height, by: samplingStride) {
            for x in stride(from: 0, to: sample.width, by: samplingStride) {
                guard points.count < maximumPointsPerFrame else { return points }
                let index = y * sample.width + x
                let depth = sample.depthMeters[index]
                let confidence = sample.confidence[index]
                guard confidence >= minimumConfidence,
                      qualityGate.admits(
                        depthMeters: depth,
                        at: PixelCoordinate(x: x, y: y),
                        in: sample,
                        minimumConfidence: minimumConfidence
                      )
                else {
                    continue
                }

                let imageX = Float(x)
                let imageY = Float(y)
                let cameraPoint = Point3D(
                    x: -((imageX - intrinsics.cx) / intrinsics.fx) * depth,
                    y: -((imageY - intrinsics.cy) / intrinsics.fy) * depth,
                    z: -depth
                )
                points.append(
                    DepthPoint(
                        position: sample.worldFromCamera.applying(to: cameraPoint),
                        confidence: confidence,
                        timestamp: sample.timestamp,
                        sourcePixel: PixelCoordinate(x: x, y: y)
                    )
                )
            }
        }
        return points
    }
}
