import Foundation
import MailpipeCore

/// Offline UI/CLI smoke check: the same two decoders and core validator, zero subprocesses.
public enum OfflineProbe {
    public static func run() throws -> [ClassificationResponse] {
        let deepseekEvents: [[String: Any]] = [
            ["type": "session", "sessionId": "synthetic-session"],
            ["type": "mailpipe_safety", "registry": [], "advertised": [], "provider": "deepseek-official", "model": "deepseek-flash"],
            ["type": "final", "sessionId": "synthetic-session", "reason": ["kind": "completed"], "text": String(decoding: SyntheticFixture.response, as: UTF8.self)]
        ]
        var deepseek = Data()
        for event in deepseekEvents { deepseek.append(try JSONSerialization.data(withJSONObject: event)); deepseek.append(10) }
        let codexEvents: [[String: Any]] = [
            ["type": "thread.started", "thread_id": "synthetic-thread"],
            ["type": "turn.started"],
            ["type": "item.completed", "item": ["type": "agent_message", "text": String(decoding: SyntheticFixture.response, as: UTF8.self)]],
            ["type": "turn.completed"]
        ]
        var codex = Data()
        for event in codexEvents { codex.append(try JSONSerialization.data(withJSONObject: event)); codex.append(10) }
        return [try DeepSeekHarnessDialect().decode(deepseek, request: SyntheticFixture.request).response,
                try CodexCLIDialect().decode(codex, request: SyntheticFixture.request).response]
    }
}
