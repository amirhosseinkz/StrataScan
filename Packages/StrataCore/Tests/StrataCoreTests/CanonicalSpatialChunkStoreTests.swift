import CryptoKit
import Foundation
import Testing
@testable import StrataCore

@Suite("Canonical spatial chunk store")
struct CanonicalSpatialChunkStoreTests {
    @Test("Canonical storage exceeds the legacy 100,000 point ceiling")
    func persistsLongCaptureWithoutGlobalTruncation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "StrataScanChunks-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "capture/spatial-chunks.bin")
        let store = try CanonicalSpatialChunkStore(destinationURL: fileURL)
        let targetCount = 100_500

        for batchStart in stride(from: 0, to: targetCount, by: 1_000) {
            let batchEnd = min(targetCount, batchStart + 1_000)
            var samples: [RGBDPointSample] = []
            samples.reserveCapacity(batchEnd - batchStart)
            for index in batchStart..<batchEnd {
                let position = Point3D(
                    x: Float(index % 500) * 0.03,
                    y: Float((index / 500) % 40) * 0.03,
                    z: Float(index / 20_000) * 2.1
                )
                samples.append(RGBDPointSample(
                    position: position,
                    confidence: 2,
                    color: PointCloudColor(red: 10, green: 20, blue: 30)
                ))
            }
            #expect(try await store.append(samples) == samples.count)
        }

        let finished = try await store.finish()
        let inspected = try CanonicalSpatialChunkStore.inspect(fileURL: fileURL)

        #expect(finished.recordCount == targetCount)
        #expect(inspected.recordCount == targetCount)
        #expect(inspected.chunkBlockCount > 1)
        #expect(inspected.rejectedInvalidRecordCount == 0)
    }

    @Test("Chunk keys are deterministic across zero and negative boundaries")
    func usesWorldAlignedChunkBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "StrataScanChunks-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "capture/spatial-chunks.bin")
        let store = try CanonicalSpatialChunkStore(destinationURL: fileURL, chunkSizeMeters: 2)

        try await store.append([
            RGBDPointSample(position: Point3D(x: -0.01, y: 0, z: 0), confidence: 1),
            RGBDPointSample(position: Point3D(x: 0, y: 0, z: 0), confidence: 1),
            RGBDPointSample(position: Point3D(x: 1.99, y: 0, z: 0), confidence: 1),
            RGBDPointSample(position: Point3D(x: 2, y: 0, z: 0), confidence: 1)
        ])
        _ = try await store.finish()

        let summary = try CanonicalSpatialChunkStore.inspect(fileURL: fileURL)
        #expect(summary.recordCount == 4)
        #expect(summary.chunkBlockCount == 3)
    }

    @Test("Cancellation closes the writer and rejects later appends")
    func cancellationStopsPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "StrataScanChunks-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CanonicalSpatialChunkStore(
            destinationURL: root.appending(path: "capture/spatial-chunks.bin")
        )

        await store.cancel()

        await #expect(throws: CanonicalSpatialChunkStoreError.alreadyClosed) {
            try await store.append([
                RGBDPointSample(position: Point3D(x: 0, y: 0, z: 0), confidence: 1)
            ])
        }
    }

    @Test("Canonical reader streams exact records, color truth, and full bounds")
    func readerStreamsValidatedRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "StrataScanCanonicalReader-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: CanonicalSpatialChunkStore.relativePath)
        let store = try CanonicalSpatialChunkStore(destinationURL: fileURL)
        let expected = [
            RGBDPointSample(
                position: Point3D(x: -1, y: 2, z: 3),
                confidence: 1,
                color: PointCloudColor(red: 10, green: 20, blue: 30)
            ),
            RGBDPointSample(
                position: Point3D(x: 4, y: -5, z: 6),
                confidence: 2,
                color: nil
            )
        ]
        try await store.append(expected)
        _ = try await store.finish()
        let scanID = UUID()
        let data = try Data(contentsOf: fileURL)
        let reference = ScanAssetReference(
            kind: .manifestAttachment,
            relativePath: CanonicalSpatialChunkStore.relativePath,
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            spatialReference: .arWorld,
            createdAt: .now
        )
        let manifest = ScanPackageManifest(
            localScanID: scanID,
            status: .completed,
            createdAt: .now,
            updatedAt: .now,
            assets: [reference]
        )
        let descriptor = try CanonicalSpatialChunkReader().open(
            packageURL: root,
            manifest: manifest,
            integrity: PackageIntegrityReport(scanID: scanID)
        )
        var actual: [RGBDPointSample] = []
        try CanonicalSpatialChunkReader().forEachBatch(
            in: descriptor,
            maximumRecordCount: 1
        ) { actual.append(contentsOf: $0) }

        #expect(actual == expected)
        #expect(descriptor.recordCount == 2)
        #expect(!descriptor.allRecordsHaveObservedColor)
        #expect(descriptor.bounds.minimum == Point3D(x: -1, y: -5, z: 3))
        #expect(descriptor.bounds.maximum == Point3D(x: 4, y: 2, z: 6))

        var changed = data
        let confidenceOffset = CanonicalSpatialChunkStore.headerByteCount
            + CanonicalSpatialChunkStore.recordByteCount + 39
        changed[confidenceOffset] ^= 1
        try changed.write(to: fileURL, options: .atomic)
        #expect(throws: CanonicalSpatialChunkReadError.sourceMismatch) {
            try CanonicalSpatialChunkReader().forEachBatch(in: descriptor) { _ in }
        }
    }
}
