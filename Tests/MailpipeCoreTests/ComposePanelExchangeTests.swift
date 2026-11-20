import XCTest
@testable import MailpipeCore

final class ComposePanelExchangeTests: XCTestCase {
    private func identity(body: String? = nil) throws -> ComposeMessageIdentity {
        try XCTUnwrap(ComposeMessageIdentity(messageID: "<letter@example.com>", subject: "Meeting",
                                            sender: "Alice@Example.COM", to: ["bob@example.com"], cc: [], displayBody: body))
    }

    func testIdentityUsesOriginalFieldsAndAvailableBodyWithoutExposingThem() throws {
        let request = try identity(body: "original\r\ntext")
        let stored = try XCTUnwrap(ComposeMessageIdentity(messageID: "letter@example.com", subject: "Meeting",
                                                          sender: "Alice@example.com", to: ["bob@example.com"], cc: [],
                                                          displayBody: "original\ntext"))
        XCTAssertTrue(request.matches(stored))
        XCTAssertTrue(try identity().matches(stored))
        XCTAssertFalse(try request.matches(identity()))
        XCTAssertFalse(try request.matches(identity(body: "different")))
        XCTAssertNil(ComposeMessageIdentity(messageID: "", subject: "Meeting", sender: "a@example.com", to: [], cc: []))
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Meeting"))
        XCTAssertFalse(encoded.contains("example.com"))
        XCTAssertFalse(encoded.contains("original"))
    }

    func testReadsOnlyOneMessageIDFromOriginalHeaders() throws {
        let sample = Data("From: me@example.com\r\nMESSAGE-ID: <m@example.com>\r\n\r\nMessage-ID: ignored@example.com".utf8)
        XCTAssertEqual(MailHeaderCodec.messageID(in: sample), "<m@example.com>")
        XCTAssertEqual(ComposeMessageIdentity.digest(forMessageID: "<m@example.com>"),
                       ComposeMessageIdentity.digest(forMessageID: "m@example.com"))
        for malformed in ["Subject: test\n\nMessage-ID: x@example.com", "Message-ID: <a>\nMessage-ID: <b>\n\n",
                          "Subject: test\n\nMessage-ID: x@example.com\r\n\r\nbody",
                          "Message-ID: <two words>\n\n", "Message-ID: <a\0b>\n\n", "Message-ID: <>\n\n"] {
            XCTAssertNil(MailHeaderCodec.messageID(in: Data(malformed.utf8)))
        }
    }

