import Foundation

/// Synthetic-only evidence. Raw message bytes never leave the callback.
public struct BodyProbeReceipt: Codable, Sendable {
    public let nonce: UUID
    public let observedAt: Date
    public let rawByteCount: Int
    public let bodyByteCount: Int?
    public let markerFound: Bool
}

extension IdentityProbeScope {
    public var bodyMarker: String { "Mailpipe synthetic body \(nonce.uuidString)" }
}

extension IdentityProbeStore {
    /// Claim before asking Mail to reenter. A crash may lose a request, never replay it.
    /// One request per consent session, including across extension restarts.
    public func observeBody(subject: String, rawData: Data?, now: Date = Date()) throws -> Bool {
        let current = try scope()
        guard current.requestsBody == true, current.accepts(subject: subject, now: now) else { return false }
        guard let rawData else {
            let claim = directory.appendingPathComponent("body-request-\(current.nonce.uuidString).json")
            do {
                try JSONEncoder().encode(now).write(to: claim, options: .withoutOverwriting)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                return false
            }
            return try scope() == current && current.accepts(subject: subject, now: Date())
        }
        // M0 fixture: single-part UTF-8 MIME (identity or base64), capped at 64 KiB.
        // Not a production MIME decoder; unsupported transfer encodings fail closed.
        var body: Data?
        if rawData.count <= 65_536 {
            for separator in [Data("\r\n\r\n".utf8), Data("\n\n".utf8)] {
                if let range = rawData.range(of: separator) {
                    let headers = String(data: rawData.prefix(upTo: range.lowerBound), encoding: .utf8) ?? ""
                    let encodings = headers.components(separatedBy: .newlines).compactMap { line -> String? in
                        let parts = line.split(separator: ":", maxSplits: 1)
                        guard parts.count == 2, parts[0].lowercased() == "content-transfer-encoding" else { return nil }
                        return parts[1].trimmingCharacters(in: .whitespaces).lowercased()
                    }
                    let payload = rawData.subdata(in: range.upperBound..<rawData.endIndex)
                    if encodings.isEmpty || (encodings.count == 1 && ["7bit", "8bit", "binary"].contains(encodings[0])) {
                        body = payload
                    } else if encodings == ["base64"], let encoded = String(data: payload, encoding: .ascii) {
                        let compact = encoded.filter { !$0.isWhitespace }
                        body = Data(base64Encoded: compact)
                    }
                    break
                }
            }
        }
        let receipt = BodyProbeReceipt(nonce: current.nonce, observedAt: now,
            rawByteCount: rawData.count, bodyByteCount: body?.count,
            markerFound: body.flatMap { String(data: $0, encoding: .utf8) }?.contains(current.bodyMarker) == true)
        guard try scope() == current else { return false }
        try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent("body-receipt.json"), options: .atomic)
        return false
    }

    public func bodyReceipt(now: Date = Date()) throws -> BodyProbeReceipt? {
        let current = try scope()
        guard current.requestsBody == true, current.accepts(subject: current.subject, now: now) else { return nil }
        let receipt = try JSONDecoder().decode(BodyProbeReceipt.self,
            from: Data(contentsOf: directory.appendingPathComponent("body-receipt.json")))
        return receipt.nonce == current.nonce ? receipt : nil
    }
}
