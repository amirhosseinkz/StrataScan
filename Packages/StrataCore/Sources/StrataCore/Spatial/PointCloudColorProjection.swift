import Foundation

/// Presentation-only calibrated colour for a bounded sampled point cloud.
///
/// The source point cloud remains untouched. A point receives a colour only
/// when it can be projected into a verified retained camera keyframe using the
/// keyframe's capture-time intrinsics and AR-world pose.
public struct PointCloudColorProjection: Equatable, Sendable {
    public var colors: [MeshVertexColor?]
    public var coloredPointCount: Int
    public var sampledFrameCount: Int

    public init(
        colors: [MeshVertexColor?],
        coloredPointCount: Int,
        sampledFrameCount: Int
    ) {
        self.colors = colors
        self.coloredPointCount = coloredPointCount
        self.sampledFrameCount = sampledFrameCount
    }
}

/// Projects verified retained keyframes onto AR-world depth points without
/// baking or persisting any derived colour back into a source scan package.
public struct PointCloudColorProjector: Sendable {
    private static let minimumForwardDepth: Float = 0.01

    public init() {}

    public func project(
        points: [Point3D],
        frames: [TextureProjectionFrame]
    ) -> PointCloudColorProjection {
        let preparedFrames = frames.enumerated().compactMap { sourceIndex, frame in
            PreparedFrame(frame, sourceIndex: sourceIndex)
        }
        var colors: [MeshVertexColor?] = []
        colors.reserveCapacity(points.count)
        var coloredPointCount = 0

        for point in points {
            let color = color(for: point, frames: preparedFrames)
            if color != nil {
                coloredPointCount += 1
            }
            colors.append(color)
        }

        return PointCloudColorProjection(
            colors: colors,
            coloredPointCount: coloredPointCount,
            sampledFrameCount: preparedFrames.count
        )
    }

    private func color(for worldPoint: Point3D, frames: [PreparedFrame]) -> MeshVertexColor? {
        guard worldPoint.x.isFinite, worldPoint.y.isFinite, worldPoint.z.isFinite else {
            return nil
        }

        var bestCandidate: ColorCandidate?
        for frame in frames {
            guard let candidate = frame.candidate(for: worldPoint) else { continue }
            if let currentBest = bestCandidate {
                if candidate.isPreferred(to: currentBest) {
                    bestCandidate = candidate
                }
            } else {
                bestCandidate = candidate
            }
        }
        return bestCandidate?.color
    }

    private struct PreparedFrame {
        let cameraFromWorld: Transform4x4
        let intrinsics: CameraIntrinsics
        let image: TextureProjectionImage
        let captureTimestamp: TimeInterval
        let sourceIndex: Int

        init?(_ frame: TextureProjectionFrame, sourceIndex: Int) {
            guard frame.metadata.isTextureSourceCandidate,
                  frame.metadata.tracking == .normal,
                  frame.metadata.timestamp.isFinite,
                  frame.metadata.intrinsics.fx.isFinite,
                  frame.metadata.intrinsics.fy.isFinite,
                  frame.metadata.intrinsics.fx > 0,
                  frame.metadata.intrinsics.fy > 0,
                  let cameraFromWorld = try? frame.metadata.worldFromCamera.inverted()
            else {
                return nil
            }
            self.cameraFromWorld = cameraFromWorld
            intrinsics = frame.metadata.intrinsics.scaled(
                toWidth: frame.image.width,
                height: frame.image.height
            )
            image = frame.image
            captureTimestamp = frame.metadata.timestamp
            self.sourceIndex = sourceIndex
        }

        func candidate(for worldPoint: Point3D) -> ColorCandidate? {
            let cameraPoint = cameraFromWorld.applying(to: worldPoint)
            guard cameraPoint.x.isFinite,
                  cameraPoint.y.isFinite,
                  cameraPoint.z.isFinite
            else {
                return nil
            }

            let forwardDepth = -cameraPoint.z
            guard forwardDepth.isFinite, forwardDepth > PointCloudColorProjector.minimumForwardDepth else {
                return nil
            }
            let squaredDistance = cameraPoint.x * cameraPoint.x
                + cameraPoint.y * cameraPoint.y
                + cameraPoint.z * cameraPoint.z
            guard squaredDistance.isFinite, squaredDistance > 0 else {
                return nil
            }
            let distance = squaredDistance.squareRoot()
            let forwardAlignment = forwardDepth / distance
            guard distance.isFinite,
                  forwardAlignment.isFinite,
                  forwardAlignment > 0
            else {
                return nil
            }

            let x = intrinsics.cx + intrinsics.fx * (cameraPoint.x / cameraPoint.z)
            let y = intrinsics.cy + intrinsics.fy * (cameraPoint.y / cameraPoint.z)
            guard x.isFinite,
                  y.isFinite,
                  x > -0.5,
                  x < Float(image.width) - 0.5,
                  y > -0.5,
                  y < Float(image.height) - 0.5
            else {
                return nil
            }
            let pixelX = Int(x.rounded())
            let pixelY = Int(y.rounded())
            guard let color = image.color(atX: pixelX, y: pixelY), color.alpha > 0 else {
                return nil
            }

            let score = forwardAlignment / distance
            guard score.isFinite else { return nil }
            return ColorCandidate(
                color: color,
                score: score,
                forwardAlignment: forwardAlignment,
                distance: distance,
                captureTimestamp: captureTimestamp,
                sourceIndex: sourceIndex
            )
        }
    }

    private struct ColorCandidate {
        let color: MeshVertexColor
        let score: Float
        let forwardAlignment: Float
        let distance: Float
        let captureTimestamp: TimeInterval
        let sourceIndex: Int

        /// Uses the same deterministic camera-choice policy as mesh colour:
        /// prioritize a closer, more head-on retained image, then settle ties
        /// by alignment, distance, capture time, and package source order.
        func isPreferred(to current: ColorCandidate) -> Bool {
            if score != current.score {
                return score > current.score
            }
            if forwardAlignment != current.forwardAlignment {
                return forwardAlignment > current.forwardAlignment
            }
            if distance != current.distance {
                return distance < current.distance
            }
            if captureTimestamp != current.captureTimestamp {
                return captureTimestamp < current.captureTimestamp
            }
            return sourceIndex < current.sourceIndex
        }
    }
}
