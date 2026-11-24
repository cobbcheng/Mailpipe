import XCTest
@testable import HarnessAdapters
import MailpipeCore

@MainActor
final class ReplyModelTests: XCTestCase {
    func testCodexRequiresCompletedTurnAndRejectsToolEvents() throws {
        let dialect = CodexCLIDialect()
        let root = try TemporaryDirectory()
        let request = try ReplyDraftRequest(message: ReplySyntheticFixture.message)
        let start = [#"{"type":"thread.started","thread_id":"fixture"}"#, #"{"type":"turn.started"}"#]
        let message = #"{"type":"item.completed","item":{"type":"agent_message","text":"{}"}}"#
        let end = #"{"type":"turn.completed","usage":{"input_tokens":8,"output_tokens":2}}"#
        func decode(_ events: [String]) throws -> ReplyModelOutput {
            try dialect.replyOutput(Data(events.joined(separator: "\n").utf8), task: .draft(request),
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
        XCTAssertTrue(dialect.acceptsVersion("codex-cli 0.169.1"))
        XCTAssertTrue(dialect.acceptsVersion("codex-cli 0.171.0-alpha.14"))
        XCTAssertFalse(dialect.acceptsVersion("codex-cli 0.169.0"))
        XCTAssertFalse(dialect.acceptsVersion("codex-cli 1.0.0"))
    }

    func testRestrictedAdaptersDeliverEnglishHostInstructions() throws {
        let root = try TemporaryDirectory()
        let fake = root.url.appendingPathComponent("fake")
        let env = ["HOME": root.url.path]
        let task = ReplyModelTask.draft(try ReplyDraftRequest(message: ReplySyntheticFixture.message))

        let claude = try ClaudeCodeDialect().replyInvocation(task: task, schema: ReplySchemas.draft,
            stdin: Data(), directory: root.url, executable: fake, environment: env)
        let flag = try XCTUnwrap(claude.arguments.firstIndex(of: "--system-prompt"))
        let claudePrompt = try XCTUnwrap(claude.arguments.dropFirst(flag + 1).first)

        let openCode = try OpenCodeProfile.prepare(directory: root.url.appendingPathComponent("opencode"),
            executable: fake, environment: env)
        let content = try XCTUnwrap(openCode["OPENCODE_CONFIG_CONTENT"])
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        let agents = try XCTUnwrap(config["agents"] as? [String: [String: Any]])
        let openCodePrompt = try XCTUnwrap(agents["mailpipe"]?["system"] as? String)

        let claw = OpenClawDialect(), work = root.url.appendingPathComponent("openclaw")
        let clawEnv = try claw.prepare(directory: work, executable: fake, environment: env)
        let run = try claw.replyInvocation(task: task, schema: ReplySchemas.draft, stdin: Data(),
            directory: work, executable: fake, environment: clawEnv)
        let clawPrompt = try String(contentsOf: run.workingDirectory.appendingPathComponent("AGENTS.md"), encoding: .utf8)

        for prompt in [claudePrompt, openCodePrompt, clawPrompt] {
            XCTAssertNil(prompt.range(of: #"\p{Han}"#, options: .regularExpression))
            XCTAssertTrue(prompt.contains("request.reply_instructions"))
            XCTAssertTrue(prompt.contains("user's customary language and tone"))
            XCTAssertTrue(prompt.contains("No lookup tools"))
        }
        XCTAssertTrue(claudePrompt.contains("runtime environment"))
        XCTAssertTrue(openCodePrompt.contains("Omit the signature"))
        XCTAssertTrue(clawPrompt.contains("output_schema"))
    }

    func testOnlyAutomaticDraftsOfferTheNoReplySchema() async throws {
        let root = try TemporaryDirectory(), dialect = DeepSeekHarnessDialect()
        let draft = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ReplySchemas.draft.utf8)) as? NSDictionary)
        let instructions = "Use two sentences.\nDescribe https://github.com/example/sample/pull/42 as \"the proposal\"."
        for automatic in [false, true] {
            let message = automatic ? MailInput(messageRef: "receipt", subject: "Payment received", body: "Your payment was received.") : ReplySyntheticFixture.message
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

    func testRegenerationWithoutExternalContextKeepsThePRReaderDisabled() throws {
        let root = try TemporaryDirectory(), dialect = DeepSeekHarnessDialect()
        let message = MailInput(messageRef: "example", subject: "Review", body: "https://github.com/example/sample/pull/42")
        let draft = try ReplyDraftRequest(message: message)
        let invocation = try dialect.replyInvocation(task: .draft(draft), schema: ReplySchemas.draft, stdin: Data(),
            directory: root.url, executable: root.url.appendingPathComponent("fake"), environment: ["MAILPIPE_PR_REVIEW": "1"])
        XCTAssertNil(invocation.environment["MAILPIPE_PR_REVIEW"])
        let output = try dialect.replyOutput(deepseekEvents(Data("{}".utf8)), task: .draft(draft),
                                             inputCharacters: 0, directory: root.url)
        XCTAssertNil(output.readPullRequestDiff)
        XCTAssertEqual(GitHubPullRequestLink.first(in: message.body), message.body)
    }

    func testTypedReplyChecksLiveAuthorizationBeforeLaunchingModel() async throws {
        let root = try TemporaryDirectory(), dialect = DeepSeekHarnessDialect()
        let request = try ReplyDraftRequest(message: ReplySyntheticFixture.message)
        let runner = RecordingRunner(inspectionOutputs(dialect))
        let adapter = DeepSeekHarnessAdapter(executable: root.url.appendingPathComponent("fake"), dialect: dialect,
            runner: runner, temporaryRoot: root.url)
        do {
            _ = try await adapter.run(.draft(request), route: AccountRoute(accountID: "test", allowedHarnesses: [.deepseek])) {
                throw MailpipeError.paused
            }
            XCTFail("paused")
        } catch { XCTAssertEqual(error as? MailpipeError, .paused) }
        let calls = await runner.calls; XCTAssertEqual(calls.count, 2)
    }

    func testTypedReplyRetainsZeroToolEnvelopeAndStdinBoundary() async throws {
        let root = try TemporaryDirectory(), dialect = DeepSeekHarnessDialect()
        let request = try ReplyDraftRequest(message: ReplySyntheticFixture.message)
        let runner = RecordingRunner(inspectionOutputs(dialect) + [ProcessOutput(stdout: try deepseekEvents(ReplySyntheticFixture.draft))])
        let adapter = DeepSeekHarnessAdapter(executable: root.url.appendingPathComponent("fake"), dialect: dialect,
            runner: runner, temporaryRoot: root.url)
        let output = try await adapter.run(.draft(request), route: AccountRoute(accountID: "test", allowedHarnesses: [.deepseek])) {}
        XCTAssertFalse(try ReplyDraft.validated(output.content, for: request).body.isEmpty)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 3)
        let call = try XCTUnwrap(calls.last)
        XCTAssertTrue(String(decoding: call.stdin, as: UTF8.self).contains("colleague@example.com"))
        XCTAssertFalse(call.arguments.joined().contains("colleague@example.com"))
        XCTAssertTrue(call.arguments.contains("read-only"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: call.workingDirectory.path))
    }
}
