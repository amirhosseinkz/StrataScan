import Foundation

public enum AlignmentMethod: String, Codable, CaseIterable, Sendable {
    case manual
    case landmarks
    case icp
    case automaticRegistration
}

/// A non-destructive relationship from immutable source coordinates into target
/// scan coordinates. The name carries matrix direction explicitly.
public struct ScanAlignment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var targetScanID: UUID
    public var sourceScanID: UUID
    public var targetFromSource: Transform4x4
    public var method: AlignmentMethod
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        targetScanID: UUID,
        sourceScanID: UUID,
        targetFromSource: Transform4x4,
        method: AlignmentMethod,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.targetScanID = targetScanID
        self.sourceScanID = sourceScanID
        self.targetFromSource = targetFromSource
        self.method = method
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AlignmentEstimate: Equatable, Sendable {
    public var targetFromSource: Transform4x4
    public var rmsError: Float
    public var correspondenceCount: Int

    public init(targetFromSource: Transform4x4, rmsError: Float, correspondenceCount: Int) {
        self.targetFromSource = targetFromSource
        self.rmsError = rmsError
        self.correspondenceCount = correspondenceCount
    }
}

public enum AlignmentError: Error, Equatable, Sendable {
    case insufficientLandmarks
    case mismatchedLandmarkCount
    case degenerateLandmarks
    case sameScan
    case invalidTransform
}

/// The user-selected correspondences that support a saved scan alignment.
/// Points remain in their respective immutable scan coordinate frames; only
/// the derived `ScanAlignment` maps source coordinates into target coordinates.
public struct ScanAlignmentLandmarkSet: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var targetScanID: UUID
    public var sourceScanID: UUID
    public var targetLandmarks: [Point3D]
    public var sourceLandmarks: [Point3D]
    public var rmsErrorMeters: Float
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        targetScanID: UUID,
        sourceScanID: UUID,
        targetLandmarks: [Point3D],
        sourceLandmarks: [Point3D],
        rmsErrorMeters: Float,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.targetScanID = targetScanID
        self.sourceScanID = sourceScanID
        self.targetLandmarks = targetLandmarks
        self.sourceLandmarks = sourceLandmarks
        self.rmsErrorMeters = rmsErrorMeters
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        guard targetScanID != sourceScanID else { throw AlignmentError.sameScan }
        guard targetLandmarks.count == sourceLandmarks.count else {
            throw AlignmentError.mismatchedLandmarkCount
        }
        guard targetLandmarks.count >= 3 else { throw AlignmentError.insufficientLandmarks }
        guard rmsErrorMeters.isFinite, rmsErrorMeters >= 0 else {
            throw AlignmentError.invalidTransform
        }
        guard (targetLandmarks + sourceLandmarks).allSatisfy({
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
        }) else {
            throw AlignmentError.invalidTransform
        }
    }
}

public protocol AlignmentStoring: Sendable {
    func save(_ alignment: ScanAlignment) async throws
    func alignment(targetScanID: UUID, sourceScanID: UUID) async -> ScanAlignment?
    func remove(targetScanID: UUID, sourceScanID: UUID) async
}

public struct ManualAlignmentEngine: Sendable {
    public init() {}

    public func transform(translation: Point3D, rotationRadians: Float, axis: Axis3D) -> Transform4x4 {
        Transform4x4.translation(x: translation.x, y: translation.y, z: translation.z)
            .composed(with: .rotation(radians: rotationRadians, axis: axis))
    }

    public func reset() -> Transform4x4 { .identity }
}

/// Rigid landmark registration using Horn's unit-quaternion formulation. It
/// estimates rotation and translation only; fixed LiDAR meter scale is preserved.
public struct LandmarkAlignmentEngine: Sendable {
    public init() {}

