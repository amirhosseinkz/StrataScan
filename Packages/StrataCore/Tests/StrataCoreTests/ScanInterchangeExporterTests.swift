import CryptoKit
import Foundation
import Testing
@testable import StrataCore

@Suite("Canonical scan interchange export", .serialized)
struct ScanInterchangeExporterTests {
    @Test("PLY is generated from every canonical point with validated color, bounds, and checksum")
    func writesCanonicalPLY() async throws {
        let samples = [
            sample(x: -1, y: 2, z: 3, confidence: 1, color: .init(red: 10, green: 20, blue: 30)),
            sample(x: 4, y: -5, z: 6, confidence: 2, color: .init(red: 40, green: 50, blue: 60))
        ]
        let fixture = try await ExportFixture(canonicalSamples: samples)
        defer { fixture.remove() }
        let destination = fixture.exportRoot.appending(path: "canonical.ply")

        let output = try ScanInterchangeExporter().writePLY(
            from: fixture.manifest,
            packageURL: fixture.packageURL,
            integrity: fixture.integrity,
            to: destination
        )

        #expect(output.fileURL == destination)
        #expect(output.fileURL != fixture.previewPLYURL)
        let result = try PointCloudPLYReader().read(from: destination, maximumPointCount: 10)
        #expect(result.header.vertexCount == samples.count)
        #expect(result.header.containsRGBColor)
        #expect(result.points.map(\.position) == samples.map(\.position))
        #expect(result.points.map(\.color) == samples.map(\.color))
        #expect(output.validation.bounds.minimum == Point3D(x: -1, y: -5, z: 3))
        #expect(output.validation.bounds.maximum == Point3D(x: 4, y: 2, z: 6))
        #expect(output.validation.hasObservedColors)
        try expectValidChecksums(output.validation, root: destination.deletingLastPathComponent())
    }

    @Test("Mixed canonical color exports all points without fabricated RGB")
    func writesUncoloredPLYWhenCanonicalColorIsIncomplete() async throws {
        let fixture = try await ExportFixture(canonicalSamples: [
            sample(x: 1, y: 2, z: 3, confidence: 1, color: .init(red: 1, green: 2, blue: 3)),
            sample(x: 4, y: 5, z: 6, confidence: 2, color: nil)
        ])
        defer { fixture.remove() }
        let destination = fixture.exportRoot.appending(path: "mixed.ply")

        let output = try ScanInterchangeExporter().writePLY(
            from: fixture.manifest,
            packageURL: fixture.packageURL,
            integrity: fixture.integrity,
            to: destination
        )

        let result = try PointCloudPLYReader().read(from: destination, maximumPointCount: 10)
        #expect(result.header.vertexCount == 2)
        #expect(!result.header.containsRGBColor)
        #expect(result.points.allSatisfy { $0.color == nil })
        #expect(!output.validation.hasObservedColors)
    }

    @Test("Canonical PLY export does not inherit the 100,000-point preview ceiling")
    func exportsBeyondCompatibilityPreviewLimit() async throws {
        let samples = (0...100_000).map { index in
            sample(
                x: Float(index),
                y: Float(-index),
                z: 1,
                confidence: 1,
                color: nil
            )
        }
        let fixture = try await ExportFixture(
            canonicalSamples: samples,
            includeProcessed: false
        )
        defer { fixture.remove() }
        let destination = fixture.exportRoot.appending(path: "complete.ply")

        let output = try ScanInterchangeExporter().writePLY(
            from: fixture.manifest,
            packageURL: fixture.packageURL,
            integrity: fixture.integrity,
            to: destination
        )

        #expect(output.validation.pointCount == 100_001)
        let header = try PointCloudPLYReader().read(
            from: destination,
            maximumPointCount: 0
        ).header
        #expect(header.vertexCount == 100_001)
        #expect(output.validation.bounds.maximum == Point3D(x: 100_000, y: 0, z: 1))
        #expect(output.validation.bounds.minimum == Point3D(x: 0, y: -100_000, z: 1))
    }

