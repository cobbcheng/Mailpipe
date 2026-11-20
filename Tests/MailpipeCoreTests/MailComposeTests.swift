import XCTest
@testable import MailpipeCore

final class MailComposeTests: XCTestCase {
    func testPreexistingComposeReceiptsDecodeAsPrefilledAndNativeWindowReceiptsRoundTrip() throws {
        let oldRecord = Data(#"{"outgoingID":"42"}"#.utf8)
        let old = try JSONDecoder().decode(MailComposeReceipt.self, from: oldRecord)
        XCTAssertEqual(old.kind, .prefilledMessage)
        XCTAssertEqual(old, MailComposeReceipt(outgoingID: "42"))
        let native = MailComposeReceipt(outgoingID: "42", kind: .nativeReplyWindow)
        XCTAssertEqual(try JSONDecoder().decode(MailComposeReceipt.self, from: JSONEncoder().encode(native)), native)
    }

    func testReplyToPrecedenceAndFailClosed() throws {
        func raw(_ extra: String) -> Data { Data(("From: original@example.com\n" + extra + "\n\nbody").utf8) }
        XCTAssertEqual(try MailReplyRecipients.parse(raw("")), ["original@example.com"])
        XCTAssertEqual(try MailReplyRecipients.parse(raw("Reply-To: Replies <reply@example.com>")), ["reply@example.com"])
        XCTAssertThrowsError(try MailReplyRecipients.parse(raw("Reply-To: broken")))
        XCTAssertThrowsError(try MailReplyRecipients.parse(raw("Reply-To: a@example.com\nReply-To: b@example.com")))
    }
    func testNoHeaderInjectionOrEmptyBody() throws {
        func request(_ subject: String, _ body: String, _ recipient: String) throws -> MailComposeRequest {
            try MailComposeRequest(recordID: "1", accountID: "a", accountName: "Test", sender: "me@example.com", recipients: [recipient], subject: subject, body: body, originalSubject: "Original", messageID: "id", localID: "1", sourceDigest: "digest", settingsRevision: UUID())
        }
        XCTAssertThrowsError(try request("Subject\nBcc: hidden@example.com", "body", "to@example.com"))
        XCTAssertThrowsError(try request("Subject", " ", "to@example.com"))
        XCTAssertThrowsError(try request("Subject", "body", "to@example.com\r\nBcc:hidden@example.com"))
        for body in ["短回复。", String(repeating: "长正文\n第二行。\n", count: 100)] {
            XCTAssertEqual(try request("Re: 中文主题", body, "to@example.com").body, body)
        }
    }
}
