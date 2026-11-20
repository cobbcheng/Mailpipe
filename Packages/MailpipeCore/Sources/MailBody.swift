import Foundation
import MailpipeCharset

/// Limits for turning a raw message into model input.
/// Parsing stays on this Mac. Nothing is fetched to clean HTML.
public enum MailBodyLimits {
    /// Raw message kept for import and full-source account checks.
    /// Large enough for HTML plus a modest attachment. Above this, the spool stores no bytes.
    public static let rawCeiling = 4 * 1024 * 1024
    /// JSON capture file ceiling. Base64 expands the raw bytes by 4/3.
    public static let captureFileCeiling = 6 * 1024 * 1024
    /// Decoded text kept before quote trimming.
    public static let extractCap = 256 * 1024
    /// UTF-8 bytes sent to triage and draft. Same bound as `MailInput`.
    public static let modelBudget = 16_384
    public static let maxDepth = 8
    public static let maxParts = 64
    public static let maxHeaderBytes = 64 * 1024
    public static let quotedMarker = "[quoted history trimmed]"
    public static let signatureMarker = "[signature trimmed]"
    public static let truncatedMarker = "[truncated]"
}

/// Why a message stays on manual review instead of going to the model.
public enum MailBodyRejection: String, Error, Equatable, Sendable {
    case messageTooLarge
    case encryptedContent
    case signedOpaque
    case attachmentOnly
    case calendarOnly
    case malformedMIME
    case unsupportedCharset
    case unsupportedContent
    case emptyBody

    public var reviewLabel: String {
        switch self {
        case .messageTooLarge: "原文超过 4 MiB，未解析"
        case .encryptedContent: "加密内容无法阅读"
        case .signedOpaque: "签名封装无法阅读"
        case .attachmentOnly: "没有可阅读的正文，只有附件"
        case .calendarOnly: "日历邀请，未提取正文"
        case .malformedMIME: "MIME 结构无法解析"
        case .unsupportedCharset: "字符集不支持"
        case .unsupportedContent: "正文类型不支持"
        case .emptyBody: "正文为空"
        }
    }
}

public struct MailAttachmentNote: Equatable, Sendable {
    public let filename: String?
    public let mediaType: String
    public init(filename: String?, mediaType: String) {
        self.filename = filename
        self.mediaType = mediaType
    }
}

public struct MailBodyExtraction: Equatable, Sendable {
    public let text: String
    public let truncated: Bool
    public let attachments: [MailAttachmentNote]
}

public enum MailHeaderCodec {
    /// The raw message may carry an ID that Mail omits from its projected header dictionary.
    public static func messageID(in raw: Data) -> String? {
        let prefix = raw.prefix(MailBodyLimits.maxHeaderBytes + 4)
        let boundary = [Data([13, 10, 13, 10]), Data([10, 10])].compactMap { prefix.range(of: $0)?.lowerBound }.min()
        guard let boundary,
              let headers = try? MIMEHeaders(prefix[..<boundary], defaultType: "text/plain"),
              let values = headers.fields["message-id"], values.count == 1,
              ComposeMessageIdentity.digest(forMessageID: values[0]) != nil else { return nil }
        return values[0]
    }

    /// RFC 2047 encoded-words. Unknown charset or broken tokens stay literal.
    public static func decodeEncodedWords(_ value: String) -> String {
        EncodedWords.decode(value)
    }
}

/// Evidence for a MailKit representation whose transport headers may be rewritten.
/// The host still requires one authorized mailbox match before reading the full source.
public struct MailSourceEvidence: Codable, Equatable, Sendable {
    private let headerDigest: String
    private let bodyDigest: String
    private let multipartDigest: String?
    private let parameters: [String: String]
    private let subjectVersion: Int?

    public init?(_ raw: Data) {
        guard let value = try? Self.components(raw, subjectForm: .decoded, compareParts: true) else { return nil }
        subjectVersion = 1
        headerDigest = value.headers
        multipartDigest = value.multipart
        bodyDigest = value.body
        parameters = value.parameters
    }

    public func matches(_ source: Data) -> Bool {
        let forms: [SubjectForm]
        switch subjectVersion {
        case 1: forms = [.decoded]
        case nil: forms = [.original, .mailKitBase64]
        default: return false
        }
        return forms.contains { form in
            guard let value = try? Self.components(source, subjectForm: form, compareParts: multipartDigest != nil),
                  value.headers == headerDigest,
                  value.body == bodyDigest || (multipartDigest != nil && value.multipart == multipartDigest) else { return false }
            // Captured MIME parameters must never silently change.
            return parameters.allSatisfy { value.parameters[$0.key] == $0.value }
        }
    }

    private enum SubjectForm { case original, decoded, mailKitBase64 }

    private static func components(_ raw: Data, subjectForm: SubjectForm, compareParts: Bool) throws -> (headers: String, body: String, parameters: [String: String], multipart: String?) {
        guard raw.count <= MailBodyLimits.rawCeiling else { throw MailBodyRejection.messageTooLarge }
        let split = try splitHeaders(raw)
        guard !split.body.isEmpty else { throw MailBodyRejection.emptyBody }
        let mime = try MIMEHeaders(split.header, defaultType: "text/plain")
        let required = ["from", "to", "date", "subject", "message-id"]
        let optional = ["cc", "reply-to", "in-reply-to", "references", "mime-version"]
        var selected: [String: String] = [:]
        for key in required + optional {
            let values = mime.fields[key] ?? []
            guard values.count <= 1, !required.contains(key) || values.count == 1 else {
                throw MailBodyRejection.malformedMIME
            }
            let value = values.first ?? ""
            if ["from", "to", "cc", "reply-to"].contains(key), !value.isEmpty {
                guard let addresses = mailboxList(value), !addresses.isEmpty else { throw MailBodyRejection.malformedMIME }
                if key == "from", addresses.count != 1 { throw MailBodyRejection.malformedMIME }
                selected[key] = addresses.joined(separator: ",")
            } else {
                let unfolded = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                if key == "subject" {
                    switch subjectForm {
                    case .original: selected[key] = unfolded
                    case .decoded: selected[key] = EncodedWords.decode(unfolded)
                    case .mailKitBase64:
                        // Compatibility with persisted, pre-normalization MailKit evidence.
                        // All other headers and the complete MIME body still have to match.
                        let decoded = EncodedWords.decode(unfolded)
                        guard !decoded.contains("=?") else { throw MailBodyRejection.malformedMIME }
                        selected[key] = "=?utf-8?B?\(Data(decoded.utf8).base64EncodedString())?="
                    }
                } else { selected[key] = unfolded }
            }
        }
        selected["content-type"] = mime.mediaType
        selected["content-transfer-encoding"] = mime.encoding
        // Disposition affects whether bytes are treated as an attachment.
        selected["content-disposition"] = mime.fields["content-disposition"]?.first ?? ""
        let headers = try JSONSerialization.data(withJSONObject: selected, options: [.sortedKeys])
        var body = Data()
        var previous: UInt8?
        for byte in split.body {
            if previous == 13 {
                if byte != 10 { body.append(13) }
            }
            if byte != 13 { body.append(byte) }
            previous = byte
        }
        if previous == 13 { body.append(13) }
        while body.last == 10 { body.removeLast() }
        let multipart = compareParts ? try? multipartFingerprint(body, mime: mime) : nil
        return (contentDigest(headers), contentDigest(body), mime.parameters, multipart)
    }

