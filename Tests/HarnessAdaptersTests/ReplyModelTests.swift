import XCTest
@testable import HarnessAdapters
import MailpipeCore

@MainActor
final class ReplyModelTests: XCTestCase {
    func testCodexRequiresCompletedTurnAndRejectsToolEvents() throws {
        let dialect = CodexCLIDialect()
        let root = try TemporaryDirectory()
        let start = [#"{"type":"thread.started","thread_id":"fixture"}"#, #"{"type":"turn.started"}"#]
        let message = #"{"type":"item.completed","item":{"type":"agent_message","text":"{}"}}"#
        let end = #"{"type":"turn.completed","usage":{"input_tokens":8,"output_tokens":2}}"#
        func decode(_ events: [String]) throws -> ReplyModelOutput {
            try dialect.replyOutput(Data(events.joined(separator: "\n").utf8), task: .triage(ReplySyntheticFixture.triage),
                                    inputCharacters: 3, directory: root.url)
        }
        let output = try decode(start + [message, end])
        XCTAssertEqual(output.inputTokens, 8)
        XCTAssertEqual(output.content, Data("{}".utf8))
        XCTAssertThrowsError(try decode(start + [message]))
        XCTAssertThrowsError(try decode(start + [message, message, end]))
        XCTAssertThrowsError(try decode(start + [#"{"type":"item.started","item":{"type":"command_execution"}}"#, message, end])) {
            XCTAssertEqual($0 as? MailpipeError, .unsafeCapability)
        }
        XCTAssertFalse(dialect.acceptsVersion("codex-cli 0.169.2"))
    }

    func testOnlyAutomaticDraftsOfferTheNoReplySchema() async throws {
        let root = try TemporaryDirectory(), dialect = DeepSeekHarnessDialect()
        let draft = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ReplySchemas.draft.utf8)) as? NSDictionary)
        let instructions = "Use two sentences.\nDescribe https://github.com/example/sample/pull/42 as \"the proposal\"."
        for automatic in [false, true] {
            let message = automatic ? MailInput(messageRef: "receipt", subject: "Payment received", body: "Your payment was received.") : ReplySyntheticFixture.triage.message
            let request = try ReplyDraftRequest(message: message, allowsNoReply: automatic,
                                                replyInstructions: automatic ? instructions : nil)
            var result: [String: Any] = ["schema_version": 1, "request_id": request.requestID,
                "triage_request_id": request.triageRequestID, "message_ref": request.message.messageRef]
            if automatic {
                result["disposition"] = "no_reply"
            } else {
                result["subject"] = "Re: Example"
                result["body"] = "I confirm receipt."
            }
            let answer = try JSONSerialization.data(withJSONObject: result)
            let runner = RecordingRunner(inspectionOutputs(dialect) + [ProcessOutput(stdout: try deepseekEvents(answer))])
            let adapter = DeepSeekHarnessAdapter(executable: root.url.appendingPathComponent("fake"), dialect: dialect,
                runner: runner, temporaryRoot: root.url, environment: ["HOME": root.url.path])
            let output = try await adapter.run(.draft(request), route: AccountRoute(accountID: "test", allowedHarnesses: [.deepseek])) {}
            let outcome = try ReplyDraftOutcome.validated(output.content, for: request)
            let calls = await runner.calls
            XCTAssertEqual(calls.count, 3)
            let call = try XCTUnwrap(calls.last)
            let input = try XCTUnwrap(JSONSerialization.jsonObject(with: call.stdin) as? [String: Any])
            let payload = try XCTUnwrap(input["request"] as? [String: Any])
            XCTAssertFalse(call.arguments.joined().contains(instructions))
            XCTAssertNil(call.environment["MAILPIPE_PR_REVIEW"])
            let schema = try XCTUnwrap(input["output_schema"] as? NSDictionary)
            if automatic {
                XCTAssertEqual(payload["reply_instructions"] as? String, instructions)
                XCTAssertEqual(outcome, .noReply)
                let choices = try XCTUnwrap(schema["oneOf"] as? [NSDictionary])
                XCTAssertEqual(choices.count, 2)
                XCTAssertEqual(choices.first, draft)
                let noReply = try XCTUnwrap(choices.last)
                let fields = try XCTUnwrap(noReply["properties"] as? [String: [String: Any]])
                XCTAssertEqual(fields["disposition"]?["enum"] as? [String], ["no_reply"])
                XCTAssertEqual(Set(noReply["required"] as? [String] ?? []), Set(fields.keys))
                XCTAssertEqual(noReply["additionalProperties"] as? Bool, false)
            } else {
                XCTAssertNil(payload["reply_instructions"])
                XCTAssertEqual(outcome, .draft(try ReplyDraft.validated(answer, for: request)))
                XCTAssertEqual(schema, draft)
            }
        }
    }
    func testRegenerationWithALinkedPullRequestKeepsTheReaderDisabled() throws {
        let root = try TemporaryDirectory(), dialect = DeepSeekHarnessDialect()
        let message = MailInput(messageRef: "example", subject: "Review", body: "https://github.com/example/sample/pull/42")
        let draft = try ReplyDraftRequest(message: message, allowsPullRequestReview: false)
        let invocation = try dialect.replyInvocation(task: .draft(draft), schema: ReplySchemas.draft, stdin: Data(),
            directory: root.url, executable: root.url.appendingPathComponent("fake"), environment: ["MAILPIPE_PR_REVIEW": "1"])
        XCTAssertNil(invocation.environment["MAILPIPE_PR_REVIEW"])
        let output = try dialect.replyOutput(deepseekEvents(Data("{}".utf8)), task: .draft(draft),
                                             inputCharacters: 0, directory: root.url)
        XCTAssertNil(output.readPullRequestDiff)
        XCTAssertEqual(try ReplyDraftRequest(message: message).pullRequestReviewTarget, message.body)
    }

