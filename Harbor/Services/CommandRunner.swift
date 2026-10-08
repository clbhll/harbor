import Darwin
import Foundation
import os

struct CommandOutput: Sendable {
    enum TerminationReason: Sendable, Equatable {
        case exit
        case uncaughtSignal
    }

    let stdout: Data
    let stderr: Data
    /// The exit code, or the signal number when `terminationReason` is `.uncaughtSignal`.
    let status: Int32
    let terminationReason: TerminationReason

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

enum CommandRunnerError: LocalizedError, Sendable, Equatable {
    case invalidTimeout
    case invalidOutputLimit
    case invalidArgument
    case systemCall(operation: String, code: Int32)
    case timedOut
    case outputLimitExceeded(limit: Int)
    case cleanupFailed(originalError: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            return "The command timeout must be greater than zero."
        case .invalidOutputLimit:
            return "The command output limit must not be negative."
        case .invalidArgument:
            return "The command path and arguments must not contain a NUL character."
        case .systemCall(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code))) (\(code))."
        case .timedOut:
            return "The command exceeded its time limit."
        case .outputLimitExceeded(let limit):
            return "The command exceeded its combined output limit of \(limit) bytes."
        case .cleanupFailed(let originalError, let code):
            return "\(originalError) Child-process cleanup failed: \(String(cString: strerror(code))) (\(code))."
        }
    }
}