    // Preserve the framing, every part header, and all payload bytes, including attachments.
    // Transfer wrapping and header order can differ between two serializations.
    private static func multipartFingerprint(_ body: Data, mime: MIMEHeaders) throws -> String {
        guard ["multipart/alternative", "multipart/mixed", "multipart/related"].contains(mime.mediaType),
              let boundary = mime.parameters["boundary"], !boundary.isEmpty,
              boundary.utf8.count <= 70 else { throw MailBodyRejection.malformedMIME }
        let ranges = try MIMESplit.partRanges(body, boundary: boundary)
        guard ranges.count <= MailBodyLimits.maxParts else { throw MailBodyRejection.malformedMIME }
        var segments: [String] = []
        var cursor = body.startIndex
        for range in ranges {
            let part = try splitHeaders(Data(body[range]))
            let headers = try MIMEHeaders(part.header, defaultType: "text/plain")
            guard headers.fields.values.allSatisfy({ $0.count == 1 }),
                  !headers.mediaType.hasPrefix("multipart/") else { throw MailBodyRejection.malformedMIME }
            segments.append(contentDigest(Data(body[cursor..<range.lowerBound])))
            segments.append(contentDigest(try JSONSerialization.data(withJSONObject: headers.fields, options: [.sortedKeys])))
            segments.append(contentDigest(try TransferDecoding.apply(part.body, encoding: headers.encoding)))
            cursor = range.upperBound
        }
        segments.append(contentDigest(Data(body[cursor...])))
        return contentDigest(Data(segments.joined(separator: "|").utf8))
    }

    /// Ignore display names, preserve mailbox order and the case-sensitive local part.
    /// Unsupported groups/comments/quoted local parts fail closed.
    fileprivate static func mailboxList(_ value: String) -> [String]? {
        var tokens: [String] = [], token = "", quoted = false, escaped = false
        for ch in value {
            if escaped { token.append(ch); escaped = false; continue }
            if ch == "\\", quoted { token.append(ch); escaped = true; continue }
            if ch == "\"" { quoted.toggle() }
            if ch == ",", !quoted { tokens.append(token); token = "" } else { token.append(ch) }
        }
        guard !quoted, !escaped else { return nil }
        tokens.append(token)
        var addresses: [String] = []
        for token in tokens {
            let text = token.trimmingCharacters(in: .whitespaces)
            let address: String
            if let open = text.firstIndex(of: "<"), let close = text.lastIndex(of: ">") {
                guard open < close, text[text.index(after: close)...].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                address = String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            } else { address = text }
            let halves = address.split(separator: "@", omittingEmptySubsequences: false)
            guard halves.count == 2, !halves[0].isEmpty, !halves[1].isEmpty,
                  address.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else { return nil }
            addresses.append(String(halves[0]) + "@" + halves[1].lowercased())
        }
        return addresses
    }
}

/// Display-only original header addresses. Never an account identity or send destination.
/// To/Cc do not prove the envelope recipient (Bcc and aliases may be absent).
public struct MailCorrespondents: Codable, Equatable, Sendable {
    public let sender: String?
    public let recipients: [String]
    public let cc: [String]
    public init?(_ raw: Data) {
        guard raw.count <= MailBodyLimits.rawCeiling,
              let split = try? splitHeaders(raw),
              let headers = try? MIMEHeaders(split.header, defaultType: "text/plain") else { return nil }
        func addresses(_ key: String) -> [String] {
            guard let values = headers.fields[key], values.count == 1,
                  values[0].utf8.count <= 16_384,
                  let result = MailSourceEvidence.mailboxList(values[0]) else { return [] }
            return Array(result.prefix(100))
        }
        let from = addresses("from")
        sender = from.count == 1 ? from[0] : nil
        recipients = addresses("to")
        cc = addresses("cc")
    }
}

/// Reply-To takes precedence. Malformed/ambiguous Reply-To never falls back to From.
public enum MailReplyRecipients {
    public static func parse(_ raw: Data) throws -> [String] {
        guard raw.count <= MailBodyLimits.rawCeiling else { throw MailComposeError.invalidRecipient }
        let split = try splitHeaders(raw)
        let headers = try MIMEHeaders(split.header, defaultType: "text/plain")
        let key = headers.fields["reply-to"] == nil ? "from" : "reply-to"
        guard let values = headers.fields[key], values.count == 1,
              let addresses = MailSourceEvidence.mailboxList(values[0]),
              (1...20).contains(addresses.count), key != "from" || addresses.count == 1 else {
            throw MailComposeError.invalidRecipient
        }
        return addresses
    }
}

public enum PlainMailBody {
    public static func decode(_ raw: Data, fromMailKit: Bool = false) throws -> String {
        try extract(raw, fromMailKit: fromMailKit).text
    }

    public static func extract(_ raw: Data, fromMailKit: Bool = false) throws -> MailBodyExtraction {
        let (readable, entity) = try readableBody(raw, forDisplay: false, fromMailKit: fromMailKit)
        let bounded = BodyBound.fit(readable, attachments: entity.attachments, alreadyCut: entity.truncated)
        guard !bounded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MailBodyRejection.emptyBody
        }
        return MailBodyExtraction(text: bounded.text, truncated: bounded.truncated, attachments: entity.attachments)
    }

    public static func displayText(_ raw: Data, fromMailKit: Bool = false) throws -> String {
        try readableBody(raw, forDisplay: true, fromMailKit: fromMailKit).0
    }

    private static func readableBody(_ raw: Data, forDisplay: Bool, fromMailKit: Bool) throws -> (String, EntityResult) {
        guard raw.count <= MailBodyLimits.rawCeiling else { throw MailBodyRejection.messageTooLarge }
        var counter = 0
        let entity = try MIMEEntity(forDisplay: forDisplay, fromMailKit: fromMailKit).parse(raw, depth: 0, defaultType: "text/plain", counter: &counter)
        let readable = entity.body.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if readable.isEmpty {
            if entity.encrypted { throw MailBodyRejection.encryptedContent }
            if entity.opaqueSignature { throw MailBodyRejection.signedOpaque }
            if entity.charsetFailed { throw MailBodyRejection.unsupportedCharset }
            let calendars = Set(["text/calendar", "application/ics"])
            if entity.calendar, entity.attachments.allSatisfy({ calendars.contains($0.mediaType) }) {
                throw MailBodyRejection.calendarOnly
            }
            if !entity.attachments.isEmpty { throw MailBodyRejection.attachmentOnly }
            if entity.unsupported { throw MailBodyRejection.unsupportedContent }
            if entity.calendar { throw MailBodyRejection.calendarOnly }
            throw MailBodyRejection.emptyBody
        }
        return (readable, entity)
    }
}

