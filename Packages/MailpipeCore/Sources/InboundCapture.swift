import Foundation
import CryptoKit
import Darwin

public func mailSourceDigest(_ raw: Data) -> String? {
    guard let text = String(data: raw, encoding: .utf8) else { return nil }
    return contentDigest(Data(text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines).utf8))
}

public enum PipelineError: String, Error, Sendable { case storage, alreadyOpen, unsupportedMIME, invalidCapture, quota, revoked, interrupted }
public func contentDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Account identity never comes from sender-controlled headers.
public struct CapturePermission: Codable, Equatable, Sendable {
    public let id: UUID
    public let grantedAt: Date
    public let exactSubject: String?
    public init(exactSubject: String? = nil) { id = UUID(); grantedAt = Date(); self.exactSubject = exactSubject }
    public func accepts(_ subject: String) -> Bool { exactSubject == nil || exactSubject == subject }
}
public struct InboundCapture: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public let permissionID: UUID
    public let capturedAt: Date
    public let subject: String
    public let messageID: String?
    public let raw: Data?
    public let issue: String?
    public init(permissionID: UUID, subject: String, messageID: String?, raw: Data?, issue: String? = nil) {
        version = 1; id = UUID(); self.permissionID = permissionID; capturedAt = Date()
        self.subject = subject; self.messageID = messageID; self.raw = raw; self.issue = issue
    }
    public func validate() throws {
        guard version == 1, subject.utf8.count <= 2_048, (messageID?.utf8.count ?? 0) <= 998,
              (raw?.count ?? 0) <= 65_536, (issue?.count ?? 0) <= 64,
              capturedAt.timeIntervalSinceNow <= 60 else { throw PipelineError.invalidCapture }
    }
}

/// Conservative decoder: attachments, HTML, multipart, and unknown charsets fail visibly.
/// Never submits raw MIME or attachments to a model.
public enum PlainMailBody {
    public static func decode(_ raw: Data) throws -> String {
        guard raw.count <= 65_536 else { throw PipelineError.unsupportedMIME }
        guard let separator = raw.range(of: Data("\r\n\r\n".utf8)) ?? raw.range(of: Data("\n\n".utf8)),
              let head = String(data: raw[..<separator.lowerBound], encoding: .utf8) else { throw PipelineError.unsupportedMIME }
        let unfolded = head.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n\t", with: " ").replacingOccurrences(of: "\n ", with: " ")
        var headers: [String: [String]] = [:]
        for line in unfolded.split(separator: "\n") {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { throw PipelineError.unsupportedMIME }
            headers[String(pair[0]).lowercased(), default: []].append(pair[1].trimmingCharacters(in: .whitespaces))
        }
        guard (headers["content-type"]?.count ?? 0) <= 1,
              (headers["content-transfer-encoding"]?.count ?? 0) <= 1,
              headers["content-disposition"] == nil else { throw PipelineError.unsupportedMIME }
        let type = (headers["content-type"]?.first ?? "text/plain").lowercased()
        let parts = type.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.first == "text/plain", parts.dropFirst().allSatisfy({
            ["charset=utf-8", "charset=\"utf-8\"", "charset=us-ascii", "charset=\"us-ascii\""].contains($0)
        }) else { throw PipelineError.unsupportedMIME }
        var body = Data(raw[separator.upperBound...])
        switch (headers["content-transfer-encoding"]?.first ?? "7bit").lowercased() {
        case "7bit", "8bit": break
        case "base64":
            guard let text = String(data: body, encoding: .ascii), let decoded = Data(base64Encoded: text.filter { !$0.isWhitespace }) else { throw PipelineError.unsupportedMIME }
            body = decoded
        case "quoted-printable":
            let bytes = Array(body); var result = Data(); var i = 0
            while i < bytes.count {
                if bytes[i] == 61 {
                    if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
                    if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }
                    guard i + 2 < bytes.count,
                          let value = UInt8(String(bytes: bytes[(i + 1)...(i + 2)], encoding: .ascii) ?? "", radix: 16) else { throw PipelineError.unsupportedMIME }
                    result.append(value); i += 3
                } else { result.append(bytes[i]); i += 1 }
            }
            body = result
        default: throw PipelineError.unsupportedMIME
        }
        guard body.count <= 16_384, let text = String(data: body, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.contains("\0") else { throw PipelineError.unsupportedMIME }
        return text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)
    }
}

/// Cross-process immutable handoff. Database commits precede deletion of these files.
public struct CaptureInbox: Sendable {
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func permission() throws -> CapturePermission? {
        let path = directory.appendingPathComponent("permission.json")
        if !FileManager.default.fileExists(atPath: path.path) { return nil }
        return try JSONDecoder().decode(CapturePermission.self, from: Self.read(path, limit: 4_096))
    }
    public func setPermission(_ value: CapturePermission?) throws {
        let path = directory.appendingPathComponent("permission.json")
        if let value { try JSONEncoder().encode(value).write(to: path, options: .atomic) }
        else if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    public func publish(_ capture: InboundCapture) throws {
        try capture.validate()
        guard let permission = try permission(), permission.id == capture.permissionID,
              permission.accepts(capture.subject) else { throw PipelineError.revoked }
        guard try files().count < 500 else { throw PipelineError.quota }
        try JSONEncoder().encode(capture).write(to: directory.appendingPathComponent(capture.id.uuidString + ".capture"), options: .atomic)
    }
    public func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "capture" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    /// Persistent one-shot body claim, bounded by inbox capacity. No callback replay API.
    public func claimBody(permission: CapturePermission, subject: String, messageID: String?) throws -> Bool {
        guard let messageID, !messageID.isEmpty else { return false }
        guard try self.permission() == permission, permission.accepts(subject) else { throw PipelineError.revoked }
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard entries.filter({ $0.pathExtension == "claim" }).count < 500, try files().count < 500 else { throw PipelineError.quota }
        let digest = contentDigest(Data((permission.id.uuidString + messageID + subject).utf8))
        let path = directory.appendingPathComponent(digest + ".claim")
        let fd = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if fd < 0 { if errno == EEXIST { return false }; throw PipelineError.storage }
        close(fd)
        return true
    }
    public func recordIssue(_ code: String) throws {
        try JSONEncoder().encode(String(code.prefix(64))).write(to: directory.appendingPathComponent("issue.json"), options: .atomic)
    }
    public func issue() throws -> String? {
        let path = directory.appendingPathComponent("issue.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try JSONDecoder().decode(String.self, from: Self.read(path, limit: 1_024))
    }
    public func pruneClaims() throws {
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) where file.pathExtension == "claim" {
            if let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < Date().addingTimeInterval(-86_400) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
    public static func read(_ file: URL, limit: Int) throws -> Data {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw PipelineError.invalidCapture }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit else { throw PipelineError.invalidCapture }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw PipelineError.invalidCapture }
        return data
    }
}
