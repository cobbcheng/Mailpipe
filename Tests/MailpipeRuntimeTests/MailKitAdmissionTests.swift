import XCTest
@testable import MailpipeRuntime
import MailpipeCore

@MainActor
final class MailKitAdmissionTests: XCTestCase {
    private func pipeline(model: FakeReplyModel = FakeReplyModel(),
                          classifyMailboxes: @escaping MailMailboxClassifier = { Array(repeating: .unknown, count: $0.count) },
                          mailboxAuditInterval: TimeInterval = 60) async throws -> ReplyPipeline {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let inbox = try CaptureInbox(directory: root.appendingPathComponent("inbox"))
        let pipeline = ReplyPipeline(store: store, inbox: inbox,
            resolve: { _, _ in XCTFail("Unexpected Mail read"); return nil },
            classifyMailboxes: classifyMailboxes,
            mailboxAuditInterval: mailboxAuditInterval,
            model: { _ in model })
        try await pipeline.updateSettings {
            $0.permission = CapturePermission(delivery: .mailKit)
            $0.executable = "/fake/dsh"
        }
        return pipeline
    }

    private func claims(_ inbox: CaptureInbox) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: inbox.directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "claim" }
    }

    private func unexpectedRead<T>(_ value: T, file: StaticString = #filePath, line: UInt = #line) -> T {
        XCTFail("The callback evaluated a field it should have skipped", file: file, line: line)
        return value
    }

    func testExcludedCallbacksDoNotRequestBodyReadRawOrEnterPipeline() async throws {
        let model = FakeReplyModel()
        let pipeline = try await pipeline(model: model)
        let samples: [(String, String, [String: [String]])] = [
            ("Automatic reply", "sender@example.com", ["Auto-Submitted": ["auto-replied"]]),
            ("Save 20% today", "sender@example.com", ["List-Unsubscribe": ["<mailto:unsubscribe@example.com>"]]),
            ("Black Friday savings start today", "offers@example.com", ["Precedence": ["bulk"]]),
            ("Your weekly newsletter", "newsletter@example.com", [:]),
            ("Payment received", "billing@example.com", ["Auto-Submitted": ["auto-generated"]])
        ]
        for (index, sample) in samples.enumerated() {
            let (subject, sender, evidence) = sample
            var headers = evidence
            headers["Message-ID"] = ["<sample-\(index)@example.com>"]
            for raw in [nil, Data("Content-Type: text/plain\r\n\r\nSynthetic".utf8)] as [Data?] {
                let decision = try pipeline.inbox.receiveMailKitMessage(subject: subject, sender: sender,
                    recipients: unexpectedRead(["to@example.com"]), cc: unexpectedRead(["copy@example.com"]),
                    headers: headers, rawData: unexpectedRead(raw))
                XCTAssertEqual(decision, .finished, subject)
            }
        }
        XCTAssertTrue(try claims(pipeline.inbox).isEmpty)
        XCTAssertTrue(try pipeline.inbox.files().isEmpty)
        try await pipeline.pump()
        let isEmpty = try await pipeline.store.records().isEmpty
        XCTAssertTrue(isEmpty)
        let calls = await model.calls
        XCTAssertEqual(calls, 0)
    }

    func testAmbiguousBroadcastCanFinishWithoutDraftOrSecondModelCall() async throws {
        let model = FakeReplyModel()
        await model.respondWithNoReply()
        let pipeline = try await pipeline(model: model)
        let headers = ["Message-ID": ["<bulletin@example.com>"]]
        let raw = Data("Content-Type: text/plain\r\n\r\nThe monthly results are attached for your records.".utf8)
        // A duplicate body callback must keep the original decision.
        for _ in 0..<2 {
            XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: "This month",
                sender: nil, headers: headers, rawData: raw), .finished)
            try await pipeline.pump()
        }
        let records = try await pipeline.store.records()
        XCTAssertEqual(records.count, 1)
        let notice = try XCTUnwrap(records.first)
        XCTAssertEqual(notice.state, .noReply)
        XCTAssertNil(notice.error)
        XCTAssertNil(notice.draftData)
        XCTAssertFalse(notice.state.isPending)
        XCTAssertFalse(notice.canDisplayInWorkbench)
        XCTAssertEqual(notice.runs.map(\.destination.taskKind), [.draft])
        let run = try XCTUnwrap(notice.runs.first)
        XCTAssertNotNil(run.finishedAt)
        XCTAssertNil(run.error)
        XCTAssertEqual(run.inputTokens, 10)
        XCTAssertEqual(run.outputTokens, 20)
        let calls = await model.calls
        XCTAssertEqual(calls, 1)
    }

    func testExplicitRegenerationRejectsNoReplyAndKeepsUserEdits() async throws {
        let model = FakeReplyModel()
        let pipeline = try await pipeline(model: model)
        let raw = Data("Content-Type: text/plain\r\n\r\nPlease confirm the date by email.".utf8)
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: "Schedule",
            sender: "person@example.com", headers: ["Message-ID": ["<request@example.com>"]], rawData: raw), .finished)
        try await pipeline.pump()
        let original = try unwrap(try await pipeline.store.records().first)
        XCTAssertNotNil(original.draft)
        try await pipeline.store.saveEdits(original.id, subject: "Our schedule", body: "Monday works for me.")
        await model.respondWithNoReply()
        try await pipeline.regenerate(original.id)
        try await pipeline.pump()
        let saved = try unwrap(try await pipeline.store.record(original.id))
        XCTAssertEqual(saved.state, .needsReview)
        XCTAssertNotNil(saved.runs.last?.error)
        XCTAssertEqual(saved.draftData, original.draftData)
        XCTAssertEqual(saved.displayedBody, "Monday works for me.")
        XCTAssertTrue(saved.canDisplayInWorkbench)
        let calls = await model.calls
        XCTAssertEqual(calls, 2)
    }

    func testAutomaticDraftAndRegenerationUseCurrentReplyInstructions() async throws {
        let model = FakeReplyModel()
        let pipeline = try await pipeline(model: model)
        let first = "Reply in Spanish."
        let second = "Use bullet points.\nSign with a thank-you."
        try await pipeline.store.saveReplyInstructions(first)
        let raw = Data("Content-Type: text/plain\r\n\r\nCan you review the schedule?".utf8)
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: "Schedule",
            sender: "person@example.com", headers: ["Message-ID": ["<schedule@example.com>"]], rawData: raw), .finished)
        try await pipeline.pump()
        let original = try unwrap(try await pipeline.store.records().first)
        XCTAssertEqual(original.state, .draftReady)

        try await pipeline.store.saveReplyInstructions(second)
        try await pipeline.pump()
        let unchanged = try unwrap(try await pipeline.store.record(original.id))
        XCTAssertEqual(unchanged.draftVersion, original.draftVersion)
        XCTAssertEqual(unchanged.runs.count, 1)
        try await pipeline.regenerate(original.id)
        try await pipeline.pump()

        try await pipeline.store.saveReplyInstructions("")
        try await pipeline.regenerate(original.id)
        try await pipeline.pump()
        let requests = await model.draftRequests
        XCTAssertEqual(requests.map(\.replyInstructions), [first, second, nil])
        XCTAssertEqual(requests.map(\.allowsNoReply), [true, false, false])
        let finalState = try await pipeline.store.record(original.id)?.state
        XCTAssertEqual(finalState, .draftReady)
    }

    func testReplyStartedBeforeBodyArrivalSurvivesNoReplyResult() async throws {
        let model = FakeReplyModel()
        await model.respondWithNoReply()
        let pipeline = try await pipeline(model: model)
        let subject = "Monthly statement"
        let headers = ["Message-ID": ["<statement@example.com>"]]
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: subject, sender: nil,
            headers: headers, rawData: nil), .requestBody)
        try await pipeline.pump()
        let waiting = try unwrap(try await pipeline.store.records().first)
        XCTAssertEqual(waiting.state, .awaitingBody)
        try await pipeline.store.saveEdits(waiting.id, subject: "Question about the statement", body: "Could you check the total?")
        let raw = Data("Content-Type: text/plain\r\n\r\nFor your records.".utf8)
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: subject, sender: nil,
            headers: headers, rawData: raw), .finished)
        try await pipeline.pump()
        let ids = try await pipeline.store.records().map(\.id)
        XCTAssertEqual(ids, [waiting.id])
        let saved = try unwrap(try await pipeline.store.record(waiting.id))
        XCTAssertEqual(saved.state, .needsReview)
        XCTAssertNotNil(saved.runs.last?.error)
        XCTAssertEqual(saved.editedSubject, "Question about the statement")
        XCTAssertEqual(saved.editedBody, "Could you check the total?")
        XCTAssertTrue(saved.canDisplayInWorkbench)
        let calls = await model.calls
        XCTAssertEqual(calls, 1)
    }

    func testOrdinaryMailAndHumanForwardFinishTheSameWaitingRecord() async throws {
        let model = FakeReplyModel()
        let pipeline = try await pipeline(model: model)
        let body = "Please review this offer.\n\nForwarded message\nAuto-Submitted: auto-replied\nSave 20% today"
        let raw = Data(("Content-Type: text/plain; charset=utf-8\r\n\r\n" + body).utf8)
        for (index, subject) in ["Project estimate", "Fwd: Save 20% today"].enumerated() {
            let id = "review-\(index)@example.com"
            var headers = ["Message-ID": ["<\(id)>"]]
            if index == 1 { headers["List-Unsubscribe"] = ["<mailto:unsubscribe@example.com>"] }
            XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: subject, sender: "person@example.com",
                headers: headers, rawData: nil), .requestBody)
            try await pipeline.pump()
            let waiting = try unwrap(try await pipeline.store.records().first { $0.messageID == id })
            XCTAssertEqual(waiting.state, .awaitingBody)
            XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: subject, sender: "person@example.com",
                headers: headers, rawData: raw), .finished)
            try await pipeline.pump()
            let completed = try unwrap(try await pipeline.store.record(waiting.id))
            XCTAssertEqual(completed.state, .draftReady)
            XCTAssertEqual(completed.input.body, body)
        }
        let count = try await pipeline.store.records().count
        XCTAssertEqual(count, 2)
        let calls = await model.calls
        XCTAssertEqual(calls, 2)
    }

    func testMailKitDisplayAddressesSurviveFailedBodyAndDoNotEstablishComposeIdentity() async throws {
        let pipeline = try await pipeline()
        let subject = "Synthetic address projection"
        let headers = ["Message-ID": ["<display@example.com>"]]
        let expected = MailCorrespondents(sender: "from@example.com", recipients: ["to@example.com"], cc: ["copy@example.com"])
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: subject, sender: expected.sender,
            recipients: ["to@example.com", "invalid", "extra@example.com\n"], cc: ["copy@example.com"],
            headers: headers, rawData: nil), .requestBody)
        try await pipeline.importInbox()
        let waiting = try unwrap(try await pipeline.store.records().first)
        XCTAssertEqual(waiting.state, .awaitingBody)
        XCTAssertEqual(waiting.displayCorrespondents, expected)
        XCTAssertNil(waiting.composeIdentity(includingBody: false))

        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: subject, sender: nil, headers: headers,
            rawData: Data("unreadable".utf8)), .finished)
        try await pipeline.importInbox()
        let unreadable = try unwrap(try await pipeline.store.record(waiting.id))
        XCTAssertEqual(unreadable.state, .needsReview)
        XCTAssertEqual(unreadable.displayCorrespondents, expected)

        let raw = Data("To: source@example.com\r\nContent-Type: text/plain\r\n\r\nReadable".utf8)
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: subject, sender: nil, headers: headers, rawData: raw), .finished)
        try await pipeline.importInbox()
        let readable = try unwrap(try await pipeline.store.record(waiting.id))
        XCTAssertEqual(readable.input.body, "Readable")
        XCTAssertEqual(readable.displayCorrespondents, MailCorrespondents(sender: "from@example.com",
            recipients: ["source@example.com"], cc: ["copy@example.com"]))
        XCTAssertNil(readable.composeIdentity(includingBody: true))
        let count = try await pipeline.store.records().count
        XCTAssertEqual(count, 1)
    }

    func testLateHeaderOnlyFillsMissingDisplayFieldsAfterBodyResult() async throws {
        let model = FakeReplyModel()
        let pipeline = try await pipeline(model: model)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (index, source) in ["Content-Type: text/plain\r\n\r\nPlease review", "unreadable"].enumerated() {
            let id = "late-\(index)@example.com"
            let headers = ["Message-ID": ["<\(id)>"]]
            XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: "Synthetic", sender: nil,
                recipients: ["first@example.com"], headers: headers, rawData: Data(source.utf8)), .finished)
            try await pipeline.pump()
            var expected = try unwrap(try await pipeline.store.records().first { $0.messageID == id })
            XCTAssertEqual(expected.state, index == 0 ? .draftReady : .needsReview)
            expected.mailKitAddresses = MailCorrespondents(sender: "from@example.com", recipients: ["first@example.com"],
                cc: ["copy@example.com"])
            XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: "Synthetic", sender: "from@example.com",
                recipients: ["later@example.com"], cc: ["copy@example.com"], headers: headers, rawData: nil), .requestBody)
            try await pipeline.pump()
            let enriched = try unwrap(try await pipeline.store.record(expected.id))
            XCTAssertEqual(try encoder.encode(enriched), try encoder.encode(expected))
            XCTAssertNil(enriched.composeIdentity(includingBody: false))
        }
        let calls = await model.calls
        XCTAssertEqual(calls, 1)
    }

    func testLateHeaderDoesNotEnrichAmbiguousDiscardedChangedOrRevokedRecord() async throws {
        for mode in ["ambiguous", "discarded", "changedSubject", "newPermission"] {
            let pipeline = try await pipeline()
            let headers = ["Message-ID": ["<late@example.com>"]]
            XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: "Synthetic", sender: nil,
                headers: headers, rawData: Data("Content-Type: text/plain\r\n\r\nPlease review".utf8)), .finished)
            try await pipeline.pump()
            let first = try unwrap(try await pipeline.store.records().first)
            switch mode {
            case "ambiguous":
                var other = StoredReply(id: UUID().uuidString, permissionID: first.permissionID, capturedAt: first.capturedAt,
                    messageID: first.messageID, input: first.input, state: first.state, error: nil)
                other.mailKitBody = true
                try await pipeline.store.save(other)
            case "discarded": try await pipeline.store.discard(first.id)
            case "newPermission": try await pipeline.updateSettings { $0.permission = CapturePermission(delivery: .mailKit) }
            default: break
            }
            XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: mode == "changedSubject" ? "Different" : "Synthetic",
                sender: "later@example.com", headers: headers, rawData: nil), .requestBody)
            try await pipeline.importInbox()
            let records = try await pipeline.store.records()
            XCTAssertTrue(records.allSatisfy { $0.displayCorrespondents?.sender == nil }, mode)
        }
    }

    func testAdditionalHeadersOnBodyCallbackDoNotStrandAdmittedMessage() async throws {
        let model = FakeReplyModel()
        let pipeline = try await pipeline(model: model)
        let subject = "Save 20% today"
        var headers = ["Message-ID": ["<late-header@example.com>"]]
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: subject, sender: "sender@example.com",
            headers: headers, rawData: nil), .requestBody)
        try await pipeline.pump()
        let pending = try unwrap(try await pipeline.store.records().first)
        XCTAssertEqual(pending.state, .awaitingBody)
        headers["Precedence"] = ["bulk"]
        let raw = Data("Content-Type: text/plain\r\n\r\nPreviously admitted".utf8)
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: subject, sender: "sender@example.com",
            headers: headers, rawData: raw), .finished)
        try await pipeline.pump()
        let ids = try await pipeline.store.records().map(\.id)
        XCTAssertEqual(ids, [pending.id])
        let state = try await pipeline.store.record(pending.id)?.state
        XCTAssertEqual(state, .draftReady)
        let calls = await model.calls
        XCTAssertEqual(calls, 1)
    }

    func testPauseAndRevocationPreventInspectionEvenAfterABodyRequest() async throws {
        let model = FakeReplyModel()
        let pipeline = try await pipeline(model: model)
        let headers = ["Message-ID": ["<pending@example.com>"]]
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: "Synthetic", sender: nil,
            headers: headers, rawData: nil), .requestBody)
        try await pipeline.pump()
        for paused in [true, false] {
            try await pipeline.updateSettings {
                $0.paused = paused
                if !paused { $0.permission = nil }
            }
            let decision = try pipeline.inbox.receiveMailKitMessage(subject: "Synthetic",
                sender: unexpectedRead("person@example.com"), recipients: unexpectedRead(["to@example.com"]),
                cc: unexpectedRead(["copy@example.com"]), headers: unexpectedRead(headers),
                rawData: unexpectedRead(Data()))
            XCTAssertEqual(decision, .finished)
            XCTAssertTrue(try pipeline.inbox.files().isEmpty)
            try await pipeline.pump()
        }
        let calls = await model.calls
        XCTAssertEqual(calls, 0)
    }

    func testMissingMessageIDPreservesDirectAndLegacyDeliveryBehavior() async throws {
        let pipeline = try await pipeline()
        let inbox = pipeline.inbox
        XCTAssertEqual(try inbox.receiveMailKitMessage(subject: "Synthetic", sender: nil, headers: [:],
            rawData: nil), .requestBody)
        XCTAssertTrue(try inbox.files().isEmpty)
        XCTAssertTrue(try claims(inbox).isEmpty)
        let raw = Data("Content-Type: text/plain\r\n\r\nDirect delivery".utf8)
        XCTAssertEqual(try inbox.receiveMailKitMessage(subject: "Synthetic", sender: nil, headers: [:],
            rawData: raw), .finished)
        try await pipeline.pump()
        let record = try unwrap(try await pipeline.store.records().first)
        XCTAssertNil(record.messageID)
        XCTAssertEqual(record.state, .draftReady)

        try await pipeline.updateSettings { $0.permission = CapturePermission() }
        XCTAssertEqual(try inbox.receiveMailKitMessage(subject: "Legacy", sender: nil, headers: [:],
            rawData: nil), .finished)
        let file = try XCTUnwrap(inbox.files().first)
        let capture = try JSONDecoder().decode(InboundCapture.self, from: Data(contentsOf: file))
        XCTAssertEqual(capture.issue, "missingMessageID")
        XCTAssertNil(capture.raw)
        XCTAssertTrue(try claims(inbox).isEmpty)
    }

    func testJunkOrTrashMailIsFilteredBeforeDraftingAndSurvivesLateBodyCallback() async throws {
        actor MailboxOracle {
            var dispositions: [String: MailMailboxDisposition] = [:]
            var batches: [[MailMessageLookup]] = []
            func set(_ id: String, _ value: MailMailboxDisposition) { dispositions[id] = value }
            func classify(_ queries: [MailMessageLookup]) -> [MailMailboxDisposition] {
                batches.append(queries)
                return queries.map { dispositions[$0.messageID] ?? .unknown }
            }
        }
        let oracle = MailboxOracle()
        await oracle.set("spam-body@example.com", .junkOrTrash)
        await oracle.set("spam-waiting@example.com", .junkOrTrash)
        await oracle.set("good-inbox@example.com", .active)
        await oracle.set("custom-folder@example.com", .unknown)

        let model = FakeReplyModel()
        let pipeline = try await pipeline(model: model, classifyMailboxes: { await oracle.classify($0) })

        let spamRaw = Data("Content-Type: text/plain\r\n\r\nCurated listing offer".utf8)
        let goodRaw = Data("Content-Type: text/plain\r\n\r\nCan we meet Tuesday?".utf8)

        // 1. Junk email arriving with body is filtered before calling the agent.
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: "Listing offer", sender: "promo@example.com",
            headers: ["Message-ID": ["<spam-body@example.com>"]], rawData: spamRaw), .finished)
        // 2. Junk email stuck in awaitingBody is filtered immediately.
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: "Waiting spam", sender: "promo@example.com",
            headers: ["Message-ID": ["<spam-waiting@example.com>"]], rawData: nil), .requestBody)
        // 3. Active inbox and custom-folder (unknown) messages still draft normally.
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: "Tuesday sync", sender: "peer@example.com",
            headers: ["Message-ID": ["<good-inbox@example.com>"]], rawData: goodRaw), .finished)
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: "Project folder note", sender: "peer@example.com",
            headers: ["Message-ID": ["<custom-folder@example.com>"]], rawData: goodRaw), .finished)

        try await pipeline.pump()

        let records = try await pipeline.store.records()
        let spamWithBody = try unwrap(records.first { $0.messageID == "spam-body@example.com" })
        XCTAssertEqual(spamWithBody.excludedFromAuthorizedInbox, true)
        XCTAssertEqual(spamWithBody.state, .cancelled)
        XCTAssertEqual(spamWithBody.error, "junkOrTrash")
        XCTAssertFalse(spamWithBody.canDisplayInWorkbench)
        XCTAssertTrue(spamWithBody.runs.isEmpty)

        let spamWaiting = try unwrap(records.first { $0.messageID == "spam-waiting@example.com" })
        XCTAssertEqual(spamWaiting.excludedFromAuthorizedInbox, true)
        XCTAssertEqual(spamWaiting.state, .cancelled)
        XCTAssertEqual(spamWaiting.error, "junkOrTrash")
        XCTAssertFalse(spamWaiting.canDisplayInWorkbench)

        let good = try unwrap(records.first { $0.messageID == "good-inbox@example.com" })
        XCTAssertEqual(good.state, .draftReady)
        XCTAssertTrue(good.canDisplayInWorkbench)

        let customFolder = try unwrap(records.first { $0.messageID == "custom-folder@example.com" })
        XCTAssertEqual(customFolder.state, .draftReady)
        XCTAssertTrue(customFolder.canDisplayInWorkbench)

        let callsAfterFirstPump = await model.calls
        XCTAssertEqual(callsAfterFirstPump, 2)

        // Late body callback for the already-excluded awaitingBody spam must not resurrect or draft it.
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: "Waiting spam", sender: "promo@example.com",
            headers: ["Message-ID": ["<spam-waiting@example.com>"]], rawData: spamRaw), .finished)
        try await pipeline.pump()

        let afterLateBody = try await pipeline.store.records().filter { $0.messageID == "spam-waiting@example.com" }
        XCTAssertEqual(afterLateBody.count, 1)
        XCTAssertEqual(afterLateBody.first?.excludedFromAuthorizedInbox, true)
        XCTAssertEqual(afterLateBody.first?.state, .cancelled)
        let callsAfterLateBody = await model.calls
        XCTAssertEqual(callsAfterLateBody, 2)
    }

    func testDraftMovedToJunkOrTrashLaterIsHiddenAndAuditRespectsThrottleAndPause() async throws {
        actor MailboxOracle {
            var dispositions: [String: MailMailboxDisposition] = [:]
            var calls = 0
            func set(_ id: String, _ value: MailMailboxDisposition) { dispositions[id] = value }
            func classify(_ queries: [MailMessageLookup]) -> [MailMailboxDisposition] {
                calls += 1
                return queries.map { dispositions[$0.messageID] ?? .unknown }
            }
        }
        let oracle = MailboxOracle()
        await oracle.set("later-trashed@example.com", .active)
        let model = FakeReplyModel()
        let pipeline = try await pipeline(model: model, classifyMailboxes: { await oracle.classify($0) },
                                          mailboxAuditInterval: 60)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let raw = Data("Content-Type: text/plain\r\n\r\nChecking in on the order.".utf8)
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: "Order check", sender: "person@example.com",
            headers: ["Message-ID": ["<later-trashed@example.com>"]], rawData: raw), .finished)
        try await pipeline.pump(now: t0)

        let initial = try unwrap(try await pipeline.store.records().first)
        XCTAssertEqual(initial.state, .draftReady)
        XCTAssertTrue(initial.canDisplayInWorkbench)
        let callsAtT0 = await oracle.calls
        XCTAssertEqual(callsAtT0, 1)

        // User moves the email to Trash in Apple Mail.
        await oracle.set("later-trashed@example.com", .junkOrTrash)

        // Within 60s throttle with no new captures: no redundant Mail audit.
        try await pipeline.pump(now: t0.addingTimeInterval(15))
        let callsAtT15 = await oracle.calls
        XCTAssertEqual(callsAtT15, 1)

        // Paused state never queries Apple Mail even past the interval.
        try await pipeline.updateSettings { $0.paused = true }
        try await pipeline.pump(now: t0.addingTimeInterval(120))
        let callsWhilePaused = await oracle.calls
        XCTAssertEqual(callsWhilePaused, 1)
        try await pipeline.updateSettings { $0.paused = false }

        // Activation check with shorter interval (5s) catches the moved message immediately.
        try await pipeline.pump(mailboxAuditMinInterval: 5, now: t0.addingTimeInterval(20))
        let callsAtT20 = await oracle.calls
        XCTAssertEqual(callsAtT20, 2)

        let updated = try unwrap(try await pipeline.store.record(initial.id))
        let settings = try await pipeline.store.settings()
        XCTAssertEqual(updated.excludedFromAuthorizedInbox, true)
        XCTAssertFalse(updated.canDisplayInWorkbench)
        XCTAssertFalse(updated.isReadyForReplyReminder(settings: settings, now: t0.addingTimeInterval(20)))
        XCTAssertNotNil(updated.draftData)
    }

    func testAutomationDenialStopsFurtherMailboxAuditsAndFailsOpen() async throws {
        actor FailingOracle {
            var calls = 0
            func classify(_ queries: [MailMessageLookup]) throws -> [MailMailboxDisposition] {
                calls += 1
                throw MailMailboxAuditError.automationDenied
            }
        }
        let oracle = FailingOracle()
        let model = FakeReplyModel()
        let pipeline = try await pipeline(model: model, classifyMailboxes: { try await oracle.classify($0) })
        let raw = Data("Content-Type: text/plain\r\n\r\nPlease confirm availability.".utf8)

        for idx in 0..<2 {
            XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: "Availability \(idx)", sender: "person@example.com",
                headers: ["Message-ID": ["<avail-\(idx)@example.com>"]], rawData: raw), .finished)
            try await pipeline.pump()
        }
        // Only attempted once; after automationDenied it stopped asking and let drafting succeed.
        let auditCalls = await oracle.calls
        XCTAssertEqual(auditCalls, 1)
        let modelCalls = await model.calls
        XCTAssertEqual(modelCalls, 2)
        let records = try await pipeline.store.records()
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.state == .draftReady && $0.canDisplayInWorkbench })
    }
}
