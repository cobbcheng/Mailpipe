import Foundation
import MailpipeCore

public struct CodexCLIDialect: ReplyHarnessDialect {
    public init() {}
    public var kind: HarnessKind { .codex }
    public var helpArguments: [String] { ["exec", "--help"] }
    public var requiredFlags: [String] {
        ["--json", "--strict-config", "--sandbox", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules"]
    }
    public func acceptsVersion(_ version: String) -> Bool { version == "codex-cli 0.169.1" }

    public func replyInvocation(task: ReplyModelTask, schema: String, stdin: Data, directory: URL,
                                executable: URL, environment: [String: String]) throws -> ProcessInvocation {
        if case .draft(let request) = task, request.approvedPullRequest != nil { throw MailpipeError.unsafeCapability }
        guard let catalog = Bundle.module.url(forResource: "codex-model", withExtension: "json", subdirectory: "Resources"),
              let policy = Bundle.module.url(forResource: "reply-policy", withExtension: "md", subdirectory: "Resources")
        else { throw MailpipeError.unsafeCapability }
        func quoted(_ path: String) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            return String(decoding: try encoder.encode(path), as: UTF8.self)
        }
        let disabled = ["shell_tool", "view_image", "hooks", "plugins", "apps", "image_generation", "memories",
                        "multi_agent", "multi_agent_v2", "tool_suggest", "skill_search", "remote_plugin", "goals"]
        let config = try ["model_provider=\"openai\"", "mcp_servers={}", "approval_policy=\"never\"", "web_search=\"disabled\"", "tools.update_plan.enabled=false",
                          "tools.experimental_request_user_input.enabled=false", "features.skip_host_skill_discovery=true",
                          "suppress_unstable_features_warning=true", "project_doc_max_bytes=0",
                          "model_catalog_json=" + quoted(catalog.path), "model_instructions_file=" + quoted(policy.path)]
            + disabled.map { "features." + $0 + "=false" }
        let args = ["exec", "--strict-config", "--json", "--sandbox", "read-only", "--ephemeral",
                    "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules", "-m", "gpt-6.2-sol"]
            + config.flatMap { ["-c", $0] } + ["-"]
        return ProcessInvocation(executable: executable, arguments: args, stdin: stdin, workingDirectory: directory,
                                 environment: environment, timeout: 120)
    }

    public func replyOutput(_ stdout: Data, task: ReplyModelTask, inputCharacters: Int, directory: URL) throws -> ReplyModelOutput {
        var thread = false, started = false, completed = false
        var message: String?, input: Int?, output: Int?
        for line in stdout.split(separator: 10) {
            guard !completed, let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { throw MailpipeError.invalidOutput }
            switch event["type"] as? String {
            case "thread.started" where !thread:
                guard let id = event["thread_id"] as? String, !id.isEmpty else { throw MailpipeError.invalidOutput }
                thread = true
            case "turn.started" where thread && !started: started = true
            case "item.started", "item.updated", "item.completed":
                guard started, let item = event["item"] as? [String: Any],
                      let type = item["type"] as? String, ["agent_message", "reasoning"].contains(type)
                else { throw MailpipeError.unsafeCapability }
                if type == "agent_message", event["type"] as? String == "item.completed" {
                    guard message == nil, let text = item["text"] as? String, !text.isEmpty else { throw MailpipeError.invalidOutput }
                    message = text
                }
            case "turn.completed" where started:
                let usage = event["usage"] as? [String: Any]
                input = tokenCount(usage?["input_tokens"])
                output = tokenCount(usage?["output_tokens"])
                completed = true
            case "error", "turn.failed": throw classifyFailure(Data(line))
            default: throw MailpipeError.invalidOutput
            }
        }
        guard completed, let message else { throw MailpipeError.invalidOutput }
        return ReplyModelOutput(content: Data(message.utf8), inputTokens: input, outputTokens: output,
                                inputCharacters: inputCharacters, outputCharacters: message.count)
    }
}
public typealias CodexCLIAdapter = CLIAdapter<CodexCLIDialect>
