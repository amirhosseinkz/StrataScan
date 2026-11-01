import Foundation
import Testing
@testable import StrataCore

@Suite("Mesh vertex color projection")
struct MeshVertexColorProjectionTests {
    @Test("Projects a forward AR-world vertex into a calibrated retained image")
    func projectsVertexColor() throws {
        let snapshot = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [Point3D(x: 0, y: 0, z: -1)],
            normals: [],
            faces: []
        )
        let projection = MeshVertexColorProjector().project(
            snapshots: [snapshot],
            frames: [try frame(image: image(red: 210, green: 40, blue: 20))]
        )

        #expect(projection.colorsByAnchorID[snapshot.anchorID] == [MeshVertexColor(red: 210, green: 40, blue: 20)])
        #expect(projection.coloredVertexCount == 1)
        #expect(projection.sampledFrameCount == 1)
    }

    @Test("Uses the highest scoring valid camera source and leaves vertices behind a camera uncolored")
    func selectsHighestScoringSourceAndRejectsBehindCamera() throws {
        let snapshot = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [Point3D(x: 0, y: 0, z: -2), Point3D(x: 0, y: 0, z: 1)],
            normals: [],
            faces: []
        )
        let distant = try frame(image: image(red: 5, green: 10, blue: 15))
        let nearby = try frame(
            image: image(red: 80, green: 160, blue: 240),
            worldFromCamera: .translation(x: 0, y: 0, z: -1)
        )

        let projection = MeshVertexColorProjector().project(
            snapshots: [snapshot],
            frames: [distant, nearby]
        )

        #expect(projection.colorsByAnchorID[snapshot.anchorID] == [MeshVertexColor(red: 80, green: 160, blue: 240), nil])
        #expect(projection.coloredVertexCount == 1)
    }

    @Test("Prefers a more forward-facing camera view over a closer oblique view")
    func prefersForwardFacingCameraView() throws {
        let snapshot = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [Point3D(x: 0, y: 0, z: -4)],
            normals: [],
            faces: []
        )
        let directImage = try image(width: 9, height: 9, red: 210, green: 40, blue: 20)
        let direct = try frame(
            image: directImage,
            timestamp: 2,
            intrinsics: intrinsics(width: 9, height: 9, cx: 4, cy: 4)
        )
        let oblique = try frame(
            image: try image(width: 9, height: 9, red: 80, green: 160, blue: 240),
            worldFromCamera: .translation(x: 3, y: 0, z: -2),
            timestamp: 1,
            intrinsics: intrinsics(width: 9, height: 9, cx: 4, cy: 4)
        )

        let projection = MeshVertexColorProjector().project(
            snapshots: [snapshot],
            frames: [oblique, direct]
        )

        #expect(projection.colorsByAnchorID[snapshot.anchorID] == [MeshVertexColor(red: 210, green: 40, blue: 20)])
    }

    @Test("Rejects an out-of-bounds image projection even when it would otherwise score higher")
    func rejectsOutOfBoundsCameraView() throws {
        let snapshot = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [Point3D(x: 0, y: 0, z: -1)],
            normals: [],
            faces: []
        )
        let outOfBounds = try frame(
            image: try image(red: 80, green: 160, blue: 240),
            worldFromCamera: .translation(x: 0, y: 0, z: -0.5),
            intrinsics: intrinsics(width: 1, height: 1, cx: 1, cy: 0)
        )
        let valid = try frame(image: try image(red: 210, green: 40, blue: 20))

        let projection = MeshVertexColorProjector().project(
            snapshots: [snapshot],
            frames: [outOfBounds, valid]
        )

        #expect(projection.colorsByAnchorID[snapshot.anchorID] == [MeshVertexColor(red: 210, green: 40, blue: 20)])
    }

    @Test("Uses capture time as a deterministic tie-breaker for equal camera views")
    func usesCaptureTimeAsDeterministicTieBreaker() throws {
        let snapshot = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [Point3D(x: 0, y: 0, z: -1)],
            normals: [],
            faces: []
        )
        let newest = try frame(
            image: try image(red: 80, green: 160, blue: 240),
            timestamp: 20
        )
        let earliest = try frame(
            image: try image(red: 210, green: 40, blue: 20),
            timestamp: 10
        )

        let projection = MeshVertexColorProjector().project(
            snapshots: [snapshot],
            frames: [newest, earliest]
        )

        #expect(projection.colorsByAnchorID[snapshot.anchorID] == [MeshVertexColor(red: 210, green: 40, blue: 20)])
    }

    @Test("Rejects malformed RGBA image storage")
    func rejectsMalformedPixels() {
        #expect(throws: TextureProjectionError.invalidPixelByteCount(expected: 4, actual: 3)) {
            try TextureProjectionImage(width: 1, height: 1, rgbaBytes: [0, 0, 0])
        }
    }

    private func frame(
        image: TextureProjectionImage,
        worldFromCamera: Transform4x4 = .identity,
        timestamp: TimeInterval = 1,
        intrinsics: CameraIntrinsics? = nil
    ) throws -> TextureProjectionFrame {
        TextureProjectionFrame(
            metadata: FrameMetadata(
                timestamp: timestamp,
                videoTimestamp: nil,
                imageWidth: image.width,
                imageHeight: image.height,
                intrinsics: intrinsics ?? self.intrinsics(width: image.width, height: image.height, cx: 0, cy: 0),
                worldFromCamera: worldFromCamera,
                tracking: .normal,
                worldMapping: .mapped,
                isTextureSourceCandidate: true
            ),
            image: image
        )
    }

    private func image(red: UInt8, green: UInt8, blue: UInt8) throws -> TextureProjectionImage {
        try TextureProjectionImage(width: 1, height: 1, rgbaBytes: [red, green, blue, 255])
    }

    private func image(
        width: Int,
        height: Int,
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) throws -> TextureProjectionImage {
        let pixel = [red, green, blue, UInt8(255)]
        return try TextureProjectionImage(
            width: width,
            height: height,
            rgbaBytes: Array(repeating: pixel, count: width * height).flatMap { $0 }
        )
    }

    private func intrinsics(width: Int, height: Int, cx: Float, cy: Float) -> CameraIntrinsics {
        CameraIntrinsics(
            imageWidth: width,
            imageHeight: height,
            fx: 1,
            fy: 1,
            cx: cx,
            cy: cy
        )
    }
}
