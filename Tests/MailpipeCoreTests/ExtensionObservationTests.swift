import XCTest
@testable import MailpipeCore

final class ExtensionObservationTests: XCTestCase {
    func testMissingFreshStaleAndMalformedEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = try CaptureInbox(directory: root), now = Date()
        XCTAssertNil(try ExtensionObservation.read(from: inbox))
        let receipt = ExtensionObservation(event: .handlerRequested, observedAt: now, build: "test")
        try receipt.write(to: inbox)
        XCTAssertEqual(try ExtensionObservation.read(from: inbox, now: now), receipt)
        XCTAssertNil(try ExtensionObservation.read(from: inbox, now: now.addingTimeInterval(8 * 86_400)))
        XCTAssertNil(try ExtensionObservation.read(from: inbox, now: now.addingTimeInterval(-1)))
        XCTAssertNil(try inbox.permission()); XCTAssertTrue(try inbox.files().isEmpty)
        try Data("invalid".utf8).write(to: root.appendingPathComponent("extension-observation.json"))
        XCTAssertThrowsError(try ExtensionObservation.read(from: inbox))
    }
}
