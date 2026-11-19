import Foundation
import MailpipeCore

public struct CLIAdapter<Dialect: HarnessDialect>: Sendable {
    public let executable: URL
    public let dialect: Dialect
    private let runner: any ProcessRunning
    private let temporaryRoot: URL
    private let environment: [String: String]

    public init(executable: URL, dialect: Dialect, runner: any ProcessRunning = POSIXProcessRunner(),
                temporaryRoot: URL = FileManager.default.temporaryDirectory,
                environment: [String: String] = ProbeEnvironment.minimal()) {
        self.executable = executable; self.dialect = dialect; self.runner = runner
        self.temporaryRoot = temporaryRoot; self.environment = environment
    }

    private func withWorkspace<T: Sendable>(_ operation: (URL) async throws -> T) async throws -> T {
        let directory = temporaryRoot.appendingPathComponent("mailpipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await operation(directory)
    }

    public func inspect() async throws -> CapabilityReport {
        try await withWorkspace { directory in
            let environment = try dialect.prepare(directory: directory, executable: executable, environment: self.environment)
            let version = try await runner.run(dialect.probeInvocation(executable: executable, arguments: ["--version"],
                directory: directory, environment: environment, outputLimit: 16_384))
            guard version.exitCode == 0, let versionText = String(data: version.stdout, encoding: .utf8),
                  versionText.count <= 200,
                  versionText.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) != nil else {
                throw MailpipeError.unsupportedVersion
            }
            guard dialect.acceptsVersion(versionText.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw MailpipeError.unsupportedVersion }
            let help = try await runner.run(dialect.probeInvocation(executable: executable, arguments: dialect.helpArguments,
                directory: directory, environment: environment, outputLimit: 262_144))
            guard help.exitCode == 0 else { throw MailpipeError.unsupportedVersion }
            let text = String(decoding: help.stdout, as: UTF8.self)
            // Match complete option tokens, not prefixes such as --tools-extra.
            let tokens = Set(text.components(separatedBy: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",="))))
            return CapabilityReport(installation: HarnessInstallation(kind: dialect.kind, executable: executable),
                                    version: versionText.trimmingCharacters(in: .whitespacesAndNewlines),
                                    missingFlags: dialect.requiredFlags.filter { !tokens.contains($0) })
        }
    }

}

public enum ReplyModelTask: Sendable {
    case triage(ReplyTriageRequest)
    case draft(ReplyDraftRequest)
}
public struct ReplyModelOutput: Sendable {
    public let content: Data
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let inputCharacters: Int
    public let outputCharacters: Int
    public let actualModel: String?
    public let readPullRequestDiff: Bool?
    public init(content: Data, inputTokens: Int? = nil, outputTokens: Int? = nil, inputCharacters: Int = 0, outputCharacters: Int = 0, readPullRequestDiff: Bool? = nil, actualModel: String? = nil) {
        self.actualModel = actualModel
        self.readPullRequestDiff = readPullRequestDiff
        self.content = content; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.inputCharacters = inputCharacters; self.outputCharacters = outputCharacters
    }
}
public protocol ReplyModelRunning: Sendable {
    func run(_ task: ReplyModelTask, route: AccountRoute,
             authorize: @escaping @Sendable () async throws -> Void) async throws -> ReplyModelOutput
}

public protocol ReplyHarnessDialect: HarnessDialect {
    func runFailure(_ result: ProcessOutput) -> MailpipeError
    func replyInvocation(task: ReplyModelTask, schema: String, stdin: Data, directory: URL,
                         executable: URL, environment: [String: String]) throws -> ProcessInvocation
    func replyOutput(_ stdout: Data, task: ReplyModelTask, inputCharacters: Int, directory: URL) throws -> ReplyModelOutput
}

public extension ReplyHarnessDialect {
    func runFailure(_ result: ProcessOutput) -> MailpipeError {
        classifyFailure(result.stderr + result.stdout)
    }
}

extension CLIAdapter: ReplyModelRunning where Dialect: ReplyHarnessDialect {
    /// Typed reply tasks with per-message read capabilities. The host owns live authorization and durable runs.
    public func run(_ task: ReplyModelTask, route: AccountRoute,
                    authorize: @escaping @Sendable () async throws -> Void) async throws -> ReplyModelOutput {
        try route.authorize(dialect.kind)
        let payload: Data, schema: String
        switch task {
        case .triage(let request): try request.validate(); payload = try JSONEncoder().encode(request); schema = ReplySchemas.triage
        case .draft(let request): try request.validate(); payload = try JSONEncoder().encode(request); schema = ReplySchemas.draft
        }
        let capability = try await inspect()
        guard capability.supportsHeadlessRun else { throw MailpipeError.unsupportedVersion }
        return try await withWorkspace { directory in
            let environment = try dialect.prepare(directory: directory, executable: executable, environment: self.environment)
            // Policy is loaded from the bundled Markdown into the system role.
            // Only the output contract and the untrusted task payload belong on stdin.
            let stdin = try JSONSerialization.data(withJSONObject: [
                "output_schema": try JSONSerialization.jsonObject(with: Data(schema.utf8)),
                "request": try JSONSerialization.jsonObject(with: payload)
            ])
            let invocation = try dialect.replyInvocation(task: task, schema: schema, stdin: stdin, directory: directory,
                                                         executable: executable, environment: environment)
            try await authorize()
            try Task.checkCancellation()
            let result = try await runner.run(invocation)
            try Task.checkCancellation()
            guard result.exitCode == 0 else { throw dialect.runFailure(result) }
            return try dialect.replyOutput(result.stdout, task: task, inputCharacters: String(decoding: invocation.stdin, as: UTF8.self).count, directory: directory)
        }
    }
}
