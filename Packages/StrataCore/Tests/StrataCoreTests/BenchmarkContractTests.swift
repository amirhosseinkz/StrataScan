import Foundation
import Testing
@testable import StrataCore

@Suite("Benchmark contract", .serialized)
struct BenchmarkContractTests {
    @Test("The governed fixture catalog covers every required scene")
    func validatesGovernedFixtureCatalog() async throws {
        let directories = try fixtureDirectories()
        #expect(directories.count == BenchmarkSceneKind.allCases.count)

        var reports: [BenchmarkValidationReport] = []
        for directory in directories {
            reports.append(try await BenchmarkFixtureValidator().validate(fixtureDirectory: directory))
        }

        let allValid = reports.allSatisfy { $0.valid }
        #expect(allValid)
        #expect(Set(reports.compactMap(\.scene)) == Set(BenchmarkSceneKind.allCases))
        let ready = reports.filter(\.e2Ready)
        #expect(ready.count == 1)
        #expect(ready.first?.fixtureID == "planar-corner-v1")
    }

    @Test("Validation output is deterministic and does not claim E2 evidence")
    func producesStableReadinessEvidence() async throws {
        let fixture = fixturesRoot().appending(path: "planar-corner-v1", directoryHint: .isDirectory)
        let validator = BenchmarkFixtureValidator()
        let first = try await validator.validate(fixtureDirectory: fixture)
        let second = try await validator.validate(fixtureDirectory: fixture)

        #expect(first.valid)
        #expect(first.e2Ready)
        #expect(first.verifiedAssetCount == 1)
        #expect(try first.stableJSON() == second.stableJSON())
    }

    @Test("A changed reference asset invalidates the fixture")
    func rejectsChecksumMismatch() async throws {
        let temporary = try copiedPlanarFixture()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("changed".utf8).write(to: temporary.appending(path: "reference/reference-geometry.json"))

        let report = try await BenchmarkFixtureValidator().validate(fixtureDirectory: temporary)

        #expect(!report.valid)
        #expect(!report.e2Ready)
        #expect(report.issues.map(\.code).contains("ASSET_SIZE"))
    }

    @Test("Unsafe relative paths remain semantic evidence instead of filesystem access")
    func rejectsTraversalPath() async throws {
        let temporary = try copiedPlanarFixture()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let manifestURL = temporary.appending(path: BenchmarkFixtureValidator.manifestFilename)
        let source = try #require(String(data: Data(contentsOf: manifestURL), encoding: .utf8))
        let changed = source.replacingOccurrences(
            of: "reference/reference-geometry.json",
            with: "../reference-geometry.json"
        )
        try Data(changed.utf8).write(to: manifestURL, options: .atomic)

        let report = try await BenchmarkFixtureValidator().validate(fixtureDirectory: temporary)

        #expect(!report.valid)
        #expect(report.issues.map(\.code).contains("ASSET_PATH"))
    }

    @Test("Symbolic-link payloads are rejected")
    func rejectsSymbolicLinkAsset() async throws {
        let temporary = try copiedPlanarFixture()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let asset = temporary.appending(path: "reference/reference-geometry.json")
        let outside = temporary.deletingLastPathComponent().appending(path: UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.removeItem(at: asset)
        try FileManager.default.createSymbolicLink(at: asset, withDestinationURL: outside)

        await #expect(throws: BenchmarkContractError.unsafeFixtureRoot) {
            try await BenchmarkFixtureValidator().validate(fixtureDirectory: temporary)
        }
    }

    @Test("Cancellation propagates")
    func propagatesCancellation() async throws {
        let fixture = fixturesRoot().appending(path: "planar-corner-v1", directoryHint: .isDirectory)
        let task = Task { try await BenchmarkFixtureValidator().validate(fixtureDirectory: fixture) }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private func fixtureDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: fixturesRoot(),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func copiedPlanarFixture() throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "benchmark-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(
            at: fixturesRoot().appending(path: "planar-corner-v1", directoryHint: .isDirectory),
            to: destination
        )
        return destination
    }

    private func fixturesRoot() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appending(path: "Benchmarks/Fixtures", directoryHint: .isDirectory)
    }
}
