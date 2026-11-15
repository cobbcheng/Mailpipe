import Foundation
import MailpipeCore

public struct ClaudeCodeDialect: HarnessDialect {
    public init() {}
    public var kind: HarnessKind { .claude }
    public var helpArguments: [String] { ["--help"] }
    public var requiredFlags: [String] {
        ["--print", "--output-format", "--json-schema", "--tools", "--strict-mcp-config", "--mcp-config",
         "--safe-mode", "--disable-slash-commands", "--no-session-persistence", "--permission-mode", "--settings"]
    }
    public func arguments(schemaFile: URL) -> [String] {
        ["--print", "--output-format", "json", "--json-schema", ClassificationSchema.json,
         "--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
         "--safe-mode", "--disable-slash-commands", "--no-session-persistence",
         "--permission-mode", "dontAsk", "--settings", #"{"disableAllHooks":true}"#]
    }
    public func decode(_ output: Data, request: ClassificationRequest) throws -> AdapterResult {
        do {
            guard let envelope = try JSONSerialization.jsonObject(with: output) as? [String: Any],
                  envelope["type"] as? String == "result" else { throw MailpipeError.invalidOutput }
            if envelope["is_error"] as? Bool == true || (envelope["subtype"] as? String)?.hasPrefix("error") == true {
                throw classifyFailure(output)
            }
            guard envelope["subtype"] as? String == "success", envelope["is_error"] as? Bool == false else {
                throw MailpipeError.invalidOutput
            }
            let payload: Data
            if let structured = envelope["structured_output"] as? [String: Any] {
                payload = try JSONSerialization.data(withJSONObject: structured)
            } else if let result = envelope["result"] as? String {
                payload = Data(result.utf8)
            } else { throw MailpipeError.invalidOutput }
            let usage = envelope["usage"] as? [String: Any]
            return AdapterResult(response: try ClassificationResponse.validated(payload, for: request),
                                 inputTokens: tokenCount(usage?["input_tokens"]), outputTokens: tokenCount(usage?["output_tokens"]))
        } catch let error as MailpipeError { throw error }
        catch { throw MailpipeError.invalidOutput }
    }
}
public typealias ClaudeCodeAdapter = CLIAdapter<ClaudeCodeDialect>
