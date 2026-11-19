import XCTest
@testable import MailpipeRuntime
import MailpipeCore

@MainActor
final class MailKitAdmissionTests: XCTestCase {
    private func pipeline(model: FakeReplyModel = FakeReplyModel()) throws -> ReplyPipeline {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let inbox = try CaptureInbox(directory: root.appendingPathComponent("inbox"))
        let pipeline = ReplyPipeline(store: store, inbox: inbox,
            resolve: { _, _ in XCTFail("Unexpected Mail read"); return nil },
            inAuthorizedInbox: { _, _, _ in XCTFail("Unexpected mailbox lookup"); return nil },
            model: { _ in model })
        try pipeline.updateSettings {
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
        let pipeline = try pipeline(model: model)
        let samples = [
            ("Automatic reply", ["Auto-Submitted": ["auto-replied"]]),
            ("Save 20% today", ["List-Unsubscribe": ["<mailto:unsubscribe@example.com>"]])
        ]
        for (index, sample) in samples.enumerated() {
            let (subject, evidence) = sample
            var headers = evidence
            headers["Message-ID"] = ["<sample-\(index)@example.com>"]
            for raw in [nil, Data("Content-Type: text/plain\r\n\r\nSynthetic".utf8)] as [Data?] {
                let decision = try pipeline.inbox.receiveMailKitMessage(subject: subject, sender: "sender@example.com",
                    headers: headers, rawData: unexpectedRead(raw))
                XCTAssertEqual(decision, .finished, subject)
            }
        }
        XCTAssertTrue(try claims(pipeline.inbox).isEmpty)
        XCTAssertTrue(try pipeline.inbox.files().isEmpty)
        try await pipeline.pump()
        XCTAssertTrue(try pipeline.store.records().isEmpty)
        let calls = await model.calls
        XCTAssertEqual(calls, 0)
    }

    func testOrdinaryMailAndHumanForwardFinishTheSameWaitingRecord() async throws {
        let model = FakeReplyModel()
        let pipeline = try pipeline(model: model)
        let body = "Please review this offer.\n\nForwarded message\nAuto-Submitted: auto-replied\nSave 20% today"
        let raw = Data(("Content-Type: text/plain; charset=utf-8\r\n\r\n" + body).utf8)
        for (index, subject) in ["Project estimate", "Fwd: Save 20% today"].enumerated() {
            let id = "review-\(index)@example.com"
            var headers = ["Message-ID": ["<\(id)>"]]
            if index == 1 { headers["List-Unsubscribe"] = ["<mailto:unsubscribe@example.com>"] }
            XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: subject, sender: "person@example.com",
                headers: headers, rawData: nil), .requestBody)
            try await pipeline.pump()
            let waiting = try XCTUnwrap(pipeline.store.records().first { $0.messageID == id })
            XCTAssertEqual(waiting.state, .awaitingBody)
            XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: subject, sender: "person@example.com",
                headers: headers, rawData: raw), .finished)
            try await pipeline.pump()
            let completed = try XCTUnwrap(pipeline.store.record(waiting.id))
            XCTAssertEqual(completed.state, .draftReady)
            XCTAssertEqual(completed.input.body, body)
        }
        XCTAssertEqual(try pipeline.store.records().count, 2)
        let calls = await model.calls
        XCTAssertEqual(calls, 2)
    }

    func testAdditionalHeadersOnBodyCallbackDoNotStrandAdmittedMessage() async throws {
        let model = FakeReplyModel()
        let pipeline = try pipeline(model: model)
        let subject = "Save 20% today"
        var headers = ["Message-ID": ["<late-header@example.com>"]]
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: subject, sender: "sender@example.com",
            headers: headers, rawData: nil), .requestBody)
        try await pipeline.pump()
        let pending = try XCTUnwrap(pipeline.store.records().first)
        XCTAssertEqual(pending.state, .awaitingBody)
        headers["Precedence"] = ["bulk"]
        let raw = Data("Content-Type: text/plain\r\n\r\nPreviously admitted".utf8)
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: subject, sender: "sender@example.com",
            headers: headers, rawData: raw), .finished)
        try await pipeline.pump()
        XCTAssertEqual(try pipeline.store.records().map(\.id), [pending.id])
        XCTAssertEqual(try pipeline.store.record(pending.id)?.state, .draftReady)
        let calls = await model.calls
        XCTAssertEqual(calls, 1)
    }

    func testPauseAndRevocationPreventInspectionEvenAfterABodyRequest() async throws {
        let model = FakeReplyModel()
        let pipeline = try pipeline(model: model)
        let headers = ["Message-ID": ["<pending@example.com>"]]
        XCTAssertEqual(try pipeline.inbox.receiveMailKitMessage(subject: "Synthetic", sender: nil,
            headers: headers, rawData: nil), .requestBody)
        try await pipeline.pump()
        for paused in [true, false] {
            try pipeline.updateSettings {
                $0.paused = paused
                if !paused { $0.permission = nil }
            }
            let decision = try pipeline.inbox.receiveMailKitMessage(subject: "Synthetic",
                sender: unexpectedRead("person@example.com"), headers: unexpectedRead(headers),
                rawData: unexpectedRead(Data()))
            XCTAssertEqual(decision, .finished)
            XCTAssertTrue(try pipeline.inbox.files().isEmpty)
            try await pipeline.pump()
        }
        let calls = await model.calls
        XCTAssertEqual(calls, 0)
    }

    func testMissingMessageIDPreservesDirectAndLegacyDeliveryBehavior() async throws {
        let pipeline = try pipeline()
        let inbox = pipeline.inbox
        XCTAssertEqual(try inbox.receiveMailKitMessage(subject: "Synthetic", sender: nil, headers: [:],
            rawData: nil), .requestBody)
        XCTAssertTrue(try inbox.files().isEmpty)
        XCTAssertTrue(try claims(inbox).isEmpty)
        let raw = Data("Content-Type: text/plain\r\n\r\nDirect delivery".utf8)
        XCTAssertEqual(try inbox.receiveMailKitMessage(subject: "Synthetic", sender: nil, headers: [:],
            rawData: raw), .finished)
        try await pipeline.pump()
        let record = try XCTUnwrap(pipeline.store.records().first)
        XCTAssertNil(record.messageID)
        XCTAssertEqual(record.state, .draftReady)

        try pipeline.updateSettings { $0.permission = CapturePermission() }
        XCTAssertEqual(try inbox.receiveMailKitMessage(subject: "Legacy", sender: nil, headers: [:],
            rawData: nil), .finished)
        let file = try XCTUnwrap(inbox.files().first)
        let capture = try JSONDecoder().decode(InboundCapture.self, from: Data(contentsOf: file))
        XCTAssertEqual(capture.issue, "missingMessageID")
        XCTAssertNil(capture.raw)
        XCTAssertTrue(try claims(inbox).isEmpty)
    }
}
