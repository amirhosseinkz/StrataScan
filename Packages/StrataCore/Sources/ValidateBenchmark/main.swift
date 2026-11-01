import Foundation
import StrataCore

private struct CatalogReport: Encodable {
    let schemaVersion = 1
    let reports: [BenchmarkValidationReport]
    let valid: Bool
    let e2ReadyFixtureIDs: [String]
}

enum ValidateBenchmarkCLI {
    static func run() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let path = arguments.first, !path.hasPrefix("-") else { throw CLIError.usage }
        arguments.removeFirst()
        var output: URL?
        if !arguments.isEmpty {
            guard arguments.count == 2, arguments[0] == "--output" else { throw CLIError.usage }
            output = URL(filePath: arguments[1])
        }

        let supplied = URL(filePath: path, directoryHint: .isDirectory)
        let manifest = supplied.appending(path: BenchmarkFixtureValidator.manifestFilename)
        let directories: [URL]
        if FileManager.default.fileExists(atPath: manifest.path) {
            directories = [supplied]
        } else {
            directories = try FileManager.default.contentsOfDirectory(
                at: supplied,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter {
                try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                    && FileManager.default.fileExists(
                        atPath: $0.appending(path: BenchmarkFixtureValidator.manifestFilename).path
                    )
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        guard !directories.isEmpty else { throw CLIError.noFixtures }

        let validator = BenchmarkFixtureValidator()
        var reports: [BenchmarkValidationReport] = []
        for directory in directories {
            reports.append(try await validator.validate(fixtureDirectory: directory))
        }
        let valid = reports.allSatisfy { $0.valid }
        let report = CatalogReport(
            reports: reports,
            valid: valid,
            e2ReadyFixtureIDs: reports.filter(\.e2Ready).compactMap(\.fixtureID).sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        if let output { try data.write(to: output, options: .atomic) }
        else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        if !valid { throw CLIError.validationFailed }
    }

    enum CLIError: LocalizedError {
        case usage
        case noFixtures
        case validationFailed

        var errorDescription: String? {
            switch self {
            case .usage:
                "Usage: validate-benchmark <fixture-or-catalog-path> [--output <report.json>]"
            case .noFixtures:
                "No benchmark fixtures were found."
            case .validationFailed:
                "One or more benchmark fixtures failed validation."
            }
        }
    }
}

do { try await ValidateBenchmarkCLI.run() }
catch {
    FileHandle.standardError.write(Data("validate-benchmark: \(String(reflecting: error))\n".utf8))
    exit(2)
}