// MARK: - Bounding

private enum BodyBound {
    static func fit(_ text: String, attachments: [MailAttachmentNote], alreadyCut: Bool) -> (text: String, truncated: Bool) {
        var truncated = alreadyCut
        var body = normalize(text)
        if body.utf8.count > MailBodyLimits.extractCap {
            body = utf8Prefix(body, MailBodyLimits.extractCap)
            truncated = true
        }
        let budget = MailBodyLimits.modelBudget
        if body.utf8.count > budget, let kept = quoteCut(body) {
            body = kept + "\n" + MailBodyLimits.quotedMarker
            truncated = true
        }
        if body.utf8.count > budget, let kept = signatureCut(body) {
            body = kept + "\n" + MailBodyLimits.signatureMarker
            truncated = true
        }
        if body.utf8.count > budget {
            let marker = "\n" + MailBodyLimits.truncatedMarker
            body = utf8Prefix(body, budget - marker.utf8.count) + marker
            truncated = true
        }
        guard !attachments.isEmpty else { return (body, truncated) }
        let full = attachmentNote(attachments, detailed: true)
        let short = "[attachments: \(attachments.count)]"
        if (body + "\n" + full).utf8.count <= budget {
            return (body + "\n" + full, truncated)
        }
        if (body + "\n" + short).utf8.count <= budget {
            return (body + "\n" + short, truncated)
        }
        let room = budget - short.utf8.count - 1
        let shrunk = utf8Prefix(body, max(0, room)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (shrunk + "\n" + short, true)
    }

    static func normalize(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\u{feff}", with: "")
        value = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        while value.contains("\n\n\n") { value = value.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func utf8Prefix(_ text: String, _ budget: Int) -> String {
    guard budget > 0 else { return "" }
    if text.utf8.count <= budget { return text }
    var count = 0
    var end = text.startIndex
    for index in text.indices {
        let next = text.utf8.distance(from: index, to: text.index(after: index))
        if count + next > budget { break }
        count += next
        end = text.index(after: index)
    }
    return String(text[..<end])
}

private func quoteCut(_ text: String) -> String? {
    let lines = text.components(separatedBy: "\n")
    guard let index = lines.indices.first(where: { quoteStarts(lines, $0) }), index > 0 else { return nil }
    let prefix = lines[..<index].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prefix.isEmpty else { return nil }
    return prefix
}

private func quoteStarts(_ lines: [String], _ index: Int) -> Bool {
    let line = lines[index].trimmingCharacters(in: .whitespaces)
    if line.hasPrefix(">") { return true }
    let lower = line.lowercased()
    if lower.hasPrefix("on "), (lower.contains("wrote:") || lower.contains("wrote：")) { return true }
    if line.contains("写道") { return true }
    if lower.contains("original message") { return true }
    if line.contains("原始邮件") { return true }
    let underscores = line.filter { $0 == "_" }.count
    if underscores >= 5, line.allSatisfy({ $0 == "_" || $0 == " " || $0 == "\t" }) { return true }
    let starters = ["from:", "发件人:", "发件人："]
    guard starters.contains(where: { lower.hasPrefix($0) || line.hasPrefix($0) }) else { return false }
    let window = lines[index..<min(index + 6, lines.count)].joined(separator: "\n").lowercased()
    return window.contains("sent:") || window.contains("date:") || window.contains("to:")
        || window.contains("发送时间") || window.contains("日期") || window.contains("收件人")
}

private func signatureCut(_ text: String) -> String? {
    let lines = text.components(separatedBy: "\n")
    guard let index = lines.indices.last(where: { lines[$0] == "-- " || lines[$0] == "--" }), index > 0 else { return nil }
    let prefix = lines[..<index].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prefix.isEmpty else { return nil }
    return prefix
}

private func attachmentNote(_ notes: [MailAttachmentNote], detailed: Bool) -> String {
    guard detailed else { return "[attachments: \(notes.count)]" }
    var parts: [String] = []
    for note in notes {
        let type = sanitizeToken(note.mediaType, limit: 80)
        if let name = note.filename.flatMap({ sanitizeToken($0, limit: 80) }), !name.isEmpty {
            parts.append("\(name) (\(type))")
        } else {
            parts.append(type)
        }
    }
    let line = "[attachments: " + parts.joined(separator: ", ") + "]"
    if line.utf8.count <= 500 { return line }
    return "[attachments: \(notes.count)]"
}

private func sanitizeToken(_ value: String, limit: Int) -> String {
    let cleaned = value.unicodeScalars.map { scalar -> Character in
        if scalar.value < 32 || scalar == "[" || scalar == "]" { return " " }
        return Character(scalar)
    }
    let text = String(cleaned).split(whereSeparator: { $0 == " " }).joined(separator: " ")
    if text.utf8.count <= limit { return text }
    return utf8Prefix(text, limit)
}

// MARK: - MIME

private struct EntityResult {
    var body: String?
    var plain: String?
    var html: String?
    var mediaType: String = "text/plain"
    var attachments: [MailAttachmentNote] = []
    var encrypted = false
    var opaqueSignature = false
    var calendar = false
    var unsupported = false
    var charsetFailed = false
    var truncated = false

    func mergedFlags(into other: inout EntityResult) {
        other.attachments.append(contentsOf: attachments)
        other.encrypted = other.encrypted || encrypted
        other.opaqueSignature = other.opaqueSignature || opaqueSignature
        other.calendar = other.calendar || calendar
        other.unsupported = other.unsupported || unsupported
        other.charsetFailed = other.charsetFailed || charsetFailed
        other.truncated = other.truncated || truncated
    }
}

private struct MIMEEntity {
    let forDisplay: Bool
    let fromMailKit: Bool

    func parse(_ data: Data, depth: Int, defaultType: String, counter: inout Int) throws -> EntityResult {
        counter += 1
        if counter > MailBodyLimits.maxParts || depth > MailBodyLimits.maxDepth { throw MailBodyRejection.malformedMIME }
        let split = try splitHeaders(data)
        let headers = try MIMEHeaders(split.header, defaultType: defaultType)
        let type = headers.mediaType
        // Attachment disposition applies to containers and embedded messages too.
        // Do not decode or recurse into their contents.
        if headers.disposition == "attachment" {
            return EntityResult(mediaType: type, attachments: [note(headers)], calendar: isCalendar(type))
        }
        let payload = try TransferDecoding.apply(split.body, encoding: headers.encoding)
        if isOpaqueSigned(type, parameters: headers.parameters) {
            return EntityResult(mediaType: type, opaqueSignature: true)
        }
        if isEncrypted(type) || type == "multipart/encrypted" {
            return EntityResult(mediaType: type, encrypted: true)
        }
        if type == "multipart/signed" {
            let children = try parts(payload, headers: headers, depth: depth, counter: &counter, defaultChild: "text/plain")
            guard let content = children.first(where: { !isDetachedSignature($0.mediaType) }) else {
                return EntityResult(mediaType: type, opaqueSignature: true)
            }
            var result = content
            result.mediaType = type
            if (result.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.opaqueSignature = true
            }
            return result
        }
        if type.hasPrefix("multipart/") {
            let childDefault = type == "multipart/digest" ? "message/rfc822" : "text/plain"
            let children = try parts(payload, headers: headers, depth: depth, counter: &counter, defaultChild: childDefault)
            if type == "multipart/alternative" { return alternative(children, mediaType: type) }
            return mixed(children, mediaType: type)
        }
        if type == "message/rfc822" || type == "message/global" {
            return try parse(payload, depth: depth + 1, defaultType: "text/plain", counter: &counter)
        }
        if isCalendar(type) {
            return EntityResult(mediaType: type, attachments: [note(headers)], calendar: true)
        }
        if type == "text/plain" || type == "text/html" {
            return try textPart(payload, headers: headers)
        }
        if isAttachment(type) {
            return EntityResult(mediaType: type, attachments: [note(headers)])
        }
        return EntityResult(mediaType: type, unsupported: true)
    }

    func textPart(_ payload: Data, headers: MIMEHeaders) throws -> EntityResult {
        if payload.contains(0) { throw MailBodyRejection.malformedMIME }
        let charset = try charsetFor(headers: headers, payload: payload)
        let limit = forDisplay ? max(1, payload.count * 4) : MailBodyLimits.extractCap
        let decoded = try CharsetText.decode(payload, charset: charset, limit: limit)
        let converted: String
        let htmlDocument = forDisplay && decoded.text.range(
            of: #"^\s*(?:<!doctype\s+html\b|<html(?:\s|>))"#,
            options: [.regularExpression, .caseInsensitive]) != nil
        if headers.mediaType == "text/html" || htmlDocument {
            converted = HTMLText.convert(decoded.text)
        } else {
            converted = try Armor.unwrap(decoded.text)
        }
        let text = forDisplay ? converted.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : BodyBound.normalize(converted)
        if text.contains("\0") { throw MailBodyRejection.malformedMIME }
        var result = EntityResult(mediaType: headers.mediaType, truncated: decoded.truncated)
        if headers.mediaType == "text/html" {
            result.html = text
            result.body = text
        } else {
            result.plain = text
            result.body = text
        }
        return result
    }

    func alternative(_ children: [EntityResult], mediaType: String) -> EntityResult {
        var result = EntityResult(mediaType: mediaType)
        for child in children { child.mergedFlags(into: &result) }
        let plain = children.compactMap(\.plain).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let html = children.compactMap(\.html).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let fallback = children.compactMap(\.body).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        result.body = plain ?? html ?? fallback
        result.plain = plain
        result.html = html
        return result
    }

    func mixed(_ children: [EntityResult], mediaType: String) -> EntityResult {
        var result = EntityResult(mediaType: mediaType)
        var texts: [String] = []
        for child in children {
            child.mergedFlags(into: &result)
            if let body = child.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                texts.append(body)
            }
        }
        if !texts.isEmpty {
            let joined = texts.joined(separator: "\n\n")
            result.body = joined
            result.plain = joined
        }
        return result
    }

    func parts(_ payload: Data, headers: MIMEHeaders, depth: Int, counter: inout Int, defaultChild: String) throws -> [EntityResult] {
        let declared = headers.parameters["boundary"]
        let canRecover = fromMailKit && depth == 0 && headers.mediaType == "multipart/alternative"
        guard let boundary = declared ?? (canRecover ? MIMESplit.enclosingBoundary(payload) : nil),
              !boundary.isEmpty, boundary.utf8.count <= 70 else {
            throw MailBodyRejection.malformedMIME
        }
        let slices = try MIMESplit.parts(payload, boundary: boundary)
        var children: [EntityResult] = []
        for slice in slices {
            do {
                children.append(try parse(slice, depth: depth + 1, defaultType: defaultChild, counter: &counter))
            } catch MailBodyRejection.unsupportedCharset {
                children.append(EntityResult(charsetFailed: true))
            }
        }
        return children
    }

    func note(_ headers: MIMEHeaders) -> MailAttachmentNote {
        MailAttachmentNote(filename: headers.filename, mediaType: headers.mediaType)
    }
}

private struct MIMEHeaders {
    var fields: [String: [String]]
    var mediaType: String
    var parameters: [String: String]
    var encoding: String
    var disposition: String?
    var filename: String?

    var subtype: String { mediaType.split(separator: "/").last.map(String.init) ?? "" }

    init(_ header: Data, defaultType: String) throws {
        guard header.count <= MailBodyLimits.maxHeaderBytes else { throw MailBodyRejection.malformedMIME }
        let text = headerText(header)
        let unfolded = unfold(text)
        var fields: [String: [String]] = [:]
        for rawLine in unfolded.split(separator: "\n", omittingEmptySubsequences: false) {
            if rawLine.isEmpty { continue }
            let pair = rawLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty, pair[0].allSatisfy({ !$0.isWhitespace }) else {
                throw MailBodyRejection.malformedMIME
            }
            fields[String(pair[0]).lowercased(), default: []].append(String(pair[1]).trimmingCharacters(in: .whitespaces))
        }
        guard (fields["content-type"]?.count ?? 0) <= 1,
              (fields["content-transfer-encoding"]?.count ?? 0) <= 1,
              (fields["content-disposition"]?.count ?? 0) <= 1 else { throw MailBodyRejection.malformedMIME }
        self.fields = fields
        let typeValue = fields["content-type"]?.first ?? defaultType
        let parsed = try MediaType.parse(typeValue)
        mediaType = parsed.type
        parameters = parsed.parameters
        encoding = (fields["content-transfer-encoding"]?.first ?? "7bit").lowercased()
        if let dispositionValue = fields["content-disposition"]?.first {
            let parsedDisposition = try MediaType.parse(dispositionValue)
            disposition = parsedDisposition.type
            filename = MIMEHeaders.filename(disposition: parsedDisposition.parameters, type: parameters)
        } else {
            disposition = nil
            filename = MIMEHeaders.filename(disposition: [:], type: parameters)
        }
    }

    static func filename(disposition: [String: String], type: [String: String]) -> String? {
        if let value = rfc2231(disposition, key: "filename") { return value }
        if let value = disposition["filename"] { return EncodedWords.decode(value) }
        if let value = rfc2231(type, key: "name") { return value }
        if let value = type["name"] { return EncodedWords.decode(value) }
        return nil
    }
}

private enum MediaType {
    static func parse(_ value: String) throws -> (type: String, parameters: [String: String]) {
        var scanner = HeaderScanner(value)
        guard let type = scanner.token()?.lowercased(), type.contains("/") || !type.contains("=") else {
            throw MailBodyRejection.malformedMIME
        }
        var parameters: [String: String] = [:]
        while !scanner.rest.isEmpty {
            scanner.skipSpaces()
            guard scanner.consume(";") else { break }
            scanner.skipSpaces()
            guard let name = scanner.token() else { throw MailBodyRejection.malformedMIME }
            scanner.skipSpaces()
            guard scanner.consume("=") else { throw MailBodyRejection.malformedMIME }
            scanner.skipSpaces()
            guard let parameter = scanner.parameterValue() else { throw MailBodyRejection.malformedMIME }
            parameters[name.lowercased()] = parameter
            scanner.skipSpaces()
        }
        return (type.lowercased(), parameters)
    }
}

private struct HeaderScanner {
    var rest: Substring
    init(_ value: String) { rest = Substring(value) }

    mutating func skipSpaces() {
        while let first = rest.first, first == " " || first == "\t" { rest.removeFirst() }
    }

    mutating func consume(_ character: Character) -> Bool {
        guard rest.first == character else { return false }
        rest.removeFirst()
        return true
    }

    mutating func token() -> String? {
        skipSpaces()
        var token = ""
        while let first = rest.first, !first.isWhitespace, first != ";", first != "=" {
            token.append(first)
            rest.removeFirst()
        }
        return token.isEmpty ? nil : token
    }

    mutating func parameterValue() -> String? {
        skipSpaces()
        if rest.first == "\"" {
            rest.removeFirst()
            var value = ""
            while let first = rest.first {
                rest.removeFirst()
                if first == "\\" , let next = rest.first {
                    value.append(next)
                    rest.removeFirst()
                    continue
                }
                if first == "\"" { break }
                value.append(first)
            }
            return value
        }
        return token()
    }
}

private func headerText(_ data: Data) -> String {
    if let text = String(data: data, encoding: .utf8) { return text }
    return String(String.UnicodeScalarView(data.map { Unicode.Scalar($0) }))
}

private func unfold(_ value: String) -> String {
    value.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\n\t", with: " ")
        .replacingOccurrences(of: "\n ", with: " ")
}

private func splitHeaders(_ data: Data) throws -> (header: Data, body: Data) {
    if let range = data.range(of: Data([13, 10, 13, 10])) {
        return (data[..<range.lowerBound], data[range.upperBound...])
    }
    if let range = data.range(of: Data([10, 10])) {
        return (data[..<range.lowerBound], data[range.upperBound...])
    }
    throw MailBodyRejection.malformedMIME
}

private enum MIMESplit {
    // MailKit can omit the outer parameter while preserving both delimiter lines.
    static func enclosingBoundary(_ data: Data) -> String? {
        let first = data.prefix(75).prefix { $0 != 10 && $0 != 13 }
        guard first.starts(with: [45, 45]), (3...72).contains(first.count),
              first.dropFirst(2).allSatisfy({ (33...126).contains($0) }) else { return nil }
        let end = data.lastIndex { $0 != 10 && $0 != 13 }
        guard let end, data[...end].suffix(first.count + 3).elementsEqual([10] + first + [45, 45]) else { return nil }
        return String(bytes: first.dropFirst(2), encoding: .ascii)
    }

    static func parts(_ data: Data, boundary: String) throws -> [Data] {
        try partRanges(data, boundary: boundary).map { Data(data[$0]) }
    }
    static func partRanges(_ data: Data, boundary: String) throws -> [Range<Int>] {
        let bytes = [UInt8](data)
        var starts = [0]
        for index in bytes.indices where bytes[index] == 10 { starts.append(index + 1) }
        func content(_ line: Int) -> [UInt8] {
            let begin = starts[line]
            var end = line + 1 < starts.count ? starts[line + 1] : bytes.count
            if end > begin, bytes[end - 1] == 10 { end -= 1 }
            if end > begin, bytes[end - 1] == 13 { end -= 1 }
            return Array(bytes[begin..<end])
        }
        let open = Array("--\(boundary)".utf8)
        let close = Array("--\(boundary)--".utf8)
        func kind(_ line: [UInt8]) -> Int {
            var trimmed = line
            while let last = trimmed.last, last == 32 || last == 9 { trimmed.removeLast() }
            if trimmed == close { return 2 }
            if trimmed == open { return 1 }
            return 0
        }
        var opens: [Int] = []
        var closing: Int?
        for line in 0..<starts.count {
            switch kind(content(line)) {
            case 1: opens.append(line)
            case 2: closing = line
            default: break
            }
            if closing != nil { break }
        }
        guard !opens.isEmpty, let closing else { throw MailBodyRejection.malformedMIME }
        var slices: [Range<Int>] = []
        let markers = opens + [closing]
        for index in 0..<(markers.count - 1) {
            let from = starts[markers[index]] + content(markers[index]).count
            let newline = from < bytes.count && bytes[from] == 13 ? 2 : 1
            let start = min(from + newline, bytes.count)
            var end = markers[index + 1] < starts.count ? starts[markers[index + 1]] : bytes.count
            if end >= 2, bytes[end - 1] == 10, bytes[end - 2] == 13 { end -= 2 }
            else if end >= 1, bytes[end - 1] == 10 { end -= 1 }
            slices.append((data.startIndex + start)..<(data.startIndex + max(start, end)))
        }
        return slices
    }
}

private enum TransferDecoding {
    static func apply(_ data: Data, encoding: String) throws -> Data {
        switch encoding {
        case "7bit", "8bit", "binary": return data
        case "base64": return try base64(data)
        case "quoted-printable": return try quotedPrintable(data)
        default: throw MailBodyRejection.malformedMIME
        }
    }

    static func base64(_ data: Data) throws -> Data {
        let filtered = data.filter { byte in
            byte != 32 && byte != 9 && byte != 10 && byte != 13
        }
        if filtered.isEmpty { return Data() }
        guard filtered.allSatisfy({ isBase64($0) }) else { throw MailBodyRejection.malformedMIME }
        guard let decoded = Data(base64Encoded: filtered) else { throw MailBodyRejection.malformedMIME }
        return decoded
    }

    static func isBase64(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 43 || byte == 47 || byte == 61
    }

    static func quotedPrintable(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var result = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] == 61 {
                if index + 1 < bytes.count, bytes[index + 1] == 10 { index += 2; continue }
                if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 { index += 3; continue }
                guard index + 2 < bytes.count, let value = hexByte(bytes[index + 1], bytes[index + 2]) else {
                    throw MailBodyRejection.malformedMIME
                }
                result.append(value)
                index += 3
            } else {
                result.append(bytes[index])
                index += 1
            }
        }
        return result
    }

    static func hexByte(_ high: UInt8, _ low: UInt8) -> UInt8? {
        guard let h = hex(high), let l = hex(low) else { return nil }
        return (h << 4) | l
    }

    static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}

// MARK: - Charset

private func charsetFor(headers: MIMEHeaders, payload: Data) throws -> String {
    if let value = headers.parameters["charset"], !value.isEmpty { return value }
    if headers.mediaType == "text/html", let meta = htmlMetaCharset(payload) { return meta }
    return "us-ascii"
}

private func htmlMetaCharset(_ data: Data) -> String? {
    let sample = data.prefix(4_096)
    let text = String(String.UnicodeScalarView(sample.map { Unicode.Scalar($0) }))
    let lower = text.lowercased()
    if let range = lower.range(of: "charset=") {
        var value = text[range.upperBound...]
        if value.first == "\"" || value.first == "'" { value.removeFirst() }
        let end = value.firstIndex(where: { $0 == "\"" || $0 == "'" || $0 == ";" || $0 == ">" || $0 == " " || $0 == "/" }) ?? value.endIndex
        let name = value[..<end].trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return String(name) }
    }
    return nil
}

