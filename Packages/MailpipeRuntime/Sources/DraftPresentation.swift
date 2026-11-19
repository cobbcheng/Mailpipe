import Foundation

/// Short mail stays whole. Longer mail keeps a prefix that ends on a pause, plus expand.
public struct IncomingPreview: Equatable, Sendable {
    public let text: String
    public let omitsRemainder: Bool

    public init(body: String, expanded: Bool) {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let core = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if core.isEmpty || expanded || core.count <= Self.fullLimit {
            text = core
            omitsRemainder = false
            return
        }
        let prefix = Self.prefix(of: core, limit: Self.previewLimit)
        text = prefix
        omitsRemainder = prefix != core
    }

    static let fullLimit = 180
    static let previewLimit = 140

    static func prefix(of text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        let pauses: Set<Character> = ["\n", "。", "！", "？", "；"]
        if let pause = head.lastIndex(where: { pauses.contains($0) }) {
            let distance = text.distance(from: text.startIndex, to: pause)
            if distance >= 24 {
                let end = text.index(after: pause)
                return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return String(head).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One summary line. A status exists only for a failed task.
public struct WorkbenchRowPresentation: Equatable, Sendable {
    public let summary: String
    public let status: String?

    public init(reply: String, incoming: String, preparing: Bool, failed: Bool) {
        let replyLine = Self.line(reply)
        let incomingLine = Self.line(incoming)
        if !replyLine.isEmpty { summary = replyLine }
        else if !incomingLine.isEmpty { summary = incomingLine }
        else if preparing { summary = "正在准备回复" }
        else { summary = "尚无回复" }
        status = failed ? "未成功" : nil
    }

    static func line(_ raw: String) -> String {
        for part in raw.split(whereSeparator: \.isNewline) {
            let words = part.split(whereSeparator: \.isWhitespace)
            if !words.isEmpty { return words.joined(separator: " ") }
        }
        return ""
    }
}
