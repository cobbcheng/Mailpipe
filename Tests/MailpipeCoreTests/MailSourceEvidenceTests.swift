import XCTest
@testable import MailpipeCore

final class MailSourceEvidenceTests: XCTestCase {
    func message(type: String = "text/plain; charset=utf-8", body: String = "Please confirm Friday.", extra: String = "") -> Data {
        Data(("From: Tester <sender@example.com>\r\nTo: recipient@example.com\r\n"
            + "Date: Tue, 17 Nov 2026 08:00:00 +0000\r\nSubject: Synthetic\r\n"
            + "Message-ID: <plain@example.com>\r\nMIME-Version: 1.0\r\n"
            + "Content-Type: \(type)\r\n" + extra + "\r\n" + body + "\r\n").utf8)
    }

    func testMissingParametersAndRewrittenTransportHeadersStillMatch() throws {
        let captured = message(type: "text/plain")
        let evidence = try XCTUnwrap(MailSourceEvidence(captured))
        var full = String(decoding: message(), as: UTF8.self)
        full = "Received: by synthetic.example.com\r\n" + full
        full = full.replacingOccurrences(of: "To: recipient@example.com", with: "To: \"Test Recipient\" <recipient@example.com>")
        full = full.replacingOccurrences(of: "Subject: Synthetic", with: "Subject:\r\n Synthetic")
        XCTAssertTrue(evidence.matches(Data(full.replacingOccurrences(of: "\r\n", with: "\n").utf8)))
        XCTAssertFalse(evidence.matches(message(type: "text/html; charset=utf-8")))
        XCTAssertFalse(try XCTUnwrap(MailSourceEvidence(message())).matches(message(type: "text/plain; charset=gbk")))
    }

    func testMessageContentAndStableHeadersCannotChange() throws {
        let raw = message(extra: "Reply-To: replies@example.com\r\n")
        let evidence = try XCTUnwrap(MailSourceEvidence(raw))
        for (old, new) in [
            ("sender@example.com", "attacker@example.com"),
            ("recipient@example.com", "another@example.com"),
            ("replies@example.com", "attacker@example.com"),
            ("Subject: Synthetic", "Subject: Other"),
            ("08:00:00", "08:01:00"),
            ("plain@example.com", "other@example.com"),
            ("Please confirm Friday.", "Different content."),
            ("MIME-Version: 1.0", "MIME-Version: 2.0"),
            ("Content-Type: text/plain; charset=utf-8", "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64")
        ] {
            XCTAssertFalse(evidence.matches(Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: old, with: new).utf8)), old)
        }
        let attached = message(extra: "Reply-To: replies@example.com\r\nContent-Disposition: attachment\r\n")
        XCTAssertFalse(evidence.matches(attached))
    }

    func testMissingBoundaryCanMatchOnlyUnchangedCompleteMIMEPayload() throws {
        let payload = "--boundary\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n请确认周五。\r\n--boundary--"
        let captured = message(type: "multipart/alternative", body: payload)
        let full = message(type: "multipart/alternative; boundary=boundary", body: payload)
        let evidence = try XCTUnwrap(MailSourceEvidence(captured))
        XCTAssertTrue(evidence.matches(full))
        XCTAssertThrowsError(try PlainMailBody.decode(captured))
        XCTAssertEqual(try PlainMailBody.decode(full), "请确认周五。")
        XCTAssertFalse(evidence.matches(message(type: "multipart/alternative; boundary=boundary", body: payload + "CHANGED")))
        let encoded = try JSONEncoder().encode(evidence)
        XCTAssertTrue(try JSONDecoder().decode(MailSourceEvidence.self, from: encoded).matches(full))
    }

    func testEquivalentChineseSubjectEncodingsMatch() throws {
        let subjects = ["你好", "=?utf-8?B?5L2g5aW9?=", "=?UTF-8?b?5L2g5aW9?=",
                        "=?UTF-8?Q?=E4=BD=A0=E5=A5=BD?=", "=?utf-8?B?5L2g?=\r\n =?utf-8?B?5aW9?="]
        func raw(_ subject: String) -> Data {
            Data(String(decoding: message(), as: UTF8.self).replacingOccurrences(of: "Subject: Synthetic", with: "Subject: " + subject).utf8)
        }
        for subject in subjects {
            let evidence = try XCTUnwrap(MailSourceEvidence(raw(subject)))
            let restored = try JSONDecoder().decode(MailSourceEvidence.self, from: JSONEncoder().encode(evidence))
            for equivalent in subjects { XCTAssertTrue(restored.matches(raw(equivalent))) }
            XCTAssertFalse(restored.matches(raw("不同")))
            XCTAssertFalse(restored.matches(raw("=?unknown?B?5L2g5aW9?=")))
            XCTAssertFalse(restored.matches(raw("=?utf-8?B?broken?=")))
        }
    }

    func testPersistedLegacyMailKitSubjectEvidenceRemainsVerifiable() throws {
        // Old evidence hashed the encoded subject literally, without a version field.
        let headers = ["from": "sender@example.com", "to": "recipient@example.com",
            "date": "Tue, 17 Nov 2026 08:00:00 +0000", "subject": "=?utf-8?B?5L2g5aW9?=",
            "message-id": "<plain@example.com>", "cc": "", "reply-to": "", "in-reply-to": "",
            "references": "", "mime-version": "1.0", "content-type": "text/plain",
            "content-transfer-encoding": "7bit", "content-disposition": ""]
        let legacy: [String: Any] = [
            "headerDigest": contentDigest(try JSONSerialization.data(withJSONObject: headers, options: [.sortedKeys])),
            "bodyDigest": contentDigest(Data("Please confirm Friday.".utf8)), "parameters": ["charset": "utf-8"]]
        let evidence = try JSONDecoder().decode(MailSourceEvidence.self, from: JSONSerialization.data(withJSONObject: legacy))
        let full = String(decoding: message(), as: UTF8.self).replacingOccurrences(of: "Subject: Synthetic", with: "Subject: =?UTF-8?Q?=E4=BD=A0=E5=A5=BD?=")
        XCTAssertTrue(evidence.matches(Data(full.utf8)))
        for (old, new) in [("sender@example.com", "other@example.com"), ("Please confirm Friday.", "Changed"),
                           ("=E4=BD=A0=E5=A5=BD", "=E4=BD=A0")] {
            XCTAssertFalse(evidence.matches(Data(full.replacingOccurrences(of: old, with: new).utf8)))
        }
        var future = legacy; future["subjectVersion"] = 99
        XCTAssertFalse(try JSONDecoder().decode(MailSourceEvidence.self, from: JSONSerialization.data(withJSONObject: future)).matches(Data(full.utf8)))
    }

    func testInsufficientOrAmbiguousEvidenceFailsClosed() throws {
        XCTAssertNil(MailSourceEvidence(Data("Content-Type: text/plain\r\n\r\nbody".utf8)))
        for header in ["From: second@example.com", "To: second@example.com", "Subject: Other", "Message-ID: <other@example.com>"] {
            XCTAssertNil(MailSourceEvidence(message(extra: header + "\r\n")))
        }
        let noBody = String(decoding: message(), as: UTF8.self).components(separatedBy: "\r\n\r\n")[0]
        XCTAssertNil(MailSourceEvidence(Data(noBody.utf8)))
    }
}
