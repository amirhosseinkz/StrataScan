import Foundation

public enum PointCloudPLYWriterError: Error, Equatable, Sendable {
    case alreadyFinished
    case incompatiblePointSchema
    case ioFailure(String)
}

/// The two point schemas StrataScan persists. Both are standard binary PLY
/// vertex layouts. The colored layout adds the conventional `red`, `green`,
/// and `blue` properties while retaining the original confidence byte.
public enum PointCloudPLYSchema: Equatable, Sendable {
    case depthWithConfidence
    case coloredDepthWithConfidence

    fileprivate var headerSuffix: String {
        switch self {
        case .depthWithConfidence:
            "\nproperty float x\nproperty float y\nproperty float z\nproperty uchar confidence\nend_header\n"
        case .coloredDepthWithConfidence:
            "\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar confidence\nend_header\n"
        }
    }

    fileprivate var recordByteCount: Int {
        switch self {
        case .depthWithConfidence:
            13
        case .coloredDepthWithConfidence:
            16
        }
    }
}

/// Streams binary little-endian PLY records so a dense capture does not need to
/// accumulate its entire point cloud in RAM. The original x/y/z/confidence
/// schema remains the default; colored records use only supplied RGB values.
public actor PointCloudPLYWriter {
    private let destinationURL: URL
    private let vertexCountOffset: UInt64
    private let schema: PointCloudPLYSchema
    private var handle: FileHandle?
    private var vertexCount = 0

    public init(
        destinationURL: URL,
        schema: PointCloudPLYSchema = .depthWithConfidence,
        fileManager: FileManager = .default
    ) throws {
        self.destinationURL = destinationURL
        self.schema = schema
        // Depth points are generated directly in ARKit world coordinates.
        // Keep the header comment aligned with the manifest asset reference so
        // downstream tools never mistake a source PLY for anchor-local data.
        let headerPrefix = "ply\nformat binary_little_endian 1.0\ncomment coordinate_system arWorld meters column-major worldFromLocal\nelement vertex "
        let placeholder = "00000000000000000000"
        let header = headerPrefix + placeholder + schema.headerSuffix
        vertexCountOffset = UInt64(headerPrefix.utf8.count)

        do {
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(header.utf8).write(to: destinationURL, options: .atomic)
            let openedHandle = try FileHandle(forWritingTo: destinationURL)
            try openedHandle.seekToEnd()
            handle = openedHandle
        } catch {
            throw PointCloudPLYWriterError.ioFailure(error.localizedDescription)
        }
    }

    public func append(_ points: [DepthPoint]) throws {
        guard let handle else { throw PointCloudPLYWriterError.alreadyFinished }
        guard schema == .depthWithConfidence else {
            throw PointCloudPLYWriterError.incompatiblePointSchema
        }
        var data = Data()
        data.reserveCapacity(points.count * schema.recordByteCount)
        for point in points {
            appendLittleEndian(point.position.x, to: &data)
            appendLittleEndian(point.position.y, to: &data)
            appendLittleEndian(point.position.z, to: &data)
            data.append(point.confidence)
        }
        do {
            try handle.write(contentsOf: data)
            vertexCount += points.count
        } catch {
            throw PointCloudPLYWriterError.ioFailure(error.localizedDescription)
        }
    }

    /// Appends a conventional RGB PLY record. This overload accepts a
    /// nonoptional color type so a caller cannot accidentally turn an
    /// unobserved point into an invented colored record.
    public func append(_ points: [ColoredPointCloudPoint]) throws {
        guard let handle else { throw PointCloudPLYWriterError.alreadyFinished }
        guard schema == .coloredDepthWithConfidence else {
            throw PointCloudPLYWriterError.incompatiblePointSchema
        }
        var data = Data()
        data.reserveCapacity(points.count * schema.recordByteCount)
        for point in points {
            appendLittleEndian(point.position.x, to: &data)
            appendLittleEndian(point.position.y, to: &data)
            appendLittleEndian(point.position.z, to: &data)
            data.append(point.color.red)
            data.append(point.color.green)
            data.append(point.color.blue)
            data.append(point.confidence)
        }
        do {
            try handle.write(contentsOf: data)
            vertexCount += points.count
        } catch {
            throw PointCloudPLYWriterError.ioFailure(error.localizedDescription)
        }
    }

    public func finish() throws {
        guard let handle else { throw PointCloudPLYWriterError.alreadyFinished }
        do {
            try handle.synchronize()
            try handle.close()
            self.handle = nil

            let updateHandle = try FileHandle(forUpdating: destinationURL)
            defer { try? updateHandle.close() }
            try updateHandle.seek(toOffset: vertexCountOffset)
            let count = String(format: "%020d", vertexCount)
            try updateHandle.write(contentsOf: Data(count.utf8))
            try updateHandle.synchronize()
        } catch {
            throw PointCloudPLYWriterError.ioFailure(error.localizedDescription)
        }
    }

    private func appendLittleEndian(_ value: Float, to data: inout Data) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
}
