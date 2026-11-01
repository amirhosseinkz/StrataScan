import Foundation
import StrataCore

@main
struct EvaluateBenchmarkCommand {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 3, !arguments.contains("--help") else {
                FileHandle.standardError.write(Data("usage: evaluate-benchmark <fixture-directory> <run-directory> <output-directory>\n".utf8))
                Foundation.exit(64)
            }
            let scorecard = try await BenchmarkEvaluator().evaluate(
                fixtureDirectory: URL(fileURLWithPath: arguments[0], isDirectory: true),
                runDirectory: URL(fileURLWithPath: arguments[1], isDirectory: true),
                outputDirectory: URL(fileURLWithPath: arguments[2], isDirectory: true)
            )
            FileHandle.standardOutput.write(try scorecard.stableJSON())
            FileHandle.standardOutput.write(Data("\n".utf8))
            switch scorecard.disposition {
            case .passed: Foundation.exit(0)
            case .insufficientEvidence: Foundation.exit(2)
            case .failed: Foundation.exit(3)
            }
        } catch is CancellationError {
            FileHandle.standardError.write(Data("evaluation cancelled\n".utf8))
            Foundation.exit(130)
        } catch {
            FileHandle.standardError.write(Data("evaluation failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}
