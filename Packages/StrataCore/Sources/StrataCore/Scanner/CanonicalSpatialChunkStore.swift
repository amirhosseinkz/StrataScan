import Foundation

public enum CanonicalSpatialChunkStoreError: Error, Equatable, Sendable {
    case invalidChunkSize(Float)
    case alreadyClosed
    case invalidFile
    case ioFailure(String)
}

public struct CanonicalSpatialChunkSummary: Equatable, Sendable {
    public var recordCount: Int
    public var chunkBlockCount: Int
    public var rejectedInvalidRecordCount: Int

    public init(recordCount: Int, chunkBlockCount: Int, rejectedInvalidRecordCount: Int) {
        self.recordCount = recordCount
        self.chunkBlockCount = chunkBlockCount
        self.rejectedInvalidRecordCount = rejectedInvalidRecordCount
    }
}

/// Append-only canonical RGB-D sample storage. Records retain unchanged
/// AR-world-meter positions and deterministic world-aligned chunk keys while
/// bounding only the current write batch in memory.
public actor CanonicalSpatialChunkStore {
    public static let relativePath = "capture/spatial-chunks.bin"
    public static let formatVersion: UInt32 = 1
    public static let headerByteCount = 20
    public static let recordByteCount = 44

    private static let magic = Data("STRARGBD".utf8)

    private let chunkSizeMeters: Float
    private var handle: FileHandle?
    private var recordCount = 0
    private var rejectedInvalidRecordCount = 0
    private var chunkBlockCount = 0
    private var lastChunkKey: ChunkKey?
    private var finalSummary: CanonicalSpatialChunkSummary?

    public init(
        destinationURL: URL,
        chunkSizeMeters: Float = 2,
        fileManager: FileManager = .default
    ) throws {
        guard chunkSizeMeters.isFinite, chunkSizeMeters > 0 else {
            throw CanonicalSpatialChunkStoreError.invalidChunkSize(chunkSizeMeters)
        }
        self.chunkSizeMeters = chunkSizeMeters

        do {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var header = Self.magic
            header.appendLittleEndian(Self.formatVersion)
            header.appendLittleEndian(chunkSizeMeters.bitPattern)
            header.appendLittleEndian(UInt32(Self.recordByteCount))
            try header.write(to: destinationURL, options: .atomic)
            handle = try FileHandle(forWritingTo: destinationURL)
            try handle?.seekToEnd()
        } catch {
            throw CanonicalSpatialChunkStoreError.ioFailure(error.localizedDescription)
        }
    }

    @discardableResult
    public func append(_ samples: [RGBDPointSample]) throws -> Int {
        guard let handle, finalSummary == nil else {
            throw CanonicalSpatialChunkStoreError.alreadyClosed
        }

        var data = Data()
        data.reserveCapacity(samples.count * Self.recordByteCount)
        var appendedCount = 0
        for sample in samples {
            guard let key = chunkKey(for: sample.position) else {
                rejectedInvalidRecordCount += 1
                continue
            }
            data.appendLittleEndian(UInt64(bitPattern: key.x))
            data.appendLittleEndian(UInt64(bitPattern: key.y))
            data.appendLittleEndian(UInt64(bitPattern: key.z))
            data.appendLittleEndian(sample.position.x.bitPattern)
            data.appendLittleEndian(sample.position.y.bitPattern)
            data.appendLittleEndian(sample.position.z.bitPattern)
            data.append(sample.color?.red ?? 0)
            data.append(sample.color?.green ?? 0)
            data.append(sample.color?.blue ?? 0)
            data.append(sample.confidence)
            data.append(sample.color == nil ? 0 : 1)
            data.append(contentsOf: [0, 0, 0])
            if lastChunkKey != key {
                chunkBlockCount += 1
                lastChunkKey = key
            }
            appendedCount += 1
        }

        do {
            if !data.isEmpty {
                try handle.write(contentsOf: data)
            }
            recordCount += appendedCount
            return appendedCount
        } catch {
            throw CanonicalSpatialChunkStoreError.ioFailure(error.localizedDescription)
        }
    }

    public func finish() throws -> CanonicalSpatialChunkSummary {
        if let finalSummary {
            return finalSummary
        }
        guard let handle else {
            throw CanonicalSpatialChunkStoreError.alreadyClosed
        }
        do {
            try handle.synchronize()
            try handle.close()
            self.handle = nil
            let summary = CanonicalSpatialChunkSummary(
                recordCount: recordCount,
                chunkBlockCount: chunkBlockCount,
                rejectedInvalidRecordCount: rejectedInvalidRecordCount
            )
            finalSummary = summary
            return summary
        } catch {
            throw CanonicalSpatialChunkStoreError.ioFailure(error.localizedDescription)
        }
    }

    public func cancel() {
        try? handle?.close()
        handle = nil
    }

    public static func inspect(fileURL: URL) throws -> CanonicalSpatialChunkSummary {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw CanonicalSpatialChunkStoreError.ioFailure(error.localizedDescription)
        }
        guard data.count >= headerByteCount,
              data.prefix(magic.count) == magic,
              data.readUInt32LittleEndian(at: 8) == formatVersion,
              data.readUInt32LittleEndian(at: 16) == UInt32(recordByteCount),
              (data.count - headerByteCount).isMultiple(of: recordByteCount)
        else {
            throw CanonicalSpatialChunkStoreError.invalidFile
        }

        let count = (data.count - headerByteCount) / recordByteCount
        var blockCount = 0
        var previousKey: ChunkKey?
        for index in 0..<count {
            let offset = headerByteCount + index * recordByteCount
            guard let x = data.readUInt64LittleEndian(at: offset),
                  let y = data.readUInt64LittleEndian(at: offset + 8),
                  let z = data.readUInt64LittleEndian(at: offset + 16),
                  let px = data.readUInt32LittleEndian(at: offset + 24),
                  let py = data.readUInt32LittleEndian(at: offset + 28),
                  let pz = data.readUInt32LittleEndian(at: offset + 32),
                  Float(bitPattern: px).isFinite,
                  Float(bitPattern: py).isFinite,
                  Float(bitPattern: pz).isFinite
            else {
                throw CanonicalSpatialChunkStoreError.invalidFile
            }
            let key = ChunkKey(
                x: Int64(bitPattern: x),
                y: Int64(bitPattern: y),
                z: Int64(bitPattern: z)
            )
            if previousKey != key {
                blockCount += 1
                previousKey = key
            }
        }
        return CanonicalSpatialChunkSummary(
            recordCount: count,
            chunkBlockCount: blockCount,
            rejectedInvalidRecordCount: 0
        )
    }

    private func chunkKey(for position: Point3D) -> ChunkKey? {
        guard let x = chunkCoordinate(position.x),
              let y = chunkCoordinate(position.y),
              let z = chunkCoordinate(position.z)
        else {
            return nil
        }
        return ChunkKey(x: x, y: y, z: z)
    }

    private func chunkCoordinate(_ value: Float) -> Int64? {
        let scaled = floor(Double(value) / Double(chunkSizeMeters))
        guard scaled.isFinite,
              scaled >= Double(Int64.min),
              scaled < Double(Int64.max)
        else {
            return nil
        }
        return Int64(scaled)
    }
}

private struct ChunkKey: Hashable, Sendable {
    var x: Int64
    var y: Int64
    var z: Int64
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt64) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    func readUInt32LittleEndian(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func readUInt64LittleEndian(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        var value: UInt64 = 0
        for byteOffset in 0..<8 {
            value |= UInt64(self[offset + byteOffset]) << UInt64(byteOffset * 8)
        }
        return value
    }
}
