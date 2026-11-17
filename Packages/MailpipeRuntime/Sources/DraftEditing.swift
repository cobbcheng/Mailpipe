import Foundation

public enum DraftSaveState: Equatable, Sendable {
    case saved, saving, failed
    public var label: String {
        switch self {
        case .saved: "已保存"
        case .saving: "保存中…"
        case .failed: "未能保存，点此重试"
        }
    }
}

/// Owned by the host model, not the disposable detail view. No automatic retry.
public struct DraftEditBuffer: Equatable, Sendable {
    public private(set) var body: String
    public private(set) var savedBody: String
    public private(set) var state: DraftSaveState = .saved
    public init(body: String) { self.body = body; savedBody = body }
    public mutating func edit(_ value: String) {
        body = value
        state = body == savedBody ? .saved : .saving
    }
    @discardableResult public mutating func persist(using write: (String) throws -> Void) -> Bool {
        guard body != savedBody else { state = .saved; return true }
        do {
            try write(body)
            savedBody = body; state = .saved
            return true
        } catch {
            state = .failed
            return false
        }
    }
}

/// Text conventions only, not a factual or semantic assessment of a reply.
public struct DraftContentWarnings: Equatable, Sendable {
    public let needsSupplement: Bool
    public let needsConfirmation: Bool
    public var requiresCopyConfirmation: Bool { needsSupplement || needsConfirmation }
    public init(body: String) {
        needsSupplement = body.contains("【待补充")
        needsConfirmation = body.contains("【待确认") || body.contains("待核实") ||
            body.contains("需要先核实") || body.contains("需要核实") || body.contains("暂无法给出结论")
    }
}
