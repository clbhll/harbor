import Darwin
import Foundation
import Testing

@testable import Harbor

/// Every executable here is a newly launched disposable child. In particular,
/// timeout/cancellation fixtures use `exec` so sleep replaces the shell; there
/// are no background descendants and no signals sent to existing user processes.
@Suite("Command runner", .serialized)
struct CommandRunnerTests {
    @Test("Captures both streams and preserves a nonzero exit status")
    func capturesOutputAndStatus() async throws {
        let output = try await CommandRunner.run(
            launchPath: "/bin/sh", arguments: ["-c", "printf 'hello'; printf 'diagnostic' >&2; exit 7"]
        )
        #expect(output.stdout == Data("hello".utf8))
        #expect(output.stderr == Data("diagnostic".utf8))
        #expect(output.status == 7)
        #expect(output.terminationReason == .exit)
    }

    @Test("A signal exit is distinct from a normal exit with the same status")
    func preservesSignalTermination() async throws {
        // The shell signals itself, never a pid obtained from machine discovery.
        let signaled = try await CommandRunner.run(
            launchPath: "/bin/sh", arguments: ["-c", "kill -TERM $$"]
        )
        let exited = try await CommandRunner.run(
            launchPath: "/bin/sh", arguments: ["-c", "exit 15"]
        )
        #expect(signaled.status == SIGTERM)
        #expect(signaled.terminationReason == .uncaughtSignal)
        #expect(exited.status == 15)
        #expect(exited.terminationReason == .exit)
    }

    @Test("Drains stdout and stderr fairly beyond pipe capacity")
    func drainsBothFullPipes() async throws {
        let stdoutChunk = String(repeating: "o", count: 256)
        let stderrChunk = String(repeating: "e", count: 256)
        // Shell builtins only. Reading stdout to EOF before reading stderr would
        // deadlock here once stderr fills, because the child cannot exit.
        let script = """
        i=0
        while [ "$i" -lt 1024 ]; do
            printf '%s' '\(stdoutChunk)'
            printf '%s' '\(stderrChunk)' >&2
            i=$((i + 1))
        done
        """
        let output = try await CommandRunner.run(
            launchPath: "/bin/sh", arguments: ["-c", script], timeout: .seconds(10)
        )
        #expect(output.status == 0)
        #expect(output.stdout == Data(String(repeating: stdoutChunk, count: 1024).utf8))
        #expect(output.stderr == Data(String(repeating: stderrChunk, count: 1024).utf8))
    }

    @Test("Preserves non-UTF-8 output as raw data")
    func preservesRawBytes() async throws {
        let output = try await CommandRunner.run(
            launchPath: "/bin/sh", arguments: ["-c", "printf '\\377'"]
        )
        #expect(output.stdout == Data([0xff]))
    }

    @Test("Child stdin is EOF rather than the application's input")
    func closesInput() async throws {
        let output = try await CommandRunner.run(
            launchPath: "/bin/sh", arguments: ["-c", "if read line; then exit 9; fi; printf eof"]
        )
        #expect(output.status == 0)
        #expect(output.stdoutString == "eof")
    }

