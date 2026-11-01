import CryptoKit
import Foundation

public enum ProcessedSurfaceReadError: Error, Equatable, Sendable {
    case notFound
    case packageIntegrityFailed
    case staleSource
    case incompleteSurface
    case unsupportedSchema
    case invalidManifest
    case invalidValidation
    case unsafePath(String)
    case invalidFile(String)
    case checksumMismatch(String)
    case completeSurfaceExceedsEvaluationLimits(vertexCount: Int, triangleCount: Int)
    case completeSurfaceExceedsDisplayLimits(vertexCount: Int, triangleCount: Int)
    case invalidGeometry
    case ioFailure(String)
}

public struct ProcessedSurfaceReadLimits: Equatable, Sendable {
    public static let `default` = ProcessedSurfaceReadLimits(
        uncheckedMaximumVertexCount: 300_000,
        maximumTriangleCount: 600_000
    )

    public var maximumVertexCount: Int
    public var maximumTriangleCount: Int

    public init(maximumVertexCount: Int = 300_000, maximumTriangleCount: Int = 600_000) throws {
        guard (3...300_000).contains(maximumVertexCount),
              (1...600_000).contains(maximumTriangleCount)
        else {
            throw ProcessedSurfaceReadError.invalidGeometry
        }
        self.maximumVertexCount = maximumVertexCount
        self.maximumTriangleCount = maximumTriangleCount
    }

    private init(uncheckedMaximumVertexCount maximumVertexCount: Int, maximumTriangleCount: Int) {
        self.maximumVertexCount = maximumVertexCount
        self.maximumTriangleCount = maximumTriangleCount
    }
}

public struct ProcessedSurfaceLOD: Equatable, Sendable {
    public var prefix: TSDFCompletedPrefixIdentity
    public var sourceVertexCount: Int
    public var sourceTriangleCount: Int
    public var vertices: [Point3D]
    public var normals: [Point3D]
    public var colors: [PointCloudColor?]
    public var indices: [UInt32]
    public var robustBounds: TSDFSurfaceBounds
    public var hasObservedColors: Bool

    public init(
        prefix: TSDFCompletedPrefixIdentity,
        sourceVertexCount: Int,
        sourceTriangleCount: Int,
        vertices: [Point3D],
        normals: [Point3D],
        colors: [PointCloudColor?],
        indices: [UInt32],
        robustBounds: TSDFSurfaceBounds,
        hasObservedColors: Bool
    ) {
        self.prefix = prefix
        self.sourceVertexCount = sourceVertexCount
        self.sourceTriangleCount = sourceTriangleCount
        self.vertices = vertices
        self.normals = normals
        self.colors = colors
        self.indices = indices
        self.robustBounds = robustBounds
        self.hasObservedColors = hasObservedColors
    }

    public var isComplete: Bool {
        vertices.count == sourceVertexCount && indices.count / 3 == sourceTriangleCount
    }
}

public struct ProcessedSurfaceEvaluationGeometry: Equatable, Sendable {
    public let prefix: TSDFCompletedPrefixIdentity
    public let vertices: [Point3D]
    public let normals: [Point3D]
    public let colors: [PointCloudColor?]
    public let indices: [UInt32]
    public let robustBounds: TSDFSurfaceBounds

    public var hasAnyObservedColors: Bool {
        colors.contains(where: { $0 != nil })
    }

    public var allVerticesHaveObservedColors: Bool {
        colors.allSatisfy { $0 != nil }
    }
}

public struct ValidatedProcessedSurface: Equatable, Sendable {
    public let directoryURL: URL
    public let manifest: TSDFProcessedSurfaceManifest
    public let validation: TSDFSurfaceValidationReport
    public let verticesURL: URL
    public let normalsURL: URL
    public let colorsURL: URL
    public let indicesURL: URL
    public let hasAnyObservedColors: Bool
    public let allVerticesHaveObservedColors: Bool

