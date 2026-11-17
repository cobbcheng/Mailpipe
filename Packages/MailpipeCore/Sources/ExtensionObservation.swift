import Foundation

/// Last observed callback, not an assertion that Mail still has the extension enabled.
/// Contains no mail content or account identifiers. No timer, retry, or replay.
public struct ExtensionObservation: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable { case initialized, handlerRequested, messageReceived }
    public let event: Event
    public let observedAt: Date
    public let build: String
    public init(event: Event, observedAt: Date = Date(), build: String) {
        self.event = event; self.observedAt = observedAt; self.build = build
    }
    public func write(to inbox: CaptureInbox) throws {
        try JSONEncoder().encode(self).write(to: inbox.directory.appendingPathComponent("extension-observation.json"), options: .atomic)
    }
    public static func read(from inbox: CaptureInbox, now: Date = Date()) throws -> Self? {
        let file = inbox.directory.appendingPathComponent("extension-observation.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: CaptureInbox.read(file, limit: 1_024))
        guard value.observedAt <= now, value.observedAt > now.addingTimeInterval(-7 * 86_400),
              value.build.utf8.count <= 64 else { return nil }
        return value
    }
}
