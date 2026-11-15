import Foundation
import MailpipeCore

/// Offline UI/CLI smoke check: the same two decoders and core validator, zero subprocesses.
public enum OfflineProbe {
    public static func run() throws -> [ClassificationResponse] {
        let object = try JSONSerialization.jsonObject(with: SyntheticFixture.response)
        let claude = try JSONSerialization.data(withJSONObject: [
            "type": "result", "subtype": "success", "is_error": false, "structured_output": object
        ])
        let codexEvents: [[String: Any]] = [
            ["type": "thread.started", "thread_id": "synthetic-thread"],
            ["type": "turn.started"],
            ["type": "item.completed", "item": ["type": "agent_message", "text": String(decoding: SyntheticFixture.response, as: UTF8.self)]],
            ["type": "turn.completed"]
        ]
        var codex = Data()
        for event in codexEvents { codex.append(try JSONSerialization.data(withJSONObject: event)); codex.append(10) }
        return [try ClaudeCodeDialect().decode(claude, request: SyntheticFixture.request).response,
                try CodexCLIDialect().decode(codex, request: SyntheticFixture.request).response]
    }
}
