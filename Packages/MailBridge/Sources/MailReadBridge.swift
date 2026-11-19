import Foundation
import HarnessAdapters
import MailpipeCore
#if os(macOS)
import Darwin
#endif

private struct MailReadQuery: Codable, Sendable {
    let accountID: String
    let mailboxName: String
    let messageID: String
    let subject: String
    var firstMatch: Bool? = nil
    let mailboxPath: [String]?
}

private enum MailReadRequest: Codable, Sendable {
    case resolve(MailReadQuery)
    case membership(MailReadQuery)
    case inboxes
}

enum MailReadResponse: Codable, Sendable {
    case match(AppleMailReplyIdentity.Match?)
    case membership(Bool?)
    case inboxes([AppleMailReplyIdentity.MailboxChoice])
    case error(IdentityQueryError)
    case messageTooLarge
}

/// Each read runs on the main thread of a short-lived copy of the signed host.
/// The host retains ownership of authorization, record updates and Mail writes.
public actor MailReadBridge {
    public static let shared = MailReadBridge(executable: Bundle.main.executableURL)
    private static let flag = "--mailpipe-read-helper"
    private static let requestLimit = 256 * 1024
    // A binary plist may encode the entire source as UTF-16.
    private static let responseLimit = MailBodyLimits.rawCeiling * 2 + 256 * 1024
    private let executable: URL?
    private let runner: any ProcessRunning
    private var occupied = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(executable: URL?, runner: any ProcessRunning = POSIXProcessRunner()) {
        self.executable = executable
        self.runner = runner
    }

    var queuedReadCount: Int { waiters.count }

    public func resolve(accountID: String, mailboxName: String, messageID: String, subject: String,
                        mailboxPath: [String]? = nil, firstMatch: Bool = false,
                        preflight: @escaping @MainActor @Sendable () throws -> Void) async throws -> AppleMailReplyIdentity.Match? {
        let query = MailReadQuery(accountID: accountID, mailboxName: mailboxName, messageID: messageID,
                                  subject: subject, firstMatch: firstMatch, mailboxPath: mailboxPath)
        guard case let .match(match) = try await call(.resolve(query), preflight: preflight) else { throw IdentityQueryError.invalidResult }
        return match
    }

    public func isInAuthorizedInbox(accountID: String, mailboxName: String, messageID: String, subject: String,
                                    mailboxPath: [String]? = nil,
                                    preflight: @escaping @MainActor @Sendable () throws -> Void) async throws -> Bool? {
        let query = MailReadQuery(accountID: accountID, mailboxName: mailboxName, messageID: messageID,
                                  subject: subject, mailboxPath: mailboxPath)
        guard case let .membership(included) = try await call(.membership(query), preflight: preflight) else { throw IdentityQueryError.invalidResult }
        return included
    }

    public func inboxes() async throws -> [AppleMailReplyIdentity.MailboxChoice] {
        guard case let .inboxes(choices) = try await call(.inboxes) else { throw IdentityQueryError.invalidResult }
        return choices
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !occupied { occupied = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelQueuedRead(id) }
        }
    }

    private func cancelQueuedRead(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().continuation.resume() }
    }

    private func call(_ request: MailReadRequest,
                      preflight: (@MainActor @Sendable () throws -> Void)? = nil) async throws -> MailReadResponse {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard let executable else { throw IdentityQueryError.invalidResult }
        let input = try PropertyListEncoder().encode(request)
        guard input.count <= Self.requestLimit else { throw IdentityQueryError.invalidScope }
        let invocation = ProcessInvocation(executable: executable, arguments: [Self.flag], stdin: input,
                                           workingDirectory: URL(fileURLWithPath: "/", isDirectory: true),
                                           environment: ProbeEnvironment.minimal(), timeout: 35,
                                           outputLimit: Self.responseLimit)
        // A read could wait behind another helper while the user changes account permissions.
        if let preflight { try await preflight() }
        try Task.checkCancellation()
        let output: ProcessOutput
        do { output = try await runner.run(invocation) }
        catch {
            try Task.checkCancellation()
            if error as? MailpipeError == .timedOut { throw IdentityQueryError.automation(-1712) }
            throw IdentityQueryError.invalidResult
        }
        try Task.checkCancellation()
        // stderr may contain private Apple Event diagnostics. Never surface or persist it.
        guard output.exitCode == 0,
              let response = try? PropertyListDecoder().decode(MailReadResponse.self, from: output.stdout) else {
            throw IdentityQueryError.invalidResult
        }
        switch response {
        case let .error(error): throw error
        case .messageTooLarge: throw MailBodyRejection.messageTooLarge
        default: return response
        }
    }

    /// Handle the private child before constructing SwiftUI, the pipeline or any windows.
    /// Return true even for a rejected helper invocation, so it cannot start the app.
    @MainActor public static func runHelperIfRequested() -> Bool {
        let arguments = CommandLine.arguments.dropFirst()
        guard arguments.contains(flag) else { return false }
#if os(macOS)
        guard arguments.elementsEqual([flag]), isChildOfSameExecutable else { return true }
        do {
            let input = FileHandle.standardInput
            var data = Data()
            while let chunk = try input.read(upToCount: 32_768), !chunk.isEmpty {
                guard data.count + chunk.count <= requestLimit else { return true }
                data.append(chunk)
            }
            let request = try PropertyListDecoder().decode(MailReadRequest.self, from: data)
            let encoded = try PropertyListEncoder().encode(perform(request))
            guard encoded.count <= responseLimit else { return true }
            try FileHandle.standardOutput.write(contentsOf: encoded)
        } catch { /* The caller treats a missing or incomplete reply as unavailable. */ }
#endif
        return true
    }

#if os(macOS)
    private static var isChildOfSameExecutable: Bool {
        func executablePath(_ pid: pid_t) -> String? {
            var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let count = proc_pidpath(pid, &bytes, UInt32(bytes.count))
            guard count > 0 else { return nil }
            return String(bytes: bytes.prefix(Int(count)), encoding: .utf8)
        }
        guard let parent = executablePath(getppid()), let child = executablePath(getpid()) else { return false }
        return parent == child
    }

    @MainActor private static func perform(_ request: MailReadRequest) -> MailReadResponse {
        do {
            switch request {
            case let .resolve(query):
                return .match(try AppleMailReplyIdentity.resolve(accountID: query.accountID, mailboxName: query.mailboxName,
                    messageID: query.messageID, subject: query.subject, mailboxPath: query.mailboxPath, firstMatch: query.firstMatch == true))
            case let .membership(query):
                return .membership(try AppleMailReplyIdentity.isInAuthorizedInbox(accountID: query.accountID, mailboxName: query.mailboxName,
                    messageID: query.messageID, subject: query.subject, mailboxPath: query.mailboxPath))
            case .inboxes:
                return .inboxes(try AppleMailReplyIdentity.inboxes())
            }
        } catch let error as IdentityQueryError { return .error(error) }
        catch MailBodyRejection.messageTooLarge { return .messageTooLarge }
        catch { return .error(.invalidResult) }
    }
#endif
}
