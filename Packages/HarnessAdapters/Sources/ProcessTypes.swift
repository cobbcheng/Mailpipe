import Foundation
import MailpipeCore

public struct ProcessInvocation: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let stdin: Data
    public let workingDirectory: URL
    public let environment: [String: String]
    public let timeout: TimeInterval
    public let outputLimit: Int

    public init(executable: URL, arguments: [String], stdin: Data = Data(), workingDirectory: URL,
                environment: [String: String], timeout: TimeInterval = 10, outputLimit: Int = 1_048_576) {
        self.executable = executable; self.arguments = arguments; self.stdin = stdin
        self.workingDirectory = workingDirectory; self.environment = environment
        self.timeout = timeout; self.outputLimit = outputLimit
    }
}
public struct ProcessOutput: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
    public init(stdout: Data, stderr: Data = Data(), exitCode: Int32 = 0) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
    }
}
public protocol ProcessRunning: Sendable {
    func run(_ invocation: ProcessInvocation) async throws -> ProcessOutput
}

/// Only a cancellation bit crosses the task/worker boundary. All FDs and PIDs stay on the worker.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); defer { lock.unlock() }; value = true }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

public enum ProbeEnvironment {
    /// No inherited API keys, DYLD variables, hooks or caller-provided agent configuration.
    /// The CLI itself may read its normal auth storage. Mailpipe never reads those credentials.
    public static func minimal(from source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "LANG": "en_US.UTF-8"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] { result[key] = source[key] }
        return result
    }
}
