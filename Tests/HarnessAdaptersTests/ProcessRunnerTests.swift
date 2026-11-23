import XCTest
#if os(macOS)
import Darwin
@testable import HarnessAdapters
import MailpipeCore

@MainActor
final class ProcessRunnerTests: XCTestCase {
    func testLargeInputAndBothOutputsDoNotDeadlock() async throws {
        let root = try TemporaryDirectory()
        let file = try root.script("/usr/bin/head -c 200000 /dev/zero >&2\n/bin/cat")
        let input = Data(repeating: 65, count: 200_000)
        let output = try await POSIXProcessRunner().run(ProcessInvocation(executable: file, arguments: [], stdin: input,
            workingDirectory: root.url, environment: [:], timeout: 5))
        XCTAssertEqual(output.stdout, input); XCTAssertEqual(output.stderr.count, 200_000); XCTAssertEqual(output.exitCode, 0)
    }
    func testArgumentsAreLiteralAndInputDoesNotRunAsShell() async throws {
        let root = try TemporaryDirectory()
        let file = try root.script("/usr/bin/printf '%s' \"$1\"\n/bin/cat")
        let injection = "$(touch \(root.url.path)/should-not-exist); `echo bad`\n'\""
        let result = try await POSIXProcessRunner().run(ProcessInvocation(executable: file, arguments: [injection], stdin: Data(injection.utf8),
            workingDirectory: root.url, environment: [:]))
        XCTAssertEqual(result.stdout, Data((injection + injection).utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("should-not-exist").path))
    }
    func testOutputLimitStopsNoisyChild() async throws {
        let root = try TemporaryDirectory(), file = try root.script("exec /usr/bin/yes noisy")
        do {
            _ = try await POSIXProcessRunner().run(ProcessInvocation(executable: file, arguments: [], workingDirectory: root.url,
                environment: [:], timeout: 5, outputLimit: 1_024))
            XCTFail("must stop")
        } catch { XCTAssertEqual(error as? MailpipeError, .outputLimit) }
    }
    func testTimeoutKillsProcessGroup() async throws {
        let root = try TemporaryDirectory()
        let file = try root.script("/bin/sleep 30 &\necho $! > child.pid\nwait")
        do {
            _ = try await POSIXProcessRunner().run(ProcessInvocation(executable: file, arguments: [], workingDirectory: root.url,
                environment: [:], timeout: 1.5))
            XCTFail("must time out")
        } catch { XCTAssertEqual(error as? MailpipeError, .timedOut) }
        try await assertChildStopped(root)
    }
    func testCancellationKillsProcessGroup() async throws {
        let root = try TemporaryDirectory()
        let file = try root.script("/bin/sleep 30 &\necho $! > child.pid\nwait")
        let task = Task { try await POSIXProcessRunner().run(ProcessInvocation(executable: file, arguments: [],
            workingDirectory: root.url, environment: [:], timeout: 10)) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.url.appendingPathComponent("child.pid").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("must cancel") }
        catch { XCTAssertTrue(error is CancellationError || error as? MailpipeError == .cancelled) }
        try await assertChildStopped(root)
    }
    private func assertChildStopped(_ root: TemporaryDirectory) async throws {
        let text = try String(contentsOf: root.url.appendingPathComponent("child.pid"), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<100 {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("child must not survive termination")
    }
    func testSpawnFailureAndNonZeroExit() async throws {
        let root = try TemporaryDirectory()
        do {
            _ = try await POSIXProcessRunner().run(ProcessInvocation(executable: root.url.appendingPathComponent("absent"), arguments: [],
                workingDirectory: root.url, environment: [:]))
            XCTFail("missing")
        } catch { XCTAssertEqual(error as? MailpipeError, .notInstalled) }
        let file = try root.script("echo diagnostic >&2\nexit 7")
        let output = try await POSIXProcessRunner().run(ProcessInvocation(executable: file, arguments: [], workingDirectory: root.url, environment: [:]))
        XCTAssertEqual(output.exitCode, 7); XCTAssertTrue(String(decoding: output.stderr, as: UTF8.self).contains("diagnostic"))
    }
    func testCodexInspectAgainstFakeExecutable() async throws {
        let root = try TemporaryDirectory(), dialect = CodexCLIDialect()
        let file = try root.script("""
        case "$*" in
          --version) echo 'codex-cli 0.169.1'; exit 0;;
          *--help*) echo '\(dialect.requiredFlags.joined(separator: " "))'; exit 0;;
        esac
        exit 1
        """)
        let adapter = CodexCLIAdapter(executable: file, dialect: dialect, temporaryRoot: root.url, environment: [:])
        let report = try await adapter.inspect()
        XCTAssertEqual(report.version, "codex-cli 0.169.1")
        XCTAssertTrue(report.supportsHeadlessRun)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.url.path), ["fake harness"])
    }
    func testCodexDraftHidesGlobalInstructionsAndUsesTheSelectedLauncher() async throws {
        let root = try TemporaryDirectory(), dialect = CodexCLIDialect()
        let instructions = root.url.appendingPathComponent("agents.md")
        let target = root.url.appendingPathComponent("private-instruction.txt")
        try Data("private instructions".utf8).write(to: instructions)
        try Data("symlink target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.url.appendingPathComponent("AGENTS.override.md"), withDestinationURL: target)
        let file = try root.script("""
        set -eu
        test ! -e "$HOME/agents.md"
        test ! -e "$HOME/AGENTS.override.md"
        test -r "$HOME/private-instruction.txt"
        /bin/cat
        """)
        let input = Data("synthetic mail".utf8)
        let invocation = try dialect.replyInvocation(task: .triage(ReplySyntheticFixture.triage), schema: ReplySchemas.triage,
            stdin: input, directory: root.url, executable: file, environment: ["HOME": root.url.path])
        XCTAssertTrue(invocation.arguments.contains("skills.include_instructions=false"))
        let result = try await POSIXProcessRunner().run(invocation)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, input)
        XCTAssertTrue(dialect.acceptsVersion("codex-cli 0.171.0-alpha.13"))
        XCTAssertFalse(dialect.acceptsVersion("codex-cli 0.171.0-alpha.14"))
    }
    func testDeepSeekAdapterAgainstFakeExecutable() async throws {
        let root = try TemporaryDirectory(), dialect = DeepSeekHarnessDialect()
        let response = String(decoding: try deepseekEvents(ReplySyntheticFixture.decision), as: UTF8.self)
        let file = try root.script("""
        case "$*" in
          --version) echo '0.2.2-rc.1'; exit 0;;
          *--help*) echo '\(dialect.requiredFlags.joined(separator: " "))'; exit 0;;
        esac
        /bin/cat >/dev/null
        /bin/cat <<'MAILPIPE_SYNTHETIC_OUTPUT'
        \(response)
        MAILPIPE_SYNTHETIC_OUTPUT
        """)
        let adapter = DeepSeekHarnessAdapter(executable: file, dialect: dialect, temporaryRoot: root.url, environment: [:])
        let output = try await adapter.run(.triage(ReplySyntheticFixture.triage),
                                           route: AccountRoute(accountID: "synthetic", allowedHarnesses: [.deepseek])) {}
        XCTAssertEqual(try ReplyDecision.validated(output.content, for: ReplySyntheticFixture.triage).shouldReply, .yes)
        XCTAssertEqual(output.inputTokens, 12)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.url.path), ["fake harness"])
    }
}
#endif
