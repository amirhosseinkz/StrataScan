import Foundation
import Testing
@testable import StrataCore

@Suite("Mesh presentation sanitizer")
struct MeshPresentationSanitizerTests {
    @Test("Normalizes unsafe presentation bounds into fixed safe limits")
    func normalizesConfigurationBounds() {
        let configuration = MeshPresentationSanitizer.Configuration(
            minimumTriangleAreaMetersSquared: .nan,
            maximumVerticesPerSnapshot: .max,
            maximumFacesPerSnapshot: -1
        )

        #expect(configuration.minimumTriangleAreaMetersSquared == 0.000_001)
        #expect(configuration.maximumVerticesPerSnapshot == 250_000)
        #expect(configuration.maximumFacesPerSnapshot == 0)
    }

    @Test("Removes malformed, degenerate, and tiny faces without changing source coordinates")
    func removesUnsafeFacesWithoutMutatingSource() throws {
        let transform = Transform4x4.translation(x: 4, y: -2, z: 7)
        var source = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: transform,
            vertices: [
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 1, y: 0, z: 0),
                Point3D(x: 0, y: 1, z: 0),
                Point3D(x: 0.000_1, y: 0, z: 0),
                Point3D(x: 0, y: 0.000_1, z: 0)
            ],
            normals: [],
            faces: [
                MeshFace(indices: (0, 1, 2)),
                MeshFace(indices: (0, 0, 1)),
                MeshFace(indices: (0, 3, 4))
            ],
            classifications: [.wall, .floor, .table]
        )
        source.faces.append(MeshFace(indices: (0, 1, 99)))
        source.classifications.append(.door)
        let original = source

        let presentation = MeshPresentationSanitizer().sanitize(source)

        #expect(presentation != nil)
        guard let presentation else { return }
        #expect(presentation.snapshot.worldFromAnchor == transform)
        #expect(presentation.snapshot.vertices == Array(source.vertices.prefix(3)))
        #expect(presentation.snapshot.faces == [MeshFace(indices: (0, 1, 2))])
        #expect(presentation.snapshot.classifications == [.wall])
        #expect(presentation.sourceVertexIndexByPresentationVertex == [0, 1, 2])
        #expect(source == original)
    }

    @Test("Drops non-finite transforms and preserves only finite local point geometry")
    func handlesNonFinitePersistedGeometry() throws {
        var source = try MeshSnapshot(
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
        source.vertices[1] = Point3D(x: .nan, y: 0, z: 0)

        let presentation = MeshPresentationSanitizer().sanitize(source)

        #expect(presentation != nil)
        guard let presentation else { return }
        #expect(presentation.snapshot.vertices == [source.vertices[0], source.vertices[2]])
        #expect(presentation.snapshot.faces.isEmpty)
        #expect(presentation.sourceVertexIndexByPresentationVertex == [0, 2])
        #expect(source.vertices[1].x.isNaN)

        var invalidTransformSource = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [Point3D(x: 0, y: 0, z: 0)],
            normals: [],
            faces: []
        )
        invalidTransformSource.worldFromAnchor = try Transform4x4(columns: [
            .nan, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1
        ])

        #expect(MeshPresentationSanitizer().sanitize(invalidTransformSource) == nil)
    }

    @Test("Compacts vertices with a stable source-index map and retains aligned attributes")
    func compactsReferencedVertices() throws {
        let vertices = [
            Point3D(x: -1, y: -1, z: 0),
            Point3D(x: 0, y: 0, z: 0),
            Point3D(x: 2, y: 2, z: 0),
            Point3D(x: 1, y: 0, z: 0),
            Point3D(x: 0, y: 1, z: 0)
        ]
        let normals = [
            Point3D(x: 0, y: 0, z: 1),
            Point3D(x: 0, y: 0, z: 2),
            Point3D(x: 0, y: 0, z: 3),
            Point3D(x: 0, y: 0, z: 4),
            Point3D(x: 0, y: 0, z: 5)
        ]
        let source = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .translation(x: 3, y: 4, z: 5),
            vertices: vertices,
            normals: normals,
            faces: [MeshFace(indices: (1, 3, 4))],
            classifications: [.ceiling]
        )

        let compacted = MeshPresentationSanitizer().sanitize(source)
        #expect(compacted != nil)
        guard let compacted else { return }
        #expect(compacted.snapshot.vertices == [vertices[1], vertices[3], vertices[4]])
        #expect(compacted.snapshot.normals == [normals[1], normals[3], normals[4]])
        #expect(compacted.snapshot.faces == [MeshFace(indices: (0, 1, 2))])
        #expect(compacted.snapshot.classifications == [.ceiling])
        #expect(compacted.sourceVertexIndexByPresentationVertex == [1, 3, 4])
        #expect(compacted.snapshot.worldFromAnchor == source.worldFromAnchor)

        let uncompressed = MeshPresentationSanitizer(
            configuration: .init(compactUnreferencedVertices: false)
        ).sanitize(source)
        #expect(uncompressed != nil)
        guard let uncompressed else { return }
        #expect(uncompressed.snapshot.vertices == vertices)
        #expect(uncompressed.snapshot.normals == normals)
        #expect(uncompressed.snapshot.faces == [MeshFace(indices: (1, 3, 4))])
        #expect(uncompressed.sourceVertexIndexByPresentationVertex == [0, 1, 2, 3, 4])
    }

    @Test("Keeps finite vertex-only geometry available for point presentation")
    func retainsVertexOnlySnapshot() throws {
        let vertices = [
            Point3D(x: 0, y: 0, z: 0),
            Point3D(x: 0.5, y: 0.5, z: 0.5)
        ]
        let source = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .translation(x: 1, y: 2, z: 3),
            vertices: vertices,
            normals: [],
            faces: []
        )

        let presentation = MeshPresentationSanitizer().sanitize(source)

        #expect(presentation != nil)
        guard let presentation else { return }
        #expect(presentation.snapshot.vertices == vertices)
        #expect(presentation.snapshot.faces.isEmpty)
        #expect(presentation.sourceVertexIndexByPresentationVertex == [0, 1])
        #expect(presentation.snapshot.worldFromAnchor == source.worldFromAnchor)
    }

    @Test("Uses stable source order within vertex and face bounds")
    func appliesDeterministicBounds() throws {
        let vertices = [
            Point3D(x: 0, y: 0, z: 0),
            Point3D(x: 1, y: 0, z: 0),
            Point3D(x: 0, y: 1, z: 0),
            Point3D(x: 1, y: 1, z: 0),
            Point3D(x: 2, y: 0, z: 0)
        ]
        let source = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: vertices,
            normals: [],
            faces: [
                MeshFace(indices: (0, 1, 2)),
                MeshFace(indices: (1, 3, 2)),
                MeshFace(indices: (2, 3, 4))
            ]
        )
        let sanitizer = MeshPresentationSanitizer(
            configuration: .init(
                compactUnreferencedVertices: false,
                maximumVerticesPerSnapshot: 4,
                maximumFacesPerSnapshot: 1
            )
        )

        let first = sanitizer.sanitize(source)
        let second = sanitizer.sanitize(source)

        #expect(first != nil)
        #expect(first == second)
        guard let first else { return }
        #expect(first.snapshot.vertices == Array(vertices.prefix(4)))
        #expect(first.snapshot.faces == [MeshFace(indices: (0, 1, 2))])
        #expect(first.sourceVertexIndexByPresentationVertex == [0, 1, 2, 3])
    }

    @Test("Drops malformed normals and classifications rather than repairing them")
    func omitsMalformedOptionalAttributes() throws {
        let vertices = [
            Point3D(x: 0, y: 0, z: 0),
            Point3D(x: 1, y: 0, z: 0),
            Point3D(x: 0, y: 1, z: 0)
        ]
        var source = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: vertices,
            normals: [
                Point3D(x: 0, y: 0, z: 1),
                Point3D(x: 0, y: 0, z: 1),
                Point3D(x: 0, y: 0, z: 1)
            ],
            faces: [MeshFace(indices: (0, 1, 2))],
            classifications: [.wall]
        )
        source.normals[1] = Point3D(x: .infinity, y: 0, z: 1)
        source.classifications = []

        let presentation = MeshPresentationSanitizer().sanitize(source)

        #expect(presentation != nil)
        guard let presentation else { return }
        #expect(presentation.snapshot.vertices == vertices)
        #expect(presentation.snapshot.normals.isEmpty)
        #expect(presentation.snapshot.faces == [MeshFace(indices: (0, 1, 2))])
        #expect(presentation.snapshot.classifications.isEmpty)
        #expect(source.normals[1].x.isInfinite)
        #expect(source.classifications.isEmpty)
    }
}
