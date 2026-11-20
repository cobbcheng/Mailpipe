import Foundation

/// Matches a compose session's original message to a local capture. The exchange only needs hashes.
public struct ComposeMessageIdentity: Codable, Equatable, Sendable {
    public let messageIDDigest: String
    public let envelopeDigest: String
    public let displayBodyDigest: String?

    public static func digest(forMessageID messageID: String) -> String? {
        var id = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("<") && id.hasSuffix(">") { id = String(id.dropFirst().dropLast()) }
        guard !id.isEmpty, id.utf8.count <= 998, id.rangeOfCharacter(from: .controlCharacters) == nil,
              !id.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }) else { return nil }
        return contentDigest(Data(id.utf8))
    }

    public init?(messageID: String, subject: String, sender: String, to: [String], cc: [String], displayBody: String? = nil) {
        guard let id = Self.digest(forMessageID: messageID),
              subject.utf8.count <= 2048, to.count <= 100, cc.count <= 100 else { return nil }
        func normalized(_ address: String) -> String? {
            guard MailComposeRequest.validAddress(address), let at = address.firstIndex(of: "@") else { return nil }
            return String(address[...at]) + address[address.index(after: at)...].lowercased()
        }
        let recipients = to.compactMap(normalized), copies = cc.compactMap(normalized)
        guard let from = normalized(sender), recipients.count == to.count, copies.count == cc.count else { return nil }
        // Nested arrays retain field boundaries, recipient order, and case-sensitive local parts.
        let fields = [[subject.precomposedStringWithCanonicalMapping], [from], recipients, copies]
        guard let encoded = try? JSONEncoder().encode(fields) else { return nil }
        messageIDDigest = id
        envelopeDigest = contentDigest(encoded)
        displayBodyDigest = displayBody.map {
            contentDigest(Data($0.replacingOccurrences(of: "\r\n", with: "\n").precomposedStringWithCanonicalMapping.utf8))
        }
    }

    /// A body supplied by Mail is additional evidence and must match the capture.
    public func matches(_ capture: Self) -> Bool {
        messageIDDigest == capture.messageIDDigest && envelopeDigest == capture.envelopeDigest &&
            (displayBodyDigest == nil || displayBodyDigest == capture.displayBodyDigest)
    }

    fileprivate var valid: Bool {
        [messageIDDigest, envelopeDigest, displayBodyDigest].compactMap { $0 }.allSatisfy {
            $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }
}

public enum ComposePanelAction: Codable, Equatable, Sendable {
    case lookup
    case regenerate(version: String)
}

public struct ComposePanelRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let identity: ComposeMessageIdentity
    public let action: ComposePanelAction
    public let createdAt: Date

    public init(sessionID: UUID, identity: ComposeMessageIdentity, action: ComposePanelAction, id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.identity = identity
        self.action = action
        self.createdAt = createdAt
    }

    fileprivate var lifetime: TimeInterval {
        switch action {
        case .lookup: 15
        // A single authorized adapter run can take 120 s, plus process startup/teardown.
        case .regenerate: 180
        }
    }

    fileprivate func isValid(at now: Date) -> Bool {
        guard identity.valid, createdAt <= now.addingTimeInterval(1), createdAt.addingTimeInterval(lifetime) > now else { return false }
        switch action {
        case .lookup: return true
        case let .regenerate(version):
            return !version.isEmpty && version.utf8.count <= 512
        }
    }
}

public struct ComposePanelSuggestion: Codable, Equatable, Sendable {
    public let body: String
    public let version: String
    public let agentName: String

    public init(body: String, version: String, agentName: String) {
        self.body = body
        self.version = version
        self.agentName = agentName
    }

