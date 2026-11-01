import Foundation
import StrataCore

@main
struct LocalizeBenchmarkResidualsCommand {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard [5, 7].contains(arguments.count),
                  arguments[0] != "--help",
                  (arguments.count == 5 || arguments[5] == "--reconstruction-report"),
                  let scanID = UUID(uuidString: arguments[3]) else {
                writeError("usage: localize-benchmark-residuals <fixture-dir> <run-dir> <package-store-root> <scan-uuid> <output-dir> [--reconstruction-report <report.json>]")
                Foundation.exit(64)
            }
            let reconstructionReport: PublicRGBDBenchmarkReconstructionReport?
            if arguments.count == 7 {
                let url = URL(fileURLWithPath: arguments[6])
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let size = values.fileSize,
                      (1...1_048_576).contains(size) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                reconstructionReport = try JSONDecoder().decode(
                    PublicRGBDBenchmarkReconstructionReport.self,
                    from: Data(contentsOf: url)
                )
            } else {
                reconstructionReport = nil
            }
            let report = try await BenchmarkEvaluator().localizeResiduals(
                fixtureDirectory: URL(fileURLWithPath: arguments[0], isDirectory: true),
                runDirectory: URL(fileURLWithPath: arguments[1], isDirectory: true),
                packageStoreRoot: URL(fileURLWithPath: arguments[2], isDirectory: true),
                scanID: scanID,
                outputDirectory: URL(fileURLWithPath: arguments[4], isDirectory: true),
                reconstructionReport: reconstructionReport
            )
            FileHandle.standardOutput.write(try report.stableJSON())
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch is CancellationError {
            writeError("residual localization cancelled")
            Foundation.exit(130)
        } catch {
            writeError("residual localization failed: \(error)")
            Foundation.exit(1)
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