    init(
        directoryURL: URL,
        manifest: TSDFProcessedSurfaceManifest,
        validation: TSDFSurfaceValidationReport,
        verticesURL: URL,
        normalsURL: URL,
        colorsURL: URL,
        indicesURL: URL,
        hasAnyObservedColors: Bool,
        allVerticesHaveObservedColors: Bool
    ) {
        self.directoryURL = directoryURL
        self.manifest = manifest
        self.validation = validation
        self.verticesURL = verticesURL
        self.normalsURL = normalsURL
        self.colorsURL = colorsURL
        self.indicesURL = indicesURL
        self.hasAnyObservedColors = hasAnyObservedColors
        self.allVerticesHaveObservedColors = allVerticesHaveObservedColors
    }
}

public actor ProcessedSurfaceStore {
    private static let maximumJSONByteCount = 1_048_576
    private static let maximumSourceIndexByteCount: Int64 = 16 * 1_024 * 1_024
    private static let maximumSourceAssetCount = 100_000
    private static let expectedGeometryPaths = [
        "geometry/vertices.bin",
        "geometry/normals.bin",
        "geometry/colors.bin",
        "geometry/indices.bin"
    ]

    public let rootURL: URL
    public let processingRootURL: URL?
    private let fileManager: FileManager

    public init(
        rootURL: URL,
        processingRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.rootURL = rootURL
        self.processingRootURL = processingRootURL
        self.fileManager = fileManager
        do {
            if fileManager.fileExists(atPath: rootURL.path) {
                try Self.requireDirectory(rootURL, allowSymbolicLink: false)
            } else {
                try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            }
        } catch let error as ProcessedSurfaceReadError {
            throw error
        } catch {
            throw ProcessedSurfaceReadError.ioFailure(error.localizedDescription)
        }
    }

    public func hasProcessingWork(for scanID: UUID) -> Bool {
        guard let processingRootURL else { return false }
        return fileManager.fileExists(
            atPath: processingRootURL.appending(path: scanID.uuidString, directoryHint: .isDirectory).path
        )
    }

    public func removeDerivedData(for scanID: UUID) throws {
        try removeScanDirectory(for: scanID, under: rootURL)
        if let processingRootURL {
            try removeScanDirectory(for: scanID, under: processingRootURL)
        }
    }

    public func loadProcessedSurface(
        scanID: UUID,
        packageURL: URL,
        manifest packageManifest: ScanPackageManifest,
        integrity: PackageIntegrityReport,
        limits: ProcessedSurfaceReadLimits = .default
    ) throws -> ProcessedSurfaceLOD {
        let validated = try validatedProcessedSurface(
            scanID: scanID,
            packageURL: packageURL,
            manifest: packageManifest,
            integrity: integrity
        )
        // Complete indexed geometry only. Independent triangle sampling creates
        // holes; it is not a surface simplification. Counts bound decoded data
        // to 15.6 MB of packed positions/normals/colors/indices at these ceilings.
        guard (3...300_000).contains(limits.maximumVertexCount),
              (1...600_000).contains(limits.maximumTriangleCount) else {
            throw ProcessedSurfaceReadError.invalidGeometry
        }
        guard validated.manifest.vertexCount <= limits.maximumVertexCount,
              validated.manifest.triangleCount <= limits.maximumTriangleCount else {
            throw ProcessedSurfaceReadError.completeSurfaceExceedsDisplayLimits(
                vertexCount: validated.manifest.vertexCount,
                triangleCount: validated.manifest.triangleCount
            )
        }
        let geometry = try Self.readCompleteEvaluationGeometry(validated)
        return ProcessedSurfaceLOD(
            prefix: geometry.prefix,
            sourceVertexCount: geometry.vertices.count,
            sourceTriangleCount: geometry.indices.count / 3,
            vertices: geometry.vertices,
            normals: geometry.normals,
            colors: geometry.colors,
            indices: geometry.indices,
            robustBounds: geometry.robustBounds,
            hasObservedColors: geometry.hasAnyObservedColors
        )
    }

    public func loadEvaluationGeometry(
        scanID: UUID,
        packageURL: URL,
        manifest packageManifest: ScanPackageManifest,
        integrity: PackageIntegrityReport,
        limits: BenchmarkEvaluationSafetyLimits = BenchmarkEvaluator.safetyLimits
    ) throws -> ProcessedSurfaceEvaluationGeometry {
        guard limits.maximumGeometryBytes > 0,
              limits.maximumGeometryBytes <= BenchmarkEvaluator.safetyLimits.maximumGeometryBytes,
              limits.maximumVertices > 0,
              limits.maximumVertices <= BenchmarkEvaluator.safetyLimits.maximumVertices,
              limits.maximumTriangles > 0,
              limits.maximumTriangles <= BenchmarkEvaluator.safetyLimits.maximumTriangles else {
            throw ProcessedSurfaceReadError.invalidGeometry
        }
        let validated = try validatedProcessedSurface(
            scanID: scanID,
            packageURL: packageURL,
            manifest: packageManifest,
            integrity: integrity
        )
        guard validated.manifest.vertexCount <= limits.maximumVertices,
              validated.manifest.triangleCount <= limits.maximumTriangles else {
            throw ProcessedSurfaceReadError.completeSurfaceExceedsEvaluationLimits(
                vertexCount: validated.manifest.vertexCount,
                triangleCount: validated.manifest.triangleCount
            )
        }
        return try Self.readCompleteEvaluationGeometry(validated)
    }

    public func validatedProcessedSurface(
        scanID: UUID,
        packageURL: URL,
        manifest packageManifest: ScanPackageManifest,
        integrity: PackageIntegrityReport
    ) throws -> ValidatedProcessedSurface {
        try Task.checkCancellation()
        guard integrity.isValid,
              integrity.scanID == scanID,
              packageManifest.localScanID == scanID
        else {
            throw ProcessedSurfaceReadError.packageIntegrityFailed
        }
        let directory = try resolvedSurfaceDirectory(for: scanID)
        guard packageManifest.assets.count <= Self.maximumSourceAssetCount,
              let indexAsset = packageManifest.assets.first(where: {
                  $0.relativePath == CalibratedRGBDKeyframeArchiveWriter.indexRelativePath
              }),
              (1...Self.maximumSourceIndexByteCount).contains(indexAsset.byteCount)
        else {
            throw ProcessedSurfaceReadError.packageIntegrityFailed
        }
        let archive: CalibratedRGBDKeyframeReplayArchive
        do {
            archive = try CalibratedRGBDKeyframeArchiveReader().open(
                packageURL: packageURL,
                manifest: packageManifest,
                integrity: integrity
            )
        } catch {
            throw ProcessedSurfaceReadError.packageIntegrityFailed
        }
        let currentSource = archive.reconstructionSource

        let surfaceManifest: TSDFProcessedSurfaceManifest = try Self.decodeJSON(
            at: directory.appending(path: "manifest.json"),
            maximumByteCount: Self.maximumJSONByteCount
        )
        guard surfaceManifest.schemaVersion == TSDFProcessedSurfaceManifest.currentSchemaVersion else {
            throw ProcessedSurfaceReadError.unsupportedSchema
        }
        guard surfaceManifest.scanID == scanID,
              surfaceManifest.prefix.source.scanID == scanID
        else {
            throw ProcessedSurfaceReadError.invalidManifest
        }
        guard surfaceManifest.prefix.source == currentSource else {
            throw ProcessedSurfaceReadError.staleSource
        }
        guard surfaceManifest.prefix.completedFrameCount == currentSource.keyframeCount,
              currentSource.keyframeCount > 0
        else {
            throw ProcessedSurfaceReadError.incompleteSurface
        }
        guard Self.isSHA256(surfaceManifest.prefix.sha256),
              surfaceManifest.vertexCount > 0,
              surfaceManifest.triangleCount > 0,
              surfaceManifest.vertexCount <= 10_000_000,
              surfaceManifest.triangleCount <= 20_000_000,
              surfaceManifest.validationFile.relativePath == "validation.json",
              surfaceManifest.geometryFiles.map(\.relativePath) == Self.expectedGeometryPaths,
              Set(surfaceManifest.geometryFiles.map(\.relativePath)).count
                == surfaceManifest.geometryFiles.count
        else {
            throw ProcessedSurfaceReadError.invalidManifest
        }

        let expectedLengths = [
            Self.checkedByteCount(surfaceManifest.vertexCount, stride: 12),
            Self.checkedByteCount(surfaceManifest.vertexCount, stride: 12),
            Self.checkedByteCount(surfaceManifest.vertexCount, stride: 4),
            Self.checkedByteCount(surfaceManifest.triangleCount, stride: 12)
        ]
        guard expectedLengths.allSatisfy({ $0 != nil }) else {
            throw ProcessedSurfaceReadError.invalidManifest
        }
        for (offset, reference) in surfaceManifest.geometryFiles.enumerated() {
            guard reference.byteCount == expectedLengths[offset] else {
                throw ProcessedSurfaceReadError.invalidManifest
            }
            try Self.verify(reference, under: directory)
        }
        try Self.verify(surfaceManifest.validationFile, under: directory)

        let validation: TSDFSurfaceValidationReport = try Self.decodeJSON(
            at: directory.appending(path: "validation.json"),
            maximumByteCount: Self.maximumJSONByteCount
        )
        guard validation.isValid,
              validation.failures.isEmpty,
              validation.vertexCount == surfaceManifest.vertexCount,
              validation.triangleCount == surfaceManifest.triangleCount,
              validation.robustBounds == surfaceManifest.robustBounds,
              validation.statistics.droppedSubmapCount == 0,
              validation.statistics.droppedVertexCount == 0,
              validation.statistics.droppedTriangleCount == 0,
              validation.sourceStatistics.droppedVoxelUpdateCount == 0
        else {
            throw ProcessedSurfaceReadError.invalidValidation
        }

        let geometryDirectory = directory.appending(path: "geometry", directoryHint: .isDirectory)
        let colorsURL = geometryDirectory.appending(path: "colors.bin")
        let colorSummary = try Self.validateColors(
            at: colorsURL,
            vertexCount: surfaceManifest.vertexCount
        )
        return ValidatedProcessedSurface(
            directoryURL: directory,
            manifest: surfaceManifest,
            validation: validation,
            verticesURL: geometryDirectory.appending(path: "vertices.bin"),
            normalsURL: geometryDirectory.appending(path: "normals.bin"),
            colorsURL: colorsURL,
            indicesURL: geometryDirectory.appending(path: "indices.bin"),
            hasAnyObservedColors: colorSummary.observedCount > 0,
            allVerticesHaveObservedColors: colorSummary.observedCount == surfaceManifest.vertexCount
        )
    }

    private func surfaceDirectory(for scanID: UUID) -> URL {
        rootURL.appending(path: scanID.uuidString, directoryHint: .isDirectory)
            .appending(path: "processed-surface", directoryHint: .isDirectory)
    }


    private func resolvedSurfaceDirectory(for scanID: UUID) throws -> URL {
        let scanDirectory = rootURL.appending(path: scanID.uuidString, directoryHint: .isDirectory)
        let directory = scanDirectory.appending(path: "processed-surface", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw ProcessedSurfaceReadError.notFound
        }
        try Self.requireDirectory(rootURL, allowSymbolicLink: false)
        try Self.requireDirectory(scanDirectory, allowSymbolicLink: false)
        try Self.requireDirectory(directory, allowSymbolicLink: false)
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard directoryPath.hasPrefix(rootPath + "/") else {
            throw ProcessedSurfaceReadError.unsafePath(directory.path)
        }
        return directory
    }

    private func removeScanDirectory(for scanID: UUID, under root: URL) throws {
        let directory = root.appending(path: scanID.uuidString, directoryHint: .isDirectory)
        let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard fileManager.fileExists(atPath: directory.path) || values?.isSymbolicLink == true else {
            return
        }
        if values?.isSymbolicLink == true {
            try fileManager.removeItem(at: directory)
            return
        }
        try Self.requireDirectory(root, allowSymbolicLink: false)
        try Self.requireDirectory(directory, allowSymbolicLink: false)
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard directoryPath.hasPrefix(rootPath + "/") else {
            throw ProcessedSurfaceReadError.unsafePath(directory.path)
        }
        try fileManager.removeItem(at: directory)
    }
}

