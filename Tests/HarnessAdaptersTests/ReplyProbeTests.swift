import XCTest
@testable import HarnessAdapters
import MailpipeCore

@MainActor
final class ReplyProbeTests: XCTestCase {
    func testL2UsesSeparateRestrictedCallsAndDestinations() async throws {
        let root = try TemporaryDirectory(), dialect = DeepSeekHarnessDialect()
        let runner = RecordingRunner(inspectionOutputs(dialect) + [
            ProcessOutput(stdout: try deepseekEvents(ReplySyntheticFixture.decision)),
            ProcessOutput(stdout: try deepseekEvents(ReplySyntheticFixture.draft))])
        let result = try await DeepSeekHarnessAdapter(executable: root.url.appendingPathComponent("fake"), dialect: dialect,
            runner: runner, temporaryRoot: root.url).runSyntheticReplyProbe { _ in }
        XCTAssertNotNil(result.draft)
        XCTAssertEqual(result.runs.count, 2)
        XCTAssertNotEqual(result.runs[0].destination.runID, result.runs[1].destination.runID)
        XCTAssertEqual(result.runs.map(\.destination.taskKind), [.triage, .draft])
        XCTAssertTrue(result.runs.allSatisfy { $0.destination.evidence == .detected && $0.inputTokens == 12 })
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 4)
        for call in calls.suffix(2) {
            XCTAssertTrue(call.arguments.contains("read-only"))
            XCTAssertFalse(call.arguments.joined().contains("example.com"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: call.workingDirectory.path))
        }
    }
    func testNoUnknownAndL1NeverLaunchDraft() async throws {
        for (reply, level) in [("no", ServiceLevel.l2), ("unknown", .l2), ("yes", .l1), ("yes", .l0)] {
            let root = try TemporaryDirectory(), dialect = DeepSeekHarnessDialect()
            let data = Data(String(decoding: ReplySyntheticFixture.decision, as: UTF8.self)
                .replacingOccurrences(of: "\"should_reply\":\"yes\"", with: "\"should_reply\":\"\(reply)\"").utf8)
            let runner = RecordingRunner(inspectionOutputs(dialect) + [ProcessOutput(stdout: try deepseekEvents(data))])
            let result = try await DeepSeekHarnessAdapter(executable: root.url.appendingPathComponent("fake"), dialect: dialect,
                runner: runner, temporaryRoot: root.url).runSyntheticReplyProbe(level: level) { _ in }
            XCTAssertNil(result.draft)
            let calls = await runner.calls
            XCTAssertEqual(calls.count, 3)
        }
    }
    func testMalformedTriageStopsAndRecordsFailure() async throws {
        let root = try TemporaryDirectory(), dialect = DeepSeekHarnessDialect()
        let runner = RecordingRunner(inspectionOutputs(dialect) + [ProcessOutput(stdout: try deepseekEvents(Data("{}".utf8)))])
        let log = root.url.appendingPathComponent("run.json")
        do {
            _ = try await DeepSeekHarnessAdapter(executable: root.url.appendingPathComponent("fake"), dialect: dialect,
                runner: runner, temporaryRoot: root.url).runSyntheticReplyProbe {
                    try JSONEncoder().encode($0).write(to: log, options: .atomic)
                }
            XCTFail("invalid response")
        } catch { XCTAssertEqual(error as? MailpipeError, .invalidOutput) }
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: log)) as! [String: Any]
        XCTAssertEqual(saved["errorCode"] as? String, "invalidOutput")
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 3)
    }
    func testFailedIntentPersistencePreventsModelCall() async throws {
        let root = try TemporaryDirectory(), dialect = DeepSeekHarnessDialect()
        let runner = RecordingRunner(inspectionOutputs(dialect))
        do {
            _ = try await DeepSeekHarnessAdapter(executable: root.url.appendingPathComponent("fake"), dialect: dialect,
                runner: runner, temporaryRoot: root.url).runSyntheticReplyProbe { _ in throw MailpipeError.invalidInput }
            XCTFail("persistence failed")
        } catch { XCTAssertEqual(error as? MailpipeError, .invalidInput) }
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 2)
    }
}

extension ReplyProbeTests {
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
