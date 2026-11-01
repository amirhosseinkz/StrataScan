import Foundation

public enum PointCloudPLYReaderError: Error, Equatable, Sendable {
    case unreadableFile
    case invalidMaximumPointCount(Int)
    case headerTooLarge
    case invalidHeader
    case unsupportedFormat
    case invalidVertexCount
    case unsupportedVertexProperties
    case recordByteCountMismatch(expected: UInt64, actual: UInt64)
    case malformedRecord
}

/// The portion of the PLY header needed to inspect a StrataScan point cloud.
public struct PointCloudPLYHeader: Equatable, Sendable {
    public let vertexCount: Int
    public let recordByteCount: Int
    public let containsRGBColor: Bool

    public init(
        vertexCount: Int,
        recordByteCount: Int = 13,
        containsRGBColor: Bool = false
    ) {
        self.vertexCount = vertexCount
        self.recordByteCount = recordByteCount
        self.containsRGBColor = containsRGBColor
    }
}

/// A bounded, render-ready point decoded from StrataScan's binary PLY format.
/// `color == nil` means that the PLY used the original uncolored layout.
public struct PointCloudPLYPoint: Equatable, Sendable {
    public let position: Point3D
    public let confidence: UInt8
    public let color: PointCloudColor?

    public init(
        position: Point3D,
        confidence: UInt8,
        color: PointCloudColor? = nil
    ) {
        self.position = position
        self.confidence = confidence
        self.color = color
    }
}

/// The header count and a deterministic subset of a point-cloud asset.
public struct PointCloudPLYReadResult: Equatable, Sendable {
    public let header: PointCloudPLYHeader
    public let points: [PointCloudPLYPoint]

    public init(header: PointCloudPLYHeader, points: [PointCloudPLYPoint]) {
        self.header = header
        self.points = points
    }
}

/// Reads the binary little-endian PLY contracts written by
/// `PointCloudPLYWriter`: the existing x/y/z/confidence format and the RGB
/// extension x/y/z/red/green/blue/confidence. It retains no more than a fixed
/// upper bound of points and seeks directly to an evenly distributed,
/// deterministic sample.
public struct PointCloudPLYReader: Sendable {
    public static let defaultMaximumPointCount = 50_000
    public static let maximumSupportedPointCount = 100_000

    private static let maximumHeaderByteCount = 64 * 1_024
    private static let headerTerminator = Data("end_header\n".utf8)
    private static let finalHeaderLine = Data("end_header".utf8)

    public init() {}

    public func read(
        from url: URL,
        maximumPointCount: Int = PointCloudPLYReader.defaultMaximumPointCount
    ) throws -> PointCloudPLYReadResult {
        guard (0...Self.maximumSupportedPointCount).contains(maximumPointCount) else {
            throw PointCloudPLYReaderError.invalidMaximumPointCount(maximumPointCount)
        }

        let fileByteCount = try byteCount(at: url)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PointCloudPLYReaderError.unreadableFile
        }
        defer { try? handle.close() }

        let headerData = try readData(from: handle, count: Self.maximumHeaderByteCount)
        let parsedHeader = try parseHeader(from: headerData)
        let header = parsedHeader.header
        let expectedRecordByteCount = try recordByteCount(
            for: header.vertexCount,
            recordByteCount: parsedHeader.layout.recordByteCount
        )

        guard fileByteCount >= parsedHeader.byteCount else {
            throw PointCloudPLYReaderError.invalidHeader
        }
        let actualRecordByteCount = fileByteCount - parsedHeader.byteCount
        guard actualRecordByteCount == expectedRecordByteCount else {
            throw PointCloudPLYReaderError.recordByteCountMismatch(
                expected: expectedRecordByteCount,
                actual: actualRecordByteCount
            )
        }

        let sampleCount = min(header.vertexCount, maximumPointCount)
        guard sampleCount > 0 else {
            return PointCloudPLYReadResult(header: header, points: [])
        }

        var points: [PointCloudPLYPoint] = []
        points.reserveCapacity(sampleCount)
        for ordinal in 0..<sampleCount {
            let vertexIndex = sampleIndex(
                for: ordinal,
                totalVertexCount: header.vertexCount,
                sampleCount: sampleCount
            )
            let offset = try recordOffset(
                headerByteCount: parsedHeader.byteCount,
                vertexIndex: vertexIndex,
                recordByteCount: parsedHeader.layout.recordByteCount
            )
            do {
                try handle.seek(toOffset: offset)
            } catch {
                throw PointCloudPLYReaderError.unreadableFile
            }
            points.append(
                try decodePoint(
                    from: readData(from: handle, count: parsedHeader.layout.recordByteCount),
                    layout: parsedHeader.layout
                )
            )
        }