private extension ProcessedSurfaceStore {
    struct ColorSummary {
        var observedCount: Int
    }

    static func readCompleteEvaluationGeometry(
        _ surface: ValidatedProcessedSurface
    ) throws -> ProcessedSurfaceEvaluationGeometry {
        let positionsHandle = try openForReading(surface.verticesURL)
        let normalsHandle = try openForReading(surface.normalsURL)
        let colorsHandle = try openForReading(surface.colorsURL)
        defer {
            try? positionsHandle.close()
            try? normalsHandle.close()
            try? colorsHandle.close()
        }

        let vertexCount = surface.manifest.vertexCount
        var vertices: [Point3D] = []
        var normals: [Point3D] = []
        var colors: [PointCloudColor?] = []
        vertices.reserveCapacity(vertexCount)
        normals.reserveCapacity(vertexCount)
        colors.reserveCapacity(vertexCount)
        let recordsPerRead = 4_096
        for start in stride(from: 0, to: vertexCount, by: recordsPerRead) {
            try Task.checkCancellation()
            let count = min(recordsPerRead, vertexCount - start)
            let positionData = try readExactly(count * 12, from: positionsHandle, filename: "vertices.bin")
            let normalData = try readExactly(count * 12, from: normalsHandle, filename: "normals.bin")
            let colorData = try readExactly(count * 4, from: colorsHandle, filename: "colors.bin")
            for offset in 0..<count {
                guard let position = point(from: positionData, at: offset * 12),
                      let normal = point(from: normalData, at: offset * 12),
                      length(normal).isFinite,
                      length(normal) > 0.5,
                      colorData[offset * 4 + 3] <= 1 else {
                    throw ProcessedSurfaceReadError.invalidGeometry
                }
                vertices.append(position)
                normals.append(normal)
                let colorOffset = offset * 4
                colors.append(colorData[colorOffset + 3] == 1
                    ? PointCloudColor(
                        red: colorData[colorOffset],
                        green: colorData[colorOffset + 1],
                        blue: colorData[colorOffset + 2]
                    )
                    : nil)
            }
        }

        let triangleCount = surface.manifest.triangleCount
        let indicesHandle = try openForReading(surface.indicesURL)
        defer { try? indicesHandle.close() }
        var indices: [UInt32] = []
        indices.reserveCapacity(triangleCount * 3)
        for start in stride(from: 0, to: triangleCount, by: recordsPerRead) {
            try Task.checkCancellation()
            let count = min(recordsPerRead, triangleCount - start)
            let data = try readExactly(count * 12, from: indicesHandle, filename: "indices.bin")
            for offset in 0..<count {
                let byteOffset = offset * 12
                guard let first = data.readUInt32LittleEndian(at: byteOffset),
                      let second = data.readUInt32LittleEndian(at: byteOffset + 4),
                      let third = data.readUInt32LittleEndian(at: byteOffset + 8),
                      first < vertexCount,
                      second < vertexCount,
                      third < vertexCount,
                      first != second,
                      second != third,
                      first != third else {
                    throw ProcessedSurfaceReadError.invalidGeometry
                }
                indices.append(contentsOf: [first, second, third])
            }
        }
        return ProcessedSurfaceEvaluationGeometry(
            prefix: surface.manifest.prefix,
            vertices: vertices,
            normals: normals,
            colors: colors,
            indices: indices,
            robustBounds: surface.manifest.robustBounds
        )
    }


