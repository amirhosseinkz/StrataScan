import Foundation
import StrataCore

enum InspectScanCLI {
    static func run() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let packagePath = arguments.first, !packagePath.hasPrefix("-") else {
            throw CLIError.usage
        }
        arguments.removeFirst()
        var derivedRoot: URL?
        var output: URL?
        while !arguments.isEmpty {
            let option = arguments.removeFirst()
            guard let value = arguments.first else { throw CLIError.usage }
            arguments.removeFirst()
            switch option {
            case "--derived-root": derivedRoot = URL(filePath: value)
            case "--output": output = URL(filePath: value)
            default: throw CLIError.usage
            }
        }
        let report = try await ScanPackageInspector().inspect(
            packageURL: URL(filePath: packagePath),
            derivedProcessingRoot: derivedRoot
        )
        let data = try report.stableJSON()
        if let output { try data.write(to: output, options: .atomic) }
        else { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8)) }
    }

    enum CLIError: LocalizedError { case usage
        var errorDescription: String? { "Usage: inspect-scan <package-path> [--derived-root <path>] [--output <report.json>]" }
    }
}

do { try await InspectScanCLI.run() }
catch { FileHandle.standardError.write(Data("inspect-scan: \(error.localizedDescription)\n".utf8)); exit(2) }