        return PointCloudPLYReadResult(header: header, points: points)
    }

    private func byteCount(at url: URL) throws -> UInt64 {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize, fileSize >= 0 else {
                throw PointCloudPLYReaderError.unreadableFile
            }
            return UInt64(fileSize)
        } catch let error as PointCloudPLYReaderError {
            throw error
        } catch {
            throw PointCloudPLYReaderError.unreadableFile
        }
    }

    private func readData(from handle: FileHandle, count: Int) throws -> Data {
        do {
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            throw PointCloudPLYReaderError.unreadableFile
        }
    }

    private func parseHeader(from data: Data) throws -> ParsedHeader {
        let terminatorRange = data.range(of: Self.headerTerminator)
            ?? data.range(of: Self.finalHeaderLine)
        guard let terminatorRange else {
            throw PointCloudPLYReaderError.headerTooLarge
        }
        let headerBytes = data[..<terminatorRange.upperBound]
        guard let headerText = String(data: headerBytes, encoding: .utf8) else {
            throw PointCloudPLYReaderError.invalidHeader
        }

        let lines = headerText.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 3, lines.first == "ply", lines.last == "end_header" else {
            throw PointCloudPLYReaderError.invalidHeader
        }
        guard lines[1] == "format binary_little_endian 1.0" else {
            if lines[1].hasPrefix("format ") {
                throw PointCloudPLYReaderError.unsupportedFormat
            }
            throw PointCloudPLYReaderError.invalidHeader
        }

        var vertexCount: Int?
        var properties: [(type: Substring, name: Substring)] = []
        for line in lines.dropFirst(2).dropLast() {
            let components = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let directive = components.first else {
                throw PointCloudPLYReaderError.invalidHeader
            }

            switch directive {
            case "comment":
                continue
            case "element":
                guard components.count == 3,
                      components[1] == "vertex",
                      vertexCount == nil,
                      properties.isEmpty
                else {
                    throw PointCloudPLYReaderError.invalidHeader
                }
                guard let count = Int(components[2]), count >= 0 else {
                    throw PointCloudPLYReaderError.invalidVertexCount
                }
                vertexCount = count
            case "property":
                guard components.count == 3, vertexCount != nil else {
                    throw PointCloudPLYReaderError.invalidHeader
                }
                properties.append((type: components[1], name: components[2]))
            default:
                throw PointCloudPLYReaderError.invalidHeader
            }
        }

        guard let vertexCount else {
            throw PointCloudPLYReaderError.invalidHeader
        }
        let depthProperties: [(type: Substring, name: Substring)] = [
            ("float", "x"),
            ("float", "y"),
            ("float", "z"),
            ("uchar", "confidence")
        ]
        let coloredDepthProperties: [(type: Substring, name: Substring)] = [
            ("float", "x"),
            ("float", "y"),
            ("float", "z"),
            ("uchar", "red"),
            ("uchar", "green"),
            ("uchar", "blue"),
            ("uchar", "confidence")
        ]
        let layout: RecordLayout
        if properties.elementsEqual(depthProperties, by: { $0.type == $1.type && $0.name == $1.name }) {
            layout = .depthWithConfidence
        } else if properties.elementsEqual(coloredDepthProperties, by: { $0.type == $1.type && $0.name == $1.name }) {
            layout = .coloredDepthWithConfidence
        } else {
            throw PointCloudPLYReaderError.unsupportedVertexProperties
        }

        return ParsedHeader(
            header: PointCloudPLYHeader(
                vertexCount: vertexCount,
                recordByteCount: layout.recordByteCount,
                containsRGBColor: layout.containsRGBColor
            ),
            byteCount: UInt64(terminatorRange.upperBound),
            layout: layout
        )
    }

    private func recordByteCount(for vertexCount: Int, recordByteCount: Int) throws -> UInt64 {
        let (byteCount, overflow) = UInt64(vertexCount).multipliedReportingOverflow(by: UInt64(recordByteCount))
        guard !overflow else {
            throw PointCloudPLYReaderError.invalidVertexCount
        }
        return byteCount
    }

    private func sampleIndex(for ordinal: Int, totalVertexCount: Int, sampleCount: Int) -> Int {
        guard sampleCount > 1 else { return 0 }

        let denominator = sampleCount - 1
        let span = totalVertexCount - 1
        let quotient = span / denominator
        let remainder = span % denominator
        return ordinal * quotient + (ordinal * remainder) / denominator
    }

    private func recordOffset(
        headerByteCount: UInt64,
        vertexIndex: Int,
        recordByteCount: Int
    ) throws -> UInt64 {
        let (recordOffset, recordOverflow) = UInt64(vertexIndex).multipliedReportingOverflow(by: UInt64(recordByteCount))
        let (offset, headerOverflow) = headerByteCount.addingReportingOverflow(recordOffset)
        guard !recordOverflow, !headerOverflow else {
            throw PointCloudPLYReaderError.invalidVertexCount
        }
        return offset
    }

    private func decodePoint(from data: Data, layout: RecordLayout) throws -> PointCloudPLYPoint {
        guard data.count == layout.recordByteCount else {
            throw PointCloudPLYReaderError.malformedRecord
        }
        let color: PointCloudColor?
        switch layout {
        case .depthWithConfidence:
            color = nil
        case .coloredDepthWithConfidence:
            color = PointCloudColor(red: data[12], green: data[13], blue: data[14])
        }
        return PointCloudPLYPoint(
            position: Point3D(
                x: float32(in: data, at: 0),
                y: float32(in: data, at: 4),
                z: float32(in: data, at: 8)
            ),
            confidence: layout.confidenceByte(in: data),
            color: color
        )
    }

    private func float32(in data: Data, at offset: Int) -> Float {
        let bits = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        return Float(bitPattern: bits)
    }

    private struct ParsedHeader {
        let header: PointCloudPLYHeader
        let byteCount: UInt64
        let layout: RecordLayout
    }

    private enum RecordLayout {
        case depthWithConfidence
        case coloredDepthWithConfidence

        var recordByteCount: Int {
            switch self {
            case .depthWithConfidence:
                13
            case .coloredDepthWithConfidence:
                16
            }
        }

        var containsRGBColor: Bool {
            switch self {
            case .depthWithConfidence:
                false
            case .coloredDepthWithConfidence:
                true
            }
        }

        func confidenceByte(in data: Data) -> UInt8 {
            switch self {
            case .depthWithConfidence:
                data[12]
            case .coloredDepthWithConfidence:
                data[15]
            }
        }
    }
}
