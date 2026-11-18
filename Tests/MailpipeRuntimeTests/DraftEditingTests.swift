import XCTest
@testable import MailpipeRuntime
import MailpipeCore

@MainActor
final class DraftEditingTests: XCTestCase {
    func testMultiAccountUnknownDoesNotBecomeConfirmedExclusion() {
        XCTAssertNil(InboxMembershipDecision.combine([false, nil]))
        XCTAssertNil(InboxMembershipDecision.combine([true, true]))
        XCTAssertNil(InboxMembershipDecision.combine([]))
        XCTAssertEqual(InboxMembershipDecision.combine([false, false]), false)
        XCTAssertEqual(InboxMembershipDecision.combine([true, nil]), true)
    }
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
    func testPlaceholderAndUncertaintyConventions() {
        for body in ["【待补充：当前进展】", "【待确认：发布标准】", "【待补充】", "需要先核实，目前暂无法给出结论。"] {
            XCTAssertTrue(DraftContentWarnings(body: body).requiresCopyConfirmation, body)
        }
        XCTAssertFalse(DraftContentWarnings(body: "已收到示例项目简报，谢谢。").requiresCopyConfirmation)
        XCTAssertTrue(DraftContentWarnings(body: "【待补充：…】").needsSupplement)
        XCTAssertFalse(DraftContentWarnings(body: "【待补充：…】").needsConfirmation)
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

    func testSafeDraftHasNoWarningAndNoRowStatus() {
        let body = "已收到示例项目简报，谢谢。"
        XCTAssertEqual(DraftAttention.resolve(in: body), .none)
        XCTAssertNil(DraftAttention.resolve(in: body).message)
        XCTAssertFalse(DraftAttention.resolve(in: body).canLocate)
        let row = WorkbenchRowPresentation(reply: body, incoming: "克彬：\n请看简报。", preparing: false, failed: false)
        XCTAssertEqual(row.summary, "已收到示例项目简报，谢谢。")
        XCTAssertNil(row.status)
        XCTAssertFalse(["草稿已备好", "需要核对", "等待准备回复", "待确认"].contains(row.summary))
    }

    func testLocatedPhraseQuotesSourceAndDoesNotInventASubject() {
        let body = "收到。关于 thread harness 项目的进展以及是否达到发布标准，我需要先核实，目前暂无法给出结论。"
        let attention = DraftAttention.resolve(in: body)
        guard case .located(let kind, let phrase, let location, let length) = attention else {
            return XCTFail("expected a located phrase")
        }
        XCTAssertEqual(kind, .confirmation)
        XCTAssertEqual(phrase, "需要先核实")
        XCTAssertEqual(attention.message, "「需要先核实」")
        XCTAssertTrue(attention.canLocate)
        XCTAssertFalse(attention.message?.contains("是否达到发布标准") ?? true)
        let utf16 = Array(body.utf16)
        let slice = utf16[location..<(location + length)]
        XCTAssertEqual(String(decoding: slice, as: UTF16.self), phrase)
        let row = WorkbenchRowPresentation(reply: body, incoming: "来信", preparing: false, failed: false)
        XCTAssertEqual(row.status, "需核实")
        XCTAssertEqual(row.summary, body)
        XCTAssertFalse(row.summary.contains("\n"))
    }

    func testPlaceholderIsLocatedAndSupplementWinsTheRowStatus() {
        let body = "【待补充：当前进展】其余稍后再写。"
        let attention = DraftAttention.resolve(in: body)
        guard case .located(let kind, let phrase, _, _) = attention else { return XCTFail("expected placeholder") }
        XCTAssertEqual(kind, .supplement)
        XCTAssertEqual(phrase, "【待补充：当前进展】")
        XCTAssertEqual(attention.message, "「【待补充：当前进展】」")
        XCTAssertTrue(attention.canLocate)
        XCTAssertEqual(WorkbenchRowPresentation(reply: body, incoming: "", preparing: false, failed: false).status, "待补充")
    }

    func testLongPlaceholderClipsTheLabelButKeepsTheFullRange() {
        let filler = String(repeating: "进展", count: 30)
        let body = "【待补充：\(filler)】"
        let attention = DraftAttention.resolve(in: body)
        guard case .located(_, let phrase, let location, let length) = attention else { return XCTFail("expected placeholder") }
        XCTAssertEqual(phrase, "【待补充：\(filler)】")
        XCTAssertTrue(attention.message?.hasSuffix("…」") ?? false)
        XCTAssertEqual(location, 0)
        XCTAssertEqual(length, body.utf16.count)
        XCTAssertLessThan(attention.message?.count ?? 0, phrase.count)
    }

    func testUnlocatedConfirmationStaysGenericWithoutALocateAction() {
        let attention = DraftAttention.resolve(requiresConfirmation: true, match: nil)
        XCTAssertEqual(attention, .generic)
        XCTAssertEqual(attention.message, "这份草稿需要你核对")
        XCTAssertFalse(attention.canLocate)
        XCTAssertFalse(attention.message?.contains("是否达到发布标准") ?? true)
        XCTAssertEqual(DraftAttention.resolve(requiresConfirmation: false, match: nil), .none)
    }

    func testIncomingPreviewKeepsShortTextAndBreaksLongTextOnAPause() {
        let short = "克彬：\n你最近在做的那个 thread harness 项目进展怎么样了？能否达到发布标准？"
        let shown = IncomingPreview(body: short, expanded: false)
        XCTAssertEqual(shown.text, short)
        XCTAssertFalse(shown.omitsRemainder)
        let sentence = "这是一段用于预览的说明。"
        let long = String(repeating: sentence, count: 20)
        let preview = IncomingPreview(body: long, expanded: false)
        XCTAssertTrue(preview.omitsRemainder)
        XCTAssertTrue(preview.text.hasSuffix("。"))
        XCTAssertLessThan(preview.text.count, long.count)
        XCTAssertGreaterThanOrEqual(preview.text.count, 24)
        XCTAssertEqual(IncomingPreview(body: long, expanded: true).text, long)
        XCTAssertFalse(IncomingPreview(body: long, expanded: true).omitsRemainder)
        XCTAssertEqual(IncomingPreview(body: "  \n", expanded: false).text, "")
    }

    func testRowUsesOneSummaryAndReservesStatusForFailure() {
        let row = WorkbenchRowPresentation(
            reply: "第一行已经够用。\n第二行不进列表。",
            incoming: "来信不该盖过回复",
            preparing: false,
            failed: true)
        XCTAssertEqual(row.summary, "第一行已经够用。")
        XCTAssertEqual(row.status, "未成功")
        let waiting = WorkbenchRowPresentation(reply: "", incoming: "", preparing: true, failed: false)
        XCTAssertEqual(waiting.summary, "正在准备回复")
        XCTAssertNil(waiting.status)
        let incomingOnly = WorkbenchRowPresentation(reply: " \n", incoming: "克彬：请看这封。\n后文", preparing: false, failed: false)
        XCTAssertEqual(incomingOnly.summary, "克彬：请看这封。")
        XCTAssertNil(incomingOnly.status)
    }
}
