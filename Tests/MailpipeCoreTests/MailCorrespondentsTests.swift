import XCTest
@testable import MailpipeCore

final class MailCorrespondentsTests: XCTestCase {
    func testOriginalHeadersNotReplyToOrDeliveryAccount() throws {
        let source = Data("From: \"Sender, Name\" <From@Example.com>\r\nTo: Alias <alias@example.com>,\r\n second@example.com\r\nCc: copy@example.com\r\nReply-To: replies@example.com\r\nDelivered-To: account@example.com\r\n\r\nbody".utf8)
        let value = try XCTUnwrap(MailCorrespondents(source))
        XCTAssertEqual(value.sender, "From@example.com")
        XCTAssertEqual(value.recipients, ["alias@example.com", "second@example.com"])
        XCTAssertEqual(value.cc, ["copy@example.com"])
        XCTAssertEqual(try JSONDecoder().decode(MailCorrespondents.self, from: JSONEncoder().encode(value)), value)
    }
    func testMissingAndAmbiguousAddressesStayUnknown() throws {
        for header in ["Reply-To: reply@example.com\nDelivered-To: account@example.com", "From: a@example.com\nFrom: b@example.com\nTo: a@example.com\nTo: b@example.com", "From: a@example.com,b@example.com\nTo: undisclosed-recipients:;"] {
            let value = try XCTUnwrap(MailCorrespondents(Data((header + "\n\nbody").utf8)))
            XCTAssertNil(value.sender)
            XCTAssertTrue(value.recipients.isEmpty)
        }
        XCTAssertNil(MailCorrespondents(Data("not a message".utf8)))
    }
}
