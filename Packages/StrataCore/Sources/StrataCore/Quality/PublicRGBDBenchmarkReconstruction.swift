import Foundation
import CryptoKit

public struct PublicRGBDBenchmarkReconstructionReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3
    public static let runnerVersion = "R0.4-production-replay-v3"

    public let schemaVersion: Int
    public let runnerVersion: String
    public let scanID: UUID
    public let source: TSDFReconstructionSource
    public let reconstructionConfiguration: TSDFReconstructionConfiguration
    public let extractionConfiguration: TSDFSurfaceExtractionConfiguration
    public let promotedVertexCount: Int
    public let promotedTriangleCount: Int
    public let robustBounds: TSDFSurfaceBounds
    public let promotedHasAnyObservedColors: Bool
    public let promotedAllVerticesHaveObservedColors: Bool
    public let reusedValidatedPromotion: Bool
    public let evaluatorGeometryRelativePath: String
    public let evaluatorGeometrySHA256: String
    public let evaluatorVertexCount: Int
    public let evaluatorTriangleCount: Int
    public let evaluatorGeometryMode: String
    public let evaluatorGeometryIsCompleteSurface: Bool
    public let evaluatorSafetyLimits: BenchmarkEvaluationSafetyLimits
    public let evaluatorHasCompleteNormalEvidence: Bool
    public let evidenceLevel: String
    public let limitations: [String]

    public func stableJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum PublicRGBDBenchmarkReconstructionError: Error, Equatable, Sendable {
    case unsafeWorkRoot
    case missingPackage(UUID)
    case invalidPackage(UUID)
    case scanIdentityMismatch
    case evaluatorArtifactExceedsByteLimit(byteCount: Int, maximumByteCount: Int64)
}

/// Runs an imported public package through the same production coordinator used
/// by saved scans. The temporary metadata catalogue only makes the immutable
/// package discoverable to that coordinator; it is not benchmark evidence.
public struct PublicRGBDBenchmarkReconstructionRunner: Sendable {
    public init() {}

    public func run(
        packageStoreRoot: URL,
        scanID: UUID,
        workRoot: URL,
        reconstructionConfiguration: TSDFReconstructionConfiguration = .productionBalanced,
        extractionConfiguration: TSDFSurfaceExtractionConfiguration = .default,
        event: @escaping @Sendable (ScanReconstructionJobEvent) async throws -> Void = { _ in }
    ) async throws -> PublicRGBDBenchmarkReconstructionReport {
        try Task.checkCancellation()
        let work = try safeWorkRoot(workRoot)
        let assetStore = try FileAssetStore(rootURL: packageStoreRoot)
        guard await assetStore.packageExists(id: scanID) else {
            throw PublicRGBDBenchmarkReconstructionError.missingPackage(scanID)
        }
        let manifest = try await assetStore.loadManifest(id: scanID)
        guard manifest.localScanID == scanID else {
            throw PublicRGBDBenchmarkReconstructionError.scanIdentityMismatch
        }
        let integrity = try await assetStore.validatePackage(id: scanID)
        guard integrity.isValid else {
            throw PublicRGBDBenchmarkReconstructionError.invalidPackage(scanID)
        }

        let metadataStore = try SQLiteMetadataStore(
            databaseURL: work.appending(path: "benchmark-metadata.sqlite")
        )
        try await metadataStore.save(
            scan: ScanMetadata(
                id: scanID,
                displayName: "Public benchmark \(scanID.uuidString.prefix(8))",
                status: manifest.status,
                createdAt: manifest.createdAt,
                updatedAt: manifest.updatedAt,
                durationSeconds: manifest.durationSeconds,
                remoteID: manifest.remoteScanID
            ),
            assets: manifest.assets
        )
        let repository = LocalScanRepository(metadataStore: metadataStore, assetStore: assetStore)
        let processingRoot = work.appending(path: "processing", directoryHint: .isDirectory)
        let derivedRoot = work.appending(path: "derived", directoryHint: .isDirectory)
        let processedSurfaceStore = try ProcessedSurfaceStore(
            rootURL: derivedRoot,
            processingRootURL: processingRoot
        )
        let packageURL = try await assetStore.packageURL(for: scanID)
        let reusedPromotion = (try? await processedSurfaceStore.validatedProcessedSurface(
            scanID: scanID,
            packageURL: packageURL,
            manifest: manifest,
            integrity: integrity
        )) != nil
        let runner = LocalScanReconstructionRunner(
            repository: repository,
            assetStore: assetStore,
            processedSurfaceStore: processedSurfaceStore,
            processingRootURL: processingRoot,
            derivedRootURL: derivedRoot,
            reconstructionConfiguration: reconstructionConfiguration,
            extractionConfiguration: extractionConfiguration
        )
        let source = try await runner.run(scanID: scanID, event: event)
        let surface = try await processedSurfaceStore.validatedProcessedSurface(
            scanID: scanID,
            packageURL: packageURL,
            manifest: manifest,
            integrity: integrity
        )
        let evaluatorGeometry = try await processedSurfaceStore.loadEvaluationGeometry(
            scanID: scanID,
            packageURL: packageURL,
            manifest: manifest,
            integrity: integrity
        )
        let evaluatorArtifact = try writeEvaluatorGeometry(
            evaluatorGeometry,
            scanID: scanID,
            workRoot: work
        )
        return PublicRGBDBenchmarkReconstructionReport(
            schemaVersion: PublicRGBDBenchmarkReconstructionReport.currentSchemaVersion,
            runnerVersion: PublicRGBDBenchmarkReconstructionReport.runnerVersion,
            scanID: scanID,
            source: source,
            reconstructionConfiguration: reconstructionConfiguration,
            extractionConfiguration: extractionConfiguration,
            promotedVertexCount: surface.manifest.vertexCount,
            promotedTriangleCount: surface.manifest.triangleCount,
            robustBounds: surface.manifest.robustBounds,
            promotedHasAnyObservedColors: surface.hasAnyObservedColors,
            promotedAllVerticesHaveObservedColors: surface.allVerticesHaveObservedColors,
            reusedValidatedPromotion: reusedPromotion,
            evaluatorGeometryRelativePath: evaluatorArtifact.relativePath,
            evaluatorGeometrySHA256: evaluatorArtifact.sha256,
            evaluatorVertexCount: evaluatorGeometry.vertices.count,
            evaluatorTriangleCount: evaluatorGeometry.indices.count / 3,
            evaluatorGeometryMode: "completePromotedSurface",
            evaluatorGeometryIsCompleteSurface: true,
            evaluatorSafetyLimits: BenchmarkEvaluator.safetyLimits,
            evaluatorHasCompleteNormalEvidence: evaluatorGeometry.normals.count == evaluatorGeometry.vertices.count,
            evidenceLevel: "E2-candidate-output",
            limitations: [
                "The evaluator geometry contains the complete promoted surface with original shared vertex indices and triangle connectivity.",
                evaluatorGeometry.allVerticesHaveObservedColors
                    ? "Every promoted vertex carries observed RGB evidence."
                    : "Unobserved promoted vertex colors remain unavailable and are not synthesized.",
                "Every promoted vertex carries a validated finite normal; the public reference may still lack normal evidence for normal-consistency scoring.",
                "A valid production-path surface remains an E2 candidate until the R0.3 evaluator scores it against a checksum-bound reference in a declared common coordinate frame.",
                "Public-scene replay does not validate physical-device capture, thermal behavior, or a competitor product."
            ]
        )
    }

