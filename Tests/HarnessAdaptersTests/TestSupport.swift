import Foundation
@testable import HarnessAdapters
import MailpipeCore

final class TemporaryDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("mailpipe-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func script(_ body: String, name: String = "fake harness") throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
}

actor RecordingRunner: ProcessRunning {
    var outputs: [ProcessOutput]
    private(set) var calls: [ProcessInvocation] = []
    init(_ outputs: [ProcessOutput] = []) { self.outputs = outputs }
    func run(_ invocation: ProcessInvocation) async throws -> ProcessOutput {
        calls.append(invocation)
        guard !outputs.isEmpty else { throw MailpipeError.launchFailed }
        return outputs.removeFirst()
    }
}

func inspectionOutputs<D: HarnessDialect>(_ dialect: D) -> [ProcessOutput] {
    [ProcessOutput(stdout: Data((dialect.kind == .deepseek ? "0.2.2-rc.1\n" : "synthetic-cli 1.2.3\n").utf8)),
     ProcessOutput(stdout: Data(dialect.requiredFlags.joined(separator: "\n").utf8))]
}
func deepseekEvents(_ payload: Data = SyntheticFixture.response) throws -> Data {
    let events: [[String: Any]] = [
        ["type":"session", "sessionId":"synthetic-session"],
        ["type":"mailpipe_safety", "registry":[], "advertised":[], "provider":"deepseek-official", "model":"deepseek-flash"],
        ["type":"status", "phase":"step_end", "usage":["inputTokens":12,"outputTokens":20]],
        ["type":"final", "sessionId":"synthetic-session", "reason":["kind":"completed"], "text":String(decoding:payload,as:UTF8.self)]
    ]
    return try events.reduce(into: Data()) { $0.append(try JSONSerialization.data(withJSONObject: $1)); $0.append(10) }
}
func codexEvents(_ payload: Data = SyntheticFixture.response, completed: Bool = true) throws -> Data {
    var events: [[String: Any]] = [["type":"thread.started"], ["type":"turn.started"],
        ["type":"item.completed", "item":["type":"agent_message", "text":String(decoding: payload, as: UTF8.self)]]]
    if completed { events.append(["type":"turn.completed", "usage":["input_tokens":12, "output_tokens":20]]) }
    return try events.reduce(into: Data()) { $0.append(try JSONSerialization.data(withJSONObject: $1)); $0.append(10) }
}
