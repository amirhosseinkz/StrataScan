import CryptoKit
import Foundation
import Testing
@testable import StrataCore

@Suite("Benchmark evaluator", .serialized)
struct BenchmarkEvaluatorTests {
    @Test("A known transform produces deterministic metric and fixed-view evidence")
    func evaluatesKnownTransformDeterministically() async throws {
        let first = try temporaryDirectory("evaluation-first")
        let second = try temporaryDirectory("evaluation-second")
        let run = try makeRun(geometry: planarGeometry(localXOffset: 1, fixtureXOffset: -1))
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second); try? FileManager.default.removeItem(at: run) }

        let evaluator = BenchmarkEvaluator()
        let one = try await evaluator.evaluate(fixtureDirectory: planarFixture(), runDirectory: run, outputDirectory: first)
        let two = try await evaluator.evaluate(fixtureDirectory: planarFixture(), runDirectory: run, outputDirectory: second)

        #expect(one.disposition == .insufficientEvidence)
        #expect(one.metric("surface-p95-distance")?.disposition == .passed)
        #expect(one.metric("observed-completeness")?.disposition == .passed)
        #expect(one.metric("volume-relative-error")?.disposition == .unavailable)
        #expect(one.fixedViews.count == 2)
        #expect(try one.stableJSON() == two.stableJSON())
        #expect(try Data(contentsOf: first.appending(path: "fixed-views/overview.svg")) == Data(contentsOf: second.appending(path: "fixed-views/overview.svg")))
    }

    @Test("Known defects and occlusion evidence fail explicit metrics")
    func reportsDefectsAndOcclusion() async throws {
        let output = try temporaryDirectory("evaluation-defect")
        let run = try makeRun(geometry: planarGeometry(surfaceLimit: 1), occlusionPassed: false)
        defer { try? FileManager.default.removeItem(at: output); try? FileManager.default.removeItem(at: run) }

        let scorecard = try await BenchmarkEvaluator().evaluate(fixtureDirectory: planarFixture(), runDirectory: run, outputDirectory: output)

        #expect(scorecard.disposition == .failed)
        #expect(scorecard.metric("observed-completeness")?.disposition == .failed)
        #expect(scorecard.metric("maximum-dimension-relative-error")?.disposition == .failed)
        #expect(scorecard.metric("reprojection-occlusion-failure-ratio")?.disposition == .failed)
    }

    @Test("Known outliers fail distance, outlier, and topology gates")
    func reportsKnownOutliers() async throws {
        let output = try temporaryDirectory("evaluation-outlier")
        let run = try makeRun(geometry: geometryWithOutlier())
        defer { try? FileManager.default.removeItem(at: output); try? FileManager.default.removeItem(at: run) }

        let scorecard = try await BenchmarkEvaluator().evaluate(fixtureDirectory: planarFixture(), runDirectory: run, outputDirectory: output)

        #expect(scorecard.disposition == .failed)
        #expect(scorecard.metric("surface-p95-distance")?.disposition == .failed)
        #expect(scorecard.metric("outlier-ratio")?.disposition == .failed)
        #expect(scorecard.metric("disconnected-component-ratio")?.disposition == .failed)
    }

    @Test("Missing optional observations are unavailable rather than failed")
    func reportsUnavailableEvidenceTruthfully() async throws {
        let output = try temporaryDirectory("evaluation-unavailable")
        let run = try makeRun(geometry: planarGeometry(), includeOptionalEvidence: false)
        defer { try? FileManager.default.removeItem(at: output); try? FileManager.default.removeItem(at: run) }

        let scorecard = try await BenchmarkEvaluator().evaluate(fixtureDirectory: planarFixture(), runDirectory: run, outputDirectory: output)

        #expect(scorecard.disposition == .insufficientEvidence)
        #expect(scorecard.metric("reprojection-rmse")?.disposition == .unavailable)
        #expect(scorecard.metric("reprojection-occlusion-failure-ratio")?.disposition == .unavailable)
        #expect(scorecard.metric("processing-time")?.disposition == .unavailable)
        #expect(scorecard.metric("peak-memory")?.disposition == .unavailable)
        #expect(scorecard.metric("storage")?.disposition == .unavailable)
    }

    @Test("Known closed geometry has the expected volume")
    func measuresKnownVolume() throws {
        let points = [
            vector(0, 0, 0), vector(1, 0, 0), vector(1, 1, 0), vector(0, 1, 0),
            vector(0, 0, 1), vector(1, 0, 1), vector(1, 1, 1), vector(0, 1, 1)
        ].map { BenchmarkEvaluationVertex(position: $0) }
        let faces = [
            (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7),
            (0, 1, 5), (0, 5, 4), (1, 2, 6), (1, 6, 5),
            (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)
        ].map(BenchmarkEvaluationTriangle.init)
        let geometry = BenchmarkEvaluationGeometry(coordinateFrame: "geometry-local", fixtureFromGeometry: .identity, vertices: points, triangles: faces)

        #expect(abs(try BenchmarkEvaluator().enclosedVolume(of: geometry) - 1) < 0.000_001)
    }

    @Test("Checksum corruption and traversal never become geometry evidence")
    func rejectsUnsafeOrCorruptGeometry() async throws {
        let output = try temporaryDirectory("evaluation-corrupt-output")
        let run = try makeRun(geometry: planarGeometry())
        defer { try? FileManager.default.removeItem(at: output); try? FileManager.default.removeItem(at: run) }
        try Data("changed".utf8).write(to: run.appending(path: "candidate.json"), options: .atomic)

        await #expect(throws: BenchmarkEvaluationError.assetIntegrityFailed) {
            try await BenchmarkEvaluator().evaluate(fixtureDirectory: planarFixture(), runDirectory: run, outputDirectory: output)
        }
    }

    @Test("Malformed and symlinked geometry never become metric evidence")
    func rejectsMalformedAndSymlinkedGeometry() async throws {
        let output = try temporaryDirectory("evaluation-invalid-output")
        var triangles = planarGeometry().triangles
        triangles[0] = BenchmarkEvaluationTriangle(a: 0, b: 1, c: 999_999)
        let malformed = planarGeometry()
        let malformedRun = try makeRun(geometry: BenchmarkEvaluationGeometry(
            coordinateFrame: malformed.coordinateFrame,
            fixtureFromGeometry: malformed.fixtureFromGeometry,
            vertices: malformed.vertices,
            triangles: triangles
        ))
        let symlinkRun = try makeRun(geometry: planarGeometry())
        let external = try temporaryDirectory("evaluation-external")
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: malformedRun)
            try? FileManager.default.removeItem(at: symlinkRun)
            try? FileManager.default.removeItem(at: external)
        }

        await #expect(throws: BenchmarkEvaluationError.geometryInvalid("Geometry contains an invalid triangle index.")) {
            try await BenchmarkEvaluator().evaluate(fixtureDirectory: planarFixture(), runDirectory: malformedRun, outputDirectory: output)
        }

        let candidate = symlinkRun.appending(path: "candidate.json")
        let externalCandidate = external.appending(path: "candidate.json")
        try FileManager.default.moveItem(at: candidate, to: externalCandidate)
        try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: externalCandidate)
        await #expect(throws: BenchmarkEvaluationError.unsafeAsset) {
            try await BenchmarkEvaluator().evaluate(fixtureDirectory: planarFixture(), runDirectory: symlinkRun, outputDirectory: output)
        }
    }

    @Test("Existing output symlinks are rejected without mutating their targets")
    func rejectsOutputSymlink() async throws {
        let output = try temporaryDirectory("evaluation-symlink-output")
        let external = try temporaryDirectory("evaluation-symlink-target")
        let run = try makeRun(geometry: planarGeometry())
        let target = external.appending(path: "protected.json")
        let original = Data("protected".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: output.appending(path: BenchmarkEvaluator.scorecardFilename),
            withDestinationURL: target
        )
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: external)
            try? FileManager.default.removeItem(at: run)
        }

        await #expect(throws: BenchmarkEvaluationError.outputFailure("An existing output is not a safe regular file.")) {
            try await BenchmarkEvaluator().evaluate(fixtureDirectory: planarFixture(), runDirectory: run, outputDirectory: output)
        }
        #expect(try Data(contentsOf: target) == original)
    }

    @Test("Cancellation propagates without a partial scorecard")
    func propagatesCancellation() async throws {
        let output = try temporaryDirectory("evaluation-cancel-output")
        let run = try makeRun(geometry: planarGeometry())
        defer { try? FileManager.default.removeItem(at: output); try? FileManager.default.removeItem(at: run) }
        let task = Task { try await BenchmarkEvaluator().evaluate(fixtureDirectory: planarFixture(), runDirectory: run, outputDirectory: output) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.appending(path: BenchmarkEvaluator.scorecardFilename).path))
    }

    private func makeRun(
        geometry: BenchmarkEvaluationGeometry,
        occlusionPassed: Bool = true,
        includeOptionalEvidence: Bool = true
    ) throws -> URL {
        let root = try temporaryDirectory("evaluation-run")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let geometryData = try encoder.encode(geometry)
        try geometryData.write(to: root.appending(path: "candidate.json"), options: .atomic)
        let asset = BenchmarkAssetReference(
            role: .candidateGeometry,
            relativePath: "candidate.json",
            mediaType: "application/vnd.stratascan.benchmark-geometry+json",
            byteCount: Int64(geometryData.count),
            sha256: digest(geometryData)
        )
        let run = BenchmarkEvaluationRunManifest(
            fixtureID: "planar-corner-v1",
            fixtureVersion: 1,
            sourcePackageSHA256: String(repeating: "a", count: 64),
            reconstructionConfigurationSHA256: String(repeating: "b", count: 64),
            buildCommit: "r0.3-test",
            geometry: asset,
            resources: includeOptionalEvidence
                ? BenchmarkResourceObservation(processingSeconds: 10, peakMemoryBytes: 100_000_000, storageBytes: 10_000_000)
                : nil,
            reprojectionSamples: includeOptionalEvidence
                ? [BenchmarkReprojectionSample(projectedX: 10, projectedY: 20, observedX: 10, observedY: 20, passedOcclusionTest: occlusionPassed)]
                : [],
            warnings: ["synthetic-oracle"]
        )
        try encoder.encode(run).write(to: root.appending(path: BenchmarkEvaluator.runManifestFilename), options: .atomic)
        return root
    }

    private func planarGeometry(localXOffset: Double = 0, fixtureXOffset: Float = 0, surfaceLimit: Int = 3) -> BenchmarkEvaluationGeometry {
        let resolution = 51
        let step = 2.0 / Double(resolution - 1)
        let color = BenchmarkEvaluationColor(red: 90, green: 180, blue: 210)
        var vertices: [BenchmarkEvaluationVertex] = []
        var triangles: [BenchmarkEvaluationTriangle] = []
        func addSurface(position: (Int, Int) -> BenchmarkVector3, normal: BenchmarkVector3) {
            let base = vertices.count
            for row in 0..<resolution { for column in 0..<resolution { vertices.append(BenchmarkEvaluationVertex(position: position(row, column), normal: normal, color: color)) } }
            for row in 0..<(resolution - 1) { for column in 0..<(resolution - 1) {
                let a = base + row * resolution + column, b = a + 1, c = a + resolution, d = c + 1
                triangles.append(BenchmarkEvaluationTriangle(a: a, b: c, c: b)); triangles.append(BenchmarkEvaluationTriangle(a: b, b: c, c: d))
            } }
        }
        if surfaceLimit >= 1 { addSurface(position: { r, c in vector(Double(c) * step + localXOffset, 0, Double(r) * step) }, normal: vector(0, 1, 0)) }
        if surfaceLimit >= 2 { addSurface(position: { r, c in vector(localXOffset, Double(r) * step, Double(c) * step) }, normal: vector(1, 0, 0)) }
        if surfaceLimit >= 3 { addSurface(position: { r, c in vector(Double(c) * step + localXOffset, Double(r) * step, 0) }, normal: vector(0, 0, 1)) }
        return BenchmarkEvaluationGeometry(
            coordinateFrame: "geometry-local",
            fixtureFromGeometry: .translation(x: fixtureXOffset, y: 0, z: 0),
            vertices: vertices,
            triangles: triangles
        )
    }

    private func geometryWithOutlier() -> BenchmarkEvaluationGeometry {
        let base = planarGeometry()
        var vertices = base.vertices
        var triangles = base.triangles
        let first = vertices.count
        let color = BenchmarkEvaluationColor(red: 255, green: 0, blue: 0)
        let resolution = 21
        for row in 0..<resolution {
            for column in 0..<resolution {
                vertices.append(BenchmarkEvaluationVertex(
                    position: vector(10 + Double(column) * 0.1, 10, 10 + Double(row) * 0.1),
                    normal: vector(0, 1, 0),
                    color: color
                ))
            }
        }
        for row in 0..<(resolution - 1) {
            for column in 0..<(resolution - 1) {
                let a = first + row * resolution + column
                let b = a + 1
                let c = a + resolution
                let d = c + 1
                triangles.append(BenchmarkEvaluationTriangle(a: a, b: c, c: b))
                triangles.append(BenchmarkEvaluationTriangle(a: b, b: c, c: d))
            }
        }
        return BenchmarkEvaluationGeometry(
            coordinateFrame: base.coordinateFrame,
            fixtureFromGeometry: base.fixtureFromGeometry,
            vertices: vertices,
            triangles: triangles
        )
    }

    private func vector(_ x: Double, _ y: Double, _ z: Double) -> BenchmarkVector3 { BenchmarkVector3(x: x, y: y, z: z) }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func temporaryDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func planarFixture() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appending(path: "Benchmarks/Fixtures/planar-corner-v1", directoryHint: .isDirectory)
    }
}