    @Test("GLB uses complete indexed promoted geometry and observed vertex color")
    func writesGLBFromValidatedProcessedSurface() async throws {
        let fixture = try await ExportFixture()
        defer { fixture.remove() }
        let surface = try await fixture.validatedSurface()
        let destination = fixture.exportRoot.appending(path: "scan.glb")

        let validation = try ScanInterchangeExporter().writeGLB(
            from: surface,
            packageURL: fixture.packageURL,
            to: destination
        )

        let glb = try GLBFixture(url: destination)
        #expect(glb.positions == ExportFixture.processedVertices)
        #expect(glb.indices == [0, 1, 2, 1, 3, 2])
        #expect(glb.colors == ExportFixture.processedColors)
        #expect(validation.pointCount == 4)
        #expect(validation.triangleCount == 2)
        #expect(validation.hasObservedColors)
        #expect(!glb.positions.contains(Point3D(x: 100, y: 100, z: 100)))
        try expectValidChecksums(validation, root: destination.deletingLastPathComponent())
    }

    @Test("3D Tiles and embedded GLB share full promoted bounds, color, and structure")
    func writesValidatedLocal3DTiles() async throws {
        let fixture = try await ExportFixture()
        defer { fixture.remove() }
        let destination = fixture.exportRoot.appending(path: "tiles", directoryHint: .isDirectory)
        let output = try ScanInterchangeExporter().writeCesium3DTiles(
            from: try await fixture.validatedSurface(),
            packageURL: fixture.packageURL,
            to: destination
        )

        let tileset = try jsonObject(at: output.tilesetURL)
        let root = try #require(tileset["root"] as? [String: Any])
        #expect((root["content"] as? [String: Any])?["uri"] as? String == "content/scan.glb")
        #expect((root["boundingVolume"] as? [String: Any])?["box"] as? [Double] == [
            10.5, -31, 20.5,
            0.5, 0, 0,
            0, 0, 0.5,
            0, -1, 0
        ])
        #expect(root["transform"] == nil)
        #expect(try GLBFixture(url: output.contentGLBURL).colors == ExportFixture.processedColors)
        #expect(output.validation.bounds == ScanInterchangeBounds(
            minimum: Point3D(x: 10, y: 20, z: 30),
            maximum: Point3D(x: 11, y: 21, z: 32)
        ))
        try expectValidChecksums(output.validation, root: destination)
    }

    @Test("OPF uses canonical positions and complete observed RGB without source identifiers")
    func writesCanonicalOPF() async throws {
        let samples = [
            sample(x: 1, y: 2, z: 3, confidence: 1, color: .init(red: 10, green: 20, blue: 30)),
            sample(x: 4, y: 5, z: 6, confidence: 2, color: .init(red: 40, green: 50, blue: 60))
        ]
        let fixture = try await ExportFixture(canonicalSamples: samples)
        defer { fixture.remove() }
        let destination = fixture.exportRoot.appending(path: "opf", directoryHint: .isDirectory)

        let output = try ScanInterchangeExporter().writeOPFPointCloud(
            from: fixture.manifest,
            packageURL: fixture.packageURL,
            integrity: fixture.integrity,
            to: destination,
            projectName: "Canonical scan"
        )

        let project = try jsonObject(at: output.projectURL)
        #expect(project["format"] as? String == "application/opf-project+json")
        #expect(project["generator"] == nil)
        #expect(project["id"] as? String != fixture.scanID.uuidString.lowercased())
        let gltf = try jsonObject(at: output.pointCloudGLTFURL)
        let primitive = try #require(
            ((gltf["meshes"] as? [[String: Any]])?.first?["primitives"] as? [[String: Any]])?.first
        )
        #expect((primitive["attributes"] as? [String: Int])?["POSITION"] == 0)
        #expect((primitive["attributes"] as? [String: Int])?["COLOR_0"] == 1)
        let binary = try Data(contentsOf: output.pointCloudBinaryURL)
        #expect(PointCloudBinaryFixture.points(in: binary, count: 2) == samples.map(\.position))
        #expect(Array(binary.suffix(6)) == [10, 20, 30, 40, 50, 60])
        #expect(output.validation.hasObservedColors)
        try expectValidChecksums(output.validation, root: destination)
    }

    @Test("Raw mesh and compatibility PLY alone expose no complete interchange format")
    func hidesLegacyCompatibilityOnlyExports() async throws {
        let fixture = try await ExportFixture(includeCanonical: false, includeProcessed: false)
        defer { fixture.remove() }

        #expect(ScanInterchangeExporter().availableFormats(
            for: fixture.manifest,
            packageURL: fixture.packageURL,
            integrity: fixture.integrity,
            processedSurface: nil
        ).isEmpty)
    }

    @Test("Canonical corruption hides point formats without hiding a valid promoted surface")
    func isolatesCanonicalCorruption() async throws {
        let fixture = try await ExportFixture()
        defer { fixture.remove() }
        var data = try Data(contentsOf: fixture.canonicalURL)
        data[data.index(before: data.endIndex)] ^= 1
        try data.write(to: fixture.canonicalURL, options: .atomic)

        #expect(ScanInterchangeExporter().availableFormats(
            for: fixture.manifest,
            packageURL: fixture.packageURL,
            integrity: fixture.integrity,
            processedSurface: try await fixture.validatedSurface()
        ) == [.glb, .cesium3DTiles])
    }

    private func sample(
        x: Float,
        y: Float,
        z: Float,
        confidence: UInt8,
        color: PointCloudColor?
    ) -> RGBDPointSample {
        RGBDPointSample(
            position: Point3D(x: x, y: y, z: z),
            confidence: confidence,
            color: color
        )
    }

    private func expectValidChecksums(
        _ validation: ScanInterchangeArtifactValidation,
        root: URL
    ) throws {
        for file in validation.files {
            let url = root.appending(path: file.relativePath)
            let data = try Data(contentsOf: url)
            #expect(Int64(data.count) == file.byteCount)
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == file.sha256)
        }
    }
}

