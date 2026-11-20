import Foundation

/// A read-only panel lookup identifies the original without transmitting mail text.
public struct ComposeMessageIdentity: Codable, Equatable, Sendable {
    public let messageIDDigest: String
    public let subjectDigest: String
    public let envelopeDigest: String
    public let displayBodyDigest: String?
    public let modelBodyDigest: String?

    public static func digest(forSubject subject: String) -> String {
        contentDigest(Data(subject.precomposedStringWithCanonicalMapping.utf8))
    }

    public static func digest(forMessageID messageID: String) -> String? {
        var id = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("<") && id.hasSuffix(">") { id = String(id.dropFirst().dropLast()) }
        guard !id.isEmpty, id.utf8.count <= 998, id.rangeOfCharacter(from: .controlCharacters) == nil,
              !id.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }) else { return nil }
        return contentDigest(Data(id.utf8))
    }

    public init?(messageID: String, subject: String, sender: String, to: [String], cc: [String],
                 displayBody: String? = nil, modelBody: String? = nil) {
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
        subjectDigest = Self.digest(forSubject: subject)
        envelopeDigest = contentDigest(encoded)
        modelBodyDigest = modelBody.map { contentDigest(Data($0.utf8)) }
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
        [messageIDDigest, subjectDigest, envelopeDigest, displayBodyDigest, modelBodyDigest]
            .compactMap { $0 }.allSatisfy(Self.validDigest)
    }

    fileprivate static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Only sent following explicit confirmation for a previously uncaptured original.
public struct ComposePanelOriginal: Codable, Equatable, Sendable {
    public let messageID: String
    public let subject: String
    public let sender: String
    public let to: [String]
    public let cc: [String]
    public let body: String
    public let displayBody: String

    public init?(messageID: String, subject: String, sender: String, to: [String], cc: [String], body: String, displayBody: String) {
        self.messageID = messageID
        self.subject = subject
        self.sender = sender
        self.to = to
        self.cc = cc
        self.body = body
        self.displayBody = displayBody
        guard identity != nil else { return nil }
    }

    private var identity: ComposeMessageIdentity? {
        guard body.utf8.count <= MailBodyLimits.modelBudget, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayBody.utf8.count <= MailBodyLimits.extractCap, !displayBody.isEmpty else { return nil }
        return ComposeMessageIdentity(messageID: messageID, subject: subject, sender: sender, to: to, cc: cc,
                                      displayBody: displayBody, modelBody: body)
    }

    public func matches(_ expected: ComposeMessageIdentity) -> Bool { identity == expected }
}

public enum ComposePanelAction: Codable, Equatable, Sendable {
    case lookup
    /// The user asked to choose a saved draft in a composer without its original message.
    case findDrafts(subjectDigest: String)
    /// A stored draft was found. Match any available body evidence before returning it.
    case verifiedLookup
    case generate(version: String, original: ComposePanelOriginal?)
    case regenerate(version: String)
}