    func testEmptyOfferCarriesNoOriginalMail() throws {
        for requiresOriginal in [true, false] {
            let offer = ComposePanelOffer(version: "v1", agentName: "Agent", requiresOriginal: requiresOriginal)
            let data = try JSONEncoder().encode(offer)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(fields.keys), ["version", "agentName", "requiresOriginal"])
        }
    }

    func testRestoredForwardSearchOnlyReturnsChoicesForRequestedSubject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let exchange = try ComposePanelExchange(directory: root)
        let source = try identity(body: "Original message")
        let search = ComposePanelAction.findDrafts(subjectDigest: source.subjectDigest)
        for (identity, action) in [(Optional(source), search), (nil, .lookup), (nil, .findDrafts(subjectDigest: "Meeting"))] {
            do {
                _ = try await exchange.send(sessionID: UUID(), identity: identity, action: action)
                XCTFail("Invalid search scope")
            } catch ComposePanelTransportError.invalidRequest {}
        }
        let choice = ComposeDraftChoice(sender: "alice@example.com", capturedAt: Date(), identity: source)
        let different = try XCTUnwrap(ComposeMessageIdentity(messageID: "next@example.com", subject: "Other",
            sender: choice.sender, to: [], cc: [], displayBody: "Different message"))
        let expected = ComposePanelResponse.draftChoices([choice])
        let wrongSubject = ComposeDraftChoice(sender: choice.sender, capturedAt: choice.capturedAt, identity: different)
        for response in [expected, .draftChoices([wrongSubject]), .ready(.init(body: "private reply", version: "v", agentName: "Agent"))] {
            let pending = Task { try await exchange.send(sessionID: UUID(), identity: nil, action: search) }
            let requests = try await claim(1, from: exchange)
            let request = try XCTUnwrap(requests.first)
            XCTAssertNil(request.identity)
            try exchange.respond(response, to: request)
            if response == expected {
                let result = try await pending.value
                XCTAssertEqual(result, response)
                let fields = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
                XCTAssertFalse(fields.contains("Original message"))
                XCTAssertFalse(fields.contains("Meeting"))
            } else {
                do { _ = try await pending.value; XCTFail("Search returned a draft or an unrelated choice") }
                catch ComposePanelTransportError.invalidResponse {}
            }
        }
    }

    func testFirstDraftRequiresTheOriginalFromTheConfirmedGenerationRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let exchange = try ComposePanelExchange(directory: root)
        let modelBody = "Can we meet on Friday?"
        let display = modelBody + "\n> Previous email"
        let id = try XCTUnwrap(ComposeMessageIdentity(messageID: "m@example.com", subject: "Meeting",
            sender: "sender@example.com", to: ["reader@example.com"], cc: [], displayBody: display, modelBody: modelBody))
        func original(_ body: String) -> ComposePanelOriginal? {
            ComposePanelOriginal(messageID: "m@example.com", subject: "Meeting", sender: "sender@example.com",
                to: ["reader@example.com"], cc: [], body: body, displayBody: display)
        }
        XCTAssertNil(original(String(repeating: "x", count: MailBodyLimits.modelBudget + 1)))
        let incorrect = try XCTUnwrap(original("A different message"))
        do {
            _ = try await exchange.send(sessionID: UUID(), identity: id, action: .generate(version: "v1", original: incorrect))
            XCTFail("Mismatched original was accepted")
        } catch ComposePanelTransportError.invalidRequest { }
        XCTAssertTrue(try exchange.claimRequests().isEmpty)
        let source = try XCTUnwrap(original(modelBody))
        let action = ComposePanelAction.generate(version: "v1", original: source)
        let client = Task { try await exchange.send(sessionID: UUID(), identity: id, action: action) }
        let claimed = try await claim(1, from: exchange)
        let request = try XCTUnwrap(claimed.first)
        XCTAssertEqual(request.action, action)
        try exchange.respond(.ready(.init(body: "Friday works.", version: "v2", agentName: "Agent")), to: request)
        _ = try await client.value
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testLookupRepliesAreBoundToUniqueRequestsAndRemovedAfterConsumption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try ComposePanelExchange(directory: root)
        let host = try ComposePanelExchange(directory: root)
        let session = UUID()
        let original = try identity()
        let first = Task { try await client.send(sessionID: session, identity: original, action: .lookup) }
        let second = Task { try await client.send(sessionID: UUID(), identity: original, action: .lookup) }
        let requests = try await claim(2, from: host)
        XCTAssertEqual(Set(requests.map(\.id)).count, 2)
        XCTAssertTrue(try host.claimRequests().isEmpty)
        let expected = ComposePanelResponse.ready(.init(body: "Draft", version: "v1", agentName: "Agent"))
        for request in requests {
            XCTAssertEqual(request.identity, original)
            try host.respond(request.sessionID == session ? expected : .noDraft, to: request)
        }
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a, expected)
        XCTAssertEqual(b, .noDraft)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testClosingPanelCancelsClaimAndCrashNeverReplaysRegeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let exchange = try ComposePanelExchange(directory: root)
        let original = try identity()
        let task = Task { try await exchange.send(sessionID: UUID(), identity: original, action: .regenerate(version: "v1")) }
        let claimed = try await claim(1, from: exchange)
        let request = try XCTUnwrap(claimed.first)
        XCTAssertEqual(request.action, .regenerate(version: "v1"))
        let encoded = try JSONEncoder().encode(request.action)
        XCTAssertEqual(try JSONDecoder().decode([String: [String: String]].self, from: encoded),
                       ["regenerate": ["version": "v1"]])
        let previousShorten = Data(#"{"shorten":{"version":"v1","body":"edited"}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ComposePanelAction.self, from: previousShorten))
        let restarted = try ComposePanelExchange(directory: root)
        XCTAssertTrue(try restarted.claimRequests().isEmpty)
        XCTAssertTrue(restarted.isActive(request))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request returned a result") }
        catch is CancellationError {}
        XCTAssertFalse(restarted.isActive(request))
        try restarted.respond(.changed, to: request)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testMalformedOrExpiredRequestCannotReachHost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try ComposePanelExchange(directory: root)
        let original = try identity()
        for (action, date) in [(ComposePanelAction.regenerate(version: ""), Date()),
                               (.lookup, Date().addingTimeInterval(-20)),
                               (.lookup, Date().addingTimeInterval(20))] {
            let request = ComposePanelRequest(sessionID: UUID(), identity: original, action: action, createdAt: date)
            let path = root.appendingPathComponent(request.id.uuidString)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            try JSONEncoder().encode(request).write(to: path.appendingPathComponent("pending"))
        }
        XCTAssertTrue(try host.claimRequests().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func claim(_ count: Int, from host: ComposePanelExchange) async throws -> [ComposePanelRequest] {
        let deadline = Date().addingTimeInterval(3)
        var requests: [ComposePanelRequest] = []
        while requests.count < count, Date() < deadline {
            requests += try host.claimRequests()
            if requests.count < count { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(requests.count, count)
        return requests
    }
}
