import Foundation

/// A short-lived, explicit consent scope for synthetic metadata only.
public struct IdentityProbeScope: Codable, Sendable, Equatable {
    public let nonce: UUID
    public let expiresAt: Date
    public init(now: Date = Date()) {
        nonce = UUID(); expiresAt = now.addingTimeInterval(900)
    }
    public var subject: String { "Mailpipe M0 \(nonce.uuidString)" }
    public func accepts(subject: String, now: Date = Date()) -> Bool {
        now < expiresAt && expiresAt.timeIntervalSince(now) <= 900 && subject == self.subject
    }
}

public struct IdentityProbeReceipt: Codable, Sendable {
    public let nonce: UUID
    public let observedAt: Date
    public let messageIDs: [String]
    public init(scope: IdentityProbeScope, headers: [String: [String]], now: Date = Date()) {
        nonce = scope.nonce; observedAt = now
        messageIDs = headers.filter { $0.key.lowercased() == "message-id" }
            .flatMap(\.value).prefix(2).map { String($0.prefix(998)) }
    }
}

/// Fixed-size session files; no body, sender, recipient or account is persisted.
public struct IdentityProbeStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func begin(now: Date = Date()) throws -> IdentityProbeScope {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let scope = IdentityProbeScope(now: now)
        try JSONEncoder().encode(scope).write(to: directory.appendingPathComponent("scope.json"), options: .atomic)
        return scope
    }
    public func stop() throws {
        let url = directory.appendingPathComponent("scope.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public func scope() throws -> IdentityProbeScope {
        try JSONDecoder().decode(IdentityProbeScope.self, from: Data(contentsOf: directory.appendingPathComponent("scope.json")))
    }
    public func capture(subject: String, headers: [String: [String]], now: Date = Date()) throws {
        let current = try scope()
        guard current.accepts(subject: subject, now: now) else { return }
        let receipt = IdentityProbeReceipt(scope: current, headers: headers, now: now)
        // Recheck consent just before publishing; the host also rejects expired/revoked receipts.
        guard try scope() == current else { return }
        try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent("receipt.json"), options: .atomic)
    }
    public func receipt(now: Date = Date()) throws -> IdentityProbeReceipt? {
        let current = try scope()
        guard current.accepts(subject: current.subject, now: now) else { return nil }
        let receipt = try JSONDecoder().decode(IdentityProbeReceipt.self, from: Data(contentsOf: directory.appendingPathComponent("receipt.json")))
        return receipt.nonce == current.nonce ? receipt : nil
    }
}


public enum ProbeReadFailure: String, Error, Sendable {
    case scopeMissing, scopeUnreadable, scopeInvalid, scopeExpired
    case receiptMissing, receiptUnreadable, receiptInvalid, receiptStale
    public var explanation: String {
        switch self {
        case .scopeMissing: "没有采集授权（已停止或尚未开始）"
        case .scopeUnreadable: "宿主无法读取会话文件；检查共享容器权限"
        case .scopeInvalid: "会话文件格式错误"
        case .scopeExpired: "采集授权已过期或时间异常"
        case .receiptMissing: "授权有效，但回执文件尚未生成；需查看扩展阶段日志"
        case .receiptUnreadable: "回执文件无法读取；检查共享容器权限"
        case .receiptInvalid: "回执文件格式错误"
        case .receiptStale: "回执属于旧会话；不用于当前定位"
        }
    }
}

extension IdentityProbeStore {
    public func diagnosedReceipt(now: Date = Date()) throws -> IdentityProbeReceipt {
        func read<T: Decodable>(_ name: String, missing: ProbeReadFailure,
                                unreadable: ProbeReadFailure, invalid: ProbeReadFailure) throws -> T {
            let bytes: Data
            do { bytes = try Data(contentsOf: directory.appendingPathComponent(name)) }
            catch {
                let e = error as NSError
                if e.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(e.code) { throw missing }
                throw unreadable
            }
            do { return try JSONDecoder().decode(T.self, from: bytes) }
            catch { throw invalid }
        }
        let current: IdentityProbeScope = try read("scope.json", missing: .scopeMissing, unreadable: .scopeUnreadable, invalid: .scopeInvalid)
        guard current.accepts(subject: current.subject, now: now) else { throw ProbeReadFailure.scopeExpired }
        let receipt: IdentityProbeReceipt = try read("receipt.json", missing: .receiptMissing, unreadable: .receiptUnreadable, invalid: .receiptInvalid)
        guard receipt.nonce == current.nonce else { throw ProbeReadFailure.receiptStale }
        return receipt
    }
}