private enum CharsetText {
    static func decode(_ data: Data, charset: String, limit: Int) throws -> (text: String, truncated: Bool) {
        let name = try canonical(charset)
        if name == "UTF-8" {
            guard let text = String(data: data, encoding: .utf8) else { throw MailBodyRejection.unsupportedCharset }
            if text.utf8.count > limit { return (utf8Prefix(text, limit), true) }
            return (text, false)
        }
        if name == "US-ASCII" {
            guard data.allSatisfy({ $0 < 0x80 }) else { throw MailBodyRejection.unsupportedCharset }
            let text = String(decoding: data, as: UTF8.self)
            if text.utf8.count > limit { return (utf8Prefix(text, limit), true) }
            return (text, false)
        }
        var output: UnsafeMutablePointer<UInt8>?
        var outputLength = 0
        let code: Int32 = data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            return mailpipe_iconv_utf8(name, base, data.count, limit, &output, &outputLength)
        }
        defer { mailpipe_iconv_free(output) }
        guard code >= 0, let output else { throw MailBodyRejection.unsupportedCharset }
        let bytes = Data(bytes: output, count: outputLength)
        guard let text = String(data: bytes, encoding: .utf8) else { throw MailBodyRejection.unsupportedCharset }
        return (text, code == 1)
    }

    /// Labeled `gb2312` is decoded as GBK. Real mail uses that label for GBK bytes.
    static func canonical(_ charset: String) throws -> String {
        let key = charset.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if let mapped = aliases[key] { return mapped }
        throw MailBodyRejection.unsupportedCharset
    }

    static let aliases: [String: String] = {
        var map: [String: String] = [
            "utf-8": "UTF-8", "utf8": "UTF-8",
            "us-ascii": "US-ASCII", "ascii": "US-ASCII", "ansi-x3.4-1968": "US-ASCII",
            "gbk": "GBK", "cp936": "GBK", "ms936": "GBK", "windows-936": "GBK",
            "gb2312": "GBK", "gb-2312": "GBK", "csgb2312": "GBK", "euc-cn": "GBK", "cn-gb": "GBK",
            "gb18030": "GB18030",
            "big5": "BIG5", "big5-hkscs": "BIG5-HKSCS", "cn-big5": "BIG5", "csbig5": "BIG5",
            "iso-2022-jp": "ISO-2022-JP", "csiso2022jp": "ISO-2022-JP",
            "latin1": "ISO-8859-1", "latin-1": "ISO-8859-1", "iso-latin-1": "ISO-8859-1"
        ]
        for number in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 15, 16] {
            map["iso-8859-\(number)"] = "ISO-8859-\(number)"
            map["iso8859-\(number)"] = "ISO-8859-\(number)"
        }
        for number in 0...8 {
            map["windows-125\(number)"] = "WINDOWS-125\(number)"
            map["cp125\(number)"] = "WINDOWS-125\(number)"
        }
        return map
    }()
}

