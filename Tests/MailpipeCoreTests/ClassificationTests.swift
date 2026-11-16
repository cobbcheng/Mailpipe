import XCTest
@testable import MailpipeCore

final class ClassificationTests: XCTestCase {
    private func changed(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: SyntheticFixture.response) as? [String: Any])
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func rejected(_ data: Data, error: MailpipeError = .invalidOutput) {
        XCTAssertThrowsError(try ClassificationResponse.validated(data, for: SyntheticFixture.request)) {
            XCTAssertEqual($0 as? MailpipeError, error)
        }
    }
    func testValidResponse() throws {
        let result = try ClassificationResponse.validated(SyntheticFixture.response, for: SyntheticFixture.request)
        XCTAssertEqual(result.results.first?.category, .billing)
        XCTAssertEqual(result.results.first?.needsAction, .no)
    }
    func testForeignRequestAndUnknownFieldsAreRejected() throws {
        rejected(try changed { $0["request_id"] = "foreign" })
        rejected(try changed { $0["run_script"] = "unsafe" })
        rejected(try changed { $0["schema_version"] = 2 })
        rejected(try changed { $0["schema_version"] = true })
    }
    func testMissingDuplicateAndForeignMessageIDsAreRejected() throws {
        rejected(try changed { $0["results"] = [] })
        rejected(try changed { let rows = $0["results"] as! [[String: Any]]; $0["results"] = rows + rows })
        rejected(try changed {
            var rows = $0["results"] as! [[String: Any]]
            rows[0]["message_ref"] = "not-in-batch"; $0["results"] = rows
        })
    }
    func testInvalidEnumsSummaryEvidenceAndActionsAreRejected() throws {
        for (key, value) in [("category", "execute"), ("needs_action", "maybe"), ("shell", "touch /tmp/not-allowed")] {
            rejected(try changed {
                var rows = $0["results"] as! [[String: Any]]; rows[0][key] = value; $0["results"] = rows
            })
        }
        for summary in [[], [" "], Array(repeating: "text", count: 4), [String(repeating: "x", count: 281)]] {
            rejected(try changed {
                var rows = $0["results"] as! [[String: Any]]; rows[0]["summary"] = summary; $0["results"] = rows
            })
        }
        for proof in [["field": "body", "text": "invented evidence"], ["field": "path", "text": "Example invoice"],
                      ["field": "subject", "text": "Example invoice", "action": "send"]] {
            rejected(try changed {
                var rows = $0["results"] as! [[String: Any]]; rows[0]["evidence"] = [proof]; $0["results"] = rows
            })
        }
    }
    func testInvalidInputAndOutputBounds() throws {
        let input = ClassificationRequest(requestID: "id", messages: [
            MailInput(messageRef: "m", subject: "s", body: String(repeating: "x", count: 16_385))
        ])
        XCTAssertThrowsError(try input.validate())
        XCTAssertThrowsError(try ClassificationRequest(requestID: "", messages: []).validate())
        rejected(Data(repeating: 32, count: 262_145), error: .outputLimit)
        rejected(Data("```json\n{}\n```".utf8))
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
}
