import XCTest
@testable import MailpipeCore

final class BodyProbeTests: XCTestCase {
    func testRequestOnceAcrossStoreRecreationAndReceiveBody() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdentityProbeStore(directory: root)
        let scope = try store.begin(requestsBody: true)
        XCTAssertTrue(try store.observeBody(subject: scope.subject, rawData: nil))
        let reopened = IdentityProbeStore(directory: root)
        XCTAssertFalse(try reopened.observeBody(subject: scope.subject, rawData: nil))
        let bytes = Data("Subject: synthetic\r\n\r\n\(scope.bodyMarker)\r\nprivate fixture text".utf8)
        XCTAssertFalse(try reopened.observeBody(subject: scope.subject, rawData: bytes))
        let receipt = try XCTUnwrap(store.bodyReceipt())
        XCTAssertTrue(receipt.markerFound)
        XCTAssertEqual(receipt.rawByteCount, bytes.count)
        let persisted = try String(contentsOf: root.appendingPathComponent("body-receipt.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("private fixture text"))
        XCTAssertFalse(persisted.contains(scope.bodyMarker))
        XCTAssertFalse(try store.observeBody(subject: scope.subject, rawData: nil))
    }

    func testConsentExpiryRevocationAndNewSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdentityProbeStore(directory: root)
        let metadata = try store.begin()
        XCTAssertFalse(try store.observeBody(subject: metadata.subject, rawData: nil))
        let scope = try store.begin(requestsBody: true)
        XCTAssertFalse(try store.observeBody(subject: "other", rawData: nil))
        XCTAssertFalse(try store.observeBody(subject: scope.subject, rawData: nil, now: scope.expiresAt))
        XCTAssertTrue(try store.observeBody(subject: scope.subject, rawData: nil))
        _ = try store.observeBody(subject: scope.subject, rawData: Data("\r\n\r\n\(scope.bodyMarker)".utf8))
        let next = try store.begin(requestsBody: true)
        XCTAssertNil(try store.bodyReceipt())
        XCTAssertFalse(try store.observeBody(subject: scope.subject, rawData: nil))
        XCTAssertTrue(try store.observeBody(subject: next.subject, rawData: nil))
        try store.stop()
        XCTAssertThrowsError(try store.observeBody(subject: next.subject, rawData: nil))
        XCTAssertThrowsError(try store.bodyReceipt())
    }

    func testHeaderOnlyMarkerAndOversizeCannotPass() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdentityProbeStore(directory: root)
        let scope = try store.begin(requestsBody: true)
        _ = try store.observeBody(subject: scope.subject, rawData: Data("Subject: \(scope.bodyMarker)\r\n\r\nother body".utf8))
        XCTAssertFalse(try XCTUnwrap(store.bodyReceipt()).markerFound)
        _ = try store.observeBody(subject: scope.subject, rawData: Data(repeating: 65, count: 65_537))
        XCTAssertNil(try XCTUnwrap(store.bodyReceipt()).bodyByteCount)
        XCTAssertFalse(try XCTUnwrap(store.bodyReceipt()).markerFound)
    }

    func testOldMetadataScopeDoesNotAuthorizeBody() throws {
        let scope = IdentityProbeScope()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(scope)) as? [String: Any])
        object.removeValue(forKey: "requestsBody")
        let old = try JSONDecoder().decode(IdentityProbeScope.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.requestsBody)
    }
    func testBase64BodyAndUnsupportedEncoding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdentityProbeStore(directory: root)
        let scope = try store.begin(requestsBody: true)
        let payload = Data(scope.bodyMarker.utf8).base64EncodedString(options: .lineLength64Characters)
        _ = try store.observeBody(subject: scope.subject, rawData: Data("Content-Transfer-Encoding: base64\r\n\r\n\(payload)".utf8))
        XCTAssertTrue(try XCTUnwrap(store.bodyReceipt()).markerFound)
        XCTAssertEqual(try XCTUnwrap(store.bodyReceipt()).bodyByteCount, scope.bodyMarker.utf8.count)
        for (encoding, payload) in [("base64", "!!invalid!!"), ("quoted-printable", scope.bodyMarker)] {
            _ = try store.observeBody(subject: scope.subject, rawData: Data("Content-Transfer-Encoding: \(encoding)\r\n\r\n\(payload)".utf8))
            XCTAssertFalse(try XCTUnwrap(store.bodyReceipt()).markerFound)
            XCTAssertNil(try XCTUnwrap(store.bodyReceipt()).bodyByteCount)
        }
    }

}
