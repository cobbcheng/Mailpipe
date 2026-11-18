import XCTest
@testable import HarnessAdapters
import MailpipeCore

@MainActor
final class AdapterTests: XCTestCase {
    func testNativeInstructionsAreBoundedEphemeralAndNotProjectOrCredentials() throws {
        let root = try TemporaryDirectory()
        let user = root.url.appendingPathComponent("user")
        let dsh = user.appendingPathComponent(".dsh")
        let agents = user.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at: dsh, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data("Prefer short replies.".utf8).write(to: dsh.appendingPathComponent("AGENTS.md"))
        try Data("Use a warm closing.".utf8).write(to: agents.appendingPathComponent("AGENTS.md"))
        try Data("must not copy".utf8).write(to: dsh.appendingPathComponent("credentials.yaml"))
        let work = root.url.appendingPathComponent("work")
        let env = try DeepSeekHarnessDialect().prepare(directory: work, executable: root.url.appendingPathComponent("dsh"), environment: ["HOME": user.path])
        XCTAssertEqual(try String(contentsOfFile: env["DSH_HOME"]! + "/AGENTS.md", encoding: .utf8), "Prefer short replies.")
        XCTAssertEqual(try String(contentsOfFile: env["DSH_AGENTS_HOME"]! + "/AGENTS.md", encoding: .utf8), "Use a warm closing.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env["DSH_HOME"]! + "/credentials.yaml"))
        let patch = try String(contentsOf: work.appendingPathComponent("deepseek-restricted.yml"), encoding: .utf8)
        XCTAssertTrue(patch.contains("instructionFileCandidates: []"))
        XCTAssertTrue(patch.contains("localInstructionFileCandidates: []"))
        XCTAssertTrue(patch.contains("- id: tool-fs\n  disabled: true"))
    }
    func testMissingOversizedAndSymlinkNativeInstructionsFallBackWithoutReadingTarget() throws {
        let root = try TemporaryDirectory()
        let user = root.url.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: user.appendingPathComponent(".dsh"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user.appendingPathComponent(".agents"), withIntermediateDirectories: true)
        let large = user.appendingPathComponent(".dsh/AGENTS.md")
        try Data(repeating: 65, count: 16_385).write(to: large)
        try FileManager.default.createSymbolicLink(at: user.appendingPathComponent(".agents/AGENTS.md"), withDestinationURL: large)
        let env = try DeepSeekHarnessDialect().prepare(directory: root.url.appendingPathComponent("work"), executable: root.url.appendingPathComponent("dsh"), environment: ["HOME": user.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: env["DSH_HOME"]! + "/AGENTS.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: env["DSH_AGENTS_HOME"]! + "/AGENTS.md"))
        let missing = try DeepSeekHarnessDialect().prepare(directory: root.url.appendingPathComponent("empty"), executable: root.url.appendingPathComponent("dsh"), environment: ["HOME": root.url.appendingPathComponent("absent").path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing["DSH_HOME"]! + "/AGENTS.md"))
    }
    func testDeepSeekRunUsesStdinAndCleansWorkspace() async throws {
        let root = try TemporaryDirectory(), dialect = DeepSeekHarnessDialect()
        let runner = RecordingRunner(inspectionOutputs(dialect) + [ProcessOutput(stdout: try deepseekEvents(ReplySyntheticFixture.decision))])
        let adapter = DeepSeekHarnessAdapter(executable: root.url.appendingPathComponent("dsh"), dialect: dialect,
                                        runner: runner, temporaryRoot: root.url, environment: [:])
        let output = try await adapter.run(.triage(ReplySyntheticFixture.triage),
                                           route: AccountRoute(accountID: "synthetic", allowedHarnesses: [.deepseek])) {}
        XCTAssertEqual(try ReplyDecision.validated(output.content, for: ReplySyntheticFixture.triage).shouldReply, .yes)
        XCTAssertEqual(output.inputTokens, 12); XCTAssertEqual(output.outputTokens, 20)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 3)
        let invocation = try XCTUnwrap(calls.last)
        XCTAssertTrue(String(decoding: invocation.stdin, as: UTF8.self).contains("colleague@example.com"))
        XCTAssertFalse(invocation.arguments.joined().contains("colleague@example.com"))
        XCTAssertTrue(invocation.arguments.contains("read-only"))
        XCTAssertTrue(invocation.arguments.contains("--patch"))
        XCTAssertEqual(invocation.environment["DSH_HOME"], invocation.workingDirectory.appendingPathComponent("dsh-home").path)
        XCTAssertNotEqual(invocation.environment["DSH_HOME"], invocation.environment["MAILPIPE_DSH_AUTH_HOME"])
        XCTAssertEqual(invocation.environment["DSH_TELEMETRY_DISABLED"], "1")
        XCTAssertFalse(invocation.arguments.contains(where: { $0.contains("skip-permissions") || $0 == "bypassPermissions" }))
        for call in calls { XCTAssertFalse(FileManager.default.fileExists(atPath: call.workingDirectory.path)) }
    }
    func testMissingFlagBlocksRunAndDoesNotRetry() async throws {
        let root = try TemporaryDirectory()
        let runner = RecordingRunner([ProcessOutput(stdout: Data("0.2.2-rc.1".utf8)),
                                      ProcessOutput(stdout: Data("--tools-extra --print --output-format".utf8))])
        let adapter = DeepSeekHarnessAdapter(executable: root.url.appendingPathComponent("dsh"), dialect: DeepSeekHarnessDialect(), runner: runner, temporaryRoot: root.url)
        do {
            _ = try await adapter.run(.triage(ReplySyntheticFixture.triage),
                                      route: AccountRoute(accountID: "synthetic", allowedHarnesses: [.deepseek])) {}
            XCTFail("must reject")
        } catch { XCTAssertEqual(error as? MailpipeError, .unsupportedVersion) }
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 2)
    }
    func testFailedProcessDoesNotReturnOutputAndWorkspaceIsRemoved() async throws {
        let root = try TemporaryDirectory(), dialect = DeepSeekHarnessDialect()
        let runner = RecordingRunner(inspectionOutputs(dialect) + [ProcessOutput(stdout: Data(), stderr: Data("authentication required: private text".utf8), exitCode: 1)])
        let adapter = DeepSeekHarnessAdapter(executable: root.url.appendingPathComponent("dsh"), dialect: dialect, runner: runner, temporaryRoot: root.url)
        do {
            _ = try await adapter.run(.triage(ReplySyntheticFixture.triage),
                                      route: AccountRoute(accountID: "synthetic", allowedHarnesses: [.deepseek])) {}
            XCTFail("must fail")
        } catch { XCTAssertEqual(error as? MailpipeError, .authRequired) }
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 3)
        for call in calls { XCTAssertFalse(FileManager.default.fileExists(atPath: call.workingDirectory.path)) }
    }
    func testDeepSeekVersionChangeStopsBeforeHelpOrModel() async throws {
        let root = try TemporaryDirectory()
        let runner = RecordingRunner([ProcessOutput(stdout: Data("0.2.3".utf8))])
        let adapter = DeepSeekHarnessAdapter(executable: root.url.appendingPathComponent("dsh"), dialect: DeepSeekHarnessDialect(), runner: runner, temporaryRoot: root.url)
        do {
            _ = try await adapter.run(.triage(ReplySyntheticFixture.triage),
                                      route: AccountRoute(accountID: "synthetic", allowedHarnesses: [.deepseek])) {}
            XCTFail("new profile needs validation")
        } catch { XCTAssertEqual(error as? MailpipeError, .unsupportedVersion) }
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
    }
    func testDeepSeekRejectsMissingAuditToolsFailedFinalAndForeignSession() throws {
        let dialect = DeepSeekHarnessDialect()
        let events = try deepseekEvents(ReplySyntheticFixture.decision).split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        func rejected(_ rows: [[String: Any]]) throws {
            let data = try rows.reduce(into: Data()) { $0.append(try JSONSerialization.data(withJSONObject: $1)); $0.append(10) }
            XCTAssertThrowsError(try dialect.decodeEnvelope(data))
        }
        try rejected(events.filter { $0["type"] as? String != "mailpipe_safety" })
        var exposed = events; exposed[1]["advertised"] = ["bash"]; try rejected(exposed)
        var tools = events; tools.insert(["type":"tool_call", "name":"read_file"], at:2); try rejected(tools)
        var failed = events; failed[3]["reason"] = ["kind":"error"]; try rejected(failed)
        var foreign = events; foreign[3]["sessionId"] = "foreign"; try rejected(foreign)
        try rejected(events + [["type":"error"]])
        try rejected(Array(events.dropLast()))
    }
    func testMinimalEnvironmentDropsCredentialsAndInjectionVariables() {
        let env = ProbeEnvironment.minimal(from: ["ANTHROPIC_API_KEY":"secret", "OPENAI_API_KEY":"secret", "DYLD_INSERT_LIBRARIES":"bad", "CLAUDE_CODE_SIMPLE":"1"])
        XCTAssertNil(env["ANTHROPIC_API_KEY"]); XCTAssertNil(env["OPENAI_API_KEY"])
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"]); XCTAssertNil(env["CLAUDE_CODE_SIMPLE"])
    }
    func testDiscoveryIgnoresRelativePATHAndDeduplicates() throws {
        let root = try TemporaryDirectory()
        _ = try root.script("exit 0", name: "dsh")
        let installations = HarnessDiscovery.find(path: ".:\(root.url.path):\(root.url.path)", home: root.url)
        let matches = installations.filter { $0.executable.path.hasPrefix(root.url.path) }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.kind, .deepseek)
    }
}
