import Foundation
import Darwin
import MailpipeCore

/// A dedicated process group, bounded nonblocking pipes, and one worker per call.
/// This manages process lifetime; it is NOT a security sandbox.
public struct POSIXProcessRunner: ProcessRunning {
    public init() {}
    public func run(_ invocation: ProcessInvocation) async throws -> ProcessOutput {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try Self.execute(invocation, flag: flag) })
                }
            }
        } onCancel: { flag.cancel() }
    }

    private static func execute(_ spec: ProcessInvocation, flag: CancellationFlag) throws -> ProcessOutput {
        guard spec.executable.isFileURL, spec.executable.path.hasPrefix("/"),
              spec.workingDirectory.isFileURL, spec.timeout.isFinite, spec.timeout > 0,
              spec.outputLimit > 0, spec.stdin.count <= 262_144,
              ([spec.executable.path, spec.workingDirectory.path] + spec.arguments +
                spec.environment.map { "\($0.key)=\($0.value)" }).allSatisfy({ !$0.contains("\0") }),
              spec.environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") }) else {
            throw MailpipeError.invalidInput
        }
        guard !flag.cancelled else { throw MailpipeError.cancelled }
        guard FileManager.default.isExecutableFile(atPath: spec.executable.path) else { throw MailpipeError.notInstalled }

        var descriptors: [Int32] = []
        func makePipe() throws -> [Int32] {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { throw MailpipeError.launchFailed }
            descriptors += fds
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            return fds
        }
        defer { for fd in descriptors where fd >= 0 { close(fd) } }
        let input = try makePipe(), output = try makePipe(), errors = try makePipe()
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw MailpipeError.launchFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw MailpipeError.launchFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        func checked(_ status: Int32) throws {
            guard status == 0 else { throw MailpipeError.launchFailed }
        }
        try checked(posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO))
        for fd in descriptors { try checked(posix_spawn_file_actions_addclose(&actions, fd)) }
        try checked(posix_spawn_file_actions_addchdir_np(&actions, spec.workingDirectory.path))
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
        try checked(posix_spawnattr_setpgroup(&attributes, 0))

        let argv = ([spec.executable.path] + spec.arguments).map { strdup($0) } + [nil]
        let envp = spec.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawnStatus = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, spec.executable.path, &actions, &attributes,
                            UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        try checked(spawnStatus)
        var reaped = false
        defer {
            // Also remove descendants that outlived a successfully exited parent.
            kill(-pid, SIGKILL)
            if !reaped {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            }
        }
        func closeOwned(_ fd: Int32) {
            if let i = descriptors.firstIndex(of: fd) { close(fd); descriptors[i] = -1 }
        }
        closeOwned(input[0]); closeOwned(output[1]); closeOwned(errors[1])
        for fd in [input[1], output[0], errors[0]] {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { throw MailpipeError.launchFailed }
        }
        guard fcntl(input[1], F_SETNOSIGPIPE, 1) != -1 else { throw MailpipeError.launchFailed }
        var inputOpen = true, outputOpen = true, errorOpen = true
        var offset = 0, stdout = Data(), stderr = Data(), status: Int32 = 0
        let start = ProcessInfo.processInfo.systemUptime
        var buffer = [UInt8](repeating: 0, count: 8192)
        while !reaped || outputOpen || errorOpen {
            if flag.cancelled { throw MailpipeError.cancelled }
            if ProcessInfo.processInfo.systemUptime - start >= spec.timeout { throw MailpipeError.timedOut }
            if inputOpen {
                if offset == spec.stdin.count { closeOwned(input[1]); inputOpen = false }
                else {
                    let count = spec.stdin.withUnsafeBytes { bytes in
                        write(input[1], bytes.baseAddress!.advanced(by: offset), min(8192, spec.stdin.count - offset))
                    }
                    if count > 0 { offset += count }
                    else if count < 0 && errno == EPIPE { closeOwned(input[1]); inputOpen = false }
                    else if count < 0 && errno != EAGAIN && errno != EINTR { throw MailpipeError.processFailed }
                }
            }
            // One chunk per pipe per iteration prevents a noisy child from starving cancellation.
            for fd in [output[0], errors[0]] {
                if fd == output[0] ? !outputOpen : !errorOpen { continue }
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    guard stdout.count + stderr.count + count <= spec.outputLimit else { throw MailpipeError.outputLimit }
                    if fd == output[0] { stdout.append(contentsOf: buffer.prefix(count)) }
                    else { stderr.append(contentsOf: buffer.prefix(count)) }
                } else if count == 0 {
                    closeOwned(fd)
                    if fd == output[0] { outputOpen = false } else { errorOpen = false }
                } else if errno != EAGAIN && errno != EINTR { throw MailpipeError.processFailed }
            }
            if !reaped {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { reaped = true }
                else if result == -1 && errno != EINTR { throw MailpipeError.processFailed }
            }
            if !reaped || outputOpen || errorOpen {
                var polls = [pollfd(fd: outputOpen ? output[0] : -1, events: Int16(POLLIN), revents: 0),
                             pollfd(fd: errorOpen ? errors[0] : -1, events: Int16(POLLIN), revents: 0),
                             pollfd(fd: inputOpen ? input[1] : -1, events: Int16(POLLOUT), revents: 0)]
                _ = poll(&polls, nfds_t(polls.count), 20)
            }
        }
        if flag.cancelled { throw MailpipeError.cancelled }
        // Darwin wait status: signal in low 7 bits, normal exit code in bits 8...15.
        let exitCode = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return ProcessOutput(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }
}
