import Foundation
import XCTest
@testable import HarnessAdapters
import MailpipeCore

@MainActor
final class OpenClawTests: XCTestCase {
    private let dialect = OpenClawDialect()
    private let task = ReplyModelTask.triage(ReplySyntheticFixture.triage)
    private var receipt: [String: Any] {
        let draft = String(decoding: ReplySyntheticFixture.draft, as: UTF8.self)
        return ["ok": true, "status": "ok", "final": draft, "payloads": [["text": draft, "mediaUrl": NSNull()]],
                "usage": ["input": 20, "output": 7, "cacheRead": 4, "cacheWrite": 0, "total": 31],
                "assistantTurns": 1, "codeModeEngaged": false, "model": "deepseek-flash",
                "provider": "deepseek", "sessionId": "synthetic"]
    }

    func testNormalDraftUsesOnlyAnIsolatedNativeTurn() async throws {
        let root = try TemporaryDirectory()
        let fake = root.url.appendingPathComponent("fake-openclaw")
        let runner = RecordingRunner([
            ProcessOutput(stdout: Data("OpenClaw 2026.11.5 (e13cf15)".utf8)),
            ProcessOutput(stdout: Data(dialect.requiredFlags.joined(separator: "\n").utf8)),
            ProcessOutput(stdout: try JSONSerialization.data(withJSONObject: receipt))
        ])
        let adapter = OpenClawHarnessAdapter(executable: fake, dialect: dialect, runner: runner, temporaryRoot: root.url,
                                             environment: ["HOME": root.url.path, "OPENCLAW_STATE_DIR": "/untrusted",
                                                           "DEEPSEEK_API_KEY": "synthetic", "NODE_OPTIONS": "--inspect"])
        let triage = ReplySyntheticFixture.triage
        let decision = try ReplyDecision.validated(ReplySyntheticFixture.decision, for: triage)
        let request = try ReplyDraftRequest(requestID: "synthetic-draft", triage: triage, decision: decision)
        let output = try await adapter.run(.draft(request), route: .init(accountID: "example", allowedHarnesses: [.openclaw])) {}
        XCTAssertNotNil(try ReplyDraft.validated(output.content, for: request))
        XCTAssertEqual(output.actualModel, "deepseek/deepseek-flash")
        XCTAssertEqual(output.inputTokens, 24)
        XCTAssertEqual(output.outputTokens, 7)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertNil(calls[0].environment["OPENCLAW_STATE_DIR"])
        let run = try XCTUnwrap(calls.last)
        XCTAssertTrue(run.arguments.contains("--isolated"))
        XCTAssertFalse(run.arguments.contains("--fallback"))
        XCTAssertFalse(run.arguments.contains(request.message.body))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: run.stdin) as? [String: Any])
        XCTAssertEqual(run.environment["OPENCLAW_STATE_DIR"], root.url.appendingPathComponent(".openclaw").path)
        XCTAssertNotEqual(run.environment["HOME"], root.url.path)
        XCTAssertNil(run.environment["DEEPSEEK_API_KEY"])
        XCTAssertNil(run.environment["NODE_OPTIONS"])
        let i = try XCTUnwrap(run.arguments.firstIndex(of: "--config-override"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(run.arguments[i + 1].utf8)) as? [String: Any])
        XCTAssertEqual((config["tools"] as? [String: Any])?["deny"] as? [String], ["*"])
        XCTAssertEqual((config["plugins"] as? [String: Bool])?["enabled"], false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.workingDirectory.path))
    }

    func testRejectsWrongModelToolsMediaAndUnverifiedCompletion() throws {
        let mutations: [[String: Any]] = [
            ["codeModeEngaged": true], ["assistantTurns": 2], ["toolSummary": ["calls": 1]],
            ["bridgeCalls": ["call": 1]], ["model": "other"], ["provider": "other"], ["ok": false],
            ["error": ["kind": "cleanup"]], ["payloads": [["text": receipt["final"]!, "mediaUrl": "file:///example"]]],
            ["sessionId": ""], ["usage": ["total": 0, "input": 0, "output": 3]]
        ]
        for mutation in mutations {
            let data = try JSONSerialization.data(withJSONObject: receipt.merging(mutation) { $1 })
            XCTAssertThrowsError(try dialect.replyOutput(data, task: task, inputCharacters: 4, directory: FileManager.default.temporaryDirectory))
        }
        XCTAssertFalse(dialect.acceptsVersion("OpenClaw 2026.11.6"))
    }

    func testNativeFailureClassificationAndPayloadTrailingWhitespace() throws {
        func failure(_ status: String, _ kind: String, _ message: String, exitCode: Int32) throws -> MailpipeError {
            let event: [String: Any] = ["ok": false, "status": status, "error": ["kind": kind, "message": message]]
            return dialect.runFailure(ProcessOutput(stdout: try JSONSerialization.data(withJSONObject: event), exitCode: exitCode))
        }
        XCTAssertEqual(try failure("timeout", "timeout", "Agent run timed out", exitCode: 2), .timedOut)
        XCTAssertEqual(try failure("error", "exception", #"No API key found for provider "deepseek"."#, exitCode: 1), .authRequired)
        XCTAssertEqual(try failure("error", "exception", "config validation timed out", exitCode: 1), .processFailed)
        let text = try XCTUnwrap(receipt["final"] as? String)
        let event = receipt.merging(["payloads": [["text": text + " \n\t"]]]) { $1 }
        let output = try dialect.replyOutput(JSONSerialization.data(withJSONObject: event), task: task,
                                             inputCharacters: 4, directory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(output.content, ReplySyntheticFixture.draft)
    }

    func testExplicitPullRequestReadIsUnsupportedBeforeInference() throws {
        let root = try TemporaryDirectory()
        var request = try ReplyDraftRequest(message: ReplySyntheticFixture.triage.message)
        request.approvedPullRequest = "https://github.com/example/repository/pull/1"
        XCTAssertThrowsError(try dialect.replyInvocation(task: .draft(request), schema: "", stdin: Data(), directory: root.url,
                                                         executable: root.url.appendingPathComponent("fake"), environment: [:])) {
            XCTAssertEqual($0 as? MailpipeError, .unsafeCapability)
        }
    }
}
