import Foundation

/// A known placeholder or warning phrase found in reply text.
/// The phrase is the matched source text. It is not an inferred task.
public struct DraftPhraseHit: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case supplement, confirmation }
    public let kind: Kind
    public let phrase: String
    public let utf16Location: Int
    public let utf16Length: Int
}

enum DraftPhraseHits {
    private struct Pattern {
        let needle: String
        let kind: DraftPhraseHit.Kind
        let bracketed: Bool
    }

    private static let patterns = [
        Pattern(needle: "【待补充", kind: .supplement, bracketed: true),
        Pattern(needle: "【待确认", kind: .confirmation, bracketed: true),
        Pattern(needle: "待核实", kind: .confirmation, bracketed: false),
        Pattern(needle: "需要先核实", kind: .confirmation, bracketed: false),
        Pattern(needle: "需要核实", kind: .confirmation, bracketed: false),
        Pattern(needle: "暂无法给出结论", kind: .confirmation, bracketed: false),
    ]

    static func found(in body: String) -> [DraftPhraseHit] {
        var hits: [DraftPhraseHit] = []
        for pattern in patterns {
            var search = body.startIndex..<body.endIndex
            while let found = body.range(of: pattern.needle, range: search) {
                let span = phraseSpan(in: body, needle: found, bracketed: pattern.bracketed)
                if let hit = makeHit(kind: pattern.kind, body: body, span: span) {
                    hits.append(hit)
                }
                search = found.upperBound..<body.endIndex
                if search.isEmpty { break }
            }
        }
        return hits.sorted {
            if $0.utf16Location == $1.utf16Location { return $0.utf16Length > $1.utf16Length }
            return $0.utf16Location < $1.utf16Location
        }
    }

    private static func phraseSpan(in body: String, needle: Range<String.Index>, bracketed: Bool) -> Range<String.Index> {
        guard bracketed else { return needle }
        let tail = body[needle.upperBound...]
        guard let close = tail.firstIndex(of: "】") else { return needle }
        return needle.lowerBound..<body.index(after: close)
    }

    private static func makeHit(kind: DraftPhraseHit.Kind, body: String, span: Range<String.Index>) -> DraftPhraseHit? {
        guard let lower = span.lowerBound.samePosition(in: body.utf16),
              let upper = span.upperBound.samePosition(in: body.utf16) else { return nil }
        let location = body.utf16.distance(from: body.utf16.startIndex, to: lower)
        let length = body.utf16.distance(from: lower, to: upper)
        guard length > 0 else { return nil }
        return DraftPhraseHit(kind: kind, phrase: String(body[span]), utf16Location: location, utf16Length: length)
    }
}

/// What the main screen may say about a reply before copy.
/// A located phrase quotes source text and can be focused. Anything else stays generic.
public enum DraftAttention: Equatable, Sendable {
    case none
    case located(kind: DraftPhraseHit.Kind, phrase: String, utf16Location: Int, utf16Length: Int)
    case generic

    public var message: String? {
        switch self {
        case .none: nil
        case .generic: "这份草稿需要你核对"
        case .located(_, let phrase, _, _): "「\(Self.clipped(phrase))」"
        }
    }

    public var canLocate: Bool {
        if case .located(_, _, let location, let length) = self { return location >= 0 && length > 0 }
        return false
    }

    public static func resolve(in body: String) -> DraftAttention {
        resolve(requiresConfirmation: DraftContentWarnings(body: body).requiresCopyConfirmation,
                match: DraftPhraseHits.found(in: body).first)
    }

    /// `requiresConfirmation` without a match is the conservative fallback.
    /// Callers must not invent a subject to fill that gap.
    public static func resolve(requiresConfirmation: Bool, match: DraftPhraseHit?) -> DraftAttention {
        guard requiresConfirmation else { return .none }
        guard let match, match.utf16Length > 0, !match.phrase.isEmpty else { return .generic }
        return .located(kind: match.kind, phrase: match.phrase,
                        utf16Location: match.utf16Location, utf16Length: match.utf16Length)
    }

    static func clipped(_ phrase: String, limit: Int = 36) -> String {
        guard phrase.count > limit else { return phrase }
        return String(phrase.prefix(limit)) + "…"
    }
}

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

/// One summary line. A status exists only for a real warning or a failed task.
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
        if failed {
            status = "未成功"
        } else {
            switch DraftAttention.resolve(in: reply) {
            case .none: status = nil
            case .generic: status = "需核对"
            case .located(let kind, _, _, _): status = kind == .supplement ? "待补充" : "需核实"
            }
        }
    }

    static func line(_ raw: String) -> String {
        for part in raw.split(whereSeparator: \.isNewline) {
            let words = part.split(whereSeparator: \.isWhitespace)
            if !words.isEmpty { return words.joined(separator: " ") }
        }
        return ""
    }
}