// MARK: - RFC 2047 / 2231

private enum EncodedWords {
    static func decode(_ value: String) -> String {
        var result = ""
        var index = value.startIndex
        var pendingSpace = ""
        var lastWasWord = false
        while index < value.endIndex {
            if let word = parse(value, at: &index) {
                if lastWasWord { pendingSpace = "" } else { result += pendingSpace }
                pendingSpace = ""
                result += word
                lastWasWord = true
                continue
            }
            let character = value[index]
            if lastWasWord, character == " " || character == "\t" {
                pendingSpace.append(character)
            } else {
                result += pendingSpace
                pendingSpace = ""
                lastWasWord = false
                result.append(character)
            }
            index = value.index(after: index)
        }
        return result + pendingSpace
    }

    static func parse(_ value: String, at index: inout String.Index) -> String? {
        guard value[index...].hasPrefix("=?") else { return nil }
        let start = index
        var cursor = value.index(index, offsetBy: 2)
        guard let charsetEnd = value[cursor...].firstIndex(of: "?"), charsetEnd > cursor else { return nil }
        let charset = String(value[cursor..<charsetEnd])
        cursor = value.index(after: charsetEnd)
        guard cursor < value.endIndex else { return nil }
        let coding = value[cursor]
        guard coding == "B" || coding == "b" || coding == "Q" || coding == "q" else { return nil }
        cursor = value.index(after: cursor)
        guard cursor < value.endIndex, value[cursor] == "?" else { return nil }
        cursor = value.index(after: cursor)
        guard let end = value[cursor...].range(of: "?=") else { return nil }
        let payload = String(value[cursor..<end.lowerBound])
        index = end.upperBound
        let bytes: Data
        if coding == "B" || coding == "b" {
            guard let decoded = Data(base64Encoded: payload.filter { !$0.isWhitespace }) else {
                index = start
                return nil
            }
            bytes = decoded
        } else {
            bytes = qDecode(payload)
        }
        guard let text = try? CharsetText.decode(bytes, charset: charset, limit: MailBodyLimits.extractCap).text else {
            index = start
            return nil
        }
        return text
    }

