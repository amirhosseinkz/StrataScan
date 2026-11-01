import CryptoKit
import Foundation
import StrataCore

/// Retained-data integration check using the production display and exporter
/// readers. No app SQLite, reconstruction, or source files are modified.
@main
struct VerifySavedSurfaceCommand {
    struct Report: Codable {
        let schemaVersion: Int
        let scanID: UUID
        let sourceManifestSHA256: String
        let promotionPrefixSHA256: String
        let vertices: Int
        let triangles: Int
        let displayMatchesCompleteGeometry: Bool
        let hasAnyObservedColor: Bool
        let allVerticesHaveObservedColor: Bool
        let exportHasObservedColor: Bool
        let glbSHA256: String
        let sourceIntegrityAfterExport: Bool
        let limitations: [String]
    }

    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 4, let scanID = UUID(uuidString: args[2]) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let sourceRoot = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath()
            let derivedRoot = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath()
            let outputRoot = URL(fileURLWithPath: args[3]).resolvingSymlinksInPath()
            guard !FileManager.default.fileExists(atPath: outputRoot.path),
                  ![sourceRoot, derivedRoot].contains(where: {
                      outputRoot.path == $0.path || outputRoot.path.hasPrefix($0.path + "/")
                  }) else { throw CocoaError(.fileWriteInvalidFileName) }
            let store = try FileAssetStore(rootURL: sourceRoot)
            let package = try await store.packageURL(for: scanID)
            let manifest = try await store.loadManifest(id: scanID)
            let integrity = try await store.validatePackage(id: scanID)
            guard integrity.isValid else { throw CocoaError(.fileReadCorruptFile) }
            let before = try Data(contentsOf: package.appending(path: "manifest.json"))
            let surfaces = try ProcessedSurfaceStore(rootURL: derivedRoot)
            let display = try await surfaces.loadProcessedSurface(scanID: scanID,
                packageURL: package, manifest: manifest, integrity: integrity)
            let complete = try await surfaces.loadEvaluationGeometry(scanID: scanID,
                packageURL: package, manifest: manifest, integrity: integrity)
            let promotion = try await surfaces.validatedProcessedSurface(scanID: scanID,
                packageURL: package, manifest: manifest, integrity: integrity)
            let equal = display.isComplete && display.vertices == complete.vertices
                && display.indices == complete.indices && display.normals == complete.normals
                && display.colors == complete.colors
            guard equal else { throw CocoaError(.fileReadCorruptFile) }
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
            let exported = try ScanInterchangeExporter().writeGLB(from: promotion,
                packageURL: package, to: outputRoot.appending(path: "scan.glb"))
            let after = try await store.validatePackage(id: scanID)
            guard after.isValid,
                  try Data(contentsOf: package.appending(path: "manifest.json")) == before,
                  exported.pointCount == complete.vertices.count,
                  exported.triangleCount == complete.indices.count / 3,
                  let glb = exported.files.first else { throw CocoaError(.fileReadCorruptFile) }
            let report = Report(schemaVersion: 1, scanID: scanID,
                sourceManifestSHA256: SHA256.hash(data: before).map { String(format: "%02x", $0) }.joined(),
                promotionPrefixSHA256: complete.prefix.sha256, vertices: complete.vertices.count,
                triangles: complete.indices.count / 3, displayMatchesCompleteGeometry: equal,
                hasAnyObservedColor: complete.hasAnyObservedColors,
                allVerticesHaveObservedColor: complete.allVerticesHaveObservedColors,
                exportHasObservedColor: exported.hasObservedColors, glbSHA256: glb.sha256,
                sourceIntegrityAfterExport: after.isValid,
                limitations: ["Reader/export contract evidence, not device or visual acceptance.",
                    "GLB omits vertex color when any vertex lacks observed color; display may show partial color.",
                    "Independent GLB consumer and fixed-view visual review remain separate gates."])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: outputRoot.appending(path: "verification.json"), options: .atomic)
            FileHandle.standardOutput.write(data)
        } catch {
            FileHandle.standardError.write(Data(("verify-saved-surface <package-store-root> <derived-root> <scan-uuid> <new-output-root>: \(error)\n").utf8))
            Foundation.exit(1)
        }
    }
}