    public func estimate(source: [Point3D], target: [Point3D]) throws -> AlignmentEstimate {
        guard source.count == target.count else { throw AlignmentError.mismatchedLandmarkCount }
        guard source.count >= 3 else { throw AlignmentError.insufficientLandmarks }

        let sourceCentroid = centroid(source)
        let targetCentroid = centroid(target)
        let centeredSource = source.map { subtract($0, sourceCentroid) }
        let centeredTarget = target.map { subtract($0, targetCentroid) }
        guard squaredLengthSum(centeredSource) > 0.000_000_1, squaredLengthSum(centeredTarget) > 0.000_000_1 else {
            throw AlignmentError.degenerateLandmarks
        }

        var covariance = Array(repeating: Array(repeating: Double.zero, count: 3), count: 3)
        for (left, right) in zip(centeredSource, centeredTarget) {
            let sourceVector = [Double(left.x), Double(left.y), Double(left.z)]
            let targetVector = [Double(right.x), Double(right.y), Double(right.z)]
            for row in 0..<3 {
                for column in 0..<3 {
                    covariance[row][column] += sourceVector[row] * targetVector[column]
                }
            }
        }

        let quaternion = largestEigenvector(of: hornMatrix(from: covariance))
        guard quaternion.count == 4 else { throw AlignmentError.invalidTransform }
        let rotation = rotationMatrix(from: quaternion)
        let rotatedSourceCentroid = apply(rotation, to: sourceCentroid)
        let translation = subtract(targetCentroid, rotatedSourceCentroid)
        let transform = try makeTransform(rotation: rotation, translation: translation)

        var squaredError: Float = 0
        for (sourcePoint, targetPoint) in zip(source, target) {
            let delta = subtract(transform.applying(to: sourcePoint), targetPoint)
            squaredError += dot(delta, delta)
        }
        return AlignmentEstimate(
            targetFromSource: transform,
            rmsError: sqrt(squaredError / Float(source.count)),
            correspondenceCount: source.count
        )
    }

    private func centroid(_ points: [Point3D]) -> Point3D {
        let summed = points.reduce(Point3D(x: 0, y: 0, z: 0), add)
        let divisor = Float(points.count)
        return Point3D(x: summed.x / divisor, y: summed.y / divisor, z: summed.z / divisor)
    }

    private func hornMatrix(from s: [[Double]]) -> [[Double]] {
        let sxx = s[0][0], sxy = s[0][1], sxz = s[0][2]
        let syx = s[1][0], syy = s[1][1], syz = s[1][2]
        let szx = s[2][0], szy = s[2][1], szz = s[2][2]
        return [
            [sxx + syy + szz, syz - szy, szx - sxz, sxy - syx],
            [syz - szy, sxx - syy - szz, sxy + syx, szx + sxz],
            [szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy],
            [sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz]
        ]
    }

    private func largestEigenvector(of matrix: [[Double]]) -> [Double] {
        var values = matrix
        var vectors = identityMatrix(size: 4)
        for _ in 0..<64 {
            var largest = 0.0
            var pivot = (0, 1)
            for row in 0..<4 {
                for column in (row + 1)..<4 where abs(values[row][column]) > largest {
                    largest = abs(values[row][column])
                    pivot = (row, column)
                }
            }
            guard largest > 0.000_000_000_001 else { break }

            let p = pivot.0
            let q = pivot.1
            let angle = 0.5 * atan2(2 * values[p][q], values[q][q] - values[p][p])
            let cosine = cos(angle)
            let sine = sin(angle)
            let app = values[p][p]
            let aqq = values[q][q]
            let apq = values[p][q]

            values[p][p] = cosine * cosine * app - 2 * sine * cosine * apq + sine * sine * aqq
            values[q][q] = sine * sine * app + 2 * sine * cosine * apq + cosine * cosine * aqq
            values[p][q] = 0
            values[q][p] = 0
            for index in 0..<4 where index != p && index != q {
                let aip = values[index][p]
                let aiq = values[index][q]
                values[index][p] = cosine * aip - sine * aiq
                values[p][index] = values[index][p]
                values[index][q] = sine * aip + cosine * aiq
                values[q][index] = values[index][q]
            }
            for row in 0..<4 {
                let vip = vectors[row][p]
                let viq = vectors[row][q]
                vectors[row][p] = cosine * vip - sine * viq
                vectors[row][q] = sine * vip + cosine * viq
            }
        }
        let index = (0..<4).max { values[$0][$0] < values[$1][$1] } ?? 0
        let vector = (0..<4).map { vectors[$0][index] }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? vector.map { $0 / norm } : []
    }

