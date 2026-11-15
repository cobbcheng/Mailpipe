import XCTest
@testable import HarnessAdapters
import MailpipeCore

@MainActor
final class AdapterTests: XCTestCase {
    func testClaudePlanUsesStdinAndCleansWorkspace() async throws {
        let root = try TemporaryDirectory(), dialect = ClaudeCodeDialect()
        let runner = RecordingRunner(inspectionOutputs(dialect) + [ProcessOutput(stdout: try claudeEnvelope())])
        let adapter = ClaudeCodeAdapter(executable: root.url.appendingPathComponent("claude"), dialect: dialect,
                                        runner: runner, temporaryRoot: root.url, environment: [:])
        let result = try await adapter.runSyntheticProbe()
        XCTAssertEqual(result.response.results.first?.category, .billing)
        XCTAssertNil(result.inputTokens)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 3)
        let invocation = try XCTUnwrap(calls.last)
        XCTAssertTrue(String(decoding: invocation.stdin, as: UTF8.self).contains("shop@example.com"))
        XCTAssertFalse(invocation.arguments.joined().contains("shop@example.com"))
        XCTAssertEqual(invocation.arguments[try XCTUnwrap(invocation.arguments.firstIndex(of: "--tools")) + 1], "")
        XCTAssertTrue(invocation.arguments.contains("--safe-mode"))
        XCTAssertFalse(invocation.arguments.contains(where: { $0.contains("skip-permissions") || $0 == "bypassPermissions" }))
        for call in calls { XCTAssertFalse(FileManager.default.fileExists(atPath: call.workingDirectory.path)) }
    }
    func testCodexPlanAndJSONLEnvelope() async throws {
        let root = try TemporaryDirectory(), dialect = CodexCLIDialect()
        let runner = RecordingRunner(inspectionOutputs(dialect) + [ProcessOutput(stdout: try codexEvents())])
        let adapter = CodexCLIAdapter(executable: root.url.appendingPathComponent("codex"), dialect: dialect,
                                      runner: runner, temporaryRoot: root.url, environment: [:])
        let result = try await adapter.runSyntheticProbe()
        XCTAssertEqual(result.inputTokens, 12); XCTAssertEqual(result.outputTokens, 20)
        let calls = await runner.calls
        let invocation = try XCTUnwrap(calls.last)
        XCTAssertTrue(invocation.arguments.contains("read-only"))
        XCTAssertTrue(invocation.arguments.contains("--ignore-user-config"))
        XCTAssertTrue(invocation.arguments.contains("features.shell_tool=false"))
        XCTAssertEqual(invocation.arguments.last, "-")
        XCTAssertFalse(invocation.arguments.contains(where: { $0.contains("bypass") || $0 == "--trust" }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocation.workingDirectory.path))
    }
    func testMissingFlagBlocksProbeAndDoesNotRetry() async throws {
        let root = try TemporaryDirectory()
        let runner = RecordingRunner([ProcessOutput(stdout: Data("version 1.2.3".utf8)),
                                      ProcessOutput(stdout: Data("--tools-extra --print --output-format".utf8))])
        let adapter = ClaudeCodeAdapter(executable: root.url.appendingPathComponent("claude"), dialect: ClaudeCodeDialect(), runner: runner, temporaryRoot: root.url)
        do { _ = try await adapter.runSyntheticProbe(); XCTFail("must reject") }
        catch { XCTAssertEqual(error as? MailpipeError, .unsupportedVersion) }
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 2)
    }
    func testRealMailNeverLaunchesEvenWithAllowedRoute() async throws {
        let runner = RecordingRunner()
        let adapter = CodexCLIAdapter(executable: URL(fileURLWithPath: "/no-executable"), dialect: CodexCLIDialect(), runner: runner)
        do {
            _ = try await adapter.classifyMail(SyntheticFixture.request, route: AccountRoute(accountID: "synthetic", allowedHarnesses: [.codex]))
            XCTFail("not certified")
        } catch { XCTAssertEqual(error as? MailpipeError, .unsafeCapability) }
        do {
            _ = try await adapter.classifyMail(SyntheticFixture.request, route: AccountRoute(accountID: nil, allowedHarnesses: [.codex]))
            XCTFail("unknown account")
        } catch { XCTAssertEqual(error as? MailpipeError, .unknownAccount) }
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }
    func testMalformedFailedAndToolEventsAreNotSuccess() throws {
        let claude = ClaudeCodeDialect(), codex = CodexCLIDialect()
        for payload in [Data("garbage".utf8), Data(#"{"type":"result","subtype":"error_max_turns","is_error":true}"#.utf8)] {
            XCTAssertThrowsError(try claude.decode(payload, request: SyntheticFixture.request))
        }
        XCTAssertThrowsError(try codex.decode(codexEvents(completed: false), request: SyntheticFixture.request))
        let tool = Data(#"{"type":"item.completed","item":{"type":"command_execution","command":"unsafe"}}"#.utf8)
        XCTAssertThrowsError(try codex.decode(tool, request: SyntheticFixture.request)) { XCTAssertEqual($0 as? MailpipeError, .unsafeCapability) }
        var trailingError = try codexEvents(); trailingError.append(Data(#"{"type":"error","message":"failed"}"#.utf8))
        XCTAssertThrowsError(try codex.decode(trailingError, request: SyntheticFixture.request))
    }
    func testFailedProcessDoesNotReturnOutputAndWorkspaceIsRemoved() async throws {
        let root = try TemporaryDirectory(), dialect = ClaudeCodeDialect()
        let runner = RecordingRunner(inspectionOutputs(dialect) + [ProcessOutput(stdout: Data(), stderr: Data("authentication required: private text".utf8), exitCode: 1)])
        let adapter = ClaudeCodeAdapter(executable: root.url.appendingPathComponent("claude"), dialect: dialect, runner: runner, temporaryRoot: root.url)
        do { _ = try await adapter.runSyntheticProbe(); XCTFail("must fail") }
        catch { XCTAssertEqual(error as? MailpipeError, .authRequired) }
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 3)
        for call in calls { XCTAssertFalse(FileManager.default.fileExists(atPath: call.workingDirectory.path)) }
    }
    func testMinimalEnvironmentDropsCredentialsAndInjectionVariables() {
        let env = ProbeEnvironment.minimal(from: ["ANTHROPIC_API_KEY":"secret", "OPENAI_API_KEY":"secret", "DYLD_INSERT_LIBRARIES":"bad", "CLAUDE_CODE_SIMPLE":"1"])
        XCTAssertNil(env["ANTHROPIC_API_KEY"]); XCTAssertNil(env["OPENAI_API_KEY"])
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"]); XCTAssertNil(env["CLAUDE_CODE_SIMPLE"])
    }
    func testOfflineExamplesUseBothParsers() throws { XCTAssertEqual(try OfflineProbe.run().count, 2) }
    func testDiscoveryIgnoresRelativePATHAndDeduplicates() throws {
        let root = try TemporaryDirectory()
        _ = try root.script("exit 0", name: "claude")
        let installations = HarnessDiscovery.find(path: ".:\(root.url.path):\(root.url.path)", home: root.url)
        let matches = installations.filter { $0.executable.path.hasPrefix(root.url.path) }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.kind, .claude)
    }
}
