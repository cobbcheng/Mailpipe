import XCTest
@testable import MailBridge
import MailpipeCore

@MainActor final class MailComposerTests: XCTestCase {
    func testScriptIsComposeOnlyAndDataNotInterpolated() throws {
        XCTAssertTrue(AppleMailComposer.composeScript.contains("make new outgoing message"))
        XCTAssertTrue(AppleMailComposer.composeScript.contains("visible:true"))
        XCTAssertFalse(AppleMailComposer.composeScript.contains("send outgoing"))
        XCTAssertFalse(AppleMailComposer.composeScript.contains("do shell script"))
#if os(macOS)
        for source in [AppleMailComposer.composeScript, AppleMailComposer.senderScript] {
            let script = try XCTUnwrap(NSAppleScript(source: source))
            var error: NSDictionary?
            XCTAssertTrue(script.compileAndReturnError(&error), String(describing: error))
        }
        XCTAssertTrue(AppleMailComposer.composeScript.contains("Ambiguous sender account"))
        XCTAssertTrue(AppleMailComposer.senderScript.contains("Ambiguous sender account"))
#endif
    }
#if os(macOS)
    func testReceiptRequiresExactAddressesSubjectAndBody() throws {
        let request = try MailComposeRequest(recordID: "1", accountID: "a", accountName: "Test", sender: "me@example.com", recipients: ["reply@example.com"], subject: "Re: 中文", body: "一行\n二行", originalSubject: "中文", messageID: "id", localID: "1", sourceDigest: "digest", settingsRevision: UUID())
        let result = NSAppleEventDescriptor.list()
        for (index, value) in ["123", "Me <me@example.com>", request.subject, request.body + "\n"].enumerated() { result.insert(.init(string: value), at: index + 1) }
        let recipients = NSAppleEventDescriptor.list(); recipients.insert(.init(string: "reply@example.com"), at: 1)
        result.insert(recipients, at: 5)
        XCTAssertThrowsError(try AppleMailComposer.decodeReceipt(result, request: request))
        result.insert(.init(boolean: false), at: 6)
        XCTAssertThrowsError(try AppleMailComposer.decodeReceipt(result, request: request))
        result.remove(at: 6)
        result.insert(.init(boolean: true), at: 6)
        XCTAssertEqual(try AppleMailComposer.decodeReceipt(result, request: request).outgoingID, "123")
        result.insert(.init(string: "wrong@example.com"), at: 2)
        XCTAssertThrowsError(try AppleMailComposer.decodeReceipt(result, request: request))
    }
#endif
}