private struct ExportFixture {
    static let processedVertices = [
        Point3D(x: 10, y: 20, z: 30),
        Point3D(x: 11, y: 20, z: 30),
        Point3D(x: 10, y: 21, z: 32),
        Point3D(x: 11, y: 21, z: 32)
    ]
    static let processedColors = [
        PointCloudColor(red: 100, green: 10, blue: 20),
        PointCloudColor(red: 110, green: 20, blue: 30),
        PointCloudColor(red: 120, green: 30, blue: 40),
        PointCloudColor(red: 130, green: 40, blue: 50)
    ]

    let root: URL
    let packageURL: URL
    let derivedRoot: URL
    let exportRoot: URL
    let scanID: UUID
    let manifest: ScanPackageManifest
    let integrity: PackageIntegrityReport
    let canonicalURL: URL
    let previewPLYURL: URL
    let processedStore: ProcessedSurfaceStore

    init(
        canonicalSamples: [RGBDPointSample] = [
            RGBDPointSample(
                position: Point3D(x: 1, y: 2, z: 3),
                confidence: 2,
                color: PointCloudColor(red: 10, green: 20, blue: 30)
            )
        ],
        includeCanonical: Bool = true,
        includeProcessed: Bool = true
    ) async throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "StrataScanCanonicalExport-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        packageURL = root.appending(path: "package", directoryHint: .isDirectory)
        derivedRoot = root.appending(path: "derived", directoryHint: .isDirectory)
        exportRoot = root.appending(path: "exports", directoryHint: .isDirectory)
        scanID = try #require(UUID(uuidString: "B85C223E-53B5-430A-AE4A-9590A4F778DA"))
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        canonicalURL = packageURL.appending(path: CanonicalSpatialChunkStore.relativePath)
        var assets: [ScanAssetReference] = []
        if includeCanonical {
            let canonicalStore = try CanonicalSpatialChunkStore(destinationURL: canonicalURL)
            try await canonicalStore.append(canonicalSamples)
            _ = try await canonicalStore.finish()
            assets.append(try Self.asset(
                kind: .manifestAttachment,
                path: CanonicalSpatialChunkStore.relativePath,
                url: canonicalURL
            ))
        }

        let archiveWriter = try CalibratedRGBDKeyframeArchiveWriter(workingDirectory: packageURL)
        let record = try await archiveWriter.append(try Self.keyframe())
        _ = try await archiveWriter.finish()
        for path in [
            CalibratedRGBDKeyframeArchiveWriter.indexRelativePath,
            record.depthPath, record.confidencePath, record.rgbPath
        ] {
            assets.append(try Self.asset(
                kind: .manifestAttachment,
                path: path,
                url: packageURL.appending(path: path)
            ))
        }

        let rawMeshURL = packageURL.appending(path: "mesh/raw-mesh.json")
        try FileManager.default.createDirectory(
            at: rawMeshURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rawMesh = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [
                Point3D(x: 100, y: 100, z: 100),
                Point3D(x: 101, y: 100, z: 100),
                Point3D(x: 100, y: 101, z: 100)
            ],
            normals: [],
            faces: [MeshFace(indices: (0, 1, 2))]
        )
        try JSONEncoder().encode([rawMesh]).write(to: rawMeshURL)
        assets.append(try Self.asset(kind: .meshRaw, path: "mesh/raw-mesh.json", url: rawMeshURL))