    static func verify(_ reference: TSDFDerivedFileReference, under directory: URL) throws {
        guard isSafe(reference.relativePath),
              reference.byteCount >= 0,
              isSHA256(reference.sha256)
        else { throw ProcessedSurfaceReadError.unsafePath(reference.relativePath) }
        let url = directory.appending(path: reference.relativePath)
        try requireRegularFile(url)
        let rootPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw ProcessedSurfaceReadError.unsafePath(reference.relativePath)
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == reference.byteCount else {
            throw ProcessedSurfaceReadError.invalidFile(reference.relativePath)
        }
        let digest = try sha256(for: url)
        guard digest == reference.sha256 else {
            throw ProcessedSurfaceReadError.checksumMismatch(reference.relativePath)
        }
    }

    static func validateColors(at url: URL, vertexCount: Int) throws -> ColorSummary {
        try requireRegularFile(url)
        let handle = try openForReading(url)
        defer { try? handle.close() }
        var observedCount = 0
        for index in 0..<vertexCount {
            if index % 4_096 == 0 { try Task.checkCancellation() }
            let data = try readExactly(4, from: handle, filename: "colors.bin")
            guard data[3] <= 1 else { throw ProcessedSurfaceReadError.invalidGeometry }
            if data[3] == 1 { observedCount += 1 }
        }
        return ColorSummary(observedCount: observedCount)
    }

