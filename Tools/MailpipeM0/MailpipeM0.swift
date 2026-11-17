import Foundation
import HarnessAdapters
import MailpipeCore
import MailpipeRuntime
import MailBridge

@main
struct MailpipeM0 {
    @MainActor static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            switch args.first {
            case "inbox-probe":
                guard args.count == 1 else { throw MailpipeError.invalidInput }
                let inboxes = try AppleMailReplyIdentity.inboxes()
                guard !inboxes.isEmpty, Set(inboxes.map(\.accountID)).count == inboxes.count else { throw MailpipeError.invalidInput }
                print("PASS: \(inboxes.count) accounts map to unique system inboxes; no messages read or model calls")
            case "discover":
                for item in HarnessDiscovery.find() { print("\(item.kind.rawValue)\t\(item.executable.path)") }
            case "onboarding-probe":
                guard args.count == 3, args[1].hasPrefix("/"), args[2].hasPrefix("/"),
                      !FileManager.default.fileExists(atPath: args[2]) else { throw MailpipeError.invalidInput }
                let store = try PipelineStore(directory: URL(fileURLWithPath: args[2]))
                let session = try OnboardingSession(store: store)
                var draft = OnboardingDraft(); draft.step = 2; draft.executable = args[1]
                try session.save(draft)
                _ = try session.beginTest(); try await session.testPipeline.pump()
                guard let result = try session.testResult(), result.state == .draftReady,
                      try store.settings().permission == nil else { throw MailpipeError.invalidInput }
                print("PASS: onboarding synthetic test; calls=\(result.runs.count); draft persisted; active policy unchanged; no Mail access")
                for run in result.runs {
                    print("\(run.destination.taskKind.rawValue): inputTokens=\(run.inputTokens.map(String.init) ?? "unknown") outputTokens=\(run.outputTokens.map(String.init) ?? "unknown") inputCharacters=\(run.inputCharacters.map(String.init) ?? "unknown") outputCharacters=\(run.outputCharacters.map(String.init) ?? "unknown") actualCost=unknown")
                }
            case "pipeline-seed":
                guard args.count == 3, args[1].hasPrefix("/"), args[2].hasPrefix("/"),
                      !FileManager.default.fileExists(atPath: args[2]) else { throw MailpipeError.invalidInput }
                let root = URL(fileURLWithPath: args[2], isDirectory: true)
                let store = try PipelineStore(directory: root)
                let pipeline = ReplyPipeline(store: store, inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")), resolve: { _, _ in nil })
                try pipeline.updateSettings { $0.executable = args[1] }
                _ = try pipeline.enqueueSynthetic()
                print("PASS: synthetic input persisted; no model or Mail call; open the App with --pipeline-directory pointing to this directory to resume")
            case "inspect":
                guard args.count == 3, let kind = HarnessKind(rawValue: args[1]), args[2].hasPrefix("/") else {
                    throw MailpipeError.invalidInput
                }
                let path = URL(fileURLWithPath: args[2])
                let report: CapabilityReport
                if kind == .deepseek { report = try await DeepSeekHarnessAdapter(executable: path, dialect: DeepSeekHarnessDialect()).inspect() }
                else { report = try await CodexCLIAdapter(executable: path, dialect: CodexCLIDialect()).inspect() }
                print("\(kind.displayName): \(report.version)")
                print("Headless flags: \(report.supportsHeadlessRun ? "available" : "missing: " + report.missingFlags.joined(separator: ", "))")
                print(report.realMailStatus)
            case nil, "--help", "-h":
                print("mailpipe-m0 discover | inspect <dsh|codex> </absolute/path>\npipeline-seed </absolute/dsh> </new/private/directory> persists one fixed synthetic input.")
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
