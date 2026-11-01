import Foundation
import Testing
@testable import StrataCore

@Suite("Depth point cloud")
struct PointCloudTests {
    @Test("Depth at the optical center maps through worldFromCamera in meters")
    func unprojectsCenterDepth() throws {
        var depths = Array(repeating: Float(0), count: 25)
        var confidence = Array(repeating: UInt8(0), count: 25)
        for index in [7, 11, 12, 13, 17] {
            depths[index] = 2
            confidence[index] = 2
        }
        let sample = DepthFrameSample(
            width: 5,
            height: 5,
            depthMeters: depths,
            confidence: confidence,
            calibration: CameraIntrinsics(imageWidth: 5, imageHeight: 5, fx: 1, fy: 1, cx: 2, cy: 2),
            worldFromCamera: .translation(x: 3, y: 0, z: 0),
            timestamp: 10
        )

        let points = try DepthPointCloudGenerator(minimumConfidence: 2, samplingStride: 2).generate(from: sample)

        #expect(points.count == 1)
        #expect(points[0].position.isApproximatelyEqual(to: Point3D(x: 3, y: 0, z: -2)))
        #expect(points[0].confidence == 2)
    }

    @Test("Invalid, low-confidence, and oversized samples are excluded")
    func filtersSamplesAndBoundsOutput() throws {
        let sample = DepthFrameSample(
            width: 2,
            height: 2,
            depthMeters: [1, -1, .infinity, 4],
            confidence: [2, 2, 2, 1],
            calibration: CameraIntrinsics(imageWidth: 2, imageHeight: 2, fx: 1, fy: 1, cx: 0, cy: 0),
            worldFromCamera: .identity,
            timestamp: 12
        )

        let points = try DepthPointCloudGenerator(
            minimumConfidence: 2,
            samplingStride: 1,
            maximumPointsPerFrame: 1,
            qualityGate: DepthSampleQualityGate(minimumConsistentNeighborCount: 0)
        ).generate(from: sample)

        #expect(points.count == 1)
        #expect(points[0].sourcePixel == PixelCoordinate(x: 0, y: 0))
    }

    @Test("Rejects isolated depth spikes before world-space unprojection")
    func rejectsSpatiallyInconsistentDepth() throws {
        var depths = Array(repeating: Float(0), count: 25)
        var confidence = Array(repeating: UInt8(0), count: 25)
        for index in [7, 11, 13, 17] {
            depths[index] = 1
            confidence[index] = 2
        }
        depths[12] = 6
        confidence[12] = 2
        let sample = DepthFrameSample(
            width: 5,
            height: 5,
            depthMeters: depths,
            confidence: confidence,
            calibration: CameraIntrinsics(imageWidth: 5, imageHeight: 5, fx: 1, fy: 1, cx: 2, cy: 2),
            worldFromCamera: .identity,
            timestamp: 12
        )

        let points = try DepthPointCloudGenerator(minimumConfidence: 2, samplingStride: 2).generate(from: sample)

        #expect(points.isEmpty)
    }

    @Test("Preserves a plausible sparse depth sample without neighboring evidence")
    func preservesSparseDepthWithoutNeighbors() throws {
        let sample = DepthFrameSample(
            width: 3,
            height: 3,
            depthMeters: [0, 0, 0, 0, 2, 0, 0, 0, 0],
            confidence: [0, 0, 0, 0, 2, 0, 0, 0, 0],
            calibration: CameraIntrinsics(imageWidth: 3, imageHeight: 3, fx: 1, fy: 1, cx: 1, cy: 1),
            worldFromCamera: .identity,
            timestamp: 13
        )

        let points = try DepthPointCloudGenerator(minimumConfidence: 2, samplingStride: 1).generate(from: sample)

        #expect(points.count == 1)
        #expect(points[0].position.isApproximatelyEqual(to: Point3D(x: 0, y: 0, z: -2)))
    }

    @Test("PLY writer streams points and writes the final vertex count")
    func streamsBinaryPLY() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "StrataScanPLY-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "cloud.ply")
        let writer = try PointCloudPLYWriter(destinationURL: destination)

        try await writer.append([
            DepthPoint(position: Point3D(x: 1, y: 2, z: 3), confidence: 2, timestamp: 1, sourcePixel: PixelCoordinate(x: 1, y: 1)),
            DepthPoint(position: Point3D(x: 4, y: 5, z: 6), confidence: 1, timestamp: 2, sourcePixel: PixelCoordinate(x: 2, y: 2))
        ])
        try await writer.finish()

        let data = try Data(contentsOf: destination)
        let headerEnd = try #require(data.range(of: Data("end_header\n".utf8)))
        let header = String(decoding: data[..<headerEnd.upperBound], as: UTF8.self)
        #expect(header.contains("element vertex 00000000000000000002"))
        #expect(data.count == headerEnd.upperBound + 26)
    }
}