/// Runs one directly owned child. No process groups, discovered pids, or descendants
/// are signalled. The worker is the child's only waiter, so an unreaped child's pid
/// cannot be recycled between the ownership check and a cleanup signal.
///
/// Both output pipes are nonblocking and drained fairly on a Dispatch worker. No
/// blocking read or wait occupies Swift's cooperative executor. Each drainage pass
/// checks cancellation and the deadline, with polling capped at 25 ms, even after
/// the child exits if a descendant has inherited an output pipe. Captured output is bounded across
/// both streams; exceeding the limit fails rather than returning truncated data.
enum CommandRunner {
    static func run(
        launchPath: String,
        arguments: [String],
        timeout: Duration = .seconds(5),
        maximumOutputBytes: Int = 4 * 1024 * 1024
    ) async throws -> CommandOutput {
        try Task.checkCancellation()
        guard timeout > .zero else { throw CommandRunnerError.invalidTimeout }
        guard maximumOutputBytes >= 0 else { throw CommandRunnerError.invalidOutputLimit }
        guard !([launchPath] + arguments).contains(where: { $0.utf8.contains(0) }) else {
            throw CommandRunnerError.invalidArgument
        }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        let cancellation = OSAllocatedUnfairLock(initialState: false)
        let output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandOutput, any Error>) in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let output = try runBlocking(
                            launchPath: launchPath,
                            arguments: arguments,
                            deadline: deadline,
                            maximumOutputBytes: maximumOutputBytes,
                            cancellation: cancellation
                        )
                        continuation.resume(returning: output)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.withLock { $0 = true }
        }
        try Task.checkCancellation()
        return output
    }

    private struct OutputPipe {
        var readFD: Int32
        var writeFD: Int32

        mutating func closeRead() {
            if readFD >= 0 { Darwin.close(readFD); readFD = -1 }
        }

        mutating func closeWrite() {
            if writeFD >= 0 { Darwin.close(writeFD); writeFD = -1 }
        }

        mutating func close() {
            closeRead()
            closeWrite()
        }
    }

    private static func runBlocking(
        launchPath: String,
        arguments: [String],
        deadline: ContinuousClock.Instant,
        maximumOutputBytes: Int,
        cancellation: OSAllocatedUnfairLock<Bool>
    ) throws -> CommandOutput {
        try checkInterruption(deadline: deadline, cancellation: cancellation)
        var stdoutPipe = try makePipe()
        defer { stdoutPipe.close() }
        var stderrPipe = try makePipe()
        defer { stderrPipe.close() }
        try checkInterruption(deadline: deadline, cancellation: cancellation)
        let pid = try spawn(launchPath: launchPath, arguments: arguments,
                            stdout: stdoutPipe.writeFD, stderr: stderrPipe.writeFD)
        // The parent must not retain a writer, or EOF would never arrive.
        stdoutPipe.closeWrite()
        stderrPipe.closeWrite()

        var ownsChild = true
        var waitStatus: Int32 = 0
        var stdout = Data()
        var stderr = Data()
        var remainingBytes = maximumOutputBytes
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        do {
            while true {
                try checkInterruption(deadline: deadline, cancellation: cancellation)
                try drain(&stdoutPipe, into: &stdout, buffer: &buffer,
                          remainingBytes: &remainingBytes, limit: maximumOutputBytes)
                try drain(&stderrPipe, into: &stderr, buffer: &buffer,
                          remainingBytes: &remainingBytes, limit: maximumOutputBytes)

                if ownsChild {
                    let waited = waitpid(pid, &waitStatus, WNOHANG)
                    if waited == pid {
                        ownsChild = false
                    } else if waited == -1 && errno != EINTR {
                        let code = errno
                        // If ownership was lost, never signal a possibly recycled pid.
                        if code == ECHILD { ownsChild = false }
                        throw CommandRunnerError.systemCall(operation: "waitpid", code: code)
                    }
                }

                if !ownsChild && stdoutPipe.readFD < 0 && stderrPipe.readFD < 0 {
                    let signal = waitStatus & 0x7f
                    return CommandOutput(
                        stdout: stdout,
                        stderr: stderr,
                        status: signal == 0 ? (waitStatus >> 8) & 0xff : signal,
                        terminationReason: signal == 0 ? .exit : .uncaughtSignal
                    )
                }

                var descriptors = [
                    pollfd(fd: stdoutPipe.readFD, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: stderrPipe.readFD, events: Int16(POLLIN), revents: 0)
                ]
                let ready = poll(&descriptors, 2, 25)
                if ready == -1 && errno != EINTR {
                    throw CommandRunnerError.systemCall(operation: "poll", code: errno)
                }
            }
        } catch {
            if ownsChild, let code = terminateAndReap(pid) {
                throw CommandRunnerError.cleanupFailed(originalError: error.localizedDescription, code: code)
            }
            throw error
        }
    }

    private static func checkInterruption(
        deadline: ContinuousClock.Instant,
        cancellation: OSAllocatedUnfairLock<Bool>
    ) throws {
        if cancellation.withLock({ $0 }) { throw CancellationError() }
        if ContinuousClock.now >= deadline { throw CommandRunnerError.timedOut }
    }

    private static func makePipe() throws -> OutputPipe {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            throw CommandRunnerError.systemCall(operation: "pipe", code: errno)
        }
        var result = OutputPipe(readFD: descriptors[0], writeFD: descriptors[1])
        do {
            // Keep pipe descriptors away from stdin/out/err even in a host whose
            // standard descriptors are closed. This makes spawn's dup2 safe.
            result.readFD = try promoteDescriptor(result.readFD)
            result.writeFD = try promoteDescriptor(result.writeFD)
            let flags = fcntl(result.readFD, F_GETFL)
            guard flags != -1, fcntl(result.readFD, F_SETFL, flags | O_NONBLOCK) != -1 else {
                throw CommandRunnerError.systemCall(operation: "fcntl(O_NONBLOCK)", code: errno)
            }
            return result
        } catch {
            result.close()
            throw error
        }
    }

    private static func promoteDescriptor(_ descriptor: Int32) throws -> Int32 {
        if descriptor > STDERR_FILENO {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else {
                throw CommandRunnerError.systemCall(operation: "fcntl(FD_CLOEXEC)", code: errno)
            }
            return descriptor
        }
        let replacement = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard replacement != -1 else {
            throw CommandRunnerError.systemCall(operation: "fcntl(F_DUPFD_CLOEXEC)", code: errno)
        }
        Darwin.close(descriptor)
        return replacement
    }

    private static func spawn(launchPath: String, arguments: [String], stdout: Int32, stderr: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        try checkSpawnCall(posix_spawn_file_actions_init(&actions), operation: "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checkSpawnCall(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                           operation: "posix_spawn_file_actions_addopen")
        try checkSpawnCall(posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO),
                           operation: "posix_spawn_file_actions_adddup2(stdout)")
        try checkSpawnCall(posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO),
                           operation: "posix_spawn_file_actions_adddup2(stderr)")
        try checkSpawnCall(posix_spawn_file_actions_addclose(&actions, stdout),
                           operation: "posix_spawn_file_actions_addclose(stdout)")
        try checkSpawnCall(posix_spawn_file_actions_addclose(&actions, stderr),
                           operation: "posix_spawn_file_actions_addclose(stderr)")

        var attributes: posix_spawnattr_t?
        try checkSpawnCall(posix_spawnattr_init(&attributes), operation: "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }

        // Dispatch workers and test/app hosts can block or ignore signals. Give
        // the child an empty mask and default dispositions instead of inheriting
        // that ambient state. These attributes affect only the spawned child.
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try checkSpawnCall(posix_spawnattr_setsigmask(&attributes, &signalMask),
                           operation: "posix_spawnattr_setsigmask")
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        try checkSpawnCall(posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
                           operation: "posix_spawnattr_setsigdefault")

        // Only explicitly redirected descriptors cross into the child. In
        // particular, another concurrently running command cannot inherit pipes.
        let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        try checkSpawnCall(posix_spawnattr_setflags(&attributes, Int16(flags)),
                           operation: "posix_spawnattr_setflags")

        let argv = try cStrings([launchPath] + arguments)
        defer { argv.forEach { free($0) } }
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let envp = try cStrings(environment)
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, launchPath, &actions, &attributes, argv, envp)
        try checkSpawnCall(result, operation: "posix_spawn(\(launchPath))")
        return pid
    }

    private static func cStrings(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = []
        for string in strings {
            guard let pointer = strdup(string) else {
                result.forEach { free($0) }
                throw CommandRunnerError.systemCall(operation: "strdup", code: ENOMEM)
            }
            result.append(pointer)
        }
        result.append(nil)
        return result
    }

    private static func checkSpawnCall(_ result: Int32, operation: String) throws {
        // posix_spawn and its configuration functions return error codes directly.
        if result != 0 { throw CommandRunnerError.systemCall(operation: operation, code: result) }
    }

    private static func drain(
        _ pipe: inout OutputPipe,
        into output: inout Data,
        buffer: inout [UInt8],
        remainingBytes: inout Int,
        limit: Int
    ) throws {
        guard pipe.readFD >= 0 else { return }
        // A writer producing continuously must not starve the other stream,
        // cancellation, or the deadline. Each pass reads at most 64 KiB per pipe.
        for _ in 0..<4 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(pipe.readFD, $0.baseAddress, $0.count) }
            if count > 0 {
                guard count <= remainingBytes else { throw CommandRunnerError.outputLimitExceeded(limit: limit) }
                output.append(contentsOf: buffer.prefix(count))
                remainingBytes -= count
            } else if count == 0 {
                pipe.closeRead()
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                return
            } else {
                throw CommandRunnerError.systemCall(operation: "read(command output)", code: errno)
            }
        }
    }

    /// Stops only the unreaped child owned by this worker. SIGKILL is intentional:
    /// a discovery utility must not hold cancellation hostage by ignoring SIGTERM.
    /// Give normal exits a bounded reaping grace period; if the kernel delays an
    /// exit, a waiter retains ownership without blocking the caller indefinitely.
    private static func terminateAndReap(_ pid: pid_t) -> Int32? {
        let signalError: Int32?
        if Darwin.kill(pid, SIGKILL) == -1 && errno != ESRCH {
            signalError = errno
        } else {
            signalError = nil
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var status: Int32 = 0
        repeat {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid || (waited == -1 && errno == ECHILD) { return signalError }
            if waited == -1 && errno != EINTR { break }
            usleep(10_000)
        } while ContinuousClock.now < deadline

        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
        return signalError
    }
}
