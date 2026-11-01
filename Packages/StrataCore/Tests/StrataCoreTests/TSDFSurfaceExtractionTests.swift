import Foundation
import Testing
@testable import StrataCore

@Suite("TSDF surface extraction and promotion")
struct TSDFSurfaceExtractionTests {
    @Test("A colored plane crosses negative and positive submaps without seams")
    func extractsKnownPlaneAcrossSubmaps() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.planeSource()

        let result = try await fixture.run(source: source)

        #expect(result.validation.isValid)
        #expect(result.promotedDirectory == fixture.promotion)
        #expect(result.validation.componentTriangleCounts.count == 1)
        #expect(result.validation.duplicateBoundaryVertexCount > 0)
        #expect(result.validation.boundarySeamMismatchCount == 0)
        let geometry = try fixture.readPromotedGeometry()
        #expect(!geometry.vertices.isEmpty)
        #expect(geometry.vertices.allSatisfy { abs($0.z) < 0.000_01 })
        #expect(geometry.normals.allSatisfy {
            $0.z > 0.99 && abs($0.x) < 0.000_1 && abs($0.y) < 0.000_1
        })
        #expect(geometry.colors.compactMap { $0 }.allSatisfy {
            (98...102).contains(Int($0.red))
        })
        #expect(geometry.indices.allSatisfy { Int($0) < geometry.vertices.count })
        #expect(try fixture.sourceInventory() == fixture.initialSourceInventory)
    }

    @Test("Repeated extraction is byte deterministic and promotion is idempotent")
    func extractsDeterministically() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.planeSource()

        let first = try await fixture.run(source: source)
        let firstFiles = try fixture.promotedFileData()
        let second = try await fixture.run(source: source)

        #expect(first.manifest == second.manifest)
        #expect(try fixture.promotedFileData() == firstFiles)

        let otherStage = fixture.root.appending(path: "other-stage")
        let otherPromotion = fixture.root.appending(path: "other-promotion")
        _ = try await TSDFSurfaceExtractionPipeline().run(
            source: source,
            sourcePackageURL: fixture.package,
            stagingDirectory: otherStage,
            promotionDirectory: otherPromotion,
            canonicalSpatialBounds: fixture.canonicalBounds,
            configuration: fixture.configuration
        )
        #expect(try fixture.fileData(in: otherPromotion) == firstFiles)
    }

    @Test("Exact-zero lattice samples share one deterministic vertex identity")
    func weldsExactZeroSamples() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source { _, center in
            TSDFVoxel(
                signedDistance: max(-1, min(1, (center.z - 0.05) / 0.2)),
                weight: 4,
                color: PointCloudColor(red: 20, green: 40, blue: 60)
            )
        }

        let result = try await fixture.run(source: source)

        #expect(result.validation.isValid)
        #expect(result.validation.boundarySeamMismatchCount == 0)
        #expect(try fixture.readPromotedGeometry().vertices.allSatisfy {
            abs($0.z - 0.05) < 0.000_01
        })
    }

    @Test("A one-sided RGB observation does not color an unobserved crossing")
    func requiresTwoObservedColorsForInterpolation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.planeSource { coordinate, voxel in
            var changed = voxel
            if coordinate.z >= 0 { changed.color = nil }
            return changed
        }

        let result = try await fixture.run(source: source)

        #expect(result.validation.isValid)
        #expect(try fixture.readPromotedGeometry().colors.allSatisfy { $0 == nil })
    }

    @Test("Cancellation after a durable chunk resumes from its completion marker")
    func resumesAfterCancellation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.planeSource()

        await #expect(throws: CancellationError.self) {
            try await fixture.run(source: source) { progress in
                if progress.phase == .extracting, progress.completedSubmapCount == 1 {
                    throw CancellationError()
                }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.promotion.path))

        let result = try await fixture.run(source: source)

        #expect(result.validation.isValid)
        #expect(result.validation.statistics.processedSubmapCount == 2)
        #expect(FileManager.default.fileExists(atPath: fixture.promotion.path))
    }

    @Test("A non-finite source cell is excluded without invalidating finite emitted geometry")
    func excludesInvalidVoxel() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.planeSource { coordinate, voxel in
            coordinate == TSDFGlobalVoxelCoordinate(x: 0, y: 0, z: 0)
                ? TSDFVoxel(signedDistance: .nan, weight: voxel.weight, color: voxel.color)
                : voxel
        }

        let result = try await fixture.run(source: source)

        #expect(result.validation.isValid)
        #expect(result.validation.statistics.invalidVoxelCellCount > 0)
        #expect(!result.validation.failures.contains(.nonFiniteAttribute))
        #expect(result.promotedDirectory != nil)
    }

    @Test("Degenerate or below-area triangles are rejected before promotion")
    func rejectsDegenerateTriangles() async throws {
        let fixture = try Fixture(minimumTriangleArea: 1)
        defer { fixture.remove() }

        let result = try await fixture.run(source: try fixture.planeSource())

        #expect(!result.validation.isValid)
        #expect(result.validation.failures.contains(.emptyGeometry))
        #expect(result.validation.statistics.rejectedDegenerateTriangleCount > 0)
        #expect(result.promotedDirectory == nil)
    }

    @Test("Dominant robust bounds must agree with canonical spatial bounds")
    func validatesRobustBoundsAndComponents() async throws {
        let fixture = try Fixture(canonicalBounds: try TSDFSurfaceBounds(
            minimum: Point3D(x: 5, y: 5, z: 5),
            maximum: Point3D(x: 6, y: 6, z: 6)
        ))
        defer { fixture.remove() }

        let result = try await fixture.run(source: try fixture.planeSource())

        #expect(!result.validation.isValid)
        #expect(result.validation.failures.contains(.canonicalBoundsDisagreement))
        #expect(result.validation.componentTriangleCounts.count == 1)
        #expect(result.validation.robustBounds != nil)
        #expect(result.promotedDirectory == nil)
    }

    @Test("Resource truncation is reported and blocks promotion")
    func reportsResourceTruncation() async throws {
        let fixture = try Fixture(maximumPromotedVertices: 3)
        defer { fixture.remove() }

        let result = try await fixture.run(source: try fixture.planeSource())

        #expect(!result.validation.isValid)
        #expect(result.validation.failures.contains(.resourceLimitReached))
        #expect(result.validation.statistics.droppedVertexCount > 0)
        #expect(result.promotedDirectory == nil)
    }

    @Test("Truncated source TSDF statistics block surface promotion")
    func rejectsTruncatedSourceTSDF() async throws {
        let fixture = try Fixture(sourceStatistics: TSDFReconstructionStatistics(
            processedFrameCount: 1,
            droppedVoxelUpdateCount: 1,
            rayLimitReachedFrameCount: 1
        ))
        defer { fixture.remove() }

        let result = try await fixture.run(source: try fixture.planeSource())

        #expect(!result.validation.isValid)
        #expect(result.validation.failures.contains(.resourceLimitReached))
        #expect(result.validation.sourceStatistics.droppedVoxelUpdateCount == 1)
        #expect(result.promotedDirectory == nil)
    }

    @Test("The configured per-frame ray cap is diagnostic when no voxel work was dropped")
    func acceptsRayLimitedSourceWithoutDroppedUpdates() async throws {
        let fixture = try Fixture(sourceStatistics: TSDFReconstructionStatistics(
            processedFrameCount: 1,
            droppedVoxelUpdateCount: 0,
            rayLimitReachedFrameCount: 1
        ))
        defer { fixture.remove() }

        let result = try await fixture.run(source: try fixture.planeSource())

        #expect(result.validation.isValid)
        #expect(!result.validation.failures.contains(.resourceLimitReached))
        #expect(result.validation.sourceStatistics.rayLimitReachedFrameCount == 1)
        #expect(result.promotedDirectory != nil)
    }

    @Test("A staircase fixture stays connected with stable normals and no seams")
    func extractsSanitizedStaircase() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source { coordinate, center in
            let lowerSlab = center.z + 0.04
            let upperStep = max(-center.x, center.z - 0.04)
            let signedDistance = max(-1, min(1, min(lowerSlab, upperStep) / 0.2))
            return TSDFVoxel(
                signedDistance: signedDistance,
                weight: 4,
                color: PointCloudColor(red: 80, green: 120, blue: 160)
            )
        }

        let result = try await fixture.run(source: source)

        #expect(result.validation.isValid)
        #expect(result.validation.componentTriangleCounts.count == 1)
        #expect(result.validation.boundarySeamMismatchCount == 0)
        #expect(result.validation.robustBounds != nil)
        let geometry = try fixture.readPromotedGeometry()
        #expect(geometry.normals.allSatisfy { normal in
            let length = sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
            return length.isFinite && abs(length - 1) < 0.000_1
        })
    }

    @Test("Staging and promotion cannot enter the source package through symlinks")
    func rejectsSymlinkContainment() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.planeSource()
        let packageLink = fixture.root.appending(path: "package-link")
        try FileManager.default.createSymbolicLink(at: packageLink, withDestinationURL: fixture.package)

        await #expect(throws: TSDFSurfaceExtractionError.invalidWritableLocation) {
            try await TSDFSurfaceExtractionPipeline().run(
                source: source,
                sourcePackageURL: fixture.package,
                stagingDirectory: packageLink.appending(path: "surface-stage"),
                promotionDirectory: fixture.promotion,
                canonicalSpatialBounds: fixture.canonicalBounds,
                configuration: fixture.configuration
            )
        }
        await #expect(throws: TSDFSurfaceExtractionError.invalidWritableLocation) {
            try await TSDFSurfaceExtractionPipeline().run(
                source: source,
                sourcePackageURL: fixture.package,
                stagingDirectory: fixture.staging,
                promotionDirectory: packageLink.appending(path: "processed-surface"),
                canonicalSpatialBounds: fixture.canonicalBounds,
                configuration: fixture.configuration
            )
        }
    }
}