    fileprivate static func validBody(_ text: String) -> Bool {
        text.utf8.count <= 65_536 && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum ComposePanelResponse: Codable, Equatable, Sendable {
    case ready(ComposePanelSuggestion)
    case noDraft, unavailable, changed, regenerationLimitReached, failed
}

public enum ComposePanelTransportError: Error, Sendable {
    case invalidRequest, hostUnavailable, timedOut, invalidResponse
}

/// One private directory per explicit panel request. The host atomically claims an operation once;
/// the waiting extension removes the directory after consuming the response or on cancellation.
/// A host restart never repeats claimed work. Its next sweep removes abandoned, expired directories.
public struct ComposePanelExchange: Sendable {
    private let directory: URL
    private static let limit = 512 * 1024
    private static let acceptInterval: TimeInterval = 8

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw ComposePanelTransportError.invalidRequest }
    }

    public func send(sessionID: UUID, identity: ComposeMessageIdentity, action: ComposePanelAction) async throws -> ComposePanelResponse {
        try Task.checkCancellation()
        let request = ComposePanelRequest(sessionID: sessionID, identity: identity, action: action)
        guard request.isValid(at: Date()) else { throw ComposePanelTransportError.invalidRequest }
        let folder = folder(for: request.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONEncoder().encode(request).write(to: folder.appendingPathComponent("pending"), options: .atomic)
        let result = folder.appendingPathComponent("result")
        while true {
            try Task.checkCancellation()
            let age = Date().timeIntervalSince(request.createdAt)
            guard age < request.lifetime else { throw ComposePanelTransportError.timedOut }
            if FileManager.default.fileExists(atPath: result.path) {
                let response = try JSONDecoder().decode(ComposePanelResponse.self, from: CaptureInbox.read(result, limit: Self.limit))
                if case .ready(let suggestion) = response {
                    guard ComposePanelSuggestion.validBody(suggestion.body), !suggestion.version.isEmpty,
                          suggestion.version.utf8.count <= 512, suggestion.agentName.utf8.count <= 512 else {
                        throw ComposePanelTransportError.invalidResponse
                    }
                }
                return response
            }
            if age >= Self.acceptInterval, !FileManager.default.fileExists(atPath: folder.appendingPathComponent("claimed").path) {
                throw ComposePanelTransportError.hostUnavailable
            }
            try await Task.sleep(for: .milliseconds(120))
        }
    }

    public func claimRequests() throws -> [ComposePanelRequest] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey]
        let children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        let now = Date()
        var requests: [ComposePanelRequest] = []
        for child in children {
            guard let id = UUID(uuidString: child.lastPathComponent),
                  id.uuidString == child.lastPathComponent,
                  let info = try? child.resourceValues(forKeys: keys), info.isDirectory == true, info.isSymbolicLink != true else { continue }
            // Client/host crash after publish/claim. Never resurrect these requests.
            if let date = info.creationDate ?? info.contentModificationDate, now.timeIntervalSince(date) > 185 {
                try? manager.removeItem(at: child)
                continue
            }
            let pending = child.appendingPathComponent("pending"), claimed = child.appendingPathComponent("claimed")
            guard manager.fileExists(atPath: pending.path), (try? manager.moveItem(at: pending, to: claimed)) != nil else { continue }
            guard let data = try? CaptureInbox.read(claimed, limit: Self.limit),
                  let request = try? JSONDecoder().decode(ComposePanelRequest.self, from: data),
                  request.id == id, request.isValid(at: now),
                  now.timeIntervalSince(request.createdAt) < Self.acceptInterval else {
                try? manager.removeItem(at: child)
                continue
            }
            requests.append(request)
        }
        return requests
    }

    public func isActive(_ request: ComposePanelRequest) -> Bool {
        request.isValid(at: Date()) && FileManager.default.fileExists(atPath: folder(for: request.id).appendingPathComponent("claimed").path)
    }

    public func respond(_ response: ComposePanelResponse, to request: ComposePanelRequest) throws {
        guard isActive(request) else { return }
        let result = folder(for: request.id).appendingPathComponent("result")
        let data = try JSONEncoder().encode(response)
        guard data.count <= Self.limit else { throw ComposePanelTransportError.invalidResponse }
        // If the client closes now, the write may fail. Never recreate the removed directory.
        try data.write(to: result, options: .atomic)
    }

    private func folder(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
}
