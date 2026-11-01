import Foundation

public enum MeshClassification: String, Codable, CaseIterable, Sendable {
    case none
    case wall
    case floor
    case ceiling
    case table
    case seat
    case window
    case door
    case unknown
}

public struct MeshFace: Codable, Equatable, Sendable {
    public var first: Int
    public var second: Int
    public var third: Int

    public init(indices: (Int, Int, Int)) {
        first = indices.0
        second = indices.1
        third = indices.2
    }

    public var indices: [Int] { [first, second, third] }
}

public enum MeshSnapshotError: Error, Equatable, Sendable {
    case normalCountMismatch
    case classificationCountMismatch
    case faceIndexOutOfRange(face: Int, index: Int)
    case nonFiniteGeometry
}

public enum MeshSnapshotProvenance: String, Codable, CaseIterable, Sendable {
    case anchorUpdate
    case finalSessionSnapshot
}

/// Immutable snapshot of one ARKit mesh anchor. Vertices remain anchor-local;
/// `worldFromAnchor` preserves the relationship needed for later processing.
public struct MeshSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var anchorID: UUID
    public var worldFromAnchor: Transform4x4
    public var vertices: [Point3D]
    public var normals: [Point3D]
    public var faces: [MeshFace]
    public var classifications: [MeshClassification]
    /// ARFrame timeline timestamp when this immutable anchor state was copied.
    /// Nil only for legacy packages and presentation-derived snapshots.
    public var captureTimestamp: TimeInterval?
    public var provenance: MeshSnapshotProvenance?

    public var id: UUID { anchorID }

    public init(
        anchorID: UUID,
        worldFromAnchor: Transform4x4,
        vertices: [Point3D],
        normals: [Point3D],
        faces: [MeshFace],
        classifications: [MeshClassification] = [],
        captureTimestamp: TimeInterval? = nil,
        provenance: MeshSnapshotProvenance? = nil
    ) throws {
        guard worldFromAnchor.columns.allSatisfy(\.isFinite),
              vertices.allSatisfy(Self.isFinite),
              normals.allSatisfy(Self.isFinite)
        else {
            throw MeshSnapshotError.nonFiniteGeometry
        }
        guard normals.isEmpty || normals.count == vertices.count else {
            throw MeshSnapshotError.normalCountMismatch
        }
        guard classifications.isEmpty || classifications.count == faces.count else {
            throw MeshSnapshotError.classificationCountMismatch
        }
        guard (captureTimestamp?.isFinite ?? true),
              (captureTimestamp == nil) == (provenance == nil)
        else {
            throw MeshSnapshotError.nonFiniteGeometry
        }
        for (faceIndex, face) in faces.enumerated() {
            for index in face.indices where index < 0 || index >= vertices.count {
                throw MeshSnapshotError.faceIndexOutOfRange(face: faceIndex, index: index)
            }
        }
        self.anchorID = anchorID
        self.worldFromAnchor = worldFromAnchor
        self.vertices = vertices
        self.normals = normals
        self.faces = faces
        self.classifications = classifications
        self.captureTimestamp = captureTimestamp
        self.provenance = provenance
    }

    public var worldVertices: [Point3D] {
        vertices.map(worldFromAnchor.applying)
    }

    private static func isFinite(_ point: Point3D) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }
}

/// Updates replace an anchor's prior snapshot. This avoids retaining the entire
/// historical AR mesh stream while keeping current scene reconstruction data.
public actor MeshSnapshotAccumulator {
    private var snapshotsByAnchorID: [UUID: MeshSnapshot] = [:]

    public init() {}

    public func replace(_ snapshot: MeshSnapshot) {
        snapshotsByAnchorID[snapshot.anchorID] = snapshot
    }

    public func remove(anchorIDs: [UUID]) {
        for id in anchorIDs {
            snapshotsByAnchorID.removeValue(forKey: id)
        }
    }

    public func replaceAll(_ snapshots: [MeshSnapshot]) {
        snapshotsByAnchorID = Dictionary(
            snapshots.map { ($0.anchorID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    public func snapshots() -> [MeshSnapshot] {
        snapshotsByAnchorID.values.sorted { $0.anchorID.uuidString < $1.anchorID.uuidString }
    }

    public func clear() {
        snapshotsByAnchorID.removeAll(keepingCapacity: false)
    }
}

/// Latest-state mesh registry intended to be owned by one actor. Production
/// capture owns it on the ARKit adapter's MainActor, so delegate callbacks can
/// update every active anchor synchronously without a lossy event hop.
public struct MeshAnchorRegistry: Sendable {
    private var snapshotsByAnchorID: [UUID: MeshSnapshot] = [:]

    public init() {}

    public mutating func replace(_ snapshot: MeshSnapshot) {
        snapshotsByAnchorID[snapshot.anchorID] = snapshot
    }

    public mutating func remove(anchorIDs: [UUID]) {
        for anchorID in anchorIDs {
            snapshotsByAnchorID.removeValue(forKey: anchorID)
        }
    }

    public mutating func replaceAll(_ snapshots: [MeshSnapshot]) {
        snapshotsByAnchorID = Dictionary(
            snapshots.map { ($0.anchorID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    public var snapshots: [MeshSnapshot] {
        snapshotsByAnchorID.values.sorted { $0.anchorID.uuidString < $1.anchorID.uuidString }
    }

    public mutating func removeAll() {
        snapshotsByAnchorID.removeAll(keepingCapacity: false)
    }
}
