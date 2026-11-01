import Foundation

/// An RGBA color sampled from a persisted camera keyframe. Values are stored
/// separately from immutable source mesh assets and are used only for display.
public struct MeshVertexColor: Codable, Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// A decoded, camera-native keyframe. Its pixel axes match the persisted
/// `FrameMetadata` calibration; callers must not apply a display orientation
/// transform before projection.
public struct TextureProjectionImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var rgbaBytes: [UInt8]

    public init(width: Int, height: Int, rgbaBytes: [UInt8]) throws {
        guard width > 0, height > 0 else {
            throw TextureProjectionError.invalidImageDimensions
        }
        guard rgbaBytes.count == width * height * 4 else {
            throw TextureProjectionError.invalidPixelByteCount(
                expected: width * height * 4,
                actual: rgbaBytes.count
            )
        }
        self.width = width
        self.height = height
        self.rgbaBytes = rgbaBytes
    }

    public func color(atX x: Int, y: Int) -> MeshVertexColor? {
        guard x >= 0, x < width, y >= 0, y < height else {
            return nil
        }
        let offset = (y * width + x) * 4
        return MeshVertexColor(
            red: rgbaBytes[offset],
            green: rgbaBytes[offset + 1],
            blue: rgbaBytes[offset + 2],
            alpha: rgbaBytes[offset + 3]
        )
    }
}

public enum TextureProjectionError: Error, Equatable, Sendable {
    case invalidImageDimensions
    case invalidPixelByteCount(expected: Int, actual: Int)
}

/// One verified keyframe and its capture-time AR-world camera relationship.
public struct TextureProjectionFrame: Equatable, Sendable {
    public var metadata: FrameMetadata
    public var image: TextureProjectionImage

    public init(metadata: FrameMetadata, image: TextureProjectionImage) {
        self.metadata = metadata
        self.image = image
    }
}

/// Display-only color samples aligned one-for-one with each mesh snapshot's
/// anchor-local vertex array. `nil` means no retained camera frame could safely
/// project that vertex into its image bounds.
public struct MeshVertexColorProjection: Equatable, Sendable {
    public var colorsByAnchorID: [UUID: [MeshVertexColor?]]
    public var coloredVertexCount: Int
    public var sampledFrameCount: Int

    public init(
        colorsByAnchorID: [UUID: [MeshVertexColor?]],
        coloredVertexCount: Int,
        sampledFrameCount: Int
    ) {
        self.colorsByAnchorID = colorsByAnchorID
        self.coloredVertexCount = coloredVertexCount
        self.sampledFrameCount = sampledFrameCount
    }
}

/// Projects retained calibrated RGB keyframes onto raw mesh vertices in AR
/// world space. It intentionally performs no visibility/occlusion test and
/// does not write a texture, UV map, or processed source mesh. The highest
/// scoring forward-facing view supplies each display color: valid projected
/// pixels are ranked by camera-forward alignment and distance, with capture
/// time as a deterministic tie-breaker. Vertices with no valid image
/// projection remain uncolored.
public struct MeshVertexColorProjector: Sendable {
    private static let minimumForwardDepth: Float = 0.01

    public init() {}

    public func project(
        snapshots: [MeshSnapshot],
        frames: [TextureProjectionFrame]
    ) -> MeshVertexColorProjection {
        let preparedFrames = frames.enumerated().compactMap { sourceIndex, frame in
            PreparedFrame(frame, sourceIndex: sourceIndex)
        }
        var colorsByAnchorID: [UUID: [MeshVertexColor?]] = [:]
        var coloredVertexCount = 0

        for snapshot in snapshots {
            var colors: [MeshVertexColor?] = []
            colors.reserveCapacity(snapshot.vertices.count)

            for vertex in snapshot.vertices {
                let worldVertex = snapshot.worldFromAnchor.applying(to: vertex)
                let color = color(for: worldVertex, frames: preparedFrames)
                if color != nil {
                    coloredVertexCount += 1
                }
                colors.append(color)
            }
            colorsByAnchorID[snapshot.anchorID] = colors
        }

        return MeshVertexColorProjection(
            colorsByAnchorID: colorsByAnchorID,
            coloredVertexCount: coloredVertexCount,
            sampledFrameCount: preparedFrames.count
        )
    }

    private func color(for worldVertex: Point3D, frames: [PreparedFrame]) -> MeshVertexColor? {
        guard worldVertex.x.isFinite, worldVertex.y.isFinite, worldVertex.z.isFinite else {
            return nil
        }

        var bestCandidate: ColorCandidate?
        for frame in frames {
            guard let candidate = frame.candidate(for: worldVertex) else {
                continue
            }
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

        func candidate(for worldVertex: Point3D) -> ColorCandidate? {
            let cameraVertex = cameraFromWorld.applying(to: worldVertex)
            guard cameraVertex.x.isFinite,
                  cameraVertex.y.isFinite,
                  cameraVertex.z.isFinite
            else {
                return nil
            }

            let forwardDepth = -cameraVertex.z
            guard forwardDepth.isFinite, forwardDepth > MeshVertexColorProjector.minimumForwardDepth else {
                return nil
            }

            let squaredDistance = cameraVertex.x * cameraVertex.x
                + cameraVertex.y * cameraVertex.y
                + cameraVertex.z * cameraVertex.z
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

            let x = intrinsics.cx + intrinsics.fx * (cameraVertex.x / cameraVertex.z)
            let y = intrinsics.cy + intrinsics.fy * (cameraVertex.y / cameraVertex.z)
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
            guard let color = image.color(atX: pixelX, y: pixelY) else {
                return nil
            }

            let score = forwardAlignment / distance
            guard score.isFinite else {
                return nil
            }
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

        /// Select a predictable source when candidates score alike. The primary
        /// score is camera-forward alignment divided by camera distance, which
        /// favors a closer, more head-on image without inventing an occlusion
        /// result or changing the source mesh.
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