        previewPLYURL = packageURL.appending(path: "pointcloud/cloud.ply")
        let previewWriter = try PointCloudPLYWriter(destinationURL: previewPLYURL)
        try await previewWriter.append([
            DepthPoint(
                position: Point3D(x: 999, y: 999, z: 999),
                confidence: 1,
                timestamp: 0,
                sourcePixel: PixelCoordinate(x: 0, y: 0)
            )
        ])
        try await previewWriter.finish()
        assets.append(try Self.asset(kind: .pointCloud, path: "pointcloud/cloud.ply", url: previewPLYURL))

        manifest = ScanPackageManifest(
            localScanID: scanID,
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            assets: assets
        )
        integrity = PackageIntegrityReport(scanID: scanID)
        processedStore = try ProcessedSurfaceStore(rootURL: derivedRoot)

        if includeProcessed {
            let archive = try CalibratedRGBDKeyframeArchiveReader().open(
                packageURL: packageURL,
                manifest: manifest,
                integrity: integrity
            )
            try Self.writeProcessedSurface(
                under: derivedRoot,
                scanID: scanID,
                source: archive.reconstructionSource
            )
        }
    }

    func validatedSurface() async throws -> ValidatedProcessedSurface {
        try await processedStore.validatedProcessedSurface(
            scanID: scanID,
            packageURL: packageURL,
            manifest: manifest,
            integrity: integrity
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private static func writeProcessedSurface(
        under derivedRoot: URL,
        scanID: UUID,
        source: TSDFReconstructionSource
    ) throws {
        let directory = derivedRoot.appending(path: scanID.uuidString)
            .appending(path: "processed-surface")
        let geometry = directory.appending(path: "geometry")
        try FileManager.default.createDirectory(at: geometry, withIntermediateDirectories: true)
        let normals = Array(repeating: Point3D(x: 0, y: 0, z: 1), count: processedVertices.count)
        let indices: [UInt32] = [0, 1, 2, 1, 3, 2]
        try pointData(processedVertices).write(to: geometry.appending(path: "vertices.bin"))
        try pointData(normals).write(to: geometry.appending(path: "normals.bin"))
        try colorData(processedColors).write(to: geometry.appending(path: "colors.bin"))
        try indexData(indices).write(to: geometry.appending(path: "indices.bin"))
        let bounds = try TSDFSurfaceBounds(
            minimum: Point3D(x: 10, y: 20, z: 30),
            maximum: Point3D(x: 11, y: 21, z: 32)
        )
        let statistics = TSDFSurfaceExtractionStatistics(
            processedSubmapCount: 1,
            inspectedCellCount: 2,
            emittedVertexOccurrenceCount: processedVertices.count,
            emittedTriangleCount: 2
        )
        let validation = TSDFSurfaceValidationReport(
            failures: [],
            vertexCount: processedVertices.count,
            triangleCount: 2,
            componentTriangleCounts: [2],
            bounds: bounds,
            robustBounds: bounds,
            duplicateBoundaryVertexCount: 0,
            boundarySeamMismatchCount: 0,
            sourceStatistics: TSDFReconstructionStatistics(processedFrameCount: 1),
            statistics: statistics
        )
        let validationURL = directory.appending(path: "validation.json")
        try jsonData(validation).write(to: validationURL)
        let prefix = TSDFCompletedPrefixIdentity(
            source: source,
            configuration: .default,
            completedFrameCount: source.keyframeCount,
            sha256: String(repeating: "c", count: 64)
        )
        let manifest = TSDFProcessedSurfaceManifest(
            scanID: scanID,
            prefix: prefix,
            extractionConfiguration: .default,
            vertexCount: processedVertices.count,
            triangleCount: 2,
            robustBounds: bounds,
            geometryFiles: try [
                "geometry/vertices.bin", "geometry/normals.bin",
                "geometry/colors.bin", "geometry/indices.bin"
            ].map { try derivedReference(path: $0, directory: directory) },
            validationFile: try derivedReference(path: "validation.json", directory: directory)
        )
        try jsonData(manifest).write(to: directory.appending(path: "manifest.json"))
    }

    private static func keyframe() throws -> CalibratedRGBDKeyframeSample {
        let intrinsics = CameraIntrinsics(
            imageWidth: 1, imageHeight: 1,
            fx: 1, fy: 1, cx: 0, cy: 0
        )
        return authoritativeTestKeyframe(
            metadata: FrameMetadata(
                timestamp: 1,
                videoTimestamp: nil,
                imageWidth: 1,
                imageHeight: 1,
                intrinsics: intrinsics,
                worldFromCamera: .identity,
                tracking: .normal,
                worldMapping: .mapped,
                isTextureSourceCandidate: false
            ),
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

    private static func asset(kind: AssetKind, path: String, url: URL) throws -> ScanAssetReference {
        let data = try Data(contentsOf: url)
        return ScanAssetReference(
            kind: kind,
            relativePath: path,
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            spatialReference: .arWorld,
            createdAt: .now
        )
    }

    private static func derivedReference(
        path: String,
        directory: URL
    ) throws -> TSDFDerivedFileReference {
        let data = try Data(contentsOf: directory.appending(path: path))
        return TSDFDerivedFileReference(
            relativePath: path,
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    private static func colorData(_ colors: [PointCloudColor]) -> Data {
        var data = Data()
        for color in colors {
            data.append(contentsOf: [color.red, color.green, color.blue, 1])
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
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private struct GLBFixture {
    let json: [String: Any]
    let binary: Data

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        #expect(Self.uint32(in: data, at: 0) == 0x4654_6C67)
        #expect(Self.uint32(in: data, at: 4) == 2)
        #expect(Self.uint32(in: data, at: 8) == data.count)
        let jsonLength = Int(Self.uint32(in: data, at: 12))
        let jsonEnd = 20 + jsonLength
        json = try #require(JSONSerialization.jsonObject(with: data[20..<jsonEnd]) as? [String: Any])
        let binaryLength = Int(Self.uint32(in: data, at: jsonEnd))
        let binaryStart = jsonEnd + 8
        binary = Data(data[binaryStart..<(binaryStart + binaryLength)])
    }

    var positions: [Point3D] { pointAccessor(index: 0) }

    var indices: [UInt32] {
        guard let primitive = primitive,
              let accessorIndex = primitive["indices"] as? Int,
              let accessor = accessors?[accessorIndex],
              let viewIndex = accessor["bufferView"] as? Int,
              let view = views?[viewIndex],
              let count = accessor["count"] as? Int,
              let offset = view["byteOffset"] as? Int
        else { return [] }
        return (0..<count).map { Self.uint32(in: binary, at: offset + $0 * 4) }
    }

    var colors: [PointCloudColor] {
        guard let colorAccessor = (primitive?["attributes"] as? [String: Int])?["COLOR_0"],
              let accessor = accessors?[colorAccessor],
              let viewIndex = accessor["bufferView"] as? Int,
              let view = views?[viewIndex],
              let count = accessor["count"] as? Int,
              let offset = view["byteOffset"] as? Int
        else { return [] }
        return (0..<count).map { index in
            let start = offset + index * 4
            return PointCloudColor(
                red: binary[start],
                green: binary[start + 1],
                blue: binary[start + 2]
            )
        }
    }

    private var primitive: [String: Any]? {
        ((json["meshes"] as? [[String: Any]])?.first?["primitives"] as? [[String: Any]])?.first
    }
    private var accessors: [[String: Any]]? { json["accessors"] as? [[String: Any]] }
    private var views: [[String: Any]]? { json["bufferViews"] as? [[String: Any]] }

    private func pointAccessor(index: Int) -> [Point3D] {
        guard let accessor = accessors?[index],
              let viewIndex = accessor["bufferView"] as? Int,
              let view = views?[viewIndex],
              let count = accessor["count"] as? Int,
              let offset = view["byteOffset"] as? Int
        else { return [] }
        return (0..<count).map { index in
            let start = offset + index * 12
            return Point3D(
                x: Float(bitPattern: Self.uint32(in: binary, at: start)),
                y: Float(bitPattern: Self.uint32(in: binary, at: start + 4)),
                z: Float(bitPattern: Self.uint32(in: binary, at: start + 8))
            )
        }
    }

    private static func uint32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

private enum PointCloudBinaryFixture {
    static func points(in data: Data, count: Int) -> [Point3D] {
        (0..<count).map { index in
            let offset = index * 12
            return Point3D(
                x: Float(bitPattern: uint32(in: data, at: offset)),
                y: Float(bitPattern: uint32(in: data, at: offset + 4)),
                z: Float(bitPattern: uint32(in: data, at: offset + 8))
            )
        }
    }

    private static func uint32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

private func jsonObject(at url: URL) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
