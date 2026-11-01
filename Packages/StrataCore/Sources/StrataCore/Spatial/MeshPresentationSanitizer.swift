import Foundation

/// Produces bounded, render-safe copies of persisted mesh snapshots.
///
/// This is deliberately a presentation-only operation. It does not modify the
/// supplied snapshots, move vertices, reconstruct surfaces, or change
/// `worldFromAnchor`. Callers must continue to retain and export the original
/// source mesh data.
public struct MeshPresentationSanitizer: Sendable {
    public struct Configuration: Equatable, Sendable {
        private static let maximumSafeVerticesPerSnapshot = 250_000
        private static let maximumSafeFacesPerSnapshot = 500_000

        /// Triangles smaller than this local, anchor-space area are omitted.
        /// ARKit mesh-anchor coordinates are measured in meters, so the value is
        /// expressed in square meters.
        public let minimumTriangleAreaMetersSquared: Float

        /// Whether to omit finite vertices not referenced by a retained face.
        /// Vertex-only snapshots keep their finite vertices so that point-based
        /// presentation remains possible.
        public let compactUnreferencedVertices: Bool

        /// The number of source vertices inspected for one presentation
        /// snapshot. Limiting inspection, rather than only output, bounds work
        /// when a malformed persisted package contains an unexpectedly large
        /// mesh. Values above the sanitizer's hard safety limit are clamped.
        public let maximumVerticesPerSnapshot: Int

        /// The number of source faces inspected for one presentation snapshot.
        /// As with vertices, only the source prefix within this bound is
        /// considered, in source order. Values above the sanitizer's hard
        /// safety limit are clamped.
        public let maximumFacesPerSnapshot: Int

        public init(
            minimumTriangleAreaMetersSquared: Float = 0.000_001,
            compactUnreferencedVertices: Bool = true,
            maximumVerticesPerSnapshot: Int = 120_000,
            maximumFacesPerSnapshot: Int = 180_000
        ) {
            self.minimumTriangleAreaMetersSquared = minimumTriangleAreaMetersSquared.isFinite
                && minimumTriangleAreaMetersSquared >= 0
                ? minimumTriangleAreaMetersSquared
                : 0.000_001
            self.compactUnreferencedVertices = compactUnreferencedVertices
            self.maximumVerticesPerSnapshot = min(
                max(0, maximumVerticesPerSnapshot),
                Self.maximumSafeVerticesPerSnapshot
            )
            self.maximumFacesPerSnapshot = min(
                max(0, maximumFacesPerSnapshot),
                Self.maximumSafeFacesPerSnapshot
            )
        }
    }

    /// A render-safe snapshot plus the source index for each presentation
    /// vertex. For example, a retained source colour at
    /// `colors[sourceVertexIndexByPresentationVertex[index]]` belongs to
    /// `snapshot.vertices[index]`.
    public struct PresentationSnapshot: Equatable, Sendable {
        public let snapshot: MeshSnapshot
        public let sourceVertexIndexByPresentationVertex: [Int]

