import Foundation
import MailpipeCore
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public typealias OpenCodeHarnessAdapter = CLIAdapter<OpenCodeDialect>

public struct OpenCodeDialect: ReplyHarnessDialect {
    private let model: String?
    /// Only the fixed connection-test fixture may use the private profile's default.
    public init(model: String? = nil) { self.model = model }
    public var kind: HarnessKind { .opencode }
    public var helpArguments: [String] { ["run", "--help"] }
    public var requiredFlags: [String] { ["--standalone", "--format", "--agent", "--title", "--log-level", "--model"] }
    public func acceptsVersion(_ version: String) -> Bool {
        SemVer.matchesBanner(version, pattern: #"^opencode v([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)$"#,
                             minimum: SemVer(major: 2, minor: 3, patch: 0), major: 2)
    }

    public func replyInvocation(task: ReplyModelTask, schema: String, stdin: Data, directory: URL,
                                executable: URL, environment: [String: String]) throws -> ProcessInvocation {
        if case .draft(let request) = task, let context = request.externalContext, !supports(context) {
            throw MailpipeError.unsafeCapability
        }
        if let model {
            guard Self.validModelReference(model) else { throw MailpipeError.invalidInput }
        } else {
            let message: MailInput
            switch task {
            case .draft(let request): message = request.message
            }
            let fixture = ReplySyntheticFixture.message
            guard message.subject == fixture.subject, message.body == fixture.body else { throw MailpipeError.routeNotAllowed }
        }
        let restricted = try OpenCodeProfile.prepare(directory: directory, executable: executable, environment: environment)
        // A fixed title suppresses the background model call used to name new sessions.
        var arguments = ["run", "--standalone", "--agent", "mailpipe", "--title", "Mailpipe",
                         "--format", "json", "--log-level", "none"]
        if let model { arguments += ["--model", model] }
        return ProcessInvocation(executable: executable, arguments: arguments, stdin: stdin, workingDirectory: directory,
                                 environment: restricted, timeout: 120)
    }

    public static func validModelReference(_ value: String) -> Bool {
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy({ !$0.isEmpty }) && value.utf8.count <= 256 &&
            !value.contains("#") && value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
    }

    public func replyOutput(_ stdout: Data, task: ReplyModelTask, inputCharacters: Int, directory: URL) throws -> ReplyModelOutput {
        var session: String?, message: String?, usage: OpenCodeUsage?
        var text = ""
        for line in stdout.split(separator: 10) {
            guard let event = try? JSONDecoder().decode(OpenCodeEvent.self, from: Data(line)) else {
                throw MailpipeError.invalidOutput
            }
            if event.type == "error" { throw classifyFailure(Data(line)) }
            guard usage == nil, let part = event.part, !event.sessionID.isEmpty, part.sessionID == event.sessionID,
                  !part.messageID.isEmpty, session == nil || session == part.sessionID,
                  message == nil || message == part.messageID else { throw MailpipeError.invalidOutput }
            switch (event.type, part.type) {
            case ("step_start", "step-start"):
                guard session == nil else { throw MailpipeError.invalidOutput }
                session = part.sessionID; message = part.messageID
            case ("text", "text"):
                guard session != nil, let fragment = part.text else { throw MailpipeError.invalidOutput }
                text += fragment
            case ("step_finish", "step-finish"):
                guard session != nil, part.reason == "stop", let tokens = part.tokens else { throw MailpipeError.invalidOutput }
                usage = tokens
            default: throw MailpipeError.unsafeCapability
            }
        }
        guard let session, let message, let usage, !text.isEmpty else { throw MailpipeError.invalidOutput }
        // 2.3.0 omits the model in run --format json. Read just this assistant's
        // receipt in the disposable database before CLIAdapter removes it.
        let actual = try modelReceipt(directory: directory, session: session, message: message)
        guard model == nil || model == actual else { throw MailpipeError.routeNotAllowed }
        return try ReplyModelOutput(content: Data(text.utf8), inputTokens: usage.sum([usage.input, usage.cache.read, usage.cache.write]),
            outputTokens: usage.sum([usage.output, usage.reasoning]), inputCharacters: inputCharacters,
            outputCharacters: text.count, actualModel: actual)
    }

    private func modelReceipt(directory: URL, session: String, message: String) throws -> String {
        // macOS Foundation can preserve the /var alias after resolving symlinks.
        // SQLite NOFOLLOW needs its physical parent path and must still reject a linked database.
        guard let parent = realpath(directory.path, nil) else { throw MailpipeError.invalidOutput }
        defer { free(parent) }
        let path = String(cString: parent) + "/opencode.db"
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            throw MailpipeError.invalidOutput
        }
        let query = """
            SELECT json_extract(data, '$.model.providerID') || '/' || json_extract(data, '$.model.id') FROM session_message
            WHERE session_id = ? AND id = ? AND type = 'assistant' AND json_extract(data, '$.agent') = 'mailpipe'
            AND json_extract(data, '$.finish') = 'stop'
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              sqlite3_bind_text(statement, 1, session, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 2, message, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_TEXT,
              let value = sqlite3_column_text(statement, 0) else { throw MailpipeError.invalidOutput }
        let model = String(cString: value)
        guard Self.validModelReference(model) else { throw MailpipeError.invalidOutput }
        return model
    }
}

private struct OpenCodeEvent: Decodable {
    let type: String
    let sessionID: String
    let part: Part?
    struct Part: Decodable {
        let type: String
        let sessionID: String
        let messageID: String
        let reason: String?
        let text: String?
        let tokens: OpenCodeUsage?
    }
}

private struct OpenCodeUsage: Decodable {
    let input, output, reasoning: Int
    let cache: Cache
    struct Cache: Decodable { let read, write: Int }

    func sum(_ counts: [Int]) throws -> Int {
        try counts.reduce(0) { total, next in
            let (sum, overflow) = total.addingReportingOverflow(next)
            guard next >= 0, !overflow else { throw MailpipeError.invalidOutput }
            return sum
        }
    }
}
