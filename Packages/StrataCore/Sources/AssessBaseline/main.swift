import Foundation
import StrataCore

@main
struct AssessBaselineCommand {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let campaignPath = arguments.first else {
                throw CommandError.usage
            }
            var outputPath: String?
            if let index = arguments.firstIndex(of: "--output"), arguments.indices.contains(index + 1) {
                outputPath = arguments[index + 1]
            }
            let report = try await R0BaselineCampaignValidator().validate(
                campaignDirectory: URL(fileURLWithPath: campaignPath, isDirectory: true)
            )
            let data = try report.stableJSON()
            if let outputPath {
                try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            Foundation.exit(report.disposition == .readyForR0ExitReview ? 0 : 2)
        } catch {
            let message = error is CommandError
                ? "Usage: assess-baseline <campaign-directory> [--output <report.json>]\n"
                : "assess-baseline failed: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Foundation.exit(64)
        }
    }

    enum CommandError: Error { case usage }
}