        init(
            snapshot: MeshSnapshot,
            sourceVertexIndexByPresentationVertex: [Int]
        ) {
            self.snapshot = snapshot
            self.sourceVertexIndexByPresentationVertex = sourceVertexIndexByPresentationVertex
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// Sanitizes snapshots in their input order, omitting any snapshot whose
    /// transform or remaining geometry cannot safely be presented.
    public func sanitize(_ snapshots: [MeshSnapshot]) -> [PresentationSnapshot] {
        snapshots.compactMap { sanitize($0) }
    }

    /// Returns a render-safe copy of a source snapshot, or `nil` when no
    /// finite local geometry can be presented with its original transform.
    public func sanitize(_ source: MeshSnapshot) -> PresentationSnapshot? {
        guard source.worldFromAnchor.columns.count == 16,
              source.worldFromAnchor.columns.allSatisfy(\.isFinite)
        else {
            return nil
        }

        let vertexLimit = min(source.vertices.count, configuration.maximumVerticesPerSnapshot)
        var vertices: [Point3D] = []
        var sourceVertexIndexByPresentationVertex: [Int] = []
        var presentationIndexBySourceVertex: [Int: Int] = [:]
        vertices.reserveCapacity(vertexLimit)
        sourceVertexIndexByPresentationVertex.reserveCapacity(vertexLimit)
        presentationIndexBySourceVertex.reserveCapacity(vertexLimit)

        if vertexLimit > 0 {
            for sourceIndex in 0..<vertexLimit {
                let vertex = source.vertices[sourceIndex]
                guard Self.isFinite(vertex) else { continue }

                presentationIndexBySourceVertex[sourceIndex] = vertices.count
                vertices.append(vertex)
                sourceVertexIndexByPresentationVertex.append(sourceIndex)
            }
        }

        // A vertex-only snapshot is useful for point-based presentation, but a
        // snapshot without any finite vertices has nothing honest to render.
        guard !vertices.isEmpty else { return nil }

        var normals = sanitizedNormals(
            from: source,
            sourceVertexIndexByPresentationVertex: sourceVertexIndexByPresentationVertex
        )
        var faces: [MeshFace] = []
        var retainedSourceFaceIndices: [Int] = []
        let faceLimit = min(source.faces.count, configuration.maximumFacesPerSnapshot)
        faces.reserveCapacity(faceLimit)
        retainedSourceFaceIndices.reserveCapacity(faceLimit)

        if faceLimit > 0 {
            for sourceFaceIndex in 0..<faceLimit {
                let sourceFace = source.faces[sourceFaceIndex]
                guard let first = presentationIndexBySourceVertex[sourceFace.first],
                      let second = presentationIndexBySourceVertex[sourceFace.second],
                      let third = presentationIndexBySourceVertex[sourceFace.third],
                      first != second,
                      second != third,
                      first != third,
                      Self.hasUsableArea(
                          first: vertices[first],
                          second: vertices[second],
                          third: vertices[third],
                          minimumAreaMetersSquared: configuration.minimumTriangleAreaMetersSquared
                      )
                else {
                    continue
                }

                faces.append(MeshFace(indices: (first, second, third)))
                retainedSourceFaceIndices.append(sourceFaceIndex)
            }
        }

        let classifications: [MeshClassification]
        if source.classifications.count == source.faces.count {
            classifications = retainedSourceFaceIndices.map { source.classifications[$0] }
        } else {
            classifications = []
        }

        if configuration.compactUnreferencedVertices, !faces.isEmpty {
            guard let compacted = compact(
                vertices: vertices,
                normals: normals,
                faces: faces,
                sourceVertexIndexByPresentationVertex: sourceVertexIndexByPresentationVertex
            ) else {
                return nil
            }
            vertices = compacted.vertices
            normals = compacted.normals
            faces = compacted.faces
            sourceVertexIndexByPresentationVertex = compacted.sourceVertexIndexByPresentationVertex
        }

        do {
            let snapshot = try MeshSnapshot(
                anchorID: source.anchorID,
                worldFromAnchor: source.worldFromAnchor,
                vertices: vertices,
                normals: normals,
                faces: faces,
                classifications: classifications
            )
            return PresentationSnapshot(
                snapshot: snapshot,
                sourceVertexIndexByPresentationVertex: sourceVertexIndexByPresentationVertex
            )
        } catch {
            // The source may have been decoded from a malformed package. Do not
            // repair it by inventing geometry if it still fails domain checks.
            return nil
        }
    }

    private func sanitizedNormals(
        from source: MeshSnapshot,
        sourceVertexIndexByPresentationVertex: [Int]
    ) -> [Point3D] {
        guard source.normals.count == source.vertices.count else { return [] }

        var normals: [Point3D] = []
        normals.reserveCapacity(sourceVertexIndexByPresentationVertex.count)
        for sourceIndex in sourceVertexIndexByPresentationVertex {
            let normal = source.normals[sourceIndex]
            guard Self.isFinite(normal) else { return [] }
            normals.append(normal)
        }
        return normals
    }

    private func compact(
        vertices: [Point3D],
        normals: [Point3D],
        faces: [MeshFace],
        sourceVertexIndexByPresentationVertex: [Int]
    ) -> (
        vertices: [Point3D],
        normals: [Point3D],
        faces: [MeshFace],
        sourceVertexIndexByPresentationVertex: [Int]
    )? {
        var isReferenced = Array(repeating: false, count: vertices.count)
        for face in faces {
            guard face.first >= 0,
                  face.second >= 0,
                  face.third >= 0,
                  face.first < vertices.count,
                  face.second < vertices.count,
                  face.third < vertices.count
            else {
                return nil
            }
            isReferenced[face.first] = true
            isReferenced[face.second] = true
            isReferenced[face.third] = true
        }

        var compactedVertices: [Point3D] = []
        var compactedNormals: [Point3D] = []
        var compactedSourceIndices: [Int] = []
        var compactedIndexByPresentationIndex = Array(repeating: -1, count: vertices.count)
        compactedVertices.reserveCapacity(vertices.count)
        compactedNormals.reserveCapacity(normals.count)
        compactedSourceIndices.reserveCapacity(sourceVertexIndexByPresentationVertex.count)

        for presentationIndex in vertices.indices where isReferenced[presentationIndex] {
            compactedIndexByPresentationIndex[presentationIndex] = compactedVertices.count
            compactedVertices.append(vertices[presentationIndex])
            compactedSourceIndices.append(sourceVertexIndexByPresentationVertex[presentationIndex])
            if !normals.isEmpty {
                compactedNormals.append(normals[presentationIndex])
            }
        }

        var compactedFaces: [MeshFace] = []
        compactedFaces.reserveCapacity(faces.count)
        for face in faces {
            let first = compactedIndexByPresentationIndex[face.first]
            let second = compactedIndexByPresentationIndex[face.second]
            let third = compactedIndexByPresentationIndex[face.third]
            guard first >= 0, second >= 0, third >= 0 else { return nil }
            compactedFaces.append(MeshFace(indices: (first, second, third)))
        }

        return (
            vertices: compactedVertices,
            normals: compactedNormals,
            faces: compactedFaces,
            sourceVertexIndexByPresentationVertex: compactedSourceIndices
        )
    }

    private static func hasUsableArea(
        first: Point3D,
        second: Point3D,
        third: Point3D,
        minimumAreaMetersSquared: Float
    ) -> Bool {
        let first = (x: Double(first.x), y: Double(first.y), z: Double(first.z))
        let second = (x: Double(second.x), y: Double(second.y), z: Double(second.z))
        let third = (x: Double(third.x), y: Double(third.y), z: Double(third.z))

        let secondFromFirst = (
            x: second.x - first.x,
            y: second.y - first.y,
            z: second.z - first.z
        )
        let thirdFromFirst = (
            x: third.x - first.x,
            y: third.y - first.y,
            z: third.z - first.z
        )
        let cross = (
            x: secondFromFirst.y * thirdFromFirst.z - secondFromFirst.z * thirdFromFirst.y,
            y: secondFromFirst.z * thirdFromFirst.x - secondFromFirst.x * thirdFromFirst.z,
            z: secondFromFirst.x * thirdFromFirst.y - secondFromFirst.y * thirdFromFirst.x
        )
        let doubledAreaSquared = cross.x * cross.x + cross.y * cross.y + cross.z * cross.z
        guard doubledAreaSquared.isFinite, doubledAreaSquared > 0 else { return false }

        let minimumDoubledArea = 2 * Double(minimumAreaMetersSquared)
        return doubledAreaSquared >= minimumDoubledArea * minimumDoubledArea
    }

    private static func isFinite(_ point: Point3D) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }
}
