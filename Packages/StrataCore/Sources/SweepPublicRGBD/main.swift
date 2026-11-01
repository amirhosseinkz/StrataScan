import CryptoKit
import Foundation
import StrataCore

private struct ConfigurationIdentity: Encodable {
    let extraction: TSDFSurfaceExtractionConfiguration
    let reconstruction: TSDFReconstructionConfiguration
}

@main
struct SweepPublicRGBDCommand {
    private static let maximumPlanBytes = 1_048_576

    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 2, !arguments.contains("--help") else {
                writeError("usage: sweep-public-rgbd <plan.json> <output-root>")
                Foundation.exit(64)
            }
            let planURL = URL(fileURLWithPath: arguments[0])
            let outputRoot = try safeDirectory(URL(fileURLWithPath: arguments[1], isDirectory: true), create: true)
            let plan = try decodePlan(at: planURL).validated()
            var variants: [ReconstructionQualitySweepVariantResult] = []
            for value in plan.values.sorted() {
                try Task.checkCancellation()
                let configuration = try plan.configuration(for: value)
                let configurationSHA256 = try configurationHash(configuration)
                var scenes: [ReconstructionQualitySweepSceneResult] = []
                for scene in plan.scenes.sorted(by: { $0.sceneID < $1.sceneID }) {
                    try Task.checkCancellation()
                    let variantRoot = try safeDirectory(
                        outputRoot.appending(
                            path: "\(plan.factor.rawValue)-\(value)",
                            directoryHint: .isDirectory
                        ),
                        create: true
                    )
                    let sceneRoot = try safeDirectory(
                        variantRoot.appending(path: scene.sceneID, directoryHint: .isDirectory),
                        create: true
                    )
                    let reconstruction = try await PublicRGBDBenchmarkReconstructionRunner().run(
                        packageStoreRoot: URL(fileURLWithPath: scene.packageStoreRoot, isDirectory: true),
                        scanID: scene.scanID,
                        workRoot: sceneRoot.appending(path: "production-work", directoryHint: .isDirectory),
                        reconstructionConfiguration: configuration,
                        extractionConfiguration: .default
                    )
                    guard reconstruction.scanID == scene.scanID,
                          reconstruction.reconstructionConfiguration == configuration,
                          reconstruction.extractionConfiguration == .default,
                          reconstruction.evaluatorGeometryIsCompleteSurface,
                          reconstruction.evaluatorVertexCount == reconstruction.promotedVertexCount,
                          reconstruction.evaluatorTriangleCount == reconstruction.promotedTriangleCount,
                          reconstruction.evaluatorSafetyLimits == BenchmarkEvaluator.safetyLimits
                    else {
                        throw ReconstructionQualitySweepError.invalidPlan
                    }
                    let scorecard = try await evaluate(
                        plan: plan,
                        scene: scene,
                        reconstruction: reconstruction,
                        sceneRoot: sceneRoot,
                        configurationSHA256: configurationSHA256
                    )
                    scenes.append(ReconstructionQualitySweepSceneResult(
                        sceneID: scene.sceneID,
                        scanID: scene.scanID,
                        candidateGeometrySHA256: reconstruction.evaluatorGeometrySHA256,
                        promotedVertexCount: reconstruction.promotedVertexCount,
                        promotedTriangleCount: reconstruction.promotedTriangleCount,
                        metrics: try ReconstructionQualitySweepMetrics(scorecard: scorecard)
                    ))
                }
                variants.append(ReconstructionQualitySweepVariantResult(
                    value: value,
                    configurationSHA256: configurationSHA256,
                    scenes: scenes
                ))
            }
            let report = try ReconstructionQualitySweepAnalyzer().analyze(plan: plan, variants: variants)
            let data = try report.stableJSON()
            try data.write(to: outputRoot.appending(path: "sweep-report.json"), options: .atomic)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch is CancellationError {
            writeError("reconstruction sweep cancelled")
            Foundation.exit(130)
        } catch {
            writeError("reconstruction sweep failed: \(error)")
            Foundation.exit(1)
        }
    }

    private static func evaluate(
        plan: ReconstructionQualitySweepPlan,
        scene: ReconstructionQualitySweepScene,
        reconstruction: PublicRGBDBenchmarkReconstructionReport,
        sceneRoot: URL,
        configurationSHA256: String
    ) async throws -> BenchmarkEvaluationScorecard {
        let productionRoot = sceneRoot.appending(path: "production-work", directoryHint: .isDirectory)
        let candidateURL = productionRoot.appending(path: reconstruction.evaluatorGeometryRelativePath)
        let candidateData = try Data(contentsOf: candidateURL, options: .mappedIfSafe)
        guard Int64(candidateData.count) <= BenchmarkEvaluator.safetyLimits.maximumGeometryBytes,
              sha256(candidateData) == reconstruction.evaluatorGeometrySHA256
        else {
            throw ReconstructionQualitySweepError.invalidPlan
        }
        let runRoot = try safeDirectory(sceneRoot.appending(path: "run", directoryHint: .isDirectory), create: true)
        let runCandidateURL = runRoot.appending(path: "candidate.json")
        try rejectUnsafeExistingFile(runCandidateURL)
        try candidateData.write(to: runCandidateURL, options: .atomic)

        let fixtureRoot = try safeDirectory(URL(fileURLWithPath: scene.fixtureDirectory, isDirectory: true), create: false)
        let fixtureData = try Data(contentsOf: fixtureRoot.appending(path: BenchmarkFixtureValidator.manifestFilename))
        let fixture = try JSONDecoder().decode(BenchmarkManifest.self, from: fixtureData)
        let packageStore = try FileAssetStore(rootURL: URL(fileURLWithPath: scene.packageStoreRoot, isDirectory: true))
        let packageURL = try await packageStore.packageURL(for: scene.scanID)
        let packageManifestURL = packageURL.appending(path: "manifest.json")
        let run = BenchmarkEvaluationRunManifest(
            fixtureID: fixture.fixtureID,
            fixtureVersion: fixture.fixtureVersion,
            sourcePackageSHA256: try sha256(packageManifestURL),
            reconstructionConfigurationSHA256: configurationSHA256,
            buildCommit: plan.buildCommit,
            geometry: BenchmarkAssetReference(
                role: .candidateGeometry,
                relativePath: "candidate.json",
                mediaType: "application/json",
                byteCount: Int64(candidateData.count),
                sha256: reconstruction.evaluatorGeometrySHA256
            ),
            warnings: [
                "no-independent-reprojection-samples",
                "public-arkitscenes-r05-one-factor-sweep"
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let runData = try encoder.encode(run)
        let runURL = runRoot.appending(path: BenchmarkEvaluator.runManifestFilename)
        try rejectUnsafeExistingFile(runURL)
        try runData.write(to: runURL, options: .atomic)
        return try await BenchmarkEvaluator().evaluate(
            fixtureDirectory: fixtureRoot,
            runDirectory: runRoot,
            outputDirectory: sceneRoot.appending(path: "scorecard", directoryHint: .isDirectory)
        )
    }

    private static func configurationHash(_ reconstruction: TSDFReconstructionConfiguration) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(ConfigurationIdentity(
            extraction: .default,
            reconstruction: reconstruction
        ))
        return sha256(data)
    }

    private static func decodePlan(at url: URL) throws -> ReconstructionQualitySweepPlan {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              (1...maximumPlanBytes).contains(size)
        else {
            throw ReconstructionQualitySweepError.invalidPlan
        }
        return try JSONDecoder().decode(ReconstructionQualitySweepPlan.self, from: Data(contentsOf: url))
    }

    private static func safeDirectory(_ url: URL, create: Bool) throws -> URL {
        let resolved = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: resolved.path) {
            let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ReconstructionQualitySweepError.invalidPlan
            }
        } else if create {
            try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        } else {
            throw ReconstructionQualitySweepError.invalidPlan
        }
        return resolved
    }

    private static func rejectUnsafeExistingFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ReconstructionQualitySweepError.invalidPlan
        }
    }

    private static func sha256(_ url: URL) throws -> String {
        try sha256(Data(contentsOf: url, options: .mappedIfSafe))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
