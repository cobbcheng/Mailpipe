import Foundation
import XCTest
@testable import HarnessAdapters
import MailpipeCore

@MainActor
final class ClaudeCodeTests: XCTestCase {
    private let dialect = ClaudeCodeDialect()
    private let route = AccountRoute(accountID: "synthetic", allowedHarnesses: [.claude])

    private var initEvent: [String: Any] {
        ["type": "system", "subtype": "init", "session_id": "s", "tools": [], "mcp_servers": [], "skills": [], "slash_commands": []]
    }

    private var result: [String: Any] {
        ["type": "result", "subtype": "success", "session_id": "s", "num_turns": 1,
         "is_error": false, "stop_reason": "end_turn", "permission_denials": [],
         "result": String(decoding: ReplySyntheticFixture.draft, as: UTF8.self),
         "modelUsage": ["synthetic-model": ["inputTokens": 12, "outputTokens": 20, "canonicalModel": "example-model"]]]
    }

    private func stream(_ events: [[String: Any]]) throws -> Data {
        try events.reduce(into: Data()) { data, event in
            data.append(try JSONSerialization.data(withJSONObject: event))
            data.append(10)
        }
    }

    private var probe: [ProcessOutput] {
        [ProcessOutput(stdout: Data("2.1.296 (Claude Code)\n".utf8)),
         ProcessOutput(stdout: Data(dialect.requiredFlags.joined(separator: "\n").utf8))]
    }

    func testRestrictedDraftAcceptsWarningAndEscapesFileMentionsBeforeClaudeSeesInput() async throws {
        let root = try TemporaryDirectory()
        let runner = RecordingRunner(probe + [ProcessOutput(stdout: try stream([initEvent, result]), stderr: Data("unrecognized_model".utf8))])
        let adapter = ClaudeCodeHarnessAdapter(executable: root.url.appendingPathComponent("fake-claude"), dialect: dialect,
                                              runner: runner, temporaryRoot: root.url)
        let triage = ReplySyntheticFixture.triage
        let decision = try ReplyDecision.validated(ReplySyntheticFixture.decision, for: triage)
        let request = try ReplyDraftRequest(requestID: "synthetic-draft", triage: triage, decision: decision)
        let draft = try await adapter.run(.draft(request), route: route) {}
        XCTAssertNotNil(try ReplyDraft.validated(draft.content, for: request))
        XCTAssertEqual(draft.actualModel, "example-model")
        XCTAssertEqual(draft.inputTokens, 12)
        XCTAssertEqual(draft.outputTokens, 20)
        XCTAssertNil(draft.readPullRequestDiff)
        let calls = await runner.calls
        let call = try XCTUnwrap(calls.last)
        XCTAssertEqual(calls.count, 3)
        XCTAssertFalse(String(decoding: call.stdin, as: UTF8.self).contains("@"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: call.stdin) as? [String: Any])
        let encoded = try XCTUnwrap(payload["request"] as? [String: Any])
        XCTAssertEqual((encoded["message"] as? [String: Any])?["body"] as? String, request.message.body)
        XCTAssertFalse(call.arguments.contains(request.message.body))
        XCTAssertFalse(call.arguments.contains("--model"))
        XCTAssertFalse(call.arguments.contains("--json-schema"))
        XCTAssertTrue(call.arguments.contains("--safe-mode"))
        XCTAssertTrue(call.arguments.contains("--strict-mcp-config"))
        XCTAssertTrue(call.arguments.contains("--no-session-persistence"))
        let i = try XCTUnwrap(call.arguments.firstIndex(of: "--tools"))
        XCTAssertEqual(call.arguments[i + 1], "")
        XCTAssertEqual(draft.inputCharacters, String(decoding: call.stdin, as: UTF8.self).count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: call.workingDirectory.path))
    }

    func testRejectsChangedToolsUnsafeResultsAndCrossSessionEvents() throws {
        let assistantTool: [String: Any] = ["type": "assistant", "session_id": "s", "message": ["content": [["type": "tool_use"]]]]
        let step = ReplyModelTask.triage(ReplySyntheticFixture.triage)
        for events in [
            [initEvent.merging(["tools": ["Read"]]) { $1 }, result],
            [initEvent.merging(["mcp_servers": [["name": "external"]]]) { $1 }, result],
            [initEvent, assistantTool, result], [result], [initEvent],
            [initEvent, result.merging(["num_turns": 2]) { $1 }],
            [initEvent, result.merging(["session_id": "other"]) { $1 }],
            [initEvent, result.merging(["is_error": true]) { $1 }],
            [initEvent, result.merging(["permission_denials": ["Read"]]) { $1 }],
            [initEvent, result.merging(["stop_reason": "max_tokens"]) { $1 }]
        ] {
            XCTAssertThrowsError(try dialect.replyOutput(stream(events), task: step, inputCharacters: 0))
        }
        XCTAssertFalse(dialect.acceptsVersion("2.1.297 (Claude Code)"))
    }

    func testRevokedPRAndWrongRouteNeverLaunchInference() async throws {
        let root = try TemporaryDirectory()
        let runner = RecordingRunner(probe + probe)
        let adapter = ClaudeCodeHarnessAdapter(executable: root.url.appendingPathComponent("fake-claude"), dialect: dialect,
                                              runner: runner, temporaryRoot: root.url)
        var request = try ReplyDraftRequest(message: ReplySyntheticFixture.triage.message)
        do {
            _ = try await adapter.run(.draft(request), route: .init(accountID: "synthetic", allowedHarnesses: [.deepseek])) {}
            XCTFail("wrong route")
        } catch { XCTAssertEqual(error as? MailpipeError, .routeNotAllowed) }
        do {
            _ = try await adapter.run(.draft(request), route: route) { throw MailpipeError.paused }
            XCTFail("paused")
        } catch { XCTAssertEqual(error as? MailpipeError, .paused) }
        request.approvedPullRequest = "https://github.com/example/project/pull/1"
        do {
            _ = try await adapter.run(.draft(request), route: route) {}
            XCTFail("unsupported PR review")
        } catch { XCTAssertEqual(error as? MailpipeError, .unsafeCapability) }
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls.allSatisfy { $0.stdin.isEmpty })
    }
}
