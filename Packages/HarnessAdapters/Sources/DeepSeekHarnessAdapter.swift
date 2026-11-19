import Foundation
import MailpipeCore

/// The profile is version-pinned because new upstream plugins must not silently expand access.
public struct DeepSeekHarnessDialect: HarnessDialect {
    public init() {}
    public var kind: HarnessKind { .deepseek }
    public var helpArguments: [String] { ["--profile", "headless", "--help"] }
    public var requiredFlags: [String] { ["--json", "--permission-mode", "--approval-policy"] }
    public func acceptsVersion(_ version: String) -> Bool { version == "0.2.2-rc.1" }
    public func prepare(directory: URL, executable: URL, environment: [String: String]) throws -> [String: String] {
        let home = directory.appendingPathComponent("dsh-home", isDirectory: true)
        let profile = home.appendingPathComponent("profiles/headless", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manifest = #"{"name":"mailpipe-headless","private":true,"dependencies":{},"dsh":{"profile":{"bundles":["@deepseek-ai/dsh-base","@deepseek-ai/dsh-headless"]}}}"#
        try Data(manifest.utf8).write(to: profile.appendingPathComponent("package.json"), options: .atomic)
        let guardFile = directory.appendingPathComponent("deepseek-guard.mjs")
        guard let resources = Bundle.module.resourceURL?.appendingPathComponent("Resources") else { throw MailpipeError.unsafeCapability }
        try Data(contentsOf: resources.appendingPathComponent("deepseek-guard.mjs")).write(to: guardFile, options: .atomic)
        let quoted = String(decoding: try JSONEncoder().encode(guardFile.path), as: UTF8.self)
        let policy = try String(contentsOf: resources.appendingPathComponent("reply-policy.md"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !policy.isEmpty else { throw MailpipeError.unsafeCapability }
        let quotedPolicy = String(decoding: try JSONEncoder().encode(policy), as: UTF8.self)
        let patch = try String(contentsOf: resources.appendingPathComponent("deepseek-restricted.yml"), encoding: .utf8)
            .replacingOccurrences(of: "__MAILPIPE_GUARD_PATH__", with: quoted)
            .replacingOccurrences(of: "__MAILPIPE_REPLY_POLICY__", with: quotedPolicy)
        try Data(patch.utf8).write(to: directory.appendingPathComponent("deepseek-restricted.yml"), options: .atomic)
        var result = environment
        // Preserve the selected npm launcher's sibling Node; do not inherit arbitrary caller PATH.
        result["PATH"] = executable.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        result["DSH_HOME"] = home.path
        result["DSH_TELEMETRY_DISABLED"] = "1"
        let userHome = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        result["MAILPIPE_DSH_AUTH_HOME"] = URL(fileURLWithPath: userHome).appendingPathComponent(".dsh").path
        // Reuse only the harness's native global instruction files. No profile,
        // credentials, transcript store, project scan or separate Mailpipe memory DB.
        let agents = directory.appendingPathComponent("agents-home", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        result["DSH_AGENTS_HOME"] = agents.path
        for (sourceRoot, targetRoot) in [(".dsh", home), (".agents", agents)] {
            let source = URL(fileURLWithPath: userHome).appendingPathComponent(sourceRoot).appendingPathComponent("AGENTS.md")
            // Reject symlinks, oversized/nonregular files and invalid UTF-8. A missing
            // or unreadable memory is neutral fallback, never a model/tool retry.
            if let bytes = try? CaptureInbox.read(source, limit: 16_384),
               let text = String(data: bytes, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let target = targetRoot.appendingPathComponent("AGENTS.md")
                try bytes.write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            }
        }
        return result
    }
    public func arguments(schemaFile: URL) -> [String] {
        ["--profile", "headless", "--patch", schemaFile.deletingLastPathComponent().appendingPathComponent("deepseek-restricted.yml").path,
         "--json", "--permission-mode", "read-only", "--approval-policy", "never", "-"]
    }
    func configurePullRequest(_ target: String, confirmed: Bool, directory: URL) throws {
        guard let server = Bundle.module.url(forResource: "mailpipe-pr-mcp", withExtension: "mjs", subdirectory: "Resources") else { throw MailpipeError.unsafeCapability }
        let args = [server.path, target, confirmed ? "confirmed" : "public"]
        let json = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
        let file = directory.appendingPathComponent("deepseek-restricted.yml")
        let patch = try String(contentsOf: file, encoding: .utf8) + """

        - insert:
            - id: mailpipe-pr-client
              name: '@deepseek-ai/dsh-mcp-client'
              config:
                serverName: mailpipe
                transport: stdio
                command: node
                args: \(json)
                reconnect: {enabled: false}
        """
        try Data(patch.utf8).write(to: file, options: .atomic)
    }
    public func decodeEnvelope(_ output: Data, review: Bool = false) throws -> DeepSeekEnvelope {
        do {
            var session: String?, finalText: String?, safetySeen = false, completed = false
            let allowed = review ? ["mcp__mailpipe__read_pr_diff"] : []
            var pendingCall: String?
            var readPatch: Bool?
            var inputTokens = 0, outputTokens = 0, usageSeen = false
            for line in output.split(separator: 10) where !line.isEmpty {
                guard !completed,
                      let event = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let type = event["type"] as? String,
                      (["tool_result", "thinking", "text"].contains(type) || event["truncated"] as? Bool != true) else { throw MailpipeError.invalidOutput }
                switch type {
                case "session":
                    guard session == nil, let id = event["sessionId"] as? String, !id.isEmpty else { throw MailpipeError.invalidOutput }
                    session = id
                case "mailpipe_safety":
                    guard session != nil, !safetySeen || review,
                          let registry = event["registry"] as? [String], registry == allowed,
                          let advertised = event["advertised"] as? [String], advertised == allowed,
                          event["provider"] as? String == "deepseek-official",
                          event["model"] as? String == "deepseek-flash" else { throw MailpipeError.unsafeCapability }
                    safetySeen = true
                case "status":
                    guard session != nil else { throw MailpipeError.invalidOutput }
                    if let usage = event["usage"] as? [String: Any] {
                        guard let input = tokenCount(usage["inputTokens"]), let output = tokenCount(usage["outputTokens"]) else { throw MailpipeError.invalidOutput }
                        guard !usageSeen || review, input <= Int.max - inputTokens, output <= Int.max - outputTokens else { throw MailpipeError.invalidOutput }
                        inputTokens += input
                        outputTokens += output
                        usageSeen = true
                    }
                case "text", "thinking":
                    guard safetySeen else { throw MailpipeError.unsafeCapability }
                case "tool_call":
                    guard review, safetySeen, pendingCall == nil, let id = event["callId"] as? String,
                          event["tool"] as? String == allowed.first,
                          let input = event["input"] as? [String: Any], input.isEmpty else { throw MailpipeError.unsafeCapability }
                    pendingCall = id
                case "tool_result":
                    guard review, let id = pendingCall, event["callId"] as? String == id else { throw MailpipeError.unsafeCapability }
                    pendingCall = nil
                    if readPatch == nil { readPatch = false }
                    // Headless shortens long tool results in its JSON transcript.
                    // The server-owned prefix precedes all repository-controlled text.
                    if event["status"] as? String == "completed", let result = event["result"] as? String,
                       result.hasPrefix("MAILPIPE_PR_PATCH_READ\n") {
                        readPatch = true
                    }
                case "error": throw classifyFailure(Data(line))
                case "final":
                    guard safetySeen, pendingCall == nil, let session, event["sessionId"] as? String == session,
                          let reason = event["reason"] as? [String: Any], reason["kind"] as? String == "completed",
                          let text = event["text"] as? String else { throw MailpipeError.invalidOutput }
                    finalText = text; completed = true
                default: throw MailpipeError.invalidOutput
                }
            }
            guard completed, let finalText else { throw MailpipeError.invalidOutput }
            var json = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            if json.hasPrefix("```json\n"), json.hasSuffix("\n```") {
                json = String(json.dropFirst(8).dropLast(4))
            }
            return DeepSeekEnvelope(content: Data(json.utf8),
                                 inputTokens: usageSeen ? inputTokens : nil, outputTokens: usageSeen ? outputTokens : nil, readPullRequestDiff: readPatch)
        } catch let error as MailpipeError { throw error }
        catch { throw MailpipeError.invalidOutput }
    }
}
public typealias DeepSeekHarnessAdapter = CLIAdapter<DeepSeekHarnessDialect>

public struct DeepSeekEnvelope: Sendable {
    public let content: Data
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let readPullRequestDiff: Bool?
}
