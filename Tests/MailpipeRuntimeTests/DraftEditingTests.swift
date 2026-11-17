import XCTest
@testable import MailpipeRuntime
import MailpipeCore

@MainActor
final class DraftEditingTests: XCTestCase {
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
    func testPlaceholderAndUncertaintyConventions() {
        for body in ["【待补充：当前进展】", "【待确认：发布标准】", "【待补充】", "需要先核实，目前暂无法给出结论。"] {
            XCTAssertTrue(DraftContentWarnings(body: body).requiresCopyConfirmation, body)
        }
        XCTAssertFalse(DraftContentWarnings(body: "已收到示例项目简报，谢谢。").requiresCopyConfirmation)
        XCTAssertTrue(DraftContentWarnings(body: "【待补充：…】").needsSupplement)
        XCTAssertFalse(DraftContentWarnings(body: "【待补充：…】").needsConfirmation)
    }
}
