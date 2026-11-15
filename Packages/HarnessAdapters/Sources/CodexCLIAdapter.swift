import Foundation
import MailpipeCore

public struct CodexCLIDialect: HarnessDialect {
    public init() {}
    public var kind: HarnessKind { .codex }
    public var helpArguments: [String] { ["exec", "--help"] }
    public var requiredFlags: [String] {
        ["--json", "--output-schema", "--sandbox", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules"]
    }
    public func arguments(schemaFile: URL) -> [String] {
        ["exec", "--json", "--output-schema", schemaFile.path, "--sandbox", "read-only",
         "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
         "-c", "approval_policy=\"never\"", "-c", "features.shell_tool=false",
         "-c", "features.view_image=false", "-c", "web_search=\"disabled\"", "-"]
    }
    public func decode(_ output: Data, request: ClassificationRequest) throws -> AdapterResult {
        do {
            var finalText: String?, completed = false
            var inputTokens: Int?, outputTokens: Int?
            for line in output.split(separator: 10) where !line.isEmpty {
                guard let event = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let type = event["type"] as? String else { throw MailpipeError.invalidOutput }
                guard !completed else { throw MailpipeError.invalidOutput }
                switch type {
                case "error", "turn.failed": throw classifyFailure(Data(line))
                case "thread.started", "turn.started": break
                case "item.started", "item.updated", "item.completed":
                    guard let item = event["item"] as? [String: Any], let itemType = item["type"] as? String,
                          ["agent_message", "reasoning"].contains(itemType) else { throw MailpipeError.unsafeCapability }
                    if type == "item.completed", itemType == "agent_message" {
                        guard finalText == nil, let text = item["text"] as? String else { throw MailpipeError.invalidOutput }
                        finalText = text
                    }
                case "turn.completed":
                    completed = true
                    let usage = event["usage"] as? [String: Any]
                    inputTokens = tokenCount(usage?["input_tokens"]); outputTokens = tokenCount(usage?["output_tokens"])
                default: throw MailpipeError.invalidOutput
                }
            }
            guard completed, let finalText else { throw MailpipeError.invalidOutput }
            return AdapterResult(response: try ClassificationResponse.validated(Data(finalText.utf8), for: request),
                                 inputTokens: inputTokens, outputTokens: outputTokens)
        } catch let error as MailpipeError { throw error }
        catch { throw MailpipeError.invalidOutput }
    }
}
public typealias CodexCLIAdapter = CLIAdapter<CodexCLIDialect>
