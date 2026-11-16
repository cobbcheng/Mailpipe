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
            let version = try await runner.run(ProcessInvocation(executable: executable, arguments: ["--version"],
                workingDirectory: directory, environment: environment, outputLimit: 16_384))
            guard version.exitCode == 0, let versionText = String(data: version.stdout, encoding: .utf8),
                  versionText.count <= 200,
                  versionText.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) != nil else {
                throw MailpipeError.unsupportedVersion
            }
            guard dialect.acceptsVersion(versionText.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw MailpipeError.unsupportedVersion }
            let help = try await runner.run(ProcessInvocation(executable: executable, arguments: dialect.helpArguments,
                workingDirectory: directory, environment: environment, outputLimit: 262_144))
            guard help.exitCode == 0 else { throw MailpipeError.unsupportedVersion }
            let text = String(decoding: help.stdout, as: UTF8.self)
            // Match complete option tokens, not prefixes such as --tools-extra.
            let tokens = Set(text.components(separatedBy: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",="))))
            return CapabilityReport(installation: HarnessInstallation(kind: dialect.kind, executable: executable),
                                    version: versionText.trimmingCharacters(in: .whitespacesAndNewlines),
                                    missingFlags: dialect.requiredFlags.filter { !tokens.contains($0) })
        }
    }

    /// Deliberately no caller-supplied prompt: only the checked-in synthetic fixture can run.
    /// The caller must explicitly start this probe; it can consume the user's model quota.
    public func runSyntheticProbe() async throws -> AdapterResult {
        let report = try await inspect()
        guard report.supportsSyntheticProbe else { throw MailpipeError.unsupportedVersion }
        return try await withWorkspace { directory in
            let environment = try dialect.prepare(directory: directory, executable: executable, environment: self.environment)
            let schema = directory.appendingPathComponent("response-schema.json")
            try Data(ClassificationSchema.json.utf8).write(to: schema, options: .atomic)
            let request = SyntheticFixture.request
            try request.validate()
            let requestData = try JSONEncoder().encode(request)
            let instruction = dialect.instruction
            var stdin = Data(instruction.utf8); stdin.append(requestData)
            let result = try await runner.run(ProcessInvocation(executable: executable, arguments: dialect.arguments(schemaFile: schema),
                stdin: stdin, workingDirectory: directory, environment: environment, timeout: 120))
            try Task.checkCancellation()
            guard result.exitCode == 0 else { throw classifyFailure(result.stderr + result.stdout) }
            return try dialect.decode(result.stdout, request: request)
        }
    }

    /// The method exists to make the mail boundary testable. No version is certified in this PR.
    public func classifyMail(_ request: ClassificationRequest, route: AccountRoute) async throws -> AdapterResult {
        try route.authorize(dialect.kind)
        try request.validate()
        throw MailpipeError.unsafeCapability
    }
}
