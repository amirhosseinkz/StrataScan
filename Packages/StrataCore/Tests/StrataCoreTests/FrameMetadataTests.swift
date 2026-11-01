import Foundation
import Testing
@testable import StrataCore

@Suite("Frame metadata")
struct FrameMetadataTests {
    @Test("NDJSON writer preserves one independently decodable record per line")
    func streamsFrameRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "StrataScanFrames-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "frame-metadata.ndjson")
        let writer = try FrameMetadataNDJSONWriter(destinationURL: output)
        let metadata = FrameMetadata(
            timestamp: 4.5,
            videoTimestamp: 1.25,
            imageWidth: 1920,
            imageHeight: 1440,
            intrinsics: CameraIntrinsics(imageWidth: 1920, imageHeight: 1440, fx: 1_000, fy: 1_000, cx: 960, cy: 720),
            worldFromCamera: .translation(x: 1, y: 2, z: 3),
            tracking: .normal,
            worldMapping: .mapped,
            isTextureSourceCandidate: true
        )

        try await writer.append(metadata)
        try await writer.finish()

        let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FrameMetadata.self, from: Data(lines[0].utf8))
        #expect(decoded == metadata)
    }
}