private actor ProceduralTSDFSource: TSDFSurfaceExtractionSource {
    typealias Field = @Sendable (TSDFGlobalVoxelCoordinate, Point3D) -> TSDFVoxel?

    let snapshot: TSDFExtractionSnapshot
    let field: Field

    init(snapshot: TSDFExtractionSnapshot, field: @escaping Field) {
        self.snapshot = snapshot
        self.field = field
    }

    func makeExtractionSnapshot() -> TSDFExtractionSnapshot {
        snapshot
    }

    func loadSubmapWithOneVoxelHalo(
        _ key: TSDFSubmapKey,
        from snapshot: TSDFExtractionSnapshot
    ) throws -> TSDFSubmapNeighborhood {
        guard snapshot == self.snapshot else {
            throw TSDFSurfaceExtractionError.snapshotMismatch
        }
        let dimension = snapshot.prefix.configuration.submapVoxelDimension
        let size = snapshot.prefix.configuration.voxelSizeMeters
        let baseX = key.x * Int64(dimension)
        let baseY = key.y * Int64(dimension)
        let baseZ = key.z * Int64(dimension)
        var voxels: [TSDFGlobalVoxelCoordinate: TSDFVoxel] = [:]
        for z in (baseZ - 1)...(baseZ + Int64(dimension)) {
            for y in (baseY - 1)...(baseY + Int64(dimension)) {
                for x in (baseX - 1)...(baseX + Int64(dimension)) {
                    let coordinate = TSDFGlobalVoxelCoordinate(x: x, y: y, z: z)
                    let center = Point3D(
                        x: (Float(x) + 0.5) * size,
                        y: (Float(y) + 0.5) * size,
                        z: (Float(z) + 0.5) * size
                    )
                    if let voxel = field(coordinate, center) { voxels[coordinate] = voxel }
                }
            }
        }
        return TSDFSubmapNeighborhood(
            key: key,
            voxelDimension: dimension,
            voxelsByGlobalCoordinate: voxels
        )
    }
}

