import Foundation
import StrataCore

@main
struct IntakeBaselineCommand {
    static func main() async {
        do {
            let parsed = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
            let report = try await R0BaselineEvidenceIntake().ingest(
                campaignDirectory: URL(fileURLWithPath: parsed.campaignDirectory, isDirectory: true),
                request: R0BaselineEvidenceIntakeRequest(
                    runID: parsed.runID,
                    arm: parsed.arm,
                    repetition: parsed.repetition,
                    evidenceLevel: parsed.evidenceLevel,
                    durationSeconds: parsed.durationSeconds,
                    inspectionEvidenceURL: parsed.inspectionPath.map { URL(fileURLWithPath: $0) },
                    benchmarkScorecardURL: parsed.scorecardPath.map { URL(fileURLWithPath: $0) }
                ),
                dryRun: parsed.dryRun
            )
            let data = try report.stableJSON()
            if let outputPath = parsed.outputPath {
                try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        } catch is CancellationError {
            FileHandle.standardError.write(Data("intake-baseline cancelled\n".utf8))
            Foundation.exit(130)
        } catch {
            let message = error is Arguments.Error
                ? Arguments.usage
                : "intake-baseline failed: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Foundation.exit(64)
        }
    }

    private struct Arguments {
        let campaignDirectory: String
        let runID: String
        let arm: R0BaselineArm
        let repetition: Int
        let evidenceLevel: R0EvidenceLevel
        let durationSeconds: Double?
        let inspectionPath: String?
        let scorecardPath: String?
        let outputPath: String?
        let dryRun: Bool

        enum Error: Swift.Error { case usage }

        static let usage = """
        Usage: intake-baseline <campaign-directory> --run-id <id> --arm <retained-failure|stratascan|competitor> --repetition <n> --evidence-level <E1|E2|E3|E4|E5> [--duration <seconds>] [--inspection <report.json>] [--scorecard <scorecard.json>] [--dry-run] [--output <result.json>]
        """

        static func parse(_ raw: [String]) throws -> Self {
            guard let campaignDirectory = raw.first, !campaignDirectory.hasPrefix("-") else {
                throw Error.usage
            }
            var values: [String: String] = [:]
            var dryRun = false
            var index = 1
            while index < raw.count {
                let option = raw[index]
                if option == "--dry-run" {
                    dryRun = true
                    index += 1
                    continue
                }
                guard option.hasPrefix("--"), raw.indices.contains(index + 1) else {
                    throw Error.usage
                }
                guard values[option] == nil else { throw Error.usage }
                values[option] = raw[index + 1]
                index += 2
            }
            let allowed = Set([
                "--run-id", "--arm", "--repetition", "--evidence-level", "--duration",
                "--inspection", "--scorecard", "--output"
            ])
            guard Set(values.keys).isSubset(of: allowed),
                  let runID = values["--run-id"],
                  let armRaw = values["--arm"], let arm = R0BaselineArm(rawValue: armRaw),
                  let repetitionRaw = values["--repetition"], let repetition = Int(repetitionRaw),
                  let levelRaw = values["--evidence-level"],
                  let evidenceLevel = R0EvidenceLevel(rawValue: levelRaw) else {
                throw Error.usage
            }
            let duration: Double?
            if let rawDuration = values["--duration"] {
                guard let parsed = Double(rawDuration) else { throw Error.usage }
                duration = parsed
            } else {
                duration = nil
            }
            return Self(
                campaignDirectory: campaignDirectory,
                runID: runID,
                arm: arm,
                repetition: repetition,
                evidenceLevel: evidenceLevel,
                durationSeconds: duration,
                inspectionPath: values["--inspection"],
                scorecardPath: values["--scorecard"],
                outputPath: values["--output"],
                dryRun: dryRun
            )
        }
    }
}
