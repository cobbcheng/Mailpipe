import Foundation
import HarnessAdapters
import MailpipeCore

@main
struct MailpipeM0 {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            switch args.first {
            case "offline":
                let results = try OfflineProbe.run()
                print("PASS: \(results.count) adapter decoders; synthetic data; no model or Mail calls")
            case "discover":
                for item in HarnessDiscovery.find() { print("\(item.kind.rawValue)\t\(item.executable.path)") }
            case "inspect":
                guard args.count == 3, let kind = HarnessKind(rawValue: args[1]), args[2].hasPrefix("/") else {
                    throw MailpipeError.invalidInput
                }
                let path = URL(fileURLWithPath: args[2])
                let report: CapabilityReport
                if kind == .claude { report = try await ClaudeCodeAdapter(executable: path, dialect: ClaudeCodeDialect()).inspect() }
                else { report = try await CodexCLIAdapter(executable: path, dialect: CodexCLIDialect()).inspect() }
                print("\(kind.displayName): \(report.version)")
                print("Synthetic probe flags: \(report.supportsSyntheticProbe ? "available" : "missing: " + report.missingFlags.joined(separator: ", "))")
                print(report.realMailStatus)
            case nil, "--help", "-h":
                print("mailpipe-m0 offline | discover | inspect <claude|codex> </absolute/path>\nNo real email or live model probe command is exposed in M0 scaffolding.")
            default: throw MailpipeError.invalidInput
            }
        } catch {
            // Do not emit raw subprocess output or user content.
            let code = (error as? MailpipeError)?.rawValue ?? "operationFailed"
            FileHandle.standardError.write(Data("mailpipe-m0: \(code)\n".utf8))
            exit(1)
        }
    }
}