private struct Fixture {
    struct Geometry {
        var vertices: [Point3D]
        var normals: [Point3D]
        var colors: [PointCloudColor?]
        var indices: [UInt32]
    }

    let root: URL
    let package: URL
    let staging: URL
    let promotion: URL
    let canonicalBounds: TSDFSurfaceBounds
    let configuration: TSDFSurfaceExtractionConfiguration
    let snapshot: TSDFExtractionSnapshot
    let initialSourceInventory: [String: Data]

    init(
        minimumTriangleArea: Float = 0.000_000_01,
        canonicalBounds: TSDFSurfaceBounds? = nil,
        maximumPromotedVertices: Int = 20_000,
        sourceStatistics: TSDFReconstructionStatistics = .init(processedFrameCount: 1)
    ) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "StrataScanSurface-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        package = root.appending(path: "package", directoryHint: .isDirectory)
        staging = root.appending(path: "surface-stage", directoryHint: .isDirectory)
        promotion = root.appending(path: "derived/scan/processed-surface", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("immutable-source".utf8).write(to: package.appending(path: "manifest.json"))
        self.canonicalBounds = try canonicalBounds ?? TSDFSurfaceBounds(
            minimum: Point3D(x: -1, y: -1, z: -1),
            maximum: Point3D(x: 1, y: 1, z: 1)
        )
        configuration = try TSDFSurfaceExtractionConfiguration(
            minimumVoxelWeight: 1,
            minimumTriangleAreaSquareMeters: minimumTriangleArea,
            minimumNormalLength: 0.000_01,
            minimumDominantComponentTriangleRatio: 0.9,
            canonicalBoundsToleranceMeters: 0.001,
            maximumSubmaps: 8,
            maximumVerticesPerSubmap: 10_000,
            maximumTrianglesPerSubmap: 20_000,
            maximumPromotedVertices: maximumPromotedVertices,
            maximumPromotedTriangles: 40_000
        )
        let reconstructionConfiguration = try TSDFReconstructionConfiguration(
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
        let source = TSDFReconstructionSource(
            scanID: UUID(uuid: (
                0x65, 0x01, 0xD9, 0x78,
                0x9D, 0xAA, 0x41, 0x08,
                0x95, 0x04, 0x5E, 0x4E,
                0x01, 0x0F, 0x22, 0x28
            )),
            keyframeIndexSHA256: String(repeating: "a", count: 64),
            calibratedArchiveSHA256: String(repeating: "b", count: 64),
            keyframeCount: 1
        )
        let prefix = TSDFCompletedPrefixIdentity(
            source: source,
            configuration: reconstructionConfiguration,
            completedFrameCount: 1,
            sha256: String(repeating: "c", count: 64)
        )
        snapshot = TSDFExtractionSnapshot(
            prefix: prefix,
            submapKeys: [
                TSDFSubmapKey(x: -1, y: 0, z: -1),
                TSDFSubmapKey(x: 0, y: 0, z: -1)
            ],
            statistics: sourceStatistics
        )
        initialSourceInventory = [
            "manifest.json": try Data(contentsOf: package.appending(path: "manifest.json"))
        ]
    }

    func planeSource(
        transform: @escaping @Sendable (TSDFGlobalVoxelCoordinate, TSDFVoxel) -> TSDFVoxel = { _, voxel in voxel }
    ) throws -> ProceduralTSDFSource {
        try source { coordinate, center in
            let signedDistance = max(-1, min(1, center.z / 0.2))
            let red = UInt8(clamping: Int(((center.z + 0.25) * 400).rounded()))
            return transform(coordinate, TSDFVoxel(
                signedDistance: signedDistance,
                weight: 4,
                color: PointCloudColor(red: red, green: 40, blue: 80)
            ))
        }
    }

    func source(
        field: @escaping ProceduralTSDFSource.Field
    ) throws -> ProceduralTSDFSource {
        ProceduralTSDFSource(snapshot: snapshot, field: field)
    }

    func run(
        source: ProceduralTSDFSource,
        progress: (@Sendable (TSDFSurfaceExtractionProgress) throws -> Void)? = nil
    ) async throws -> TSDFSurfaceExtractionResult {
        try await TSDFSurfaceExtractionPipeline().run(
            source: source,
            sourcePackageURL: package,
            stagingDirectory: staging,
            promotionDirectory: promotion,
            canonicalSpatialBounds: canonicalBounds,
            configuration: configuration,
            progress: progress
        )
    }

    func readPromotedGeometry() throws -> Geometry {
        let geometry = promotion.appending(path: "geometry", directoryHint: .isDirectory)
        let vertexData = try Data(contentsOf: geometry.appending(path: "vertices.bin"))
        let normalData = try Data(contentsOf: geometry.appending(path: "normals.bin"))
        let colorData = try Data(contentsOf: geometry.appending(path: "colors.bin"))
        let indexData = try Data(contentsOf: geometry.appending(path: "indices.bin"))
        return Geometry(
            vertices: try points(from: vertexData),
            normals: try points(from: normalData),
            colors: try colors(from: colorData),
            indices: try uint32Values(from: indexData)
        )
    }

    func promotedFileData() throws -> [String: Data] {
        try fileData(in: promotion)
    }

    func fileData(in directory: URL) throws -> [String: Data] {
        let paths = [
            "manifest.json", "validation.json", "geometry/vertices.bin",
            "geometry/normals.bin", "geometry/colors.bin", "geometry/indices.bin"
        ]
        return try Dictionary(uniqueKeysWithValues: paths.map {
            ($0, try Data(contentsOf: directory.appending(path: $0)))
        })
    }

    func sourceInventory() throws -> [String: Data] {
        ["manifest.json": try Data(contentsOf: package.appending(path: "manifest.json"))]
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func points(from data: Data) throws -> [Point3D] {
        guard data.count % 12 == 0 else { throw TSDFSurfaceExtractionError.invalidStagingArtifact("point-data") }
        return try stride(from: 0, to: data.count, by: 12).map { offset in
            guard let x = data.float(at: offset),
                  let y = data.float(at: offset + 4),
                  let z = data.float(at: offset + 8)
            else { throw TSDFSurfaceExtractionError.invalidStagingArtifact("point-data") }
            return Point3D(x: x, y: y, z: z)
        }
    }

    private func colors(from data: Data) throws -> [PointCloudColor?] {
        guard data.count % 4 == 0 else { throw TSDFSurfaceExtractionError.invalidStagingArtifact("color-data") }
        return stride(from: 0, to: data.count, by: 4).map { offset in
            data[offset + 3] == 1
                ? PointCloudColor(red: data[offset], green: data[offset + 1], blue: data[offset + 2])
                : nil
        }
    }

    private func uint32Values(from data: Data) throws -> [UInt32] {
        guard data.count % 4 == 0 else { throw TSDFSurfaceExtractionError.invalidStagingArtifact("index-data") }
        return try stride(from: 0, to: data.count, by: 4).map { offset in
            guard let value = data.uint32(at: offset) else {
                throw TSDFSurfaceExtractionError.invalidStagingArtifact("index-data")
            }
            return value
        }
    }
}

private extension Data {
    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func float(at offset: Int) -> Float? {
        uint32(at: offset).map(Float.init(bitPattern:))
    }
}