    static func qDecode(_ value: String) -> Data {
        var bytes = [UInt8]()
        let scalars = Array(value.utf8)
        var index = 0
        while index < scalars.count {
            if scalars[index] == 95 {
                bytes.append(32)
                index += 1
            } else if scalars[index] == 61, index + 2 < scalars.count,
                      let byte = TransferDecoding.hexByte(scalars[index + 1], scalars[index + 2]) {
                bytes.append(byte)
                index += 3
            } else {
                bytes.append(scalars[index])
                index += 1
            }
        }
        return Data(bytes)
    }
}

private func rfc2231(_ parameters: [String: String], key: String) -> String? {
    if let single = parameters[key + "*"] { return decode2231(single, leadingCharset: true) }
    var sections: [(Int, String, Bool)] = []
    for (name, value) in parameters {
        let prefix = key + "*"
        guard name.hasPrefix(prefix) else { continue }
        var rest = name.dropFirst(prefix.count)
        let extended = rest.hasSuffix("*")
        if extended { rest.removeLast() }
        guard let number = Int(rest) else { continue }
        sections.append((number, value, extended))
    }
    guard !sections.isEmpty else { return nil }
    sections.sort { $0.0 < $1.0 }
    var charset: String?
    var bytes = Data()
    for (index, value, extended) in sections {
        if extended {
            if index == 0 {
                let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                guard pieces.count == 3 else { return nil }
                charset = String(pieces[0])
                bytes.append(percentBytes(String(pieces[2])))
            } else {
                bytes.append(percentBytes(value))
            }
        } else {
            bytes.append(Data(value.utf8))
        }
    }
    let decoded: String
    if let charset {
        guard let text = try? CharsetText.decode(bytes, charset: charset, limit: 2_048).text else { return nil }
        decoded = text
    } else if let text = String(data: bytes, encoding: .utf8) {
        decoded = text
    } else {
        return nil
    }
    return decoded
}

