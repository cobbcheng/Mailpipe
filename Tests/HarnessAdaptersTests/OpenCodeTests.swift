import Foundation
import XCTest
import MailpipeCore
@testable import HarnessAdapters
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

final class OpenCodeTests: XCTestCase {
    private let task = ReplyModelTask.triage(ReplySyntheticFixture.triage)
    private let model = "fixture/test-chat"
    private let steps = [
        #"{"type":"step_start","sessionID":"session","part":{"type":"step-start","messageID":"message","sessionID":"session"}}"#,
        #"{"type":"text","sessionID":"session","part":{"type":"text","messageID":"message","sessionID":"session","text":"reply"}}"#,
        #"{"type":"step_finish","sessionID":"session","part":{"type":"step-finish","messageID":"message","sessionID":"session","reason":"stop","tokens":{"input":12,"output":4,"reasoning":6,"cache":{"read":2,"write":1}}}}"#
    ]

    private func installReceipt(in directory: URL) {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("opencode.db").path, &db), SQLITE_OK)
        let sql = """
            CREATE TABLE session_message(session_id TEXT, id TEXT PRIMARY KEY, type TEXT, data TEXT);
            INSERT INTO session_message VALUES ('session','message','assistant','{"model":{"providerID":"fixture","id":"test-chat"},"agent":"mailpipe","finish":"stop"}');
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    func testReceiptMatchesAssistantAndPinnedModelAndAddsTokenBuckets() throws {
        let root = try TemporaryDirectory()
        installReceipt(in: root.url)
        let stream = Data(steps.joined(separator: "\n").utf8)
        let output = try OpenCodeDialect(model: model).replyOutput(stream, task: task, inputCharacters: 82, directory: root.url)
        XCTAssertEqual(output.actualModel, model)
        XCTAssertEqual(output.content, Data("reply".utf8))
        XCTAssertEqual(output.inputTokens, 15)
        XCTAssertEqual(output.outputTokens, 10)
        XCTAssertEqual(output.outputCharacters, 5)
        XCTAssertThrowsError(try OpenCodeDialect(model: "fixture/other").replyOutput(stream, task: task,
                                                                                inputCharacters: 1, directory: root.url))
        let unrelated = Data(String(decoding: stream, as: UTF8.self).replacingOccurrences(of: #""messageID":"message""#,
                                                                                  with: #""messageID":"other""#).utf8)
        XCTAssertThrowsError(try OpenCodeDialect().replyOutput(unrelated, task: task, inputCharacters: 1, directory: root.url))
    }

    func testRejectsIncompleteRepeatedToolAndForeignSteps() throws {
        let root = try TemporaryDirectory(), dialect = OpenCodeDialect()
        installReceipt(in: root.url)
        for lines in [Array(steps.dropLast()), [steps[0], steps[0], steps[1], steps[2]],
                      [steps[0], steps[1].replacingOccurrences(of: #""type":"text""#, with: #""type":"tool_use""#), steps[2]],
                      [steps[0], steps[1].replacingOccurrences(of: #""sessionID":"session""#, with: #""sessionID":"other""#), steps[2]],
                      [steps[0], steps[1], steps[2].replacingOccurrences(of: #""stop""#, with: #""length""#)]] {
            XCTAssertThrowsError(try dialect.replyOutput(Data(lines.joined(separator: "\n").utf8), task: task,
                                                        inputCharacters: 10, directory: root.url))
        }
    }

    func testMetadataAndInvocationUseOnlySelectedModelAndPrivateServer() throws {
        let root = try TemporaryDirectory(), work = root.url.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let cli = root.url.appendingPathComponent("opencode")
        let dialect = OpenCodeDialect(model: model)
        XCTAssertTrue(dialect.acceptsVersion("opencode v2.3.0"))
        XCTAssertFalse(dialect.acceptsVersion("opencode v2.3.1"))
        let stdin = Data("synthetic message".utf8)
        let call = try dialect.replyInvocation(task: task, schema: "{}", stdin: stdin, directory: work,
                                               executable: cli, environment: ["HOME": root.url.path])
        XCTAssertEqual(call.arguments, ["run", "--standalone", "--agent", "mailpipe", "--title", "Mailpipe",
                                        "--format", "json", "--log-level", "none", "--model", model])
        XCTAssertEqual(call.stdin, stdin)
        XCTAssertEqual(call.environment["OPENCODE_DB"], work.appendingPathComponent("opencode.db").path)
        XCTAssertNotEqual(call.environment["HOME"], root.url.path)

        let ordinary = try ReplyDraftRequest(message: MailInput(messageRef: "one", subject: "Test", body: "Confirm receipt."))
        XCTAssertThrowsError(try OpenCodeDialect().replyInvocation(task: .draft(ordinary), schema: "{}", stdin: stdin,
                                                                   directory: work, executable: cli, environment: [:]))
        var pr = ordinary
        pr.approvedPullRequest = "https://github.com/example/project/pull/1"
        XCTAssertThrowsError(try dialect.replyInvocation(task: .draft(pr), schema: "{}", stdin: stdin, directory: work,
                                                        executable: cli, environment: [:]))
        for bad in ["", "unknown", "/empty", "provider/", "provider/model#variant", "provider/m\nodel"] {
            XCTAssertFalse(OpenCodeDialect.validModelReference(bad))
        }
    }
}