    private func writeEvaluatorGeometry(
        _ surface: ProcessedSurfaceEvaluationGeometry,
        scanID: UUID,
        workRoot: URL
    ) throws -> (relativePath: String, sha256: String) {
        try Task.checkCancellation()
        guard surface.vertices.count == surface.normals.count,
              surface.vertices.count == surface.colors.count,
              surface.indices.count.isMultiple(of: 3)
        else {
            throw PublicRGBDBenchmarkReconstructionError.invalidPackage(scanID)
        }
        let vertices = try surface.vertices.indices.map { index in
            if index % 2_048 == 0 { try Task.checkCancellation() }
            let position = surface.vertices[index]
            let normal = surface.normals[index]
            let color = surface.colors[index]
            return BenchmarkEvaluationVertex(
                position: BenchmarkVector3(
                    x: Double(position.x),
                    y: Double(position.y),
                    z: Double(position.z)
                ),
                normal: BenchmarkVector3(
                    x: Double(normal.x),
                    y: Double(normal.y),
                    z: Double(normal.z)
                ),
                color: color.map {
                    BenchmarkEvaluationColor(red: $0.red, green: $0.green, blue: $0.blue)
                }
            )
        }
        var triangles: [BenchmarkEvaluationTriangle] = []
        triangles.reserveCapacity(surface.indices.count / 3)
        for offset in stride(from: 0, to: surface.indices.count, by: 3) {
            if offset % 6_144 == 0 { try Task.checkCancellation() }
            triangles.append(BenchmarkEvaluationTriangle(
                a: Int(surface.indices[offset]),
                b: Int(surface.indices[offset + 1]),
                c: Int(surface.indices[offset + 2])
            ))
        }
        let geometry = BenchmarkEvaluationGeometry(
            // The imported ARKitScenes world is the declared local geometry
            // frame. A public fixture supplies the explicit fixtureFromGeometry
            // transform (identity for the R0.4 ARKitScenes fixtures), which is
            // the evaluator contract; do not encode a benchmark-specific frame
            // name that the evaluator cannot consume.
            coordinateFrame: "geometry-local",
            fixtureFromGeometry: .identity,
            vertices: vertices,
            triangles: triangles
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(geometry)
        try Task.checkCancellation()
        guard data.count <= BenchmarkEvaluator.safetyLimits.maximumGeometryBytes else {
            throw PublicRGBDBenchmarkReconstructionError.evaluatorArtifactExceedsByteLimit(
                byteCount: data.count,
                maximumByteCount: BenchmarkEvaluator.safetyLimits.maximumGeometryBytes
            )
        }
        let directory = try safeDirectory(
            workRoot.appending(path: "evaluator-candidates", directoryHint: .isDirectory)
        )
        let filename = "\(scanID.uuidString.lowercased()).geometry.json"
        let outputURL = directory.appending(path: filename)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            let values = try outputURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw PublicRGBDBenchmarkReconstructionError.unsafeWorkRoot
            }
        }
        try data.write(to: outputURL, options: .atomic)
        return (
            relativePath: "evaluator-candidates/\(filename)",
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    private func safeWorkRoot(_ url: URL) throws -> URL {
        try safeDirectory(url)
    }

    private func safeDirectory(_ url: URL) throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw PublicRGBDBenchmarkReconstructionError.unsafeWorkRoot
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }
}
