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
                let (tool, root) = try syntheticTarget(args)
                let store = try PipelineStore(directory: root)
                let session = try OnboardingSession(store: store)
                var draft = OnboardingDraft(); draft.step = 2; draft.executable = tool.executable.path; draft.harnessKind = tool.kind
                try session.save(draft)
                _ = try session.beginTest(); try await session.testPipeline.pump()
                guard let result = try session.testResult(), result.state == .draftReady,
                      try store.settings().permission == nil else { throw MailpipeError.invalidInput }
                print("PASS: onboarding synthetic test; calls=\(result.runs.count); draft persisted; active policy unchanged; no Mail access")
                for run in result.runs {
                    print("\(run.destination.taskKind.rawValue): inputTokens=\(run.inputTokens.map(String.init) ?? "unknown") outputTokens=\(run.outputTokens.map(String.init) ?? "unknown") inputCharacters=\(run.inputCharacters.map(String.init) ?? "unknown") outputCharacters=\(run.outputCharacters.map(String.init) ?? "unknown") actualCost=unknown")
                }
            case "pipeline-seed":
                let (tool, root) = try syntheticTarget(args)
                let store = try PipelineStore(directory: root)
                let pipeline = ReplyPipeline(store: store, inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")), resolve: { _, _ in nil })
                try pipeline.updateSettings { $0.executable = tool.executable.path; $0.harnessKind = tool.kind }
                _ = try pipeline.enqueueSynthetic()
                print("PASS: synthetic input persisted; no model or Mail call; open the App with --pipeline-directory pointing to this directory to resume")
            case "inspect":
                guard args.count == 3, let kind = HarnessKind(rawValue: args[1]), args[2].hasPrefix("/") else {
                    throw MailpipeError.invalidInput
                }
                let path = URL(fileURLWithPath: args[2])
                let report = try await HarnessInstallation(kind: kind, executable: path).inspect()
                print("\(kind.displayName): \(report.version)")
                print("Headless flags: \(report.supportsHeadlessRun ? "available" : "missing: " + report.missingFlags.joined(separator: ", "))")
                print(report.realMailStatus)
            case nil, "--help", "-h":
                print("mailpipe-m0 discover | inspect <dsh|claude|codex> </absolute/path>\nonboarding-probe [dsh|claude] </absolute/tool> </new/private/directory> tests one synthetic draft.\npipeline-seed [dsh|claude] </absolute/tool> </new/private/directory> persists one fixed synthetic input.")
            default: throw MailpipeError.invalidInput
            }
        } catch {
            // Do not emit raw subprocess output or user content.
            let code = (error as? MailpipeError)?.rawValue ?? "operationFailed"
            FileHandle.standardError.write(Data("mailpipe-m0: \(code)\n".utf8))
            exit(1)
        }
    }

    /// Omit the harness argument to use the original DSH probe syntax.
    private static func syntheticTarget(_ args: [String]) throws -> (HarnessInstallation, URL) {
        guard (3...4).contains(args.count),
              let kind = HarnessKind(rawValue: args.count == 4 ? args[1] : "dsh"), kind != .codex,
              args[args.count - 2].hasPrefix("/"), let directory = args.last, directory.hasPrefix("/"),
              !FileManager.default.fileExists(atPath: directory) else { throw MailpipeError.invalidInput }
        let executable = URL(fileURLWithPath: args[args.count - 2])
        return (HarnessInstallation(kind: kind, executable: executable), URL(fileURLWithPath: directory, isDirectory: true))
    }
}
