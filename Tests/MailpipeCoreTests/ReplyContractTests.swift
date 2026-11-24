import XCTest
@testable import MailpipeCore

final class ReplyContractTests: XCTestCase {
    func testDraftValidationRejectsForeignFieldsAndUnsafeKeys() throws {
        let request = try ReplyDraftRequest(message: ReplySyntheticFixture.message)
        XCTAssertFalse(try ReplyDraft.validated(ReplySyntheticFixture.draft, for: request).body.isEmpty)
        var row = try JSONSerialization.jsonObject(with: ReplySyntheticFixture.draft) as! [String: Any]
        for (key, bad) in [("request_id", "foreign"), ("triage_request_id", "foreign"), ("message_ref", "foreign"),
                           ("subject", "Header\r\nInjected"), ("body", " "), ("body", String(repeating: "x", count: 16_385)),
                           ("send", "true"), ("to", "other@example.com")] {
            let original = row[key]; row[key] = bad
            XCTAssertThrowsError(try ReplyDraft.validated(JSONSerialization.data(withJSONObject: row), for: request))
            row[key] = original
        }
        XCTAssertThrowsError(try ReplyDraft.validated(Data(repeating: 32, count: 262_145), for: request)) {
            XCTAssertEqual($0 as? MailpipeError, .outputLimit)
        }
        XCTAssertThrowsError(try ReplyDraft.validated(Data("```json\n{}\n```".utf8), for: request)) {
            XCTAssertEqual($0 as? MailpipeError, .outputJSON)
        }
    }

    func testInvalidInputBoundsAreRejected() throws {
        let oversize = MailInput(messageRef: "m", subject: "s", body: String(repeating: "x", count: 16_385))
        XCTAssertThrowsError(try ReplyDraftRequest(message: oversize))
        let emptyRef = MailInput(messageRef: "", subject: "s", body: "body")
        XCTAssertThrowsError(try ReplyDraftRequest(message: emptyRef))
    }

    func testRouteCannotUseUnknownOrDisallowedAccount() throws {
        for route in [AccountRoute(accountID: nil, allowedHarnesses: [.deepseek]),
                      AccountRoute(accountID: " ", allowedHarnesses: [.deepseek])] {
            XCTAssertThrowsError(try route.authorize(.deepseek)) { XCTAssertEqual($0 as? MailpipeError, .unknownAccount) }
        }
        XCTAssertThrowsError(try AccountRoute(accountID: "synthetic", allowedHarnesses: [.deepseek]).authorize(.codex)) {
            XCTAssertEqual($0 as? MailpipeError, .routeNotAllowed)
        }
        XCTAssertThrowsError(try AccountRoute(accountID: "synthetic", allowedHarnesses: [.deepseek], paused: true).authorize(.deepseek)) {
            XCTAssertEqual($0 as? MailpipeError, .paused)
        }
    }

    func testAutomaticDraftCanReturnAnExplicitBoundNoReply() throws {
        let message = MailInput(messageRef: "receipt", subject: "Payment received", body: "Your payment was received.")
        let automatic = try ReplyDraftRequest(message: message, allowsNoReply: true)
        let manual = try ReplyDraftRequest(message: message)
        let row: [String: Any] = [
            "schema_version": 1, "request_id": automatic.requestID, "triage_request_id": automatic.triageRequestID,
            "message_ref": message.messageRef, "disposition": "no_reply"
        ]
        let noReply = try JSONSerialization.data(withJSONObject: row)
        XCTAssertEqual(try ReplyDraftOutcome.validated(noReply, for: automatic), .noReply)
        XCTAssertThrowsError(try ReplyDraftOutcome.validated(noReply, for: manual))
        XCTAssertThrowsError(try ReplyDraft.validated(noReply, for: automatic))
        for (key, value): (String, Any) in [
            ("schema_version", 2), ("schema_version", true), ("disposition", "unknown"), ("request_id", "foreign"),
            ("triage_request_id", "foreign"), ("message_ref", "foreign"), ("action", "dismiss"), ("body", "")
        ] {
            var changed = row
            changed[key] = value
            XCTAssertThrowsError(try ReplyDraftOutcome.validated(JSONSerialization.data(withJSONObject: changed), for: automatic), key)
        }
        for key in row.keys {
            var changed = row
            changed.removeValue(forKey: key)
            XCTAssertThrowsError(try ReplyDraftOutcome.validated(JSONSerialization.data(withJSONObject: changed), for: automatic), key)
        }
        var draft = row
        draft.removeValue(forKey: "disposition")
        draft["subject"] = "Re: Payment received"
        draft["body"] = "Please send a copy to accounting."
        let data = try JSONSerialization.data(withJSONObject: draft)
        for request in [automatic, manual] {
            XCTAssertEqual(try ReplyDraftOutcome.validated(data, for: request), .draft(try ReplyDraft.validated(data, for: request)))
        }
        draft["body"] = " "
        XCTAssertThrowsError(try ReplyDraftOutcome.validated(JSONSerialization.data(withJSONObject: draft), for: automatic))
    }

    func testDestinationEvidenceAndRoundTrip() throws {
        let value = try DataDestination(messageRef: "synthetic", runID: "run", taskKind: .triage, harness: .deepseek)
        XCTAssertNil(value.vendor)
        XCTAssertEqual(try JSONDecoder().decode(DataDestination.self, from: JSONEncoder().encode(value)), value)
        XCTAssertThrowsError(try DataDestination(messageRef: "synthetic", runID: "run", taskKind: .draft, harness: .deepseek, vendor: "local"))
        XCTAssertThrowsError(try DataDestination(messageRef: "synthetic", runID: "run", taskKind: .draft, harness: .deepseek, evidence: .detected))
        let modelOnly = try DataDestination(messageRef: "synthetic", runID: "run", taskKind: .draft,
                                            harness: .claude, model: "deepseek-v4.1-flash", evidence: .detected)
        XCTAssertNil(modelOnly.vendor)
        XCTAssertEqual(try JSONDecoder().decode(DataDestination.self, from: JSONEncoder().encode(modelOnly)), modelOnly)
        var row = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        row["vendor"] = "local"
        XCTAssertThrowsError(try JSONDecoder().decode(DataDestination.self, from: JSONSerialization.data(withJSONObject: row)))
    }

#if canImport(Darwin)
    func testDirectoryWatcherFiresOnFileCreation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mailpipe-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fired = XCTestExpectation(description: "Watcher observed directory write")
        fired.assertForOverFulfill = false
        let watcher = try XCTUnwrap(DirectoryWatcher(directory: dir, label: "com.mailpipe.test.watch") {
            fired.fulfill()
        })
        defer { watcher.stop() }
        try Data("hello".utf8).write(to: dir.appendingPathComponent("item.txt"), options: .atomic)
        let status = await XCTWaiter.fulfillment(of: [fired], timeout: 2)
        XCTAssertEqual(status, .completed)
    }
#endif
}
