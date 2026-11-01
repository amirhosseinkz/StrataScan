import CryptoKit
import Foundation
import Testing
@testable import StrataCore

@Suite("Processed surface discovery and bounded reading")
struct ProcessedSurfaceStoreTests {
    @Test("A promoted surface reopens completely without omitted faces")
    func readsBoundedLOD() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let store = try ProcessedSurfaceStore(rootURL: fixture.derivedRoot)
        let limits = try ProcessedSurfaceReadLimits(maximumVertexCount: 12, maximumTriangleCount: 4)

        let first = try await store.loadProcessedSurface(
            scanID: fixture.scanID,
            packageURL: fixture.packageURL,
            manifest: fixture.packageManifest,
            integrity: fixture.integrity,
            limits: limits
        )
        let second = try await store.loadProcessedSurface(
            scanID: fixture.scanID,
            packageURL: fixture.packageURL,
            manifest: fixture.packageManifest,
            integrity: fixture.integrity,
            limits: limits
        )

        #expect(first == second)
        #expect(first.sourceVertexCount == 12)
        #expect(first.sourceTriangleCount == 4)
        #expect(first.vertices.count == 12)
        #expect(first.indices.count == 12)
        #expect(first.hasObservedColors)
        #expect(first.isComplete)
        #expect(first.vertices.first == Point3D(x: 0, y: 0, z: 0))
        #expect(first.vertices.last == Point3D(x: 3, y: 0, z: 1))
    }

    @Test("Evaluation reads the complete promotion with original shared connectivity")
    func readsCompleteEvaluationGeometry() async throws {
        let sharedVertices = [
            Point3D(x: 0, y: 0, z: 0),
            Point3D(x: 1, y: 0, z: 0),
            Point3D(x: 0, y: 1, z: 0),
            Point3D(x: 1, y: 1, z: 0)
        ]
        let sharedIndices: [UInt32] = [0, 1, 2, 2, 1, 3]
        let fixture = try await Fixture(
            coloredTriangleOrdinals: [0],
            vertices: sharedVertices,
            indices: sharedIndices
        )
        defer { fixture.remove() }
        let store = try ProcessedSurfaceStore(rootURL: fixture.derivedRoot)

        let first = try await store.loadEvaluationGeometry(
            scanID: fixture.scanID,
            packageURL: fixture.packageURL,
            manifest: fixture.packageManifest,
            integrity: fixture.integrity
        )
        let second = try await store.loadEvaluationGeometry(
            scanID: fixture.scanID,
            packageURL: fixture.packageURL,
            manifest: fixture.packageManifest,
            integrity: fixture.integrity
        )

        #expect(first == second)
        #expect(first.vertices == sharedVertices)
        #expect(first.indices == sharedIndices)
        #expect(first.vertices.count == 4)
        #expect(first.indices.count / 3 == 2)
        #expect(Set(first.indices).count == 4)
        #expect(Fixture.connectedComponentCount(indices: first.indices) == 1)
        #expect(first.colors[0] != nil)
        #expect(first.colors[3] == nil)
        #expect(!first.allVerticesHaveObservedColors)
        let display = try await store.loadProcessedSurface(
            scanID: fixture.scanID, packageURL: fixture.packageURL,
            manifest: fixture.packageManifest, integrity: fixture.integrity
        )
        #expect(display.vertices == first.vertices)
        #expect(display.indices == sharedIndices)
        #expect(display.isComplete)
        #expect(Fixture.connectedComponentCount(indices: display.indices) == 1)
    }

    @Test("Evaluation fails explicitly when the complete promotion exceeds its limits")
    func rejectsEvaluationGeometryOverLimit() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let store = try ProcessedSurfaceStore(rootURL: fixture.derivedRoot)
        let limits = try BenchmarkEvaluationSafetyLimits(
            maximumGeometryBytes: 1_024,
            maximumVertices: 6,
            maximumTriangles: 2
        )

        await #expect(throws: ProcessedSurfaceReadError.completeSurfaceExceedsEvaluationLimits(
            vertexCount: 12,
            triangleCount: 4
        )) {
            try await store.loadEvaluationGeometry(
                scanID: fixture.scanID,
                packageURL: fixture.packageURL,
                manifest: fixture.packageManifest,
                integrity: fixture.integrity,
                limits: limits
            )
        }
    }

    @Test("A complete promoted surface remains readable when the per-frame ray budget was reached")
    func acceptsRayBudgetWithoutDroppedVoxelUpdates() async throws {
        let fixture = try await Fixture(
            sourceStatistics: TSDFReconstructionStatistics(
                processedFrameCount: 1,
                droppedVoxelUpdateCount: 0,
                rayLimitReachedFrameCount: 1
            )
        )
        defer { fixture.remove() }
        let store = try ProcessedSurfaceStore(rootURL: fixture.derivedRoot)

        let surface = try await store.loadProcessedSurface(
            scanID: fixture.scanID,
            packageURL: fixture.packageURL,
            manifest: fixture.packageManifest,
            integrity: fixture.integrity
        )

        #expect(surface.sourceTriangleCount == 4)
    }

    @Test("Checksum corruption is rejected before geometry is exposed")
    func rejectsCorruption() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let verticesURL = fixture.surfaceDirectory.appending(path: "geometry/vertices.bin")
        var data = try Data(contentsOf: verticesURL)
        data[0] ^= 0xFF
        try data.write(to: verticesURL, options: .atomic)
        let store = try ProcessedSurfaceStore(rootURL: fixture.derivedRoot)

        await #expect(throws: ProcessedSurfaceReadError.checksumMismatch("geometry/vertices.bin")) {
            try await store.loadProcessedSurface(
                scanID: fixture.scanID,
                packageURL: fixture.packageURL,
                manifest: fixture.packageManifest,
                integrity: fixture.integrity
            )
        }
    }

    @Test("Truncated evaluation geometry fails closed")
    func rejectsTruncatedEvaluationGeometry() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let indicesURL = fixture.surfaceDirectory.appending(path: "geometry/indices.bin")
        var data = try Data(contentsOf: indicesURL)
        data.removeLast()
        try data.write(to: indicesURL, options: .atomic)
        let store = try ProcessedSurfaceStore(rootURL: fixture.derivedRoot)

        await #expect(throws: ProcessedSurfaceReadError.invalidFile("geometry/indices.bin")) {
            try await store.loadEvaluationGeometry(
                scanID: fixture.scanID,
                packageURL: fixture.packageURL,
                manifest: fixture.packageManifest,
                integrity: fixture.integrity
            )
        }
    }

    @Test("A surface from another calibrated archive is stale")
    func rejectsStaleSource() async throws {
        let fixture = try await Fixture(staleSource: true)
        defer { fixture.remove() }
        let store = try ProcessedSurfaceStore(rootURL: fixture.derivedRoot)

        await #expect(throws: ProcessedSurfaceReadError.staleSource) {
            try await store.loadProcessedSurface(
                scanID: fixture.scanID,
                packageURL: fixture.packageURL,
                manifest: fixture.packageManifest,
                integrity: fixture.integrity
            )
        }
    }

    @Test("Incomplete and validation-failed surfaces are unavailable")
    func rejectsIncompleteAndFailedValidation() async throws {
        let incomplete = try await Fixture(completedFrameCount: 0)
        defer { incomplete.remove() }
        let incompleteStore = try ProcessedSurfaceStore(rootURL: incomplete.derivedRoot)
        await #expect(throws: ProcessedSurfaceReadError.incompleteSurface) {
            try await incompleteStore.loadProcessedSurface(
                scanID: incomplete.scanID,
                packageURL: incomplete.packageURL,
                manifest: incomplete.packageManifest,
                integrity: incomplete.integrity
            )
        }

        let failed = try await Fixture(validationFailures: [.fragmentedGeometry])
        defer { failed.remove() }
        let failedStore = try ProcessedSurfaceStore(rootURL: failed.derivedRoot)
        await #expect(throws: ProcessedSurfaceReadError.invalidValidation) {
            try await failedStore.loadProcessedSurface(
                scanID: failed.scanID,
                packageURL: failed.packageURL,
                manifest: failed.packageManifest,
                integrity: failed.integrity
            )
        }
    }

    @Test("Symbolic-link geometry is rejected even when its target is valid")
    func rejectsSymbolicLinkGeometry() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let geometry = fixture.surfaceDirectory.appending(path: "geometry", directoryHint: .isDirectory)
        let colors = geometry.appending(path: "colors.bin")
        let target = geometry.appending(path: "colors-target.bin")
        try FileManager.default.moveItem(at: colors, to: target)
        try FileManager.default.createSymbolicLink(at: colors, withDestinationURL: target)
        let store = try ProcessedSurfaceStore(rootURL: fixture.derivedRoot)

        await #expect(throws: ProcessedSurfaceReadError.unsafePath("colors.bin")) {
            try await store.loadProcessedSurface(
                scanID: fixture.scanID,
                packageURL: fixture.packageURL,
                manifest: fixture.packageManifest,
                integrity: fixture.integrity
            )
        }
    }

    @Test("A symbolic-link scan directory cannot escape the configured derived root")
    func rejectsSymbolicLinkScanDirectory() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let scanDirectory = fixture.surfaceDirectory.deletingLastPathComponent()
        let externalDirectory = fixture.root.appending(path: "external-scan", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: scanDirectory, to: externalDirectory)
        try FileManager.default.createSymbolicLink(
            at: scanDirectory,
            withDestinationURL: externalDirectory
        )
        let store = try ProcessedSurfaceStore(rootURL: fixture.derivedRoot)

        await #expect(throws: ProcessedSurfaceReadError.unsafePath(fixture.scanID.uuidString)) {
            try await store.loadProcessedSurface(
                scanID: fixture.scanID,
                packageURL: fixture.packageURL,
                manifest: fixture.packageManifest,
                integrity: fixture.integrity
            )
        }
    }

    @Test("Display preserves observed colors from every source region")
    func derivesColorAvailabilityFromSelectedLOD() async throws {
        let fixture = try await Fixture(coloredTriangleOrdinals: [3])
        defer { fixture.remove() }
        let store = try ProcessedSurfaceStore(rootURL: fixture.derivedRoot)
        let limits = try ProcessedSurfaceReadLimits(maximumVertexCount: 12, maximumTriangleCount: 4)

        let surface = try await store.loadProcessedSurface(
            scanID: fixture.scanID,
            packageURL: fixture.packageURL,
            manifest: fixture.packageManifest,
            integrity: fixture.integrity,
            limits: limits
        )

        #expect(surface.hasObservedColors)
        #expect(surface.colors.filter { $0 != nil }.count == 3)
        #expect(surface.isComplete)
    }

    @Test("Display refuses an oversized surface rather than silently dropping faces")
    func refusesDisplayFaceSampling() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let store = try ProcessedSurfaceStore(rootURL: fixture.derivedRoot)
        let limits = try ProcessedSurfaceReadLimits(maximumVertexCount: 6, maximumTriangleCount: 2)
        await #expect(throws: ProcessedSurfaceReadError.completeSurfaceExceedsDisplayLimits(vertexCount: 12, triangleCount: 4)) {
            try await store.loadProcessedSurface(scanID: fixture.scanID, packageURL: fixture.packageURL,
                manifest: fixture.packageManifest, integrity: fixture.integrity, limits: limits)
        }
    }

    @Test("Missing promotion discovery does not open the calibrated archive")
    func missingPromotionDoesNotRequireArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "StrataScanMissingProcessedSurface-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        let store = try ProcessedSurfaceStore(rootURL: root.appending(path: "derived"))
        let manifest = ScanPackageManifest(
            localScanID: scanID,
            status: .completed,
            createdAt: .now,
            updatedAt: .now
        )

        await #expect(throws: ProcessedSurfaceReadError.notFound) {
            try await store.loadProcessedSurface(
                scanID: scanID,
                packageURL: root.appending(path: "missing-package"),
                manifest: manifest,
                integrity: PackageIntegrityReport(scanID: scanID)
            )
        }
    }

    @Test("Deleting derived data removes only the scan's promotion and processing work")
    func removesOwnedDerivedData() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let processingRoot = fixture.root.appending(path: "processing", directoryHint: .isDirectory)
        let processingDirectory = processingRoot.appending(
            path: fixture.scanID.uuidString,
            directoryHint: .isDirectory
        )
        let unrelated = fixture.derivedRoot.appending(path: "unrelated", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: processingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let store = try ProcessedSurfaceStore(
            rootURL: fixture.derivedRoot,
            processingRootURL: processingRoot
        )

        try await store.removeDerivedData(for: fixture.scanID)

        #expect(!FileManager.default.fileExists(atPath: fixture.surfaceDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: processingDirectory.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("Cancellation prevents promoted geometry from loading")
    func observesCancellation() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let store = try ProcessedSurfaceStore(rootURL: fixture.derivedRoot)
        let task = Task {
            try await store.loadEvaluationGeometry(
                scanID: fixture.scanID,
                packageURL: fixture.packageURL,
                manifest: fixture.packageManifest,
                integrity: fixture.integrity
            )
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}

private struct Fixture {
    let root: URL
    let derivedRoot: URL
    let scanID: UUID
    let packageURL: URL
    let packageManifest: ScanPackageManifest
    let integrity: PackageIntegrityReport
    let surfaceDirectory: URL

    init(
        staleSource: Bool = false,
        completedFrameCount: Int = 1,
        validationFailures: [TSDFSurfaceValidationFailure] = [],
        coloredTriangleOrdinals: Set<Int> = [0, 1, 2, 3],
        sourceStatistics: TSDFReconstructionStatistics = TSDFReconstructionStatistics(
            processedFrameCount: 1
        ),
        vertices suppliedVertices: [Point3D]? = nil,
        indices suppliedIndices: [UInt32]? = nil
    ) async throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "StrataScanProcessedReader-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        derivedRoot = root.appending(path: "derived", directoryHint: .isDirectory)
        scanID = UUID()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let capture = root.appending(path: "capture", directoryHint: .isDirectory)
        let writer = try CalibratedRGBDKeyframeArchiveWriter(workingDirectory: capture)
        let record = try await writer.append(Self.keyframe())
        _ = try await writer.finish()
        let store = try FileAssetStore(rootURL: root.appending(path: "assets"))
        packageManifest = try await store.finalize(
            manifest: ScanPackageManifest(
                localScanID: scanID,
                status: .completed,
                createdAt: .now,
                updatedAt: .now
            ),
            assets: [
                CalibratedRGBDKeyframeArchiveWriter.indexRelativePath,
                record.depthPath,
                record.confidencePath,
                record.rgbPath
            ].map {
                AssetInput(
                    kind: .manifestAttachment,
                    relativePath: $0,
                    fileURL: capture.appending(path: $0),
                    spatialReference: .arWorld
                )
            }
        )
        packageURL = try await store.packageURL(for: scanID)
        integrity = try await store.validatePackage(id: scanID)
        let archive = try CalibratedRGBDKeyframeArchiveReader().open(
            packageURL: packageURL,
            manifest: packageManifest,
            integrity: integrity
        )
        var source = archive.reconstructionSource
        if staleSource { source.calibratedArchiveSHA256 = String(repeating: "d", count: 64) }
        let configuration = try TSDFReconstructionConfiguration(
            voxelSizeMeters: 0.1,
            truncationDistanceMeters: 0.2,
            submapVoxelDimension: 2,
            depthPixelStride: 1,
            maximumRaysPerFrame: 10,
            maximumUniqueVoxelUpdatesPerFrame: 100,
            maximumRaySteps: 5,
            minimumConfidence: 1,
            minimumDepthMeters: 0.1,
            maximumDepthMeters: 5,
            maximumVoxelWeight: 8
        )
        let prefix = TSDFCompletedPrefixIdentity(
            source: source,
            configuration: configuration,
            completedFrameCount: completedFrameCount,
            sha256: String(repeating: "c", count: 64)
        )
        let bounds = try TSDFSurfaceBounds(
            minimum: Point3D(x: 0, y: 0, z: 0),
            maximum: Point3D(x: 3, y: 1, z: 1)
        )
        let extractionConfiguration = try TSDFSurfaceExtractionConfiguration(
            maximumSubmaps: 8,
            maximumVerticesPerSubmap: 100,
            maximumTrianglesPerSubmap: 100,
            maximumPromotedVertices: 100,
            maximumPromotedTriangles: 100
        )
        surfaceDirectory = derivedRoot.appending(path: scanID.uuidString, directoryHint: .isDirectory)
            .appending(path: "processed-surface", directoryHint: .isDirectory)
        let geometry = surfaceDirectory.appending(path: "geometry", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: geometry, withIntermediateDirectories: true)
        let vertices = suppliedVertices ?? Self.vertices()
        let normals = Array(repeating: Point3D(x: 1, y: 0, z: 0), count: vertices.count)
        let colors = vertices.indices.map { index -> PointCloudColor? in
            guard coloredTriangleOrdinals.contains(index / 3) else { return nil }
            return PointCloudColor(red: UInt8(index * 10), green: 80, blue: 120)
        }
        let indices = suppliedIndices ?? [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
        try Self.pointData(vertices).write(to: geometry.appending(path: "vertices.bin"))
        try Self.pointData(normals).write(to: geometry.appending(path: "normals.bin"))
        try Self.colorData(colors).write(to: geometry.appending(path: "colors.bin"))
        try Self.indexData(indices).write(to: geometry.appending(path: "indices.bin"))
        let statistics = TSDFSurfaceExtractionStatistics(
            processedSubmapCount: 1,
            inspectedCellCount: 4,
            emittedVertexOccurrenceCount: vertices.count,
            emittedTriangleCount: indices.count / 3
        )
        let validation = TSDFSurfaceValidationReport(
            failures: validationFailures,
            vertexCount: vertices.count,
            triangleCount: indices.count / 3,
            componentTriangleCounts: [indices.count / 3],
            bounds: bounds,
            robustBounds: bounds,
            duplicateBoundaryVertexCount: 0,
            boundarySeamMismatchCount: 0,
            sourceStatistics: sourceStatistics,
            statistics: statistics
        )
        let validationURL = surfaceDirectory.appending(path: "validation.json")
        try Self.jsonData(validation).write(to: validationURL)
        let geometryReferences = try [
            "geometry/vertices.bin", "geometry/normals.bin",
            "geometry/colors.bin", "geometry/indices.bin"
        ].map { try Self.reference(path: $0, under: surfaceDirectory) }
        let manifest = TSDFProcessedSurfaceManifest(
            scanID: scanID,
            prefix: prefix,
            extractionConfiguration: extractionConfiguration,
            vertexCount: vertices.count,
            triangleCount: indices.count / 3,
            robustBounds: bounds,
            geometryFiles: geometryReferences,
            validationFile: try Self.reference(path: "validation.json", under: surfaceDirectory)
        )
        try Self.jsonData(manifest).write(to: surfaceDirectory.appending(path: "manifest.json"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private static func vertices() -> [Point3D] {
        (0..<4).flatMap { triangle in
            let x = Float(triangle)
            return [
                Point3D(x: x, y: 0, z: 0),
                Point3D(x: x, y: 1, z: 0),
                Point3D(x: x, y: 0, z: 1)
            ]
        }
    }

    static func connectedComponentCount(indices: [UInt32]) -> Int {
        let triangles = stride(from: 0, to: indices.count, by: 3).map {
            Set(indices[$0...($0 + 2)])
        }
        var remaining = Set(triangles.indices)
        var count = 0
        while let seed = remaining.first {
            count += 1
            remaining.remove(seed)
            var frontier = [seed]
            while let current = frontier.popLast() {
                let neighbors = remaining.filter { !triangles[current].isDisjoint(with: triangles[$0]) }
                remaining.subtract(neighbors)
                frontier.append(contentsOf: neighbors)
            }
        }
        return count
    }

    private static func keyframe() -> CalibratedRGBDKeyframeSample {
        let intrinsics = CameraIntrinsics(imageWidth: 1, imageHeight: 1, fx: 1, fy: 1, cx: 0, cy: 0)
        let metadata = FrameMetadata(
            timestamp: 1,
            videoTimestamp: nil,
            imageWidth: 1,
            imageHeight: 1,
            intrinsics: intrinsics,
            worldFromCamera: .identity,
            tracking: .normal,
            worldMapping: .mapped,
            isTextureSourceCandidate: false
        )
        return authoritativeTestKeyframe(
            metadata: metadata,
            depth: DepthFrameSample(
                width: 1,
                height: 1,
                depthMeters: [1],
                confidence: [2],
                observedColors: [PointCloudColor(red: 1, green: 2, blue: 3)],
                calibration: intrinsics,
                worldFromCamera: .identity,
                timestamp: 1
            )
        )
    }

    private static func pointData(_ points: [Point3D]) -> Data {
        var data = Data()
        for point in points {
            data.appendLittleEndian(point.x.bitPattern)
            data.appendLittleEndian(point.y.bitPattern)
            data.appendLittleEndian(point.z.bitPattern)
        }
        return data
    }

    private static func colorData(_ colors: [PointCloudColor?]) -> Data {
        var data = Data()
        for color in colors {
            if let color {
                data.append(contentsOf: [color.red, color.green, color.blue, 1])
            } else {
                data.append(contentsOf: [0, 0, 0, 0])
            }
        }
        return data
    }

    private static func indexData(_ indices: [UInt32]) -> Data {
        var data = Data()
        for index in indices { data.appendLittleEndian(index) }
        return data
    }

    private static func jsonData<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func reference(path: String, under directory: URL) throws -> TSDFDerivedFileReference {
        let url = directory.appending(path: path)
        let data = try Data(contentsOf: url)
        return TSDFDerivedFileReference(
            relativePath: path,
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