public struct ComposePanelRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let identity: ComposeMessageIdentity?
    public let action: ComposePanelAction
    public let createdAt: Date

    public init(sessionID: UUID, identity: ComposeMessageIdentity?, action: ComposePanelAction, id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.identity = identity
        self.action = action
        self.createdAt = createdAt
    }

    fileprivate var lifetime: TimeInterval {
        switch action {
        case .lookup, .verifiedLookup, .findDrafts: 15
        // A single authorized adapter run can take 120 s, plus process startup/teardown.
        case .generate, .regenerate: 180
        }
    }

    fileprivate func isValid(at now: Date) -> Bool {
        guard createdAt <= now.addingTimeInterval(1), createdAt.addingTimeInterval(lifetime) > now else { return false }
        switch action {
        case let .findDrafts(digest):
            return identity == nil && ComposeMessageIdentity.validDigest(digest)
        case .lookup, .verifiedLookup: return identity?.valid == true
        case let .generate(version, original):
            guard let identity, identity.valid else { return false }
            return !version.isEmpty && version.utf8.count <= 512 && (original?.matches(identity) ?? true)
        case let .regenerate(version):
            return identity?.valid == true && !version.isEmpty && version.utf8.count <= 512
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

public struct ComposePanelOffer: Codable, Equatable, Sendable {
    public let version: String
    public let agentName: String
    /// Only an uncaptured message needs its source supplied by Mail at generation time.
    public let requiresOriginal: Bool

    public init(version: String, agentName: String, requiresOriginal: Bool) {
        self.version = version
        self.agentName = agentName
        self.requiresOriginal = requiresOriginal
    }

    fileprivate var valid: Bool {
        !version.isEmpty && version.utf8.count <= 512 && !agentName.isEmpty && agentName.utf8.count <= 512
    }
}

/// Identifies one source the user can select without transferring the original or the draft.
public struct ComposeDraftChoice: Codable, Equatable, Sendable {
    public static let limit = 50
    public let sender: String
    public let capturedAt: Date
    public let identity: ComposeMessageIdentity

    public init(sender: String, capturedAt: Date, identity: ComposeMessageIdentity) {
        self.sender = sender
        self.capturedAt = capturedAt
        self.identity = identity
    }

    fileprivate func isValid(for subjectDigest: String) -> Bool {
        MailComposeRequest.validAddress(sender) && capturedAt.timeIntervalSinceReferenceDate.isFinite &&
            identity.valid && identity.subjectDigest == subjectDigest && identity.displayBodyDigest != nil
    }
}

public enum ComposePanelResponse: Codable, Equatable, Sendable {
    case ready(ComposePanelSuggestion)
    case draftChoices([ComposeDraftChoice])
    case canGenerate(ComposePanelOffer)
    case verifyOriginal, preparing, noDraft, unavailable, changed, regenerationLimitReached, failed
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
    // The confirmed source can include up to 256 KiB display text and escaped JSON characters.
    private static let requestLimit = 2 * 1024 * 1024
    private static let acceptInterval: TimeInterval = 8

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw ComposePanelTransportError.invalidRequest }
    }

    public func send(sessionID: UUID, identity: ComposeMessageIdentity?, action: ComposePanelAction) async throws -> ComposePanelResponse {
        try Task.checkCancellation()
        let request = ComposePanelRequest(sessionID: sessionID, identity: identity, action: action)
        guard request.isValid(at: Date()) else { throw ComposePanelTransportError.invalidRequest }
        let folder = folder(for: request.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try JSONEncoder().encode(request)
        guard data.count <= Self.requestLimit else { throw ComposePanelTransportError.invalidRequest }
        try data.write(to: folder.appendingPathComponent("pending"), options: .atomic)
        let result = folder.appendingPathComponent("result")
        while true {
            try Task.checkCancellation()
            let age = Date().timeIntervalSince(request.createdAt)
            guard age < request.lifetime else { throw ComposePanelTransportError.timedOut }
            if FileManager.default.fileExists(atPath: result.path) {
                let response = try JSONDecoder().decode(ComposePanelResponse.self, from: CaptureInbox.read(result, limit: Self.limit))
                switch (action, response) {
                case let (.findDrafts(subjectDigest), .draftChoices(choices)):
                    guard choices.count <= ComposeDraftChoice.limit, choices.allSatisfy({ $0.isValid(for: subjectDigest) }) else {
                        throw ComposePanelTransportError.invalidResponse
                    }
                case (.findDrafts, .failed), (.findDrafts, .unavailable), (.findDrafts, .noDraft): break
                case (.findDrafts, _), (_, .draftChoices): throw ComposePanelTransportError.invalidResponse
                default: break
                }
                if case .ready(let suggestion) = response {
                    guard ComposePanelSuggestion.validBody(suggestion.body), !suggestion.version.isEmpty,
                          suggestion.version.utf8.count <= 512, suggestion.agentName.utf8.count <= 512 else {
                        throw ComposePanelTransportError.invalidResponse
                    }
                }
                if case .canGenerate(let offer) = response, !offer.valid { throw ComposePanelTransportError.invalidResponse }
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
            guard let data = try? CaptureInbox.read(claimed, limit: Self.requestLimit),
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
        request.createdAt.addingTimeInterval(request.lifetime) > Date() &&
            FileManager.default.fileExists(atPath: folder(for: request.id).appendingPathComponent("claimed").path)
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
