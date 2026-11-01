import Foundation
import Testing
@testable import StrataCore

@Suite("Point cloud PLY reader", .serialized)
struct PointCloudPLYReaderTests {
    @Test("Reads the writer format and deterministically downsamples across the full cloud")
    func readsWriterOutputWithEvenlyDistributedSamples() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "cloud.ply")
        let writer = try PointCloudPLYWriter(destinationURL: destination)

        try await writer.append((0..<17).map { index in
            DepthPoint(
                position: Point3D(x: Float(index), y: Float(index + 10), z: Float(-index)),
                confidence: UInt8(index % 3),
                timestamp: TimeInterval(index),
                sourcePixel: PixelCoordinate(x: index, y: 0)
            )
        })
        try await writer.finish()

        let result = try PointCloudPLYReader().read(from: destination, maximumPointCount: 4)

        #expect(result.header.vertexCount == 17)
        #expect(result.header.recordByteCount == 13)
        #expect(!result.header.containsRGBColor)
        #expect(result.points.map(\.position.x) == [0, 5, 10, 16])
        #expect(result.points.map(\.position.y) == [10, 15, 20, 26])
        #expect(result.points.map(\.position.z) == [0, -5, -10, -16])
        #expect(result.points.map(\.confidence) == [0, 2, 1, 1])
    }

    @Test("A zero sample limit exposes the header without retaining point records")
    func exposesHeaderWithoutSamples() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "cloud.ply")
        let writer = try PointCloudPLYWriter(destinationURL: destination)
        try await writer.append([
            DepthPoint(position: Point3D(x: 1, y: 2, z: 3), confidence: 2, timestamp: 0, sourcePixel: PixelCoordinate(x: 0, y: 0))
        ])
        try await writer.finish()

        let result = try PointCloudPLYReader().read(from: destination, maximumPointCount: 0)

        #expect(result.header.vertexCount == 1)
        #expect(result.points.isEmpty)
    }

    @Test("Reads standard RGB PLY records without changing legacy point-cloud behavior")
    func readsColoredPLYRecords() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "colored-cloud.ply")
        let writer = try PointCloudPLYWriter(
            destinationURL: destination,
            schema: .coloredDepthWithConfidence
        )

        try await writer.append([
            ColoredPointCloudPoint(
                position: Point3D(x: 1, y: 2, z: 3),
                confidence: 2,
                color: PointCloudColor(red: 12, green: 34, blue: 56)
            ),
            ColoredPointCloudPoint(
                position: Point3D(x: 4, y: 5, z: 6),
                confidence: 1,
                color: PointCloudColor(red: 78, green: 90, blue: 123)
            )
        ])
        try await writer.finish()

        let result = try PointCloudPLYReader().read(from: destination, maximumPointCount: 2)

        #expect(result.header.vertexCount == 2)
        #expect(result.header.recordByteCount == 16)
        #expect(result.header.containsRGBColor)
        #expect(result.points.map(\.position) == [
            Point3D(x: 1, y: 2, z: 3),
            Point3D(x: 4, y: 5, z: 6)
        ])
        #expect(result.points.map(\.confidence) == [2, 1])
        #expect(result.points.map(\.color) == [
            PointCloudColor(red: 12, green: 34, blue: 56),
            PointCloudColor(red: 78, green: 90, blue: 123)
        ])
    }

    @Test("Rejects an unsupported PLY header")
    func rejectsUnsupportedHeader() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "invalid.ply")
        try Data("ply\nformat ascii 1.0\nelement vertex 0\nend_header\n".utf8).write(to: destination, options: .atomic)

        #expect(throws: PointCloudPLYReaderError.unsupportedFormat) {
            _ = try PointCloudPLYReader().read(from: destination, maximumPointCount: 1)
        }
    }

    @Test("Rejects a header whose declared records are truncated")
    func rejectsTruncatedRecordData() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "truncated.ply")
        let header = """
        ply
        format binary_little_endian 1.0
        comment coordinate_system scanLocal meters column-major worldFromLocal
        element vertex 2
        property float x
        property float y
        property float z
        property uchar confidence
        end_header
        """
        var data = Data((header + "\n").utf8)
        data.append(Data(repeating: 0, count: 13))
        try data.write(to: destination, options: .atomic)

        #expect(throws: PointCloudPLYReaderError.recordByteCountMismatch(expected: 26, actual: 13)) {
            _ = try PointCloudPLYReader().read(from: destination, maximumPointCount: 2)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "StrataScanPLYReader-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
