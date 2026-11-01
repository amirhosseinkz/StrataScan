import CryptoKit
import Foundation

public enum CanonicalSpatialChunkReadError: Error, Equatable, Sendable {
    case packageIntegrityFailed
    case missingSource
    case ambiguousSource
    case unsafePath
    case sourceMismatch
    case invalidFile
    case emptySource
    case ioFailure(String)
}

public struct CanonicalSpatialBounds: Equatable, Sendable {
    public var minimum: Point3D
    public var maximum: Point3D

    public init(minimum: Point3D, maximum: Point3D) {
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct CanonicalSpatialChunkDescriptor: Equatable, Sendable {
    public let sourceURL: URL
    public let sourceReference: ScanAssetReference
    public let recordCount: Int
    public let chunkSizeMeters: Float
    public let bounds: CanonicalSpatialBounds
    public let allRecordsHaveObservedColor: Bool

    init(
        sourceURL: URL,
        sourceReference: ScanAssetReference,
        recordCount: Int,
        chunkSizeMeters: Float,
        bounds: CanonicalSpatialBounds,
        allRecordsHaveObservedColor: Bool
    ) {
        self.sourceURL = sourceURL
        self.sourceReference = sourceReference
        self.recordCount = recordCount
        self.chunkSizeMeters = chunkSizeMeters
        self.bounds = bounds
        self.allRecordsHaveObservedColor = allRecordsHaveObservedColor
    }
}

/// Integrity-checks and streams the complete canonical accepted RGB-D record
/// source without retaining the scan in memory.
public struct CanonicalSpatialChunkReader: Sendable {
    public static let defaultBatchSize = 8_192

    public init() {}

    public func open(
        packageURL: URL,
        manifest: ScanPackageManifest,
        integrity: PackageIntegrityReport
    ) throws -> CanonicalSpatialChunkDescriptor {
        try Task.checkCancellation()
        guard integrity.isValid,
              integrity.scanID == manifest.localScanID
        else { throw CanonicalSpatialChunkReadError.packageIntegrityFailed }

        let matches = manifest.assets.filter {
            $0.relativePath == CanonicalSpatialChunkStore.relativePath
        }
        guard !matches.isEmpty else { throw CanonicalSpatialChunkReadError.missingSource }
        guard matches.count == 1, let reference = matches.first else {
            throw CanonicalSpatialChunkReadError.ambiguousSource
        }
        guard reference.kind == .manifestAttachment,
              reference.spatialReference == .arWorld,
              reference.byteCount >= Int64(CanonicalSpatialChunkStore.headerByteCount),
              Self.isSHA256(reference.sha256),
              Self.isSafeRelativePath(reference.relativePath)
        else { throw CanonicalSpatialChunkReadError.sourceMismatch }

        let sourceURL = packageURL.appending(path: reference.relativePath)
        try Self.requireContainedRegularFile(sourceURL, under: packageURL)
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == reference.byteCount else {
            throw CanonicalSpatialChunkReadError.sourceMismatch
        }
        let summary = try scan(sourceURL: sourceURL, batchSize: Self.defaultBatchSize, body: nil)
        guard summary.sha256 == reference.sha256.lowercased() else {
            throw CanonicalSpatialChunkReadError.sourceMismatch
        }
        guard summary.recordCount > 0, let bounds = summary.bounds else {
            throw CanonicalSpatialChunkReadError.emptySource
        }
        return CanonicalSpatialChunkDescriptor(
            sourceURL: sourceURL,
            sourceReference: reference,
            recordCount: summary.recordCount,
            chunkSizeMeters: summary.chunkSizeMeters,
            bounds: bounds,
            allRecordsHaveObservedColor: summary.allRecordsHaveObservedColor
        )
    }

    public func forEachBatch(
        in descriptor: CanonicalSpatialChunkDescriptor,
        maximumRecordCount: Int = CanonicalSpatialChunkReader.defaultBatchSize,
        _ body: @escaping ([RGBDPointSample]) throws -> Void
    ) throws {
        guard maximumRecordCount > 0 else { throw CanonicalSpatialChunkReadError.invalidFile }
        let summary = try scan(
            sourceURL: descriptor.sourceURL,
            batchSize: maximumRecordCount,
            body: body
        )
        guard summary.recordCount == descriptor.recordCount,
              summary.chunkSizeMeters == descriptor.chunkSizeMeters,
              summary.bounds == descriptor.bounds,
              summary.allRecordsHaveObservedColor == descriptor.allRecordsHaveObservedColor,
              summary.sha256 == descriptor.sourceReference.sha256.lowercased()
        else { throw CanonicalSpatialChunkReadError.sourceMismatch }
    }

    private func scan(
        sourceURL: URL,
        batchSize: Int,
        body: (([RGBDPointSample]) throws -> Void)?
    ) throws -> CanonicalScanSummary {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: sourceURL)
        } catch {
            throw CanonicalSpatialChunkReadError.ioFailure(error.localizedDescription)
        }
        defer { try? handle.close() }

        let header = try Self.readExactly(
            CanonicalSpatialChunkStore.headerByteCount,
            from: handle
        )
        var hasher = SHA256()
        hasher.update(data: header)
        guard header.prefix(8) == Data("STRARGBD".utf8),
              header.readUInt32LittleEndian(at: 8) == CanonicalSpatialChunkStore.formatVersion,
              let chunkBits = header.readUInt32LittleEndian(at: 12),
              header.readUInt32LittleEndian(at: 16) == UInt32(CanonicalSpatialChunkStore.recordByteCount)
        else { throw CanonicalSpatialChunkReadError.invalidFile }
        let chunkSize = Float(bitPattern: chunkBits)
        guard chunkSize.isFinite, chunkSize > 0 else {
            throw CanonicalSpatialChunkReadError.invalidFile
        }
        let fileSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        let payloadByteCount = fileSize - CanonicalSpatialChunkStore.headerByteCount
        guard payloadByteCount >= 0,
              payloadByteCount.isMultiple(of: CanonicalSpatialChunkStore.recordByteCount)
        else { throw CanonicalSpatialChunkReadError.invalidFile }
        let recordCount = payloadByteCount / CanonicalSpatialChunkStore.recordByteCount

        var accumulator = BoundsAccumulator()
        var allHaveColor = recordCount > 0
        var processed = 0
        while processed < recordCount {
            try Task.checkCancellation()
            let count = min(batchSize, recordCount - processed)
            let bytes = try Self.readExactly(
                count * CanonicalSpatialChunkStore.recordByteCount,
                from: handle
            )
            hasher.update(data: bytes)
            var samples: [RGBDPointSample] = []
            samples.reserveCapacity(count)
            for index in 0..<count {
                let offset = index * CanonicalSpatialChunkStore.recordByteCount
                guard let chunkXBits = bytes.readUInt64LittleEndian(at: offset),
                      let chunkYBits = bytes.readUInt64LittleEndian(at: offset + 8),
                      let chunkZBits = bytes.readUInt64LittleEndian(at: offset + 16),
                      let xBits = bytes.readUInt32LittleEndian(at: offset + 24),
                      let yBits = bytes.readUInt32LittleEndian(at: offset + 28),
                      let zBits = bytes.readUInt32LittleEndian(at: offset + 32)
                else { throw CanonicalSpatialChunkReadError.invalidFile }
                let position = Point3D(
                    x: Float(bitPattern: xBits),
                    y: Float(bitPattern: yBits),
                    z: Float(bitPattern: zBits)
                )
                let colorFlag = bytes[offset + 40]
                guard Self.isFinite(position),
                      colorFlag <= 1,
                      bytes[offset + 41] == 0,
                      bytes[offset + 42] == 0,
                      bytes[offset + 43] == 0,
                      Self.chunkCoordinate(position.x, size: chunkSize) == Int64(bitPattern: chunkXBits),
                      Self.chunkCoordinate(position.y, size: chunkSize) == Int64(bitPattern: chunkYBits),
                      Self.chunkCoordinate(position.z, size: chunkSize) == Int64(bitPattern: chunkZBits)
                else { throw CanonicalSpatialChunkReadError.invalidFile }
                let color: PointCloudColor?
                if colorFlag == 1 {
                    color = PointCloudColor(
                        red: bytes[offset + 36],
                        green: bytes[offset + 37],
                        blue: bytes[offset + 38]
                    )
                } else {
                    guard bytes[offset + 36] == 0,
                          bytes[offset + 37] == 0,
                          bytes[offset + 38] == 0
                    else { throw CanonicalSpatialChunkReadError.invalidFile }
                    color = nil
                    allHaveColor = false
                }
                accumulator.include(position)
                samples.append(
                    RGBDPointSample(
                        position: position,
                        confidence: bytes[offset + 39],
                        color: color
                    )
                )
            }
            if let body { try body(samples) }
            processed += count
        }
        return CanonicalScanSummary(
            recordCount: recordCount,
            chunkSizeMeters: chunkSize,
            bounds: accumulator.finalized,
            allRecordsHaveObservedColor: allHaveColor,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func requireContainedRegularFile(_ url: URL, under packageURL: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CanonicalSpatialChunkReadError.unsafePath
        }
        let root = packageURL.resolvingSymlinksInPath().standardizedFileURL.path
        let source = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard source.hasPrefix(root + "/") else {
            throw CanonicalSpatialChunkReadError.unsafePath
        }
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        do {
            while result.count < count {
                guard let data = try handle.read(upToCount: count - result.count), !data.isEmpty else {
                    throw CanonicalSpatialChunkReadError.invalidFile
                }
                result.append(data)
            }
            return result
        } catch let error as CanonicalSpatialChunkReadError {
            throw error
        } catch {
            throw CanonicalSpatialChunkReadError.ioFailure(error.localizedDescription)
        }
    }

    private static func chunkCoordinate(_ value: Float, size: Float) -> Int64? {
        let scaled = floor(Double(value) / Double(size))
        guard scaled.isFinite,
              scaled >= Double(Int64.min),
              scaled < Double(Int64.max)
        else { return nil }
        return Int64(scaled)
    }

    private static func isFinite(_ point: Point3D) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
}

private struct CanonicalScanSummary {
    var recordCount: Int
    var chunkSizeMeters: Float
    var bounds: CanonicalSpatialBounds?
    var allRecordsHaveObservedColor: Bool
    var sha256: String
}

private struct BoundsAccumulator {
    private var minimum: Point3D?
    private var maximum: Point3D?

    mutating func include(_ point: Point3D) {
        guard let minimum, let maximum else {
            self.minimum = point
            self.maximum = point
            return
        }
        self.minimum = Point3D(
            x: min(minimum.x, point.x),
            y: min(minimum.y, point.y),
            z: min(minimum.z, point.z)
        )
        self.maximum = Point3D(
            x: max(maximum.x, point.x),
            y: max(maximum.y, point.y),
            z: max(maximum.z, point.z)
        )
    }

    var finalized: CanonicalSpatialBounds? {
        guard let minimum, let maximum else { return nil }
        return CanonicalSpatialBounds(minimum: minimum, maximum: maximum)
    }
}

private extension Data {
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
        for index in 0..<8 {
            value |= UInt64(self[offset + index]) << UInt64(index * 8)
        }
        return value
    }
}