    func testTypedReplyChecksLiveAuthorizationBeforeLaunchingModel() async throws {
        let root = try TemporaryDirectory(), dialect = DeepSeekHarnessDialect()
        let runner = RecordingRunner(inspectionOutputs(dialect))
        let adapter = DeepSeekHarnessAdapter(executable: root.url.appendingPathComponent("fake"), dialect: dialect,
            runner: runner, temporaryRoot: root.url)
        do {
            _ = try await adapter.run(.triage(ReplySyntheticFixture.triage), route: AccountRoute(accountID: "test", allowedHarnesses: [.deepseek])) {
                throw MailpipeError.paused
            }
            XCTFail("paused")
        } catch { XCTAssertEqual(error as? MailpipeError, .paused) }
        let calls = await runner.calls; XCTAssertEqual(calls.count, 2)
    }
    func testTypedReplyRetainsZeroToolEnvelopeAndStdinBoundary() async throws {
        let root = try TemporaryDirectory(), dialect = DeepSeekHarnessDialect()
        let runner = RecordingRunner(inspectionOutputs(dialect) + [ProcessOutput(stdout: try deepseekEvents(ReplySyntheticFixture.decision))])
        let adapter = DeepSeekHarnessAdapter(executable: root.url.appendingPathComponent("fake"), dialect: dialect,
            runner: runner, temporaryRoot: root.url)
        let output = try await adapter.run(.triage(ReplySyntheticFixture.triage), route: AccountRoute(accountID: "test", allowedHarnesses: [.deepseek])) {}
        XCTAssertEqual(try ReplyDecision.validated(output.content, for: ReplySyntheticFixture.triage).shouldReply, .yes)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 3)
        let call = try XCTUnwrap(calls.last)
        XCTAssertTrue(String(decoding: call.stdin, as: UTF8.self).contains("colleague@example.com"))
        XCTAssertFalse(call.arguments.joined().contains("colleague@example.com"))
        XCTAssertTrue(call.arguments.contains("read-only"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: call.workingDirectory.path))
    }
}
