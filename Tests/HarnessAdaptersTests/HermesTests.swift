import Foundation
import XCTest
@testable import HarnessAdapters
import MailpipeCore

@MainActor
final class HermesTests: XCTestCase {
    func testIsolatedProfileAndOrdinaryMailOnly() throws {
        let root = try TemporaryDirectory()
        let dialect = HermesDialect()
        let cli = root.url.appendingPathComponent("fake-hermes")
        let environment = try dialect.prepare(directory: root.url, executable: cli,
                                               environment: ["HOME": root.url.path, "DEEPSEEK_API_KEY": "synthetic"])
        let profile = try XCTUnwrap(environment["MAILPIPE_HERMES_AUTH_PROFILE"])
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: profile + "/.env")
        XCTAssertEqual(target, root.url.appendingPathComponent(".hermes/.env").path)
        XCTAssertNil(environment["DEEPSEEK_API_KEY"])
        XCTAssertEqual(environment["HERMES_SAFE_MODE"], "1")
        XCTAssertEqual(environment["HERMES_SINGLE_QUERY_SESSION"], "1")
        XCTAssertNotEqual(environment["HOME"], root.url.path)
        var request = try ReplyDraftRequest(message: ReplySyntheticFixture.message)
        let stdin = Data("synthetic".utf8)
        let call = try dialect.replyInvocation(task: .draft(request), schema: "{}", stdin: stdin, directory: root.url,
                                               executable: cli, environment: environment)
        XCTAssertEqual(call.executable, cli)
        XCTAssertEqual(call.stdin, stdin)
        XCTAssertEqual(call.arguments.prefix(2), ["--run-module", "cProfile"])
        request.externalContext = .gitHubPullRequest(url: "https://github.com/example/project/pull/1", authenticated: true)
        XCTAssertThrowsError(try dialect.replyInvocation(task: .draft(request), schema: "{}", stdin: stdin, directory: root.url,
                                                         executable: cli, environment: environment))
        XCTAssertTrue(dialect.acceptsVersion("Hermes Agent 0.23.3"))
        XCTAssertFalse(dialect.acceptsVersion("Hermes Agent 0.23.1"))
        XCTAssertFalse(dialect.acceptsVersion("Hermes Agent 1.0.0"))
    }

    func testRuntimeRejectsUnapprovedRequestsAndMapsProviderFailuresWithoutNetwork() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hermes-runtime.py")
        let dialect = HermesDialect()
        let cases: [(String, MailpipeError?, Int)] = [
            ("success", nil, 1), ("local-tools", .unsafeCapability, 0), ("wire-tools", .unsafeCapability, 0),
            ("foreign-host", .unsafeCapability, 0), ("extra-message", .unsafeCapability, 0),
            ("repeated", .unsafeCapability, 1), ("changed-model", .invalidOutput, 1),
            ("401", .authRequired, 1), ("402", .quotaExhausted, 1), ("429", .rateLimited, 1), ("timeout", .timedOut, 1)
        ]
        for (scenario, expected, calls) in cases {
            let root = try TemporaryDirectory()
            let task = ReplyModelTask.draft(try ReplyDraftRequest(message: ReplySyntheticFixture.message))
            let python = URL(fileURLWithPath: "/usr/bin/python3")
            let call = try dialect.replyInvocation(task: task, schema: "{}", stdin: Data("synthetic".utf8),
                directory: root.url, executable: python, environment: [:])
            let script = try XCTUnwrap(call.arguments.last)
            let result = try await POSIXProcessRunner().run(ProcessInvocation(executable: python,
                arguments: ["-I", fixtures.path, scenario, script], stdin: call.stdin, workingDirectory: root.url,
                environment: ["HOME": root.url.path, "MAILPIPE_HERMES_AUTH_PROFILE": root.url.path, "PATH": "/usr/bin:/bin"]))
            let counter = try? String(contentsOf: root.url.appendingPathComponent("calls"), encoding: .utf8)
            XCTAssertEqual(counter?.split(separator: "\n").count ?? 0, calls, scenario)
            if let expected {
                XCTAssertNotEqual(result.exitCode, 0, scenario)
                XCTAssertEqual(dialect.runFailure(result), expected, scenario)
                XCTAssertTrue(result.stdout.isEmpty, scenario)
            } else {
                XCTAssertEqual(result.exitCode, 0)
                let receipt = try dialect.replyOutput(result.stdout, task: task, inputCharacters: 9, directory: root.url)
                XCTAssertEqual(receipt.actualModel, "deepseek-flash")
                XCTAssertEqual(receipt.inputTokens, 11)
                XCTAssertEqual(receipt.outputTokens, 4)
                XCTAssertEqual(String(decoding: receipt.content, as: UTF8.self), "fixture")
            }
        }
    }
}
