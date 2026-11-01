import Foundation

public struct Point3D: Codable, Hashable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    public func isApproximatelyEqual(to other: Point3D, tolerance: Float = 0.000_01) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(z - other.z) <= tolerance
    }
}

public enum Axis3D: String, Codable, CaseIterable, Sendable {
    case x
    case y
    case z

    fileprivate var unitVector: Point3D {
        switch self {
        case .x: Point3D(x: 1, y: 0, z: 0)
        case .y: Point3D(x: 0, y: 1, z: 0)
        case .z: Point3D(x: 0, y: 0, z: 1)
        }
    }
}

public enum TransformError: Error, Equatable, Sendable {
    case invalidElementCount(Int)
    case singularMatrix
}

/// A persisted, column-major transform that maps a local homogeneous point into
/// its parent coordinate system. `a.composed(with: b)` applies `b` first, then
/// `a`, matching `parentFromLocal * localPoint` convention used by ARKit.
public struct Transform4x4: Codable, Equatable, Sendable {
    public let columns: [Float]

    public init(columns: [Float]) throws {
        guard columns.count == 16 else {
            throw TransformError.invalidElementCount(columns.count)
        }
        self.columns = columns
    }

    private init(uncheckedColumns: [Float]) {
        columns = uncheckedColumns
    }

    public static let identity = Transform4x4(uncheckedColumns: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    ])

    public static func translation(x: Float, y: Float, z: Float) -> Transform4x4 {
        Transform4x4(uncheckedColumns: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            x, y, z, 1
        ])
    }

    public static func rotation(radians: Float, axis: Axis3D) -> Transform4x4 {
        let vector = axis.unitVector
        let c = cos(radians)
        let s = sin(radians)
        let t = 1 - c
        let r00 = c + vector.x * vector.x * t
        let r01 = vector.x * vector.y * t - vector.z * s
        let r02 = vector.x * vector.z * t + vector.y * s
        let r10 = vector.y * vector.x * t + vector.z * s
        let r11 = c + vector.y * vector.y * t
        let r12 = vector.y * vector.z * t - vector.x * s
        let r20 = vector.z * vector.x * t - vector.y * s
        let r21 = vector.z * vector.y * t + vector.x * s
        let r22 = c + vector.z * vector.z * t

        return Transform4x4(uncheckedColumns: [
            r00, r10, r20, 0,
            r01, r11, r21, 0,
            r02, r12, r22, 0,
            0, 0, 0, 1
        ])
    }

    public func composed(with other: Transform4x4) -> Transform4x4 {
        var result = Array(repeating: Float.zero, count: 16)
        for column in 0..<4 {
            for row in 0..<4 {
                var value: Float = 0
                for index in 0..<4 {
                    value += element(row: row, column: index) * other.element(row: index, column: column)
                }
                result[column * 4 + row] = value
            }
        }
        return Transform4x4(uncheckedColumns: result)
    }

    public func applying(to point: Point3D) -> Point3D {
        let x = element(row: 0, column: 0) * point.x
            + element(row: 0, column: 1) * point.y
            + element(row: 0, column: 2) * point.z
            + element(row: 0, column: 3)
        let y = element(row: 1, column: 0) * point.x
            + element(row: 1, column: 1) * point.y
            + element(row: 1, column: 2) * point.z
            + element(row: 1, column: 3)
        let z = element(row: 2, column: 0) * point.x
            + element(row: 2, column: 1) * point.y
            + element(row: 2, column: 2) * point.z
            + element(row: 2, column: 3)
        let w = element(row: 3, column: 0) * point.x
            + element(row: 3, column: 1) * point.y
            + element(row: 3, column: 2) * point.z
            + element(row: 3, column: 3)
        let divisor = abs(w) > .ulpOfOne ? w : 1
        return Point3D(x: x / divisor, y: y / divisor, z: z / divisor)
    }

    public func inverted() throws -> Transform4x4 {
        var augmented = Array(repeating: Array(repeating: Float.zero, count: 8), count: 4)
        for row in 0..<4 {
            for column in 0..<4 {
                augmented[row][column] = element(row: row, column: column)
            }
            augmented[row][row + 4] = 1
        }

        for pivotColumn in 0..<4 {
            let pivotRow = (pivotColumn..<4).max { abs(augmented[$0][pivotColumn]) < abs(augmented[$1][pivotColumn]) } ?? pivotColumn
            guard abs(augmented[pivotRow][pivotColumn]) > 0.000_000_1 else {
                throw TransformError.singularMatrix
            }
            if pivotRow != pivotColumn {
                augmented.swapAt(pivotRow, pivotColumn)
            }

            let pivot = augmented[pivotColumn][pivotColumn]
            for column in 0..<8 {
                augmented[pivotColumn][column] /= pivot
            }

            for row in 0..<4 where row != pivotColumn {
                let factor = augmented[row][pivotColumn]
                guard factor != 0 else { continue }
                for column in 0..<8 {
                    augmented[row][column] -= factor * augmented[pivotColumn][column]
                }
            }
        }

        var inverse = Array(repeating: Float.zero, count: 16)
        for row in 0..<4 {
            for column in 0..<4 {
                inverse[column * 4 + row] = augmented[row][column + 4]
            }
        }
        return Transform4x4(uncheckedColumns: inverse)
    }

    private func element(row: Int, column: Int) -> Float {
        columns[column * 4 + row]
    }
}