private func decode2231(_ value: String, leadingCharset: Bool) -> String? {
    guard leadingCharset else { return value }
    let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
    guard pieces.count == 3 else { return nil }
    let bytes = percentBytes(String(pieces[2]))
    return try? CharsetText.decode(bytes, charset: String(pieces[0]), limit: 2_048).text
}

private func percentBytes(_ value: String) -> Data {
    var bytes = [UInt8]()
    let scalars = Array(value.utf8)
    var index = 0
    while index < scalars.count {
        if scalars[index] == 37, index + 2 < scalars.count, let byte = TransferDecoding.hexByte(scalars[index + 1], scalars[index + 2]) {
            bytes.append(byte)
            index += 3
        } else {
            bytes.append(scalars[index])
            index += 1
        }
    }
    return Data(bytes)
}

// MARK: - Armor and classification

private enum Armor {
    static func unwrap(_ text: String) throws -> String {
        if let signed = clearSigned(text) { return signed }
        if let range = text.range(of: "-----BEGIN PGP MESSAGE-----") {
            let end = text.range(of: "-----END PGP MESSAGE-----").map { text[$0.upperBound...] } ?? ""
            let rest = (text[..<range.lowerBound] + end).trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.count < 20 { throw MailBodyRejection.encryptedContent }
            return rest + "\n[encrypted part omitted]"
        }
        return text
    }

    static func clearSigned(_ text: String) -> String? {
        guard let start = text.range(of: "-----BEGIN PGP SIGNED MESSAGE-----"),
              let signature = text.range(of: "-----BEGIN PGP SIGNATURE-----"),
              signature.lowerBound > start.lowerBound else { return nil }
        let preface = text[..<start.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let header = text[start.upperBound..<signature.lowerBound]
        var lines = header.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        guard let blank = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let body = lines[(blank + 1)...].map { line -> String in
            line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return preface.isEmpty ? body : preface + "\n" + body
    }
}

private func isEncrypted(_ type: String) -> Bool {
    ["application/pkcs7-mime", "application/x-pkcs7-mime", "application/pgp-encrypted"].contains(type)
}

private func isOpaqueSigned(_ type: String, parameters: [String: String]) -> Bool {
    guard type == "application/pkcs7-mime" || type == "application/x-pkcs7-mime" else { return false }
    return parameters["smime-type"]?.lowercased() == "signed-data"
}

private func isDetachedSignature(_ type: String) -> Bool {
    ["application/pgp-signature", "application/pkcs7-signature", "application/x-pkcs7-signature"].contains(type)
}

private func isCalendar(_ type: String) -> Bool {
    type == "text/calendar" || type == "application/ics"
}

private func isAttachment(_ type: String) -> Bool {
    if type.hasPrefix("image/") || type.hasPrefix("audio/") || type.hasPrefix("video/") { return true }
    let blocked = [
        "application/pdf", "application/zip", "application/gzip", "application/octet-stream",
        "application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/ms-tnef", "application/vnd.ms-tnef", "application/x-apple-msg-attachment"
    ]
    return blocked.contains(type)
}

// MARK: - HTML

private enum HTMLText {
    static func convert(_ html: String) -> String {
        var scanner = HTMLScanner(html)
        return BodyBound.normalize(scanner.convert())
    }
}

private struct HTMLFrame {
    var name: String
    var skip = false
    var quote = false
    var pre = false
    var signature = false
}

private struct HTMLScanner {
    var source: String
    var index: String.Index
    var output = ""
    var stack: [HTMLFrame] = []
    var anchors: [(href: String, count: Int)] = []
    var lists: [(ordered: Bool, item: Int)] = []

    init(_ html: String) {
        source = html
        index = html.startIndex
    }

    var skipping: Bool { stack.contains { $0.skip } }

    mutating func convert() -> String {
        while index < source.endIndex {
            if source[index] == "<" {
                if source[index...].hasPrefix("<!--") {
                    skipUntil("-->")
                    continue
                }
                if let tag = readTag() {
                    apply(tag)
                    continue
                }
                emit("<")
                continue
            }
            let text = readText()
            if !skipping, !text.isEmpty { emit(decodeEntities(text)) }
        }
        return finishRegions(output)
    }

    mutating func apply(_ tag: HTMLTag) {
        let name = tag.name
        if tag.closing {
            close(name)
            return
        }
        if ["script", "style", "head", "title", "svg"].contains(name) {
            stack.append(HTMLFrame(name: name, skip: true))
            return
        }
        if hidden(tag) {
            if !isVoid(name) { stack.append(HTMLFrame(name: name, skip: true)) }
            return
        }
        var frame = HTMLFrame(name: name)
        if name == "blockquote" || classTokens(tag).contains("gmail_quote") || classTokens(tag).contains("moz-cite-prefix") {
            frame.quote = true
            emit("\n\u{E000}")
        }
        if classTokens(tag).contains("gmail_signature") || classTokens(tag).contains("moz-signature") {
            frame.signature = true
            emit("\n-- \n")
        }
        if name == "pre" {
            frame.pre = true
            emit("\u{E002}")
        }
        if name == "br" || name == "hr" {
            emit("\n")
            return
        }
        if name == "img" {
            if let alt = tag.attributes["alt"]?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty, alt.utf8.count <= 80 {
                emit(decodeEntities(alt))
            }
            return
        }
        if name == "a" {
            anchors.append((tag.attributes["href"] ?? "", output.count))
        }
        if name == "ol" { lists.append((true, 0)) }
        if name == "ul" { lists.append((false, 0)) }
        if isBlock(name) { emit("\n") }
        if name == "li" {
            let indent = String(repeating: "  ", count: max(0, lists.count - 1))
            if !lists.isEmpty {
                var list = lists.removeLast()
                list.item += 1
                let marker = list.ordered ? "\(list.item). " : "- "
                lists.append(list)
                emit(indent + marker)
            } else {
                emit("- ")
            }
        }
        if !isVoid(name) { stack.append(frame) }
    }

    mutating func close(_ name: String) {
        if name == "a", let anchor = anchors.popLast() {
            let added = String(output.dropFirst(anchor.count))
            let rendered = renderLink(added, href: decodeEntities(anchor.href))
            output = String(output.prefix(anchor.count)) + rendered
        }
        if name == "ol" || name == "ul", !lists.isEmpty { lists.removeLast() }
        guard let found = stack.lastIndex(where: { $0.name == name }) else { return }
        let removed = stack[found...]
        stack.removeSubrange(found...)
        for frame in removed.reversed() {
            if frame.quote { emit("\n\u{E001}") }
            if frame.pre { emit("\u{E003}") }
            if isBlock(frame.name) { emit("\n") }
        }
    }

    mutating func emit(_ text: String) {
        guard !skipping else { return }
        output += text
    }

    mutating func readText() -> String {
        var text = ""
        while index < source.endIndex, source[index] != "<" {
            text.append(source[index])
            index = source.index(after: index)
        }
        return text
    }

    mutating func skipUntil(_ token: String) {
        if let range = source.range(of: token, range: index..<source.endIndex) {
            index = range.upperBound
        } else {
            index = source.endIndex
        }
    }

    mutating func readTag() -> HTMLTag? {
        let start = index
        guard source[index] == "<" else { return nil }
        var cursor = source.index(after: index)
        if cursor < source.endIndex, source[cursor] == "/" { cursor = source.index(after: cursor) }
        guard cursor < source.endIndex, source[cursor].isLetter else {
            index = source.index(after: start)
            return nil
        }
        var name = ""
        while cursor < source.endIndex, source[cursor].isLetter || source[cursor].isNumber {
            name.append(source[cursor])
            cursor = source.index(after: cursor)
        }
        var attributes: [String: String] = [:]
        while cursor < source.endIndex, source[cursor] != ">" {
            while cursor < source.endIndex, source[cursor].isWhitespace || source[cursor] == "/" { cursor = source.index(after: cursor) }
            if cursor < source.endIndex, source[cursor] == ">" { break }
            var attribute = ""
            while cursor < source.endIndex, source[cursor] != "=", source[cursor] != ">", !source[cursor].isWhitespace, source[cursor] != "/" {
                attribute.append(source[cursor])
                cursor = source.index(after: cursor)
            }
            while cursor < source.endIndex, source[cursor].isWhitespace { cursor = source.index(after: cursor) }
            var value = ""
            if cursor < source.endIndex, source[cursor] == "=" {
                cursor = source.index(after: cursor)
                while cursor < source.endIndex, source[cursor].isWhitespace { cursor = source.index(after: cursor) }
                if cursor < source.endIndex, source[cursor] == "\"" || source[cursor] == "'" {
                    let quote = source[cursor]
                    cursor = source.index(after: cursor)
                    while cursor < source.endIndex, source[cursor] != quote {
                        value.append(source[cursor])
                        cursor = source.index(after: cursor)
                    }
                    if cursor < source.endIndex { cursor = source.index(after: cursor) }
                } else {
                    while cursor < source.endIndex, !source[cursor].isWhitespace, source[cursor] != ">" {
                        value.append(source[cursor])
                        cursor = source.index(after: cursor)
                    }
                }
            }
            if !attribute.isEmpty { attributes[attribute.lowercased()] = value }
        }
        guard cursor < source.endIndex, source[cursor] == ">" else {
            index = source.index(after: start)
            return nil
        }
        index = source.index(after: cursor)
        let closing = source[source.index(after: start)] == "/"
        return HTMLTag(name: name.lowercased(), closing: closing, attributes: attributes)
    }
}

private struct HTMLTag {
    var name: String
    var closing: Bool
    var attributes: [String: String]
}

private func isBlock(_ name: String) -> Bool {
    ["p", "div", "tr", "table", "section", "article", "header", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "ul", "ol", "pre", "li"].contains(name)
}

private func isVoid(_ name: String) -> Bool {
    ["br", "hr", "img", "meta", "link", "input", "source", "wbr", "area", "base", "col", "embed"].contains(name)
}

private func classTokens(_ tag: HTMLTag) -> Set<String> {
    Set((tag.attributes["class"] ?? "").split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() })
}

private func hidden(_ tag: HTMLTag) -> Bool {
    guard let style = tag.attributes["style"]?.lowercased().replacingOccurrences(of: " ", with: "") else { return false }
    return style.contains("display:none") || style.contains("visibility:hidden")
}

private func renderLink(_ text: String, href: String) -> String {
    let visible = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = href.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = url.lowercased()
    if url.isEmpty || lower.hasPrefix("javascript:") || lower.hasPrefix("data:") || lower.hasPrefix("cid:") { return visible }
    guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") else {
        return visible.isEmpty ? "" : visible
    }
    let shown = readableURL(url)
    if visible.isEmpty { return shown }
    if visible == url || visible.contains(url) { return visible }
    return "\(visible) (\(shown))"
}

