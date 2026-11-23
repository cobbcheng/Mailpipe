import Foundation
import MailpipeCore

/// Each supported release uses the same restricted invocation and stream contract.
public struct ClaudeCodeDialect: ReplyHarnessDialect {
    public init() {}
    public var kind: HarnessKind { .claude }
    public var helpArguments: [String] { ["--help"] }
    public var requiredFlags: [String] {
        ["--print", "--safe-mode", "--tools", "--strict-mcp-config", "--no-session-persistence",
         "--disable-slash-commands", "--permission-mode", "--setting-sources", "--verbose",
         "--output-format", "--system-prompt"]
    }
    public func acceptsVersion(_ version: String) -> Bool {
        ["2.1.296 (Claude Code)", "2.1.330 (Claude Code)"].contains(version)
    }

    public func prepare(directory: URL, executable: URL, environment: [String: String]) throws -> [String: String] {
        var result = environment
        result["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        result["CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY"] = "1"
        return result
    }

    public func replyInvocation(task: ReplyModelTask, schema: String, stdin: Data, directory: URL,
                                executable: URL, environment: [String: String]) throws -> ProcessInvocation {
        if case .draft(let request) = task, request.approvedPullRequest != nil { throw MailpipeError.unsafeCapability }
        guard let policyFile = Bundle.module.url(forResource: "reply-policy", withExtension: "md", subdirectory: "Resources")
            else { throw MailpipeError.unsafeCapability }
        let policy = try String(contentsOf: policyFile, encoding: .utf8)
        // --json-schema enables Claude's StructuredOutput tool and can consume a second turn.
        // Send the schema on stdin and keep every tool disabled; the host validates the response.
        let arguments = ["--print", "--safe-mode", "--tools", "", "--strict-mcp-config", "--no-session-persistence",
                         "--disable-slash-commands", "--permission-mode", "dontAsk", "--setting-sources", "user",
                         "--output-format", "stream-json", "--verbose", "--system-prompt",
                         policy + "\nNo lookup tools are available for this request. Base factual claims only on the input email. Do not claim to have verified external facts. Omit the signature if neither the writing preferences nor the incoming email specifies a signature for the person replying. Do not infer identity from the runtime environment."]
        // The CLI preprocesses literal file mentions before tool permissions. JSON escaping
        // retains the exact string value while preventing implicit attachments at launch.
        let transport = String(decoding: stdin, as: UTF8.self).replacingOccurrences(of: "@", with: #"\u0040"#)
        return ProcessInvocation(executable: executable, arguments: arguments, stdin: Data(transport.utf8), workingDirectory: directory,
                                 environment: environment, timeout: 120)
    }

    public func replyOutput(_ stdout: Data, task: ReplyModelTask, inputCharacters: Int, directory: URL) throws -> ReplyModelOutput {
        var session: String?
        var output: ReplyModelOutput?
        for line in stdout.split(separator: 10) {
            guard output == nil,
                  let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = event["session_id"] as? String, !id.isEmpty, session == nil || session == id else {
                throw MailpipeError.invalidOutput
            }
            if event["type"] as? String == "system", event["subtype"] as? String == "ui_invalidate" { continue }
            if event["type"] as? String == "system", event["subtype"] as? String == "init" {
                guard session == nil, (event["tools"] as? [String]) == [],
                      (event["mcp_servers"] as? [Any])?.isEmpty == true,
                      (event["skills"] as? [String]) == [], (event["slash_commands"] as? [String]) == []
                    else { throw MailpipeError.unsafeCapability }
                session = id
                continue
            }
            guard session != nil else { throw MailpipeError.invalidOutput }
            switch event["type"] as? String {
            case "system" where event["subtype"] as? String == "thinking_tokens":
                continue
            case "assistant":
                guard let message = event["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]],
                      blocks.allSatisfy({ ["text", "thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") })
                    else { throw MailpipeError.unsafeCapability }
            case "result":
                guard event["subtype"] as? String == "success", event["is_error"] as? Bool == false
                    else { throw classifyFailure(Data(line)) }
                guard tokenCount(event["num_turns"]) == 1, event["stop_reason"] as? String == "end_turn",
                      (event["permission_denials"] as? [Any])?.isEmpty == true,
                      let text = event["result"] as? String, !text.isEmpty,
                      let models = event["modelUsage"] as? [String: [String: Any]], models.count == 1,
                      let (name, usage) = models.first, !name.isEmpty,
                      let input = tokenCount(usage["inputTokens"]), let generated = tokenCount(usage["outputTokens"])
                    else { throw MailpipeError.invalidOutput }
                let model = usage["canonicalModel"] as? String ?? name
                guard !model.isEmpty, model.utf8.count <= 256, model.rangeOfCharacter(from: .controlCharacters) == nil
                    else { throw MailpipeError.invalidOutput }
                output = ReplyModelOutput(content: Data(text.utf8), inputTokens: input, outputTokens: generated,
                    inputCharacters: inputCharacters, outputCharacters: text.count, actualModel: model)
            default: throw MailpipeError.unsafeCapability
            }
        }
        guard let output else { throw MailpipeError.invalidOutput }
        return output
    }
}
public typealias ClaudeCodeHarnessAdapter = CLIAdapter<ClaudeCodeDialect>
