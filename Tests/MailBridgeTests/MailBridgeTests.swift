import XCTest
import MailBridge
import MailpipeCore

@MainActor
final class MailBridgeTests: XCTestCase {
    func testScaffoldCannotReadActualMail() async {
        let bridge = UnavailableMailBridge()
        do { _ = try await bridge.resolve(messageID: "synthetic@example.com", accountID: "synthetic"); XCTFail("unavailable") }
        catch { XCTAssertEqual(error as? MailpipeError, .mailBridgeUnavailable) }
        do {
            _ = try await bridge.snapshot(at: MailLocator(accountID: "synthetic", mailboxID: "inbox", localMessageID: "1"))
            XCTFail("unavailable")
        } catch { XCTAssertEqual(error as? MailpipeError, .mailBridgeUnavailable) }
    }
}
