import XCTest
@testable import MailBridge
import MailpipeCore

final class IdentityQueryTests: XCTestCase {
    func testMissingScopeCannotQuery() {
        for values in [("", "INBOX", "a"), ("Google", "", "a"), ("Google", "INBOX", "<>"), ("Google", "INBOX", "a\nb")] {
            XCTAssertThrowsError(try IdentityQuery(accountName: values.0, mailboxName: values.1, messageID: values.2))
        }
    }
    func testMessageIDNormalizationAndLiteralArguments() throws {
        let query = try IdentityQuery(accountName: "test\" & do shell script", mailboxName: "INBOX", messageID: "<synthetic@example.com>")
        XCTAssertEqual(query.messageID, "synthetic@example.com")
        XCTAssertEqual(query.accountName, "test\" & do shell script")
    }
    @MainActor func testSourceCeilingMatchesBodyLimit() {
        XCTAssertTrue(AppleMailReplyIdentity.scriptSource.contains(String(MailBodyLimits.rawCeiling)))
        XCTAssertFalse(AppleMailReplyIdentity.scriptSource.contains("65536"))
    }
#if os(macOS)
    @MainActor func testFixedReadOnlyScriptCompilesWithoutExecuting() {
        for source in [AppleMailReplyIdentity.catalogScript, AppleMailReplyIdentity.scriptSource] {
            let script = NSAppleScript(source: source)!
            var error: NSDictionary?
            XCTAssertTrue(script.compileAndReturnError(&error), "\(String(describing: error))")
        }
        let script = NSAppleScript(source: AppleMailIdentityProbe.scriptSource)!
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "\(String(describing: error))")
    }
#endif
}