    private func rotationMatrix(from quaternion: [Double]) -> [[Float]] {
        let w = quaternion[0], x = quaternion[1], y = quaternion[2], z = quaternion[3]
        return [
            [Float(w * w + x * x - y * y - z * z), Float(2 * (x * y - w * z)), Float(2 * (x * z + w * y))],
            [Float(2 * (x * y + w * z)), Float(w * w - x * x + y * y - z * z), Float(2 * (y * z - w * x))],
            [Float(2 * (x * z - w * y)), Float(2 * (y * z + w * x)), Float(w * w - x * x - y * y + z * z)]
        ]
    }

    private func makeTransform(rotation: [[Float]], translation: Point3D) throws -> Transform4x4 {
        try Transform4x4(columns: [
            rotation[0][0], rotation[1][0], rotation[2][0], 0,
            rotation[0][1], rotation[1][1], rotation[2][1], 0,
            rotation[0][2], rotation[1][2], rotation[2][2], 0,
            translation.x, translation.y, translation.z, 1
        ])
    }

    private func apply(_ matrix: [[Float]], to point: Point3D) -> Point3D {
        Point3D(
            x: matrix[0][0] * point.x + matrix[0][1] * point.y + matrix[0][2] * point.z,
            y: matrix[1][0] * point.x + matrix[1][1] * point.y + matrix[1][2] * point.z,
            z: matrix[2][0] * point.x + matrix[2][1] * point.y + matrix[2][2] * point.z
        )
    }

    private func identityMatrix(size: Int) -> [[Double]] {
        (0..<size).map { row in (0..<size).map { $0 == row ? 1 : 0 } }
    }

    private func add(_ left: Point3D, _ right: Point3D) -> Point3D {
        Point3D(x: left.x + right.x, y: left.y + right.y, z: left.z + right.z)
    }

    private func subtract(_ left: Point3D, _ right: Point3D) -> Point3D {
        Point3D(x: left.x - right.x, y: left.y - right.y, z: left.z - right.z)
    }

    private func dot(_ left: Point3D, _ right: Point3D) -> Float {
        left.x * right.x + left.y * right.y + left.z * right.z
    }

    private func squaredLengthSum(_ points: [Point3D]) -> Float {
        points.reduce(0) { $0 + dot($1, $1) }
    }
}

public actor InMemoryAlignmentStore: AlignmentStoring {
    private struct Key: Hashable, Sendable {
        var targetScanID: UUID
        var sourceScanID: UUID
    }

    private var alignments: [Key: ScanAlignment] = [:]

    public init() {}

    public func save(_ alignment: ScanAlignment) throws {
        guard alignment.targetScanID != alignment.sourceScanID else {
            throw AlignmentError.sameScan
        }
        alignments[Key(targetScanID: alignment.targetScanID, sourceScanID: alignment.sourceScanID)] = alignment
    }

    public func alignment(targetScanID: UUID, sourceScanID: UUID) -> ScanAlignment? {
        alignments[Key(targetScanID: targetScanID, sourceScanID: sourceScanID)]
    }

    public func remove(targetScanID: UUID, sourceScanID: UUID) {
        alignments.removeValue(forKey: Key(targetScanID: targetScanID, sourceScanID: sourceScanID))
    }
}

/// Durable alignment persistence delegates relationship records to the metadata
/// store while source geometry remains external immutable package data.
public actor SQLiteAlignmentStore: AlignmentStoring {
    private let metadataStore: SQLiteMetadataStore

    public init(metadataStore: SQLiteMetadataStore) {
        self.metadataStore = metadataStore
    }

    public func save(_ alignment: ScanAlignment) async throws {
        try await metadataStore.saveAlignment(alignment)
    }

    public func alignment(targetScanID: UUID, sourceScanID: UUID) async -> ScanAlignment? {
        try? await metadataStore.alignment(targetScanID: targetScanID, sourceScanID: sourceScanID)
    }

    public func remove(targetScanID: UUID, sourceScanID: UUID) async {
        try? await metadataStore.deleteAlignment(targetScanID: targetScanID, sourceScanID: sourceScanID)
    }
}