    @Test("A timeout kills and reaps its own child even when SIGTERM is ignored")
    func timesOutAndReaps() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        let started = ContinuousClock.now
        do {
            _ = try await CommandRunner.run(
                launchPath: "/bin/sh",
                arguments: ["-c", "trap '' TERM; printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 30", "fixture", pidFile.path],
                timeout: .seconds(2)
            )
            Issue.record("Expected the command to time out")
        } catch {
            #expect(error as? CommandRunnerError == .timedOut)
        }
        #expect(started.duration(to: .now) < .seconds(5))
        let pid = try readPID(at: pidFile)
        expectReaped(pid)
    }

    @Test("Cancellation promptly kills and reaps the launched sleep child")
    func cancelsAndReaps() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        let task = Task {
            try await CommandRunner.run(
                launchPath: "/bin/sh",
                arguments: ["-c", "printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 30", "fixture", pidFile.path],
                timeout: .seconds(10)
            )
        }
        defer { task.cancel() }
        let pid = try await waitForPID(at: pidFile)
        let cancelled = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(cancelled.duration(to: .now) < .seconds(5))
        expectReaped(pid)
    }

    @Test("A pre-cancelled task never launches a command")
    func doesNotLaunchAfterCancellation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("launched")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CommandRunner.run(
                launchPath: "/bin/sh",
                arguments: ["-c", "printf launched > \"$1\"", "fixture", marker.path]
            )
        }
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("The output budget is shared by stdout and stderr")
    func boundsCombinedOutput() async {
        do {
            _ = try await CommandRunner.run(
                launchPath: "/bin/sh",
                arguments: ["-c", "printf 1234567890; printf 1234567890 >&2"],
                maximumOutputBytes: 16
            )
            Issue.record("Expected the combined output limit to be enforced")
        } catch {
            #expect(error as? CommandRunnerError == .outputLimitExceeded(limit: 16))
        }
    }

    @Test("A continuously writing child is stopped when its output limit is reached")
    func stopsUnboundedOutput() async {
        do {
            _ = try await CommandRunner.run(
                launchPath: "/bin/sh", arguments: ["-c", "while :; do printf 1234567890; done"],
                maximumOutputBytes: 1024
            )
            Issue.record("Expected output limit failure")
        } catch {
            #expect(error as? CommandRunnerError == .outputLimitExceeded(limit: 1024))
        }
    }

    @Test("Launch failures report their actual POSIX error")
    func reportsLaunchFailure() async {
        do {
            _ = try await CommandRunner.run(launchPath: "/nonexistent-harbor-fixture-\(UUID().uuidString)", arguments: [])
            Issue.record("Expected launch failure")
        } catch let error as CommandRunnerError {
            guard case .systemCall(let operation, let code) = error else {
                Issue.record("Unexpected runner error: \(error)")
                return
            }
            #expect(operation.hasPrefix("posix_spawn("))
            #expect(code == ENOENT)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Invalid timeouts and NUL arguments are rejected")
    func validatesInputs() async {
        do {
            _ = try await CommandRunner.run(launchPath: "/bin/sh", arguments: [], timeout: .zero)
            Issue.record("Expected invalid timeout")
        } catch {
            #expect(error as? CommandRunnerError == .invalidTimeout)
        }
        do {
            _ = try await CommandRunner.run(launchPath: "/bin/sh", arguments: ["a\0b"])
            Issue.record("Expected invalid argument")
        } catch {
            #expect(error as? CommandRunnerError == .invalidArgument)
        }
    }

    @Test("Original pipe descriptors are not inherited in addition to stdout and stderr")
    func closesChildSideDuplicates() async throws {
        let output = try await CommandRunner.run(
            launchPath: "/bin/sh",
            arguments: ["-c", "for fd in /dev/fd/*; do if [ -p \"$fd\" ]; then printf '%s\\n' \"${fd##*/}\"; fi; done"]
        )
        #expect(output.status == 0)
        #expect(Set(output.stdoutString.split(separator: "\n")) == ["1", "2"])
    }

    @Test("Repeated success and launch failure do not accumulate open descriptors")
    func doesNotAccumulateDescriptors() async throws {
        // Warm up dispatch/Foundation before the baseline. A small allowance
        // accommodates unrelated test-harness descriptors; a per-run pipe leak
        // would add at least 32 descriptors and fail this assertion.
        _ = try await CommandRunner.run(launchPath: "/bin/sh", arguments: ["-c", "exit 0"])
        let before = openDescriptorCount()
        for _ in 0..<32 {
            _ = try await CommandRunner.run(launchPath: "/bin/sh", arguments: ["-c", "printf o; printf e >&2"])
            _ = try? await CommandRunner.run(launchPath: "/nonexistent-harbor-fixture", arguments: [])
        }
        #expect(openDescriptorCount() <= before + 4)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HarborCommandTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readPID(at url: URL) throws -> pid_t {
        let text = try String(contentsOf: url, encoding: .utf8)
        let pid = try #require(pid_t(text))
        try #require(pid > 1 && pid != getpid())
        return pid
    }

    private func waitForPID(at url: URL) async throws -> pid_t {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = pid_t(text), pid > 1, pid != getpid() {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        throw CommandRunnerError.timedOut
    }

    private func expectReaped(_ pid: pid_t) {
        // waitpid only observes this test process's own children. No kill(pid, 0)
        // probes or other signals are sent by the tests to verify cleanup.
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        let code = errno
        #expect(result == -1)
        #expect(code == ECHILD)
    }

    private func openDescriptorCount() -> Int {
        (0..<getdtablesize()).reduce(into: 0) { count, descriptor in
            if fcntl(descriptor, F_GETFD) != -1 { count += 1 }
        }
    }
}
