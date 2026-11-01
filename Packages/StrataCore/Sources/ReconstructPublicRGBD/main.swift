import Foundation
import StrataCore

enum ReconstructPublicRGBDCommand {
    static func run(arguments: [String]) async -> Int32 {
        guard arguments.count >= 3, let scanID = UUID(uuidString: arguments[1]) else {
            writeError("usage: reconstruct-public-rgbd <package-store-root> <scan-uuid> <work-root> [--output <report.json>]")
            return 64
        }
        var outputURL: URL?
        if arguments.count > 3 {
            guard arguments.count == 5, arguments[3] == "--output" else {
                writeError("invalid arguments")
                return 64
            }
            outputURL = URL(fileURLWithPath: arguments[4])
        }
        do {
            let report = try await PublicRGBDBenchmarkReconstructionRunner().run(
                packageStoreRoot: URL(fileURLWithPath: arguments[0], isDirectory: true),
                scanID: scanID,
                workRoot: URL(fileURLWithPath: arguments[2], isDirectory: true)
            )
            let data = try report.stableJSON()
            if let outputURL { try data.write(to: outputURL, options: .atomic) }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            return 0
        } catch is CancellationError {
            writeError("reconstruction cancelled")
            return 130
        } catch {
            writeError("public RGB-D reconstruction failed: \(error)")
            return 1
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

exit(await ReconstructPublicRGBDCommand.run(arguments: Array(CommandLine.arguments.dropFirst())))
