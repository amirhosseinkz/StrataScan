import Foundation
import Testing
@testable import StrataCore

@Suite("Point-cloud colour projection")
struct PointCloudColorProjectionTests {
    @Test("Projects a real calibrated keyframe colour onto a forward AR-world depth point")
    func projectsForwardPoint() throws {
        let projection = PointCloudColorProjector().project(
            points: [Point3D(x: 0, y: 0, z: -2)],
            frames: [try frame(red: 210, green: 40, blue: 20)]
        )

        #expect(projection.colors == [MeshVertexColor(red: 210, green: 40, blue: 20)])
        #expect(projection.coloredPointCount == 1)
        #expect(projection.sampledFrameCount == 1)
    }

    @Test("Uses the nearest valid verified keyframe and rejects points behind its camera")
    func usesNearestValidKeyframe() throws {
        let distant = try frame(red: 5, green: 10, blue: 15)
        let nearby = try frame(
            red: 80,
            green: 160,
            blue: 240,
            worldFromCamera: .translation(x: 0, y: 0, z: -1)
        )

        let projection = PointCloudColorProjector().project(
            points: [Point3D(x: 0, y: 0, z: -2), Point3D(x: 0, y: 0, z: 1)],
            frames: [distant, nearby]
        )

        #expect(projection.colors == [MeshVertexColor(red: 80, green: 160, blue: 240), nil])
        #expect(projection.coloredPointCount == 1)
    }

    @Test("Rejects a frame not verified as a retained texture source")
    func rejectsUnverifiedFrame() throws {
        let unverified = try frame(
            red: 80,
            green: 160,
            blue: 240,
            isTextureSourceCandidate: false
        )

        let projection = PointCloudColorProjector().project(
            points: [Point3D(x: 0, y: 0, z: -1)],
            frames: [unverified]
        )

        #expect(projection.colors == [nil])
        #expect(projection.coloredPointCount == 0)
        #expect(projection.sampledFrameCount == 0)
    }

    private func frame(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        worldFromCamera: Transform4x4 = .identity,
        isTextureSourceCandidate: Bool = true
    ) throws -> TextureProjectionFrame {
        TextureProjectionFrame(
            metadata: FrameMetadata(
                timestamp: 1,
                videoTimestamp: nil,
                imageWidth: 1,
                imageHeight: 1,
                intrinsics: CameraIntrinsics(
                    imageWidth: 1,
                    imageHeight: 1,
                    fx: 1,
                    fy: 1,
                    cx: 0,
                    cy: 0
                ),
                worldFromCamera: worldFromCamera,
                tracking: .normal,
                worldMapping: .mapped,
                isTextureSourceCandidate: isTextureSourceCandidate
            ),
            image: try TextureProjectionImage(
                width: 1,
                height: 1,
                rgbaBytes: [red, green, blue, 255]
            )
        )
    }
}
