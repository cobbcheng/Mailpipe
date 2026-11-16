import Foundation
import HarnessAdapters
import MailpipeCore
import MailpipeRuntime

@main
struct MailpipeM0 {
    @MainActor static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            switch args.first {
            case "offline":
                let results = try OfflineProbe.run()
                print("PASS: \(results.count) adapter decoders; synthetic data; no model or Mail calls")
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
            case "reply-probe":
                guard args.count == 3, args[1].hasPrefix("/"), args[2].hasPrefix("/") else { throw MailpipeError.invalidInput }
                let output = URL(fileURLWithPath: args[2], isDirectory: true)
                guard !FileManager.default.fileExists(atPath: output.path) else { throw MailpipeError.invalidInput }
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let adapter = DeepSeekHarnessAdapter(executable: URL(fileURLWithPath: args[1]), dialect: DeepSeekHarnessDialect())
                let report = try await adapter.runSyntheticReplyProbe { run in
                    let data = try JSONEncoder().encode(run)
                    try data.write(to: output.appendingPathComponent(run.destination.runID + ".json"), options: .atomic)
                }
                try JSONEncoder().encode(report.decision).write(to: output.appendingPathComponent("decision.json"), options: .atomic)
                if let draft = report.draft { try JSONEncoder().encode(draft).write(to: output.appendingPathComponent("draft.json"), options: .atomic) }
                print("PASS: synthetic reply probe; calls=\(report.runs.count); should_reply=\(report.decision.shouldReply.rawValue); draft=\(report.draft != nil); no Mail actions")
            case "inspect":
                guard args.count == 3, let kind = HarnessKind(rawValue: args[1]), args[2].hasPrefix("/") else {
                    throw MailpipeError.invalidInput
                }
                let path = URL(fileURLWithPath: args[2])
                let report: CapabilityReport
                if kind == .deepseek { report = try await DeepSeekHarnessAdapter(executable: path, dialect: DeepSeekHarnessDialect()).inspect() }
                else { report = try await CodexCLIAdapter(executable: path, dialect: CodexCLIDialect()).inspect() }
                print("\(kind.displayName): \(report.version)")
                print("Synthetic probe flags: \(report.supportsSyntheticProbe ? "available" : "missing: " + report.missingFlags.joined(separator: ", "))")
                print(report.realMailStatus)
            case nil, "--help", "-h":
                print("mailpipe-m0 offline | discover | inspect <dsh|codex> </absolute/path>\npipeline-seed </absolute/dsh> </new/private/directory> persists one fixed synthetic input.\nreply-probe </absolute/dsh> </new/private/output-directory> runs up to two live synthetic model calls; no real email or Mail actions.")
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
