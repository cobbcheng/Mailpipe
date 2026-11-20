import XCTest
@testable import MailpipeCore

final class ReplyContractTests: XCTestCase {
    func decision(_ reply: String = "yes") throws -> ReplyDecision {
        let data = Data(String(decoding: ReplySyntheticFixture.decision, as: UTF8.self)
            .replacingOccurrences(of: "\"should_reply\":\"yes\"", with: "\"should_reply\":\"\(reply)\"").utf8)
        return try ReplyDecision.validated(data, for: ReplySyntheticFixture.triage)
    }
    func testServiceLevelsAndUnknownDoNotGenerate() throws {
        XCTAssertEqual(ServiceLevel.default, .l2)
        for reply in ["yes", "no", "unknown"] {
            let value = try decision(reply)
            XCTAssertEqual(ServiceLevel.l0.disposition(for: value), .none)
            XCTAssertEqual(ServiceLevel.l1.disposition(for: value), reply == "yes" ? .needsReply : .none)
            XCTAssertEqual(ServiceLevel.l2.disposition(for: value), reply == "yes" ? .generateDraft : .none)
            for level in ServiceLevel.allCases {
                if reply != "yes" || level != .l2 {
                    XCTAssertThrowsError(try ReplyDraftRequest(requestID: "draft", triage: ReplySyntheticFixture.triage, decision: value, level: level))
                }
            }
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ServiceLevel.self, from: Data("\"l3\"".utf8)))
    }
    func testDraftIsBoundToValidatedContent() throws {
        let value = try decision()
        let changed = ReplyTriageRequest(requestID: ReplySyntheticFixture.triage.requestID,
            message: MailInput(messageRef: value.messageRef, subject: "Changed", body: "Changed"))
        XCTAssertThrowsError(try ReplyDraftRequest(requestID: "draft", triage: changed, decision: value))
        let unvalidated = try JSONDecoder().decode(ReplyDecision.self, from: ReplySyntheticFixture.decision)
        XCTAssertThrowsError(try ReplyDraftRequest(requestID: "draft", triage: ReplySyntheticFixture.triage, decision: unvalidated))
        let request = try ReplyDraftRequest(requestID: "synthetic-draft", triage: ReplySyntheticFixture.triage, decision: value)
        XCTAssertFalse(try ReplyDraft.validated(ReplySyntheticFixture.draft, for: request).body.isEmpty)
        var row = try JSONSerialization.jsonObject(with: ReplySyntheticFixture.draft) as! [String: Any]
        for (key, bad) in [("request_id", "foreign"), ("triage_request_id", "foreign"), ("message_ref", "foreign"),
                           ("subject", "Header\r\nInjected"), ("body", " "), ("body", String(repeating: "x", count: 16_385)),
                           ("send", "true"), ("to", "other@example.com")] {
            let original = row[key]; row[key] = bad
            XCTAssertThrowsError(try ReplyDraft.validated(JSONSerialization.data(withJSONObject: row), for: request))
            row[key] = original
        }
    }
    func testTriageRejectsActionsAndInventedEvidence() throws {
        var row = try JSONSerialization.jsonObject(with: ReplySyntheticFixture.decision) as! [String: Any]
        for (key, bad) in [("request_id", "foreign"), ("message_ref", "foreign"), ("should_reply", "maybe"), ("action", "send")] {
            let original = row[key]; row[key] = bad
            XCTAssertThrowsError(try ReplyDecision.validated(JSONSerialization.data(withJSONObject: row), for: ReplySyntheticFixture.triage))
            row[key] = original
        }
        row["evidence"] = [["field": "body", "text": "invented evidence"]]
        XCTAssertThrowsError(try ReplyDecision.validated(JSONSerialization.data(withJSONObject: row), for: ReplySyntheticFixture.triage))
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
    func testTriageReportsRejectedValidationStage() throws {
        let request = ReplySyntheticFixture.triage
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: ReplySyntheticFixture.decision) as? [String: Any])
        for (key, value, expected): (String, Any, MailpipeError) in [
            ("request_id", "other", .outputReference), ("should_reply", true, .outputFields),
            ("summary", [], .outputSummary), ("evidence", [["field": "body", "text": "invented"]], .outputEvidence)
        ] {
            var row = valid
            row[key] = value
            XCTAssertThrowsError(try ReplyDecision.validated(JSONSerialization.data(withJSONObject: row), for: request)) {
                XCTAssertEqual($0 as? MailpipeError, expected)
            }
        }
        XCTAssertThrowsError(try ReplyDecision.validated(Data("invalid".utf8), for: request)) {
            XCTAssertEqual($0 as? MailpipeError, .outputJSON)
        }
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
}
