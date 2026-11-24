import Foundation
import MailpipeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Caches successful CLI capability probes keyed by executable identity (resolved path, inode,
/// size, and modification timestamp) so repeated drafts avoid spawning --version and --help.
actor InspectionCache {
    static let shared = InspectionCache()

    struct Key: Hashable, Sendable {
        let kind: HarnessKind
        let resolvedPath: String
        let inode: UInt64
        let size: Int64
        let mtimeSec: Int
        let mtimeNsec: Int

        static func fingerprint(kind: HarnessKind, executable: URL) -> Key? {
            let resolved = executable.resolvingSymlinksInPath().path
            var info = stat()
            guard stat(resolved, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
#if canImport(Darwin)
            let sec = info.st_mtimespec.tv_sec
            let nsec = info.st_mtimespec.tv_nsec
#else
            let sec = info.st_mtim.tv_sec
            let nsec = info.st_mtim.tv_nsec
#endif
            return Key(kind: kind, resolvedPath: resolved, inode: UInt64(info.st_ino),
                       size: Int64(info.st_size), mtimeSec: sec, mtimeNsec: nsec)
        }
    }

    private var reports: [Key: CapabilityReport] = [:]

    func get(_ key: Key) -> CapabilityReport? {
        reports[key]
    }

    func set(_ report: CapabilityReport, for key: Key) {
        if reports.count >= 64 { reports.removeAll(keepingCapacity: true) }
        reports[key] = report
    }

    func reset() {
        reports.removeAll()
    }
}

public struct CLIAdapter<Dialect: HarnessDialect>: Sendable {
    public let executable: URL
    public let dialect: Dialect
    private let runner: any ProcessRunning
    private let temporaryRoot: URL
    private let environment: [String: String]
    private let cache: InspectionCache?

    public init(executable: URL, dialect: Dialect, runner: any ProcessRunning = POSIXProcessRunner(),
                temporaryRoot: URL = FileManager.default.temporaryDirectory,
                environment: [String: String] = ProbeEnvironment.minimal()) {
        self.init(executable: executable, dialect: dialect, runner: runner, temporaryRoot: temporaryRoot,
                  environment: environment, cache: .shared)
    }

    init(executable: URL, dialect: Dialect, runner: any ProcessRunning,
         temporaryRoot: URL, environment: [String: String], cache: InspectionCache?) {
        self.executable = executable; self.dialect = dialect; self.runner = runner
        self.temporaryRoot = temporaryRoot; self.environment = environment; self.cache = cache
    }

    private func withWorkspace<T: Sendable>(_ operation: (URL) async throws -> T) async throws -> T {
        let directory = temporaryRoot.appendingPathComponent("mailpipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await operation(directory)
    }

    public func inspect(bypassCache: Bool = false) async throws -> CapabilityReport {
        let cacheKey = !bypassCache ? InspectionCache.Key.fingerprint(kind: dialect.kind, executable: executable) : nil
        if let cacheKey, let cache, let cached = await cache.get(cacheKey) {
            return cached
        }
        let report: CapabilityReport = try await withWorkspace { directory in
            let environment = try dialect.prepare(directory: directory, executable: executable, environment: self.environment)
            let version = try await runner.run(dialect.probeInvocation(executable: executable, arguments: ["--version"],
                directory: directory, environment: environment, outputLimit: 16_384))
            guard version.exitCode == 0, let versionText = String(data: version.stdout, encoding: .utf8),
                  versionText.count <= 200,
                  let number = versionText.range(of: #"[0-9]+\.[0-9]+\.[0-9]+(?:-(?:alpha|beta|rc)[.-]?[0-9]+)?"#, options: .regularExpression) else {
                throw MailpipeError.unsupportedVersion
            }
            let installation = HarnessInstallation(kind: dialect.kind, executable: executable)
            let banner = versionText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard dialect.acceptsVersion(banner) else {
                // Report only the version number from an unrecognized launcher's output.
                return CapabilityReport(installation: installation, version: String(versionText[number]),
                                        versionSupported: false, missingFlags: [])
            }
            let help = try await runner.run(dialect.probeInvocation(executable: executable, arguments: dialect.helpArguments,
                directory: directory, environment: environment, outputLimit: 262_144))
            guard help.exitCode == 0 else { throw MailpipeError.unsupportedVersion }
            let text = String(decoding: help.stdout, as: UTF8.self)
            // Match complete option tokens, not prefixes such as --tools-extra.
            let tokens = Set(text.components(separatedBy: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",="))))
            return CapabilityReport(installation: installation, version: banner, versionSupported: true,
                                    missingFlags: dialect.requiredFlags.filter { !tokens.contains($0) })
        }
        if let cacheKey, let cache, report.supportsHeadlessRun {
            await cache.set(report, for: cacheKey)
        }
        return report
    }

}

public enum ReplyModelTask: Sendable {
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
    func supports(_ context: DraftExternalContext) -> Bool
    func runFailure(_ result: ProcessOutput) -> MailpipeError
    func replyInvocation(task: ReplyModelTask, schema: String, stdin: Data, directory: URL,
                         executable: URL, environment: [String: String]) throws -> ProcessInvocation
    func replyOutput(_ stdout: Data, task: ReplyModelTask, inputCharacters: Int, directory: URL) throws -> ReplyModelOutput
}

public extension ReplyHarnessDialect {
    func supports(_ context: DraftExternalContext) -> Bool { false }
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
        case .draft(let request):
            try request.validate()
            if let context = request.externalContext, !dialect.supports(context) {
                throw MailpipeError.unsafeCapability
            }
            payload = try JSONEncoder().encode(request)
            schema = request.allowsNoReply ? ReplySchemas.automaticDraft : ReplySchemas.draft
        }
        let capability = try await inspect()
        guard capability.supportsHeadlessRun else { throw MailpipeError.unsupportedVersion }
        return try await withWorkspace { directory in
            let environment = try dialect.prepare(directory: directory, executable: executable, environment: self.environment)
            // Policy is loaded from the bundled Markdown into the system role.
            // Stdin carries the output contract and task data, including any user writing preferences.
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
