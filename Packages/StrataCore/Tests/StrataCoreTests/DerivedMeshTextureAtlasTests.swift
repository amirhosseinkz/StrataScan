import Foundation
import Testing
@testable import StrataCore

@Suite("Derived mesh texture atlas")
struct DerivedMeshTextureAtlasTests {
    @Test("Builds verified per-vertex colour gradients only for fully observed mesh faces")
    func buildsTilesForFullyObservedFaces() throws {
        let snapshot = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 1, y: 0, z: 0),
                Point3D(x: 0, y: 1, z: 0),
                Point3D(x: 1, y: 1, z: 0)
            ],
            normals: [],
            faces: [
                MeshFace(indices: (0, 1, 2)),
                MeshFace(indices: (1, 3, 2))
            ]
        )
        let colors: [MeshVertexColor?] = [
            .init(red: 30, green: 60, blue: 90),
            .init(red: 60, green: 90, blue: 120),
            .init(red: 90, green: 120, blue: 150),
            nil
        ]

        let atlas = try #require(
            DerivedMeshTextureAtlasBuilder(maximumFaceCount: 8, texelsPerTile: 3)
                .build(snapshot: snapshot, vertexColors: colors)
        )

        #expect(atlas.faces.count == 1)
        #expect(atlas.faces[0].sourceVertexIndices == [0, 1, 2])
        #expect(atlas.faces[0].color == MeshVertexColor(red: 60, green: 90, blue: 120))
        #expect(atlas.width == 3)
        #expect(atlas.height == 3)
        #expect(atlas.color(atX: 0, y: 0) == MeshVertexColor(red: 30, green: 60, blue: 90))
        #expect(atlas.color(atX: 2, y: 0) == MeshVertexColor(red: 60, green: 90, blue: 120))
        #expect(atlas.color(atX: 0, y: 2) == MeshVertexColor(red: 90, green: 120, blue: 150))
        #expect(atlas.color(atX: 2, y: 2) == nil)
        #expect(atlas.faces[0].textureCoordinates[0] != atlas.faces[0].textureCoordinates[1])
    }

    @Test("Caps face work with deterministic end-to-end sampling")
    func boundsAndSamplesFacesDeterministically() throws {
        let snapshot = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: (0..<7).map { Point3D(x: Float($0), y: 0, z: 0) },
            normals: [],
            faces: [
                MeshFace(indices: (0, 1, 2)),
                MeshFace(indices: (1, 2, 3)),
                MeshFace(indices: (2, 3, 4)),
                MeshFace(indices: (3, 4, 5)),
                MeshFace(indices: (4, 5, 6))
            ]
        )
        let colors = (0..<7).map { index in
            MeshVertexColor(red: UInt8(index), green: 0, blue: 0)
        }

        let atlas = try #require(
            DerivedMeshTextureAtlasBuilder(maximumFaceCount: 2, texelsPerTile: 1)
                .build(snapshot: snapshot, vertexColors: colors)
        )

        #expect(atlas.faces.count == 2)
        #expect(atlas.faces.map(\.sourceVertexIndices) == [[0, 1, 2], [4, 5, 6]])
        #expect(atlas.width == 2)
        #expect(atlas.height == 1)
    }

    @Test("Does not derive a texture when no face has complete observed color")
    func returnsNilWithoutCompleteFaceColors() throws {
        let snapshot = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 1, y: 0, z: 0),
                Point3D(x: 0, y: 1, z: 0)
            ],
            normals: [],
            faces: [MeshFace(indices: (0, 1, 2))]
        )

        #expect(
            DerivedMeshTextureAtlasBuilder().build(
                snapshot: snapshot,
                vertexColors: [.init(red: 1, green: 2, blue: 3), nil, .init(red: 4, green: 5, blue: 6)]
            ) == nil
        )
    }
}
