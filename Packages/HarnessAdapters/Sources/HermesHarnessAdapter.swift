import Foundation
import MailpipeCore

public typealias HermesHarnessAdapter = CLIAdapter<HermesDialect>

public struct HermesDialect: ReplyHarnessDialect {
    public init() {}
    public var kind: HarnessKind { .hermes }
    public var helpArguments: [String] { ["--help"] }
    public var requiredFlags: [String] {
        ["enabled_toolsets", "skip_context_files", "skip_memory", "skip_background_review"]
    }
    public func acceptsVersion(_ version: String) -> Bool { version == "Hermes Agent 0.23.2" }

    public func prepare(directory: URL, executable: URL, environment: [String: String]) throws -> [String: String] {
        guard let home = environment["HOME"], home.hasPrefix("/") else { throw MailpipeError.authRequired }
        let files = FileManager.default
        let runHome = directory.appendingPathComponent("home", isDirectory: true)
        let authProfile = directory.appendingPathComponent("auth", isDirectory: true)
        for folder in [runHome, authProfile] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // Hermes reads its own dotenv through a profile-secret scope. The rest of
        // the user's profile (config, hooks, plugins and sessions) stays out of the run.
        try files.createSymbolicLink(at: authProfile.appendingPathComponent(".env"),
            withDestinationURL: URL(fileURLWithPath: home).appendingPathComponent(".hermes/.env"))
        return ["HOME": runHome.path, "HERMES_HOME": runHome.appendingPathComponent(".hermes").path,
                "MAILPIPE_HERMES_AUTH_PROFILE": authProfile.path, "HERMES_SAFE_MODE": "1",
                "HERMES_IGNORE_RULES": "1", "HERMES_IGNORE_USER_CONFIG": "1", "HERMES_SINGLE_QUERY_SESSION": "1",
                "TMPDIR": directory.path, "PATH": environment["PATH"] ?? "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
    }

    private func runtimeArguments(_ arguments: [String]) throws -> [String] {
        guard let script = Bundle.module.url(forResource: "hermes-draft", withExtension: "py", subdirectory: "Resources")
            else { throw MailpipeError.unsafeCapability }
        // The official source and macOS launchers bind --run-module to their own
        // managed interpreter. cProfile can run an absolute script in that runtime.
        return ["--run-module", "cProfile", "-o", "/dev/null", script.path] + arguments
    }

    public func probeInvocation(executable: URL, arguments: [String], directory: URL, environment: [String: String],
                                outputLimit: Int) throws -> ProcessInvocation {
        try ProcessInvocation(executable: executable, arguments: runtimeArguments(arguments), workingDirectory: directory,
                              environment: environment, timeout: 30, outputLimit: outputLimit)
    }

    public func replyInvocation(task: ReplyModelTask, schema: String, stdin: Data, directory: URL,
                                executable: URL, environment: [String: String]) throws -> ProcessInvocation {
        if case .draft(let request) = task, request.approvedPullRequest != nil { throw MailpipeError.unsafeCapability }
        return try ProcessInvocation(executable: executable, arguments: runtimeArguments([]), stdin: stdin,
                                     workingDirectory: directory, environment: environment, timeout: 120)
    }

    public func runFailure(_ result: ProcessOutput) -> MailpipeError {
        switch result.exitCode {
        case 2: .unsafeCapability
        case 3: .authRequired
        case 4: .quotaExhausted
        case 5: .rateLimited
        case 6: .timedOut
        case 7: .invalidOutput
        default: .processFailed
        }
    }

    public func replyOutput(_ stdout: Data, task: ReplyModelTask, inputCharacters: Int, directory: URL) throws -> ReplyModelOutput {
        struct Receipt: Decodable {
            let model, content: String
            let inputTokens, outputTokens, calls: Int
        }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: stdout),
              receipt.calls == 1, receipt.inputTokens >= 0, receipt.outputTokens >= 0,
              !receipt.content.isEmpty, receipt.model == "deepseek-flash"
            else { throw MailpipeError.invalidOutput }
        return ReplyModelOutput(content: Data(receipt.content.utf8), inputTokens: receipt.inputTokens,
                                outputTokens: receipt.outputTokens, inputCharacters: inputCharacters,
                                outputCharacters: receipt.content.count, actualModel: receipt.model)
    }
}
