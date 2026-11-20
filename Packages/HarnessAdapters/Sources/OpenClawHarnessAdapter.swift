import Foundation
import MailpipeCore

/// Verified against the embedded one-shot runner and JSON receipt of this release.
public struct OpenClawDialect: ReplyHarnessDialect {
    public init() {}
    public var kind: HarnessKind { .openclaw }
    public var helpArguments: [String] { ["agent", "exec", "--help"] }
    public var requiredFlags: [String] {
        ["--isolated", "--config-override", "--state-dir", "--cwd", "--message-file", "--model",
         "--thinking", "--code-mode", "--json", "--timeout"]
    }
    public func acceptsVersion(_ version: String) -> Bool { version == "OpenClaw 2026.11.5 (e13cf15)" }

    public func prepare(directory: URL, executable: URL, environment: [String: String]) throws -> [String: String] {
        let manager = FileManager.default
        for component in ["home", "workspace", "run-state", "tmp"] {
            try manager.createDirectory(at: directory.appendingPathComponent(component), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        let config = directory.appendingPathComponent("openclaw.json")
        try Data("{}".utf8).write(to: config, options: .atomic)
        let home = environment["HOME"] ?? manager.homeDirectoryForCurrentUser.path
        return [
            "OPENCLAW_CONFIG_PATH": config.path,
            "OPENCLAW_LOG_LEVEL": "silent",
            "HOME": directory.appendingPathComponent("home").path,
            "LANG": environment["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": directory.appendingPathComponent("tmp").path,
            "PATH": executable.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin"),
            // Capability probes never use operator state. Only agent exec needs its native profile store.
            "MAILPIPE_OPENCLAW_AUTH_ROOT": URL(fileURLWithPath: home).appendingPathComponent(".openclaw").path
        ]
    }

    public func replyInvocation(task: ReplyModelTask, schema: String, stdin: Data, directory: URL,
                                executable: URL, environment: [String: String]) throws -> ProcessInvocation {
        if case .draft(let request) = task, request.approvedPullRequest != nil { throw MailpipeError.unsafeCapability }
        guard let config = Bundle.module.url(forResource: "openclaw-restricted", withExtension: "json", subdirectory: "Resources"),
              let policy = Bundle.module.url(forResource: "reply-policy", withExtension: "md", subdirectory: "Resources")
        else { throw MailpipeError.unsafeCapability }
        let workspace = directory.appendingPathComponent("workspace")
        let instructions = try String(contentsOf: policy, encoding: .utf8) +
            "\nNo lookup tools are available for this request. Base factual claims only on the input email. Return only a JSON object that conforms to output_schema, without Markdown fences."
        try Data(instructions.utf8).write(to: workspace.appendingPathComponent("AGENTS.md"), options: .atomic)
        let restricted = try String(contentsOf: config, encoding: .utf8)
        var child = environment
        guard let authRoot = child.removeValue(forKey: "MAILPIPE_OPENCLAW_AUTH_ROOT") else { throw MailpipeError.authRequired }
        // agent exec --isolated ignores ambient config, dotenv and installed plugin roots.
        // OpenClaw resolves its own stored credential; all turn state is under --state-dir.
        child["OPENCLAW_STATE_DIR"] = authRoot
        let arguments = ["agent", "exec", "--isolated", "--config-override", restricted, "--state-dir",
                         directory.appendingPathComponent("run-state").path, "--cwd", workspace.path,
                         "--message-file", "-", "--model", "deepseek/deepseek-flash",
                         "--thinking", "off", "--code-mode", "direct", "--json", "--timeout", "90"]
        return ProcessInvocation(executable: executable, arguments: arguments, stdin: stdin, workingDirectory: workspace,
                                 environment: child, timeout: 120)
    }

    public func runFailure(_ result: ProcessOutput) -> MailpipeError {
        struct Failure: Decodable {
            struct Detail: Decodable { let kind, message: String }
            let ok: Bool
            let status: String
            let error: Detail
        }
        guard let failure = try? JSONDecoder().decode(Failure.self, from: result.stdout), !failure.ok else {
            return classifyFailure(result.stderr)
        }
        if result.exitCode == 2, failure.status == "timeout", failure.error.kind == "timeout" { return .timedOut }
        if result.exitCode == 1, failure.status == "error",
           failure.error.message.contains(#"No API key found for provider "deepseek"."#) { return .authRequired }
        return classifyFailure(Data(failure.error.message.utf8))
    }

    public func replyOutput(_ stdout: Data, task: ReplyModelTask, inputCharacters: Int, directory: URL) throws -> ReplyModelOutput {
        guard let event = try? JSONDecoder().decode(Receipt.self, from: stdout),
              event.ok, event.status == "ok", event.error == nil,
              event.provider == "deepseek", event.model == "deepseek-flash", !event.sessionId.isEmpty,
              event.assistantTurns == 1, !event.codeModeEngaged, event.toolSummary == nil, event.bridgeCalls == nil,
              event.payloads.count == 1, let payload = event.payloads.first, payload.text.hasPrefix(event.final),
              payload.text.dropFirst(event.final.count).allSatisfy(\.isWhitespace),
              !event.final.isEmpty, payload.isError != true, payload.isCommentary != true, payload.isReasoning != true,
              payload.mediaUrl == nil, (payload.mediaUrls ?? []).isEmpty,
              event.usage.input >= 0, event.usage.output > 0, event.usage.total >= event.usage.output,
              event.usage.total - event.usage.output >= event.usage.input
        else { throw MailpipeError.invalidOutput }
        return ReplyModelOutput(content: Data(event.final.utf8), inputTokens: event.usage.total - event.usage.output,
                                outputTokens: event.usage.output,
                                inputCharacters: inputCharacters, outputCharacters: event.final.count,
                                actualModel: event.provider + "/" + event.model)
    }

    private struct Receipt: Decodable {
        struct Presence: Decodable {}
        struct Usage: Decodable { let input, output, total: Int }
        struct Payload: Decodable {
            let text: String
            let mediaUrl: String?
            let mediaUrls: [String]?
            let isError, isCommentary, isReasoning: Bool?
        }
        let ok, codeModeEngaged: Bool
        let status, final, sessionId, provider, model: String
        let assistantTurns: Int
        let error, toolSummary, bridgeCalls: Presence?
        let usage: Usage
        let payloads: [Payload]
    }
}

public typealias OpenClawHarnessAdapter = CLIAdapter<OpenClawDialect>
