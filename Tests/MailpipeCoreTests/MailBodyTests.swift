import XCTest
@testable import MailpipeCore

final class MailBodyTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "eml", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func text(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let value = try PlainMailBody.decode(try fixture(name))
        XCTAssertLessThanOrEqual(value.utf8.count, MailBodyLimits.modelBudget, file: file, line: line)
        return value
    }

    func expect(_ name: String, _ reason: MailBodyRejection, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try fixture(name)
        XCTAssertThrowsError(try PlainMailBody.decode(data), file: file, line: line) { error in
            XCTAssertEqual(error as? MailBodyRejection, reason, file: file, line: line)
        }
    }

    func testPlainUTF8QuotedPrintableAndBase64() throws {
        XCTAssertEqual(try text("plain-utf8"), "Please reply about Friday.")
        XCTAssertEqual(try text("plain-qp"), "Please reply")
        XCTAssertEqual(try text("plain-base64"), "Please reply")
        XCTAssertEqual(contentDigest(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testHTMLBecomesReadableText() throws {
        let body = try text("html-basic")
        XCTAssertTrue(body.contains("Please review the invoice (https://example.com/invoice)."))
        XCTAssertTrue(body.contains("- Amount due"))
        XCTAssertTrue(body.contains("- Due Friday"))
        XCTAssertTrue(body.contains("> On Monday Alex wrote:"))
        XCTAssertTrue(body.contains("> Old thread"))
        XCTAssertFalse(body.contains("tracker"))
        XCTAssertFalse(body.contains("pixel.gif"))
        XCTAssertFalse(body.contains("secret tracking phrase"))
        XCTAssertFalse(body.contains("<p>"))
        XCTAssertFalse(body.contains("<script"))
    }

    func testAlternativePrefersPlainAndFallsBackToHTML() throws {
        let plain = try text("alternative-plain")
        XCTAssertEqual(plain, "Use the plain part.")
        XCTAssertFalse(plain.contains("must not win"))
        XCTAssertEqual(try text("alternative-html"), "Hello from HTML")
    }

    func testMixedRelatedAndNestedIgnoreAttachmentBytes() throws {
        let mixed = try PlainMailBody.extract(try fixture("mixed-attachment"))
        XCTAssertEqual(mixed.text, "See the attached report.\n[attachments: report.pdf (application/pdf)]")
        XCTAssertEqual(mixed.attachments.map(\.filename), ["report.pdf"])
        XCTAssertFalse(mixed.text.contains("JVBER"))
        let related = try text("related-inline")
        XCTAssertTrue(related.contains("See the logo."))
        XCTAssertTrue(related.contains("logo.png (image/png)"))
        XCTAssertFalse(related.contains("iVBORw0KGgo"))
        let nested = try text("nested")
        XCTAssertTrue(nested.contains("Inner plain wins."))
        XCTAssertTrue(nested.contains("Outer note."))
        XCTAssertFalse(nested.contains("must not win"))
    }

    func testChineseAndLegacyCharsets() throws {
        XCTAssertEqual(try text("gbk"), "请确认周五的会议。")
        XCTAssertEqual(try text("gb2312"), "会议通知")
        XCTAssertEqual(try text("gb18030"), "中文测试")
        XCTAssertEqual(try text("big5"), "請確認週五的會議。")
        XCTAssertEqual(try text("iso-2022-jp"), "会議の確認をお願いします。")
        XCTAssertEqual(try text("iso-8859-1"), "Café résumé")
        XCTAssertEqual(try text("windows-1252"), "Café \u{2014} résumé")
        let header = Data("Content-Type: text/html\r\n\r\n".utf8)
        let page = Data(hexBytes: "3c68746d6c3e3c686561643e3c6d65746120636861727365743d2267626b223e3c2f686561643e3c626f64793e3c703ec7ebc8b7c8cfd6dccee5a1a33c2f703e3c2f626f64793e3c2f68746d6c3e")
        XCTAssertEqual(try PlainMailBody.decode(header + page), "请确认周五。")
    }

    func testAttachedMessagesDoNotBecomeModelBody() throws {
        for type in ["message/rfc822", "message/global"] {
            let attachment = "Content-Type: \(type)\r\nContent-Disposition: attachment; filename=archive.eml\r\n\r\n"
                + "From: sender@example.com\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nATTACHMENT-ONLY-CANARY"
            let raw = Data(("Content-Type: multipart/mixed; boundary=b\r\n\r\n"
                + "--b\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nPlease review the attachment.\r\n"
                + "--b\r\n" + attachment + "\r\n--b--\r\n").utf8)
            let result = try PlainMailBody.extract(raw)
            XCTAssertEqual(result.text, "Please review the attachment.\n[attachments: archive.eml (\(type))]")
            XCTAssertEqual(result.attachments, [MailAttachmentNote(filename: "archive.eml", mediaType: type)])
            XCTAssertThrowsError(try PlainMailBody.decode(Data(attachment.utf8))) { error in
                XCTAssertEqual(error as? MailBodyRejection, .attachmentOnly)
            }
        }
    }

    func testAttachedMultipartIsNotTraversed() throws {
        let source = [
            "Content-Type: multipart/mixed; boundary=outer\r\n\r\n",
            "--outer\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nVisible body.\r\n",
            "--outer\r\nContent-Type: multipart/mixed; boundary=inner\r\n",
            "Content-Disposition: attachment; filename=bundle.mime\r\n\r\n",
            "--inner\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nATTACHED-CONTAINER-CANARY\r\n",
            "--inner--\r\n--outer--\r\n"
        ].joined()
        let raw = Data(source.utf8)
        let result = try PlainMailBody.extract(raw)
        XCTAssertEqual(result.text, "Visible body.\n[attachments: bundle.mime (multipart/mixed)]")
        XCTAssertEqual(result.attachments.map(\.filename), ["bundle.mime"])
    }

    func testInlineMessageRemainsReadable() throws {
        let raw = Data(("Content-Type: message/rfc822\r\nContent-Disposition: inline\r\n\r\n"
            + "From: sender@example.com\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nInline forwarded body.").utf8)
        let result = try PlainMailBody.extract(raw)
        XCTAssertEqual(result.text, "Inline forwarded body.")
        XCTAssertTrue(result.attachments.isEmpty)
    }

    func testHiddenVoidElementsPreserveFollowingBody() throws {
        for tag in ["img", "br", "hr", "meta", "link", "input", "source", "wbr", "area", "base", "col", "embed"] {
            for style in ["display:none", "visibility:hidden"] {
                let raw = Data(("Content-Type: text/html; charset=utf-8\r\n\r\n<html><body>"
                    + "<p>Intro.</p><\(tag) style=\"\(style)\" alt=\"HIDDEN-ALT-CANARY\">"
                    + "<div style=\"display:none\"><span>HIDDEN-BLOCK-CANARY</span></div>"
                    + "<p>Please confirm Friday.</p></body></html>").utf8)
                let text = try PlainMailBody.decode(raw)
                XCTAssertTrue(text.contains("Intro."), "\(tag): \(text)")
                XCTAssertTrue(text.contains("Please confirm Friday."), "\(tag): \(text)")
                XCTAssertFalse(text.contains("HIDDEN-ALT-CANARY"))
                XCTAssertFalse(text.contains("HIDDEN-BLOCK-CANARY"))
            }
        }
    }

    func testEncodedHeaders() throws {
        XCTAssertEqual(MailHeaderCodec.decodeEncodedWords("=?UTF-8?B?6K+35rGC6K+B5piO?="), "请求证明")
        XCTAssertEqual(MailHeaderCodec.decodeEncodedWords("=?utf-8?Q?Please?= =?utf-8?Q?_reply?="), "Please reply")
        let encoded = try text("rfc2047-filename")
        XCTAssertTrue(encoded.contains("报告.pdf (application/pdf)"))
        XCTAssertFalse(encoded.contains("=?UTF-8"))
        let star = try text("rfc2231-filename")
        XCTAssertTrue(star.contains("报告.pdf (application/pdf)"))
    }

    func testSignedTextIsReadable() throws {
        XCTAssertEqual(try text("signed"), "Please confirm Friday.")
        XCTAssertFalse(try text("signed").contains("SIGNATURE-BLOB"))
        XCTAssertEqual(try text("pgp-clear"), "Please confirm Friday.")
        XCTAssertFalse(try text("pgp-clear").contains("BEGIN PGP SIGNATURE"))
    }

    func testRejectedFormatsRecordAReason() throws {
        try expect("pkcs7-encrypted", .encryptedContent)
        try expect("pgp-encrypted", .encryptedContent)
        try expect("pgp-message", .encryptedContent)
        try expect("signed-opaque", .signedOpaque)
        try expect("attachment-only", .attachmentOnly)
        try expect("calendar-only", .calendarOnly)
        try expect("malformed", .malformedMIME)
        try expect("unknown-charset", .unsupportedCharset)
        try expect("text-enriched", .unsupportedContent)
        XCTAssertEqual(MailBodyRejection.encryptedContent.reviewLabel, "加密内容无法阅读")
        XCTAssertEqual(MailBodyRejection.attachmentOnly.reviewLabel, "没有可阅读的正文，只有附件")
        XCTAssertEqual(MailBodyRejection.calendarOnly.reviewLabel, "日历邀请，未提取正文")
    }

    func testMessagesAbove64KiBAreBoundedInsteadOfRejected() throws {
        let intro = "INVOICE-TOKEN\n"
        let raw = Data(("Content-Type: text/plain; charset=utf-8\r\n\r\n" + intro).utf8) + Data(repeating: 0x41, count: 80_000)
        let body = try PlainMailBody.decode(raw)
        XCTAssertTrue(body.hasPrefix("INVOICE-TOKEN"))
        XCTAssertTrue(body.contains(MailBodyLimits.truncatedMarker))
        XCTAssertLessThanOrEqual(body.utf8.count, MailBodyLimits.modelBudget)
        XCTAssertGreaterThan(raw.count, 65_536)
    }

    func testQuotedHistoryAndSignatureTrimBeforeTheModelBudget() throws {
        let quote = "Please confirm the Friday invoice.\n\nOn Friday, Ada wrote:\n" + String(repeating: "old quoted line\n", count: 2_000)
        let quoted = try PlainMailBody.decode(plain(quote))
        XCTAssertTrue(quoted.contains("Please confirm the Friday invoice."))
        XCTAssertTrue(quoted.contains(MailBodyLimits.quotedMarker))
        XCTAssertFalse(quoted.contains("old quoted line"))
        XCTAssertLessThanOrEqual(quoted.utf8.count, MailBodyLimits.modelBudget)
        let chineseQuote = "请确认周五。\n\n在 2026年11月14日，ada@example.com 写道：\n" + String(repeating: "旧内容\n", count: 2_000)
        let chinese = try PlainMailBody.decode(plain(chineseQuote))
        XCTAssertTrue(chinese.contains("请确认周五。"))
        XCTAssertTrue(chinese.contains(MailBodyLimits.quotedMarker))
        XCTAssertFalse(chinese.contains("旧内容"))

        let filler = String(repeating: "A", count: 16_360)
        let signed = filler + "\n\n-- \nAda Lovelace <ada@example.com>\n"
        let trimmed = try PlainMailBody.decode(plain(signed))
        XCTAssertFalse(trimmed.contains("Ada Lovelace"))
        XCTAssertTrue(trimmed.contains(MailBodyLimits.signatureMarker))
        XCTAssertLessThanOrEqual(trimmed.utf8.count, MailBodyLimits.modelBudget)

        let kept = try PlainMailBody.decode(plain("Thanks.\n\n-- \nAda Lovelace <ada@example.com>\n"))
        XCTAssertTrue(kept.contains("Ada Lovelace"))
        XCTAssertFalse(kept.contains(MailBodyLimits.signatureMarker))
    }

    func testHardCeilingDepthAndEmptyBody() throws {
        var huge = Data("Content-Type: text/plain; charset=utf-8\r\n\r\nHi".utf8)
        huge.append(Data(repeating: 0x41, count: MailBodyLimits.rawCeiling))
        XCTAssertThrowsError(try PlainMailBody.decode(huge)) { error in
            XCTAssertEqual(error as? MailBodyRejection, .messageTooLarge)
        }
        var nested = "Content-Type: text/plain; charset=utf-8\r\n\r\nleaf"
        for index in 0..<10 {
            nested = "Content-Type: multipart/mixed; boundary=b\(index)\r\n\r\n--b\(index)\r\n" + nested + "\r\n--b\(index)--\r\n"
        }
        XCTAssertThrowsError(try PlainMailBody.decode(Data(nested.utf8))) { error in
            XCTAssertEqual(error as? MailBodyRejection, .malformedMIME)
        }
        XCTAssertThrowsError(try PlainMailBody.decode(plain("   \r\n"))) { error in
            XCTAssertEqual(error as? MailBodyRejection, .emptyBody)
        }
        let nul = Data("Content-Type: text/plain; charset=utf-8\r\n\r\nHello".utf8) + Data([0])
        XCTAssertThrowsError(try PlainMailBody.decode(nul)) { error in
            XCTAssertEqual(error as? MailBodyRejection, .malformedMIME)
        }
    }

    func testDisplayPreservesLongTextAndParagraphBreaks() throws {
        let history = String(repeating: "quoted history ", count: 20_000)
        let body = "First line\r\nSecond line\r\n\r\n\r\nOn Friday, Ada wrote:\r\n> " + history + "END"
        XCTAssertEqual(try PlainMailBody.displayText(plain(body)), body.replacingOccurrences(of: "\r\n", with: "\n"))
        let model = try PlainMailBody.decode(plain(body))
        XCTAssertLessThanOrEqual(model.utf8.count, MailBodyLimits.modelBudget)
        XCTAssertFalse(model.contains("END"))
    }

    func testDisplayConvertsHTMLDocumentWithPlainContentType() throws {
        let html = "<html><body><p>One<br>Two</p><p>Three</p></body></html>"
        XCTAssertEqual(try PlainMailBody.displayText(plain(html)), "One\nTwo\n\nThree")
        XCTAssertEqual(try PlainMailBody.decode(plain(html)), html)
    }

    private func plain(_ body: String) -> Data {
        Data(("Content-Type: text/plain; charset=utf-8\r\n\r\n" + body).utf8)
    }
}

private extension Data {
    init(hexBytes: String) {
        var bytes: [UInt8] = []
        var index = hexBytes.startIndex
        while index < hexBytes.endIndex {
            let next = hexBytes.index(index, offsetBy: 2)
            bytes.append(UInt8(hexBytes[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
