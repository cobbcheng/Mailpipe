import XCTest
@testable import HarnessAdapters
import MailpipeCore

@MainActor
final class ReplyModelTests: XCTestCase {
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
