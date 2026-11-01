import Foundation
import Testing
@testable import StrataCore

@Suite("Surface mesh snapshots")
struct MeshTests {
    @Test("Anchor-local vertices map into documented world coordinates")
    func mapsAnchorVerticesToWorld() throws {
        let id = try #require(UUID(uuidString: "8C217618-54DD-4891-A7F5-3B8ED8A19A1D"))
        let snapshot = try MeshSnapshot(
            anchorID: id,
            worldFromAnchor: .translation(x: 5, y: 0, z: 0),
            vertices: [Point3D(x: 1, y: 2, z: 3), Point3D(x: 0, y: 0, z: 0), Point3D(x: 0, y: 1, z: 0)],
            normals: [Point3D(x: 0, y: 0, z: 1), Point3D(x: 0, y: 0, z: 1), Point3D(x: 0, y: 0, z: 1)],
            faces: [MeshFace(indices: (0, 1, 2))],
            classifications: [.wall]
        )

        #expect(snapshot.worldVertices[0].isApproximatelyEqual(to: Point3D(x: 6, y: 2, z: 3)))
        #expect(snapshot.classifications == [.wall])
    }

    @Test("A newer anchor snapshot replaces instead of appending geometry history")
    func replacesAnchorSnapshot() async throws {
        let id = UUID()
        let first = try MeshSnapshot(
            anchorID: id,
            worldFromAnchor: .identity,
            vertices: [Point3D(x: 0, y: 0, z: 0), Point3D(x: 1, y: 0, z: 0), Point3D(x: 0, y: 1, z: 0)],
            normals: [],
            faces: [MeshFace(indices: (0, 1, 2))]
        )
        let replacement = try MeshSnapshot(
            anchorID: id,
            worldFromAnchor: .identity,
            vertices: [Point3D(x: 0, y: 0, z: 0), Point3D(x: 2, y: 0, z: 0), Point3D(x: 0, y: 2, z: 0)],
            normals: [],
            faces: [MeshFace(indices: (0, 1, 2))]
        )
        let accumulator = MeshSnapshotAccumulator()

        await accumulator.replace(first)
        await accumulator.replace(replacement)

        let all = await accumulator.snapshots()
        #expect(all == [replacement])
    }

    @Test("Authoritative registry preserves every active latest anchor")
    func registryAppliesUpdatesAndRemovals() throws {
        let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let first = try snapshot(id: firstID, extent: 1)
        let firstReplacement = try snapshot(id: firstID, extent: 2)
        let second = try snapshot(id: secondID, extent: 3)
        var registry = MeshAnchorRegistry()

        registry.replace(first)
        registry.replace(second)
        registry.replace(firstReplacement)
        #expect(registry.snapshots == [firstReplacement, second])

        registry.remove(anchorIDs: [firstID])
        #expect(registry.snapshots == [second])

        registry.replaceAll([first, second])
        #expect(registry.snapshots == [first, second])
    }

    @Test("Out-of-range faces are rejected before persistence")
    func rejectsInvalidFaceIndices() {
        #expect(throws: MeshSnapshotError.faceIndexOutOfRange(face: 0, index: 3)) {
            _ = try MeshSnapshot(
                anchorID: UUID(),
                worldFromAnchor: .identity,
                vertices: [Point3D(x: 0, y: 0, z: 0)],
                normals: [],
                faces: [MeshFace(indices: (0, 3, 0))]
            )
        }
    }

    private func snapshot(id: UUID, extent: Float) throws -> MeshSnapshot {
        try MeshSnapshot(
            anchorID: id,
            worldFromAnchor: .identity,
            vertices: [
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: extent, y: 0, z: 0),
                Point3D(x: 0, y: extent, z: 0)
            ],
            normals: [],
            faces: [MeshFace(indices: (0, 1, 2))]
        )
    }
}