    static func decodeJSON<Value: Decodable>(at url: URL, maximumByteCount: Int) throws -> Value {
        try requireRegularFile(url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, (1...maximumByteCount).contains(size) else {
            throw ProcessedSurfaceReadError.invalidFile(url.lastPathComponent)
        }
        do {
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
        } catch {
            throw ProcessedSurfaceReadError.invalidFile(url.lastPathComponent)
        }
    }

    static func requireDirectory(_ url: URL, allowSymbolicLink: Bool) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true,
              allowSymbolicLink || values.isSymbolicLink != true
        else { throw ProcessedSurfaceReadError.unsafePath(url.lastPathComponent) }
    }

    static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ProcessedSurfaceReadError.unsafePath(url.lastPathComponent)
        }
    }

    static func sha256(for url: URL) throws -> String {
        let handle = try openForReading(url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func openForReading(_ url: URL) throws -> FileHandle {
        do { return try FileHandle(forReadingFrom: url) }
        catch { throw ProcessedSurfaceReadError.ioFailure(error.localizedDescription) }
    }

    static func readExactly(_ count: Int, from handle: FileHandle, filename: String) throws -> Data {
        do {
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw ProcessedSurfaceReadError.invalidFile(filename) }
            return data
        } catch let error as ProcessedSurfaceReadError { throw error }
        catch { throw ProcessedSurfaceReadError.ioFailure(error.localizedDescription) }
    }


    static func point(from data: Data, at offset: Int = 0) -> Point3D? {
        guard let x = data.readFloat32LittleEndian(at: offset),
              let y = data.readFloat32LittleEndian(at: offset + 4),
              let z = data.readFloat32LittleEndian(at: offset + 8),
              x.isFinite, y.isFinite, z.isFinite
        else { return nil }
        return Point3D(x: x, y: y, z: z)
    }

    static func length(_ point: Point3D) -> Float {
        sqrt(point.x * point.x + point.y * point.y + point.z * point.z)
    }

    static func checkedByteCount(_ count: Int, stride: Int) -> Int64? {
        let result = count.multipliedReportingOverflow(by: stride)
        guard !result.overflow, let value = Int64(exactly: result.partialValue) else { return nil }
        return value
    }

    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
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

    func readFloat32LittleEndian(at offset: Int) -> Float? {
        readUInt32LittleEndian(at: offset).map(Float.init(bitPattern:))
    }
}
