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
        let prefix = "    personaPrefix: "
        let line = try XCTUnwrap(patch.components(separatedBy: "\n").first { $0.hasPrefix(prefix) })
        let policy = try JSONDecoder().decode(String.self, from: Data(line.dropFirst(prefix.count).utf8))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = repo.appendingPathComponent("Packages/HarnessAdapters/Sources/Resources/reply-policy.md")
        let expected = try String(contentsOf: source, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(policy, expected)
        XCTAssertFalse(patch.contains("__MAILPIPE_REPLY_POLICY__"))
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
    func testOptionalLookupRequiresMatchingReceiptWhenCalled() throws {
        let tool = "mcp__mailpipe__read_pr_diff"
        let dialect = DeepSeekHarnessDialect()
        var events = try deepseekEvents(ReplySyntheticFixture.draft).split(separator: 10).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        events[1]["registry"] = [tool]
        events[1]["advertised"] = [tool]
        func decode() throws -> DeepSeekEnvelope {
            let data = try events.reduce(into: Data()) { buffer, row in
                buffer.append(try JSONSerialization.data(withJSONObject: row))
                buffer.append(10)
            }
            return try dialect.decodeEnvelope(data, review: true)
        }
        XCTAssertNil(try decode().readPullRequestDiff)
        events.insert(["type": "tool_call", "tool": tool, "callId": "one", "input": [String: String]()], at: 2)
        XCTAssertThrowsError(try decode())
        events.insert(["type": "tool_result", "callId": "other", "status": "completed"], at: 3)
        XCTAssertThrowsError(try decode())
        events[3]["callId"] = "one"
        events[3]["truncated"] = true
        events[3]["result"] = "MAILPIPE_PR_PATCH_READ\n" + #"{"changes":[{"file":"example.swift","patch":"+example"}]}"#
        XCTAssertEqual(try decode().readPullRequestDiff, true)
        events.insert(["type": "thinking", "truncated": true], at: 4)
        XCTAssertEqual(try decode().readPullRequestDiff, true)
        let final = events.count - 1
        let original = try XCTUnwrap(events[final]["text"] as? String)
        events[final]["text"] = "```json\n" + original + "\n```"
        XCTAssertEqual(try decode().content, Data(original.utf8))
        events[final]["truncated"] = true
        XCTAssertThrowsError(try decode())
        events[final].removeValue(forKey: "truncated")
        events[3]["status"] = "error"
        XCTAssertEqual(try decode().readPullRequestDiff, false)
        events[2]["tool"] = "bash"
        XCTAssertThrowsError(try decode())
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

    func testClaudeDiscoveryKeepsStableLauncherAndOnlyOffersDraftTools() throws {
        let root = try TemporaryDirectory()
        let binary = try root.script("exit 1", name: "2.1.296")
        let bin = root.url.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let launcher = bin.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: binary)
        _ = try root.script("exit 1", name: "codex")
        let found = HarnessDiscovery.find(path: root.url.path, home: root.url)
        let choices = HarnessDiscovery.replyLaunchers(in: found, keeping: launcher.path, kind: .claude)
        XCTAssertEqual(choices.first, HarnessInstallation(kind: .claude, executable: launcher))
        XCTAssertTrue(choices.contains { $0.kind == .codex })
        XCTAssertEqual(choices.filter { $0.executable == launcher }.count, 1)
    }

    func testDiscoversBundledCodexWithoutShellPATH() throws {
        let root = try TemporaryDirectory()
        let bin = root.url.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let binary = try root.script("exit 1", name: "bundled-codex")
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("codex"), withDestinationURL: binary)
        let found = HarnessDiscovery.find(path: "", home: root.url)
        XCTAssertTrue(found.contains { $0.kind == .codex && $0.executable == bin.appendingPathComponent("codex") })
    }

    func testDiscoveryWithoutShellPATHKeepsInstalledLauncher() throws {
        let root = try TemporaryDirectory()
        let locations: [(HarnessKind, String)] = [
            (.opencode, ".opencode/bin"), (.openclaw, ".openclaw/bin"), (.hermes, ".local/bin")
        ]
        for (kind, location) in locations {
            let bin = root.url.appendingPathComponent(location)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let binary = try root.script("exit 1", name: kind.rawValue + "-test")
            let launcher = bin.appendingPathComponent(kind.rawValue)
            try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: binary)
            let found = HarnessDiscovery.find(path: "", home: root.url)
            let candidates = HarnessDiscovery.replyLaunchers(in: found, keeping: launcher.path, kind: kind)
            XCTAssertTrue(found.contains(HarnessInstallation(kind: kind, executable: launcher)))
            XCTAssertEqual(candidates.first?.executable, launcher)
            XCTAssertEqual(candidates.filter { $0.executable == launcher }.count, 1)
        }
    }

    func testDeepSeekSetupLauncherRespectsPATHAndRestoresSavedAlias() throws {
        let root = try TemporaryDirectory()
        let versions = root.url.appendingPathComponent(".nvm/versions/node")
        func install(_ version: String) throws -> URL {
            let bin = versions.appendingPathComponent(version + "/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let target = try root.script("exit 1", name: version + ".js")
            let launcher = bin.appendingPathComponent("dsh")
            try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: target)
            return launcher
        }
        let older = try install("v20.9.0")
        let newer = try install("v20.12.0")
        func discover(_ path: String) -> [HarnessInstallation] {
            HarnessDiscovery.find(path: path, home: root.url)
                .filter { $0.executable.path.hasPrefix(root.url.path + "/") }
        }
        let nvm = discover("")
        XCTAssertEqual(nvm.map(\.executable), [newer, older])
        let viaPath = discover(older.deletingLastPathComponent().path)
        XCTAssertEqual(HarnessDiscovery.replyLaunchers(in: viaPath, keeping: nil).first?.executable, older)

        let alias = root.url.appendingPathComponent("dsh")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: newer)
        for saved in [alias, newer.resolvingSymlinksInPath()] {
            let matches = HarnessDiscovery.replyLaunchers(in: viaPath, keeping: saved.path)
            XCTAssertEqual(matches.map(\.executable), [saved, older])
        }
        try FileManager.default.removeItem(at: alias)
        XCTAssertEqual(HarnessDiscovery.replyLaunchers(in: viaPath, keeping: alias.path), viaPath)
    }
}
