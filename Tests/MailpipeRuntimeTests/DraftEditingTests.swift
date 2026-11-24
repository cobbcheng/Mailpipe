import XCTest
@testable import MailpipeRuntime
import MailpipeCore

@MainActor
final class DraftEditingTests: XCTestCase {
    func testRegenerationRequiresBodyAndCurrentAccountAuthorization() throws {
        let permission = CapturePermission()
        let scope = try AccountScope(accountID: "test", accountName: "test", mailboxName: "INBOX")
        var settings = PipelineSettings()
        settings.permission = permission; settings.scope = scope; settings.executable = "/fake/dsh"
        var item = StoredReply(id: "candidate", permissionID: permission.id, capturedAt: Date(), messageID: "test@example.com",
            input: MailInput(messageRef: "candidate", subject: "Synthetic", body: ""), state: .awaitingBody)
        XCTAssertFalse(item.canRequestRegeneration(settings: settings))
        item.state = .needsReview
        XCTAssertFalse(item.canRequestRegeneration(settings: settings))
        item.accountID = scope.accountID; item.scopeID = scope.id; item.state = .draftReady
        XCTAssertTrue(item.canRequestRegeneration(settings: settings))
        settings.paused = true
        XCTAssertFalse(item.canRequestRegeneration(settings: settings))
        settings.paused = false; settings.permission = nil
        XCTAssertFalse(item.canRequestRegeneration(settings: settings))
    }
    func testSaveFailureKeepsBufferAndRetryWritesLatestBody() {
        var buffer = DraftEditBuffer(body: "Saved reply")
        buffer.edit("Unsaved reply")
        XCTAssertEqual(buffer.state, .saving)
        XCTAssertFalse(buffer.persist { _ in throw PipelineError.storage })
        XCTAssertEqual(buffer.state, .failed)
        XCTAssertEqual(buffer.body, "Unsaved reply")
        XCTAssertEqual(buffer.savedBody, "Saved reply")
        // Switching detail views does not own or reset this host-owned buffer.
        buffer.edit("Newer unsaved reply")
        var written: String?
        XCTAssertTrue(buffer.persist { written = $0 })
        XCTAssertEqual(written, "Newer unsaved reply")
        XCTAssertEqual(buffer.state, .saved)
        XCTAssertEqual(buffer.savedBody, buffer.body)
    }
    func testReturningToSavedTextNeedsNoWrite() {
        var buffer = DraftEditBuffer(body: "Original")
        buffer.edit("Edited"); buffer.edit("Original")
        XCTAssertEqual(buffer.state, .saved)
        XCTAssertTrue(buffer.persist { _ in XCTFail("No write needed") })
    }
    func testSaveLabelFollowsPersistence() {
        var buffer = DraftEditBuffer(body: "已有回复")
        XCTAssertEqual(buffer.state, .saved)
        XCTAssertEqual(buffer.state.label, "已保存")
        buffer.edit("改过的回复")
        XCTAssertEqual(buffer.state, .saving)
        XCTAssertNotEqual(buffer.state.label, "已保存")
        XCTAssertFalse(buffer.persist { _ in throw PipelineError.storage })
        XCTAssertEqual(buffer.state, .failed)
        XCTAssertEqual(buffer.state.label, "未能保存，点此重试")
        XCTAssertNotEqual(buffer.state.label, "已保存")
    }
}
