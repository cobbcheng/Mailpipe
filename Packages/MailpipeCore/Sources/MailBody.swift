import Foundation
import MailpipeMailParserFFI

/// Limits for turning a raw message into model input.
/// Parsing stays on this Mac via stalwartlabs/mail-parser + html5gum. Nothing is fetched to clean HTML.
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

public struct MailAttachmentNote: Equatable, Sendable, Decodable {
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

// MARK: - Rust mail-parser FFI bridge

private enum MailParserBridge {
    private struct Response: Decodable {
        let ok: Bool
        let text: String?
        let truncated: Bool?
        let attachments: [MailAttachmentNote]?
        let rejection: String?
    }

    static func parse(_ raw: Data, forDisplay: Bool, fromMailKit: Bool) throws -> MailBodyExtraction {
        guard raw.count <= MailBodyLimits.rawCeiling else { throw MailBodyRejection.messageTooLarge }
        var outLen: Int = 0
        let ptr: UnsafeMutablePointer<UInt8>? = raw.withUnsafeBytes { buffer in
            let base = buffer.bindMemory(to: UInt8.self).baseAddress
            return mailpipe_parse_mail_body(base, raw.count, forDisplay, fromMailKit, &outLen)
        }
        guard let ptr, outLen > 0 else { throw MailBodyRejection.malformedMIME }
        defer { mailpipe_mail_parser_free(ptr, outLen) }
        let json = Data(bytes: ptr, count: outLen)
        guard let response = try? JSONDecoder().decode(Response.self, from: json) else {
            throw MailBodyRejection.malformedMIME
        }
        guard response.ok, let text = response.text else {
            if let code = response.rejection, let reason = MailBodyRejection(rawValue: code) {
                throw reason
            }
            throw MailBodyRejection.malformedMIME
        }
        return MailBodyExtraction(
            text: text,
            truncated: response.truncated ?? false,
            attachments: response.attachments ?? []
        )
    }

    static func decodeEncodedWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        let bytes = Array(value.utf8)
        var outLen: Int = 0
        let ptr: UnsafeMutablePointer<UInt8>? = bytes.withUnsafeBufferPointer { buffer in
            mailpipe_decode_encoded_words(buffer.baseAddress, buffer.count, &outLen)
        }
        guard let ptr else { return value }
        defer { mailpipe_mail_parser_free(ptr, outLen) }
        if outLen == 0 { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: outLen), as: UTF8.self)
    }
}

public enum MailHeaderCodec {
    /// The raw message may carry an ID that Mail omits from its projected header dictionary.
    public static func messageID(in raw: Data) -> String? {
        guard let split = try? splitHeaders(raw),
              let headers = try? MIMEHeaders(split.header, defaultType: "text/plain"),
              let values = headers.fields["message-id"], values.count == 1,
              ComposeMessageIdentity.digest(forMessageID: values[0]) != nil else { return nil }
        return values[0]
    }

    /// RFC 2047 encoded-words. Unknown charset or broken tokens stay literal.
    public static func decodeEncodedWords(_ value: String) -> String {
        MailParserBridge.decodeEncodedWords(value)
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
                    case .decoded: selected[key] = MailParserBridge.decodeEncodedWords(unfolded)
                    case .mailKitBase64:
                        // Compatibility with persisted, pre-normalization MailKit evidence.
                        // All other headers and the complete MIME body still have to match.
                        let decoded = MailParserBridge.decodeEncodedWords(unfolded)
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
    public init(sender: String?, recipients: [String], cc: [String]) {
        self.sender = sender
        self.recipients = recipients
        self.cc = cc
    }

    public func fillingMissingFields(from other: Self) -> Self {
        Self(sender: sender ?? other.sender, recipients: recipients.isEmpty ? other.recipients : recipients,
             cc: cc.isEmpty ? other.cc : cc)
    }
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
        let parsed = try MailParserBridge.parse(raw, forDisplay: false, fromMailKit: fromMailKit)
        let bounded = BodyBound.fit(parsed.text, attachments: parsed.attachments, alreadyCut: parsed.truncated)
        guard !bounded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MailBodyRejection.emptyBody
        }
        return MailBodyExtraction(text: bounded.text, truncated: bounded.truncated, attachments: parsed.attachments)
    }

    public static func displayText(_ raw: Data, fromMailKit: Bool = false) throws -> String {
        try MailParserBridge.parse(raw, forDisplay: true, fromMailKit: fromMailKit).text
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
        var result = String.UnicodeScalarView()
        result.reserveCapacity(text.unicodeScalars.count)
        var pendingCR = false
        var consecutiveNewlines = 0
        func emitNewline() {
            consecutiveNewlines += 1
            if consecutiveNewlines <= 2 { result.append("\n") }
        }
        for scalar in text.unicodeScalars {
            if scalar == "\u{feff}" { continue }
            if pendingCR {
                pendingCR = false
                if scalar == "\n" { emitNewline(); continue }
                emitNewline()
            }
            if scalar == "\r" { pendingCR = true }
            else if scalar == "\n" { emitNewline() }
            else { consecutiveNewlines = 0; result.append(scalar) }
        }
        if pendingCR { emitNewline() }
        return String(result).trimmingCharacters(in: .whitespacesAndNewlines)
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

// MARK: - Minimal header & framing helpers for source evidence and correspondent checks

private struct MIMEHeaders {
    var fields: [String: [String]]
    var mediaType: String
    var parameters: [String: String]
    var encoding: String

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
                if first == "\\", let next = rest.first {
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
    // MailKit can serialize the envelope and the original MIME parts with different line endings.
    let prefix = data.prefix(MailBodyLimits.maxHeaderBytes + 4)
    let separators = [Data([13, 10, 13, 10]), Data([10, 10])]
    guard let range = separators.compactMap({ prefix.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
        throw MailBodyRejection.malformedMIME
    }
    return (data[..<range.lowerBound], data[range.upperBound...])
}

private enum MIMESplit {
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
            let value = content(line)
            switch kind(value) {
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
        let filtered = data.filter { $0 != 32 && $0 != 9 && $0 != 10 && $0 != 13 }
        if filtered.isEmpty { return Data() }
        guard filtered.allSatisfy({ isBase64($0) }),
              let decoded = Data(base64Encoded: filtered) else { throw MailBodyRejection.malformedMIME }
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