private func readableURL(_ url: String) -> String {
    if url.utf8.count <= 300 { return url }
    if let query = url.firstIndex(of: "?") {
        let base = String(url[..<query])
        if base.utf8.count <= 300 { return base }
    }
    return utf8Prefix(url, 300)
}

private func decodeEntities(_ text: String) -> String {
    var result = ""
    var index = text.startIndex
    while index < text.endIndex {
        if text[index] == "&", let end = text[index...].firstIndex(of: ";"), text.distance(from: index, to: end) <= 12 {
            let token = String(text[text.index(after: index)..<end])
            if let scalar = entity(token) {
                result.unicodeScalars.append(scalar)
                index = text.index(after: end)
                continue
            }
        }
        result.append(text[index])
        index = text.index(after: index)
    }
    return result
}

private func entity(_ token: String) -> Unicode.Scalar? {
    let named: [String: UInt32] = [
        "amp": 38, "lt": 60, "gt": 62, "quot": 34, "apos": 39, "nbsp": 160,
        "hellip": 8230, "mdash": 8212, "ndash": 8211, "rsquo": 8217, "lsquo": 8216,
        "rdquo": 8221, "ldquo": 8220, "bull": 8226, "middot": 183, "copy": 169
    ]
    if let value = named[token.lowercased()] { return Unicode.Scalar(value) }
    if token.hasPrefix("#x") || token.hasPrefix("#X"), let value = UInt32(token.dropFirst(2), radix: 16) {
        return Unicode.Scalar(value)
    }
    if token.hasPrefix("#"), let value = UInt32(token.dropFirst(), radix: 10) {
        return Unicode.Scalar(value)
    }
    return nil
}

private func finishRegions(_ text: String) -> String {
    var quote = 0
    var pre = false
    var result = ""
    var lineStart = true
    var index = text.startIndex
    while index < text.endIndex {
        let character = text[index]
        if character == "\u{E000}" { quote += 1; index = text.index(after: index); continue }
        if character == "\u{E001}" { quote = max(0, quote - 1); index = text.index(after: index); continue }
        if character == "\u{E002}" { pre = true; index = text.index(after: index); continue }
        if character == "\u{E003}" { pre = false; index = text.index(after: index); continue }
        if character == "\n" {
            result.append("\n")
            lineStart = true
            index = text.index(after: index)
            continue
        }
        if lineStart {
            if quote > 0 { result.append(String(repeating: "> ", count: quote)) }
            lineStart = false
        }
        if !pre, character == " " || character == "\t" {
            if let last = result.last, last == " " || last == "\n" || last == ">" {
                index = text.index(after: index)
                continue
            }
            result.append(" ")
        } else {
            result.append(character)
        }
        index = text.index(after: index)
    }
    return result
}
