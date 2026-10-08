import Darwin
import Foundation
import Testing

@testable import Harbor

private final class StubProcessController: ProcessControlling {
    var current: ProcessIdentity?
    var errorCode: Int32?
    var signaled: [Int32] = []

    init(current: ProcessIdentity?, errorCode: Int32? = nil) {
        self.current = current
        self.errorCode = errorCode
    }

    func identity(for pid: Int32) -> ProcessIdentity? { current }
    func sendTerminationSignal(to pid: Int32) -> Int32? {
        signaled.append(pid)
        return errorCode
    }
}

@Suite("Termination identity checks")
struct ProcessSafetyTests {
    private let identity = ProcessIdentity(
        pid: 4242, startedSeconds: 100, startedMicroseconds: 123,
        userID: 501, executablePath: "/test/node"
    )

    private func server(identity: ProcessIdentity?, pid: Int32 = 4242) -> ListeningServer {
        ListeningServer(
            id: "test", pid: pid, processName: "node", port: 3000,
            address: "*", executablePath: "/test/node", commandLine: nil,
            processIdentity: identity
        )
    }

    @Test("An unreadable scan identity cannot signal")
    func missingStoredIdentity() {
        let controller = StubProcessController(current: identity)
        let outcome = PortActions.terminate(server(identity: nil), controller: controller)
        #expect(outcome != .succeeded)
        #expect(controller.signaled.isEmpty)
    }

    @Test("An unreadable current identity cannot signal")
    func missingCurrentIdentity() {
        let controller = StubProcessController(current: nil)
        #expect(PortActions.terminate(server(identity: identity), controller: controller) != .succeeded)
        #expect(controller.signaled.isEmpty)
    }

    @Test("A reused PID is rejected even when the executable is unchanged")
    func reusedPID() {
        let replacement = ProcessIdentity(
            pid: identity.pid, startedSeconds: 200, startedMicroseconds: 123,
            userID: identity.userID, executablePath: identity.executablePath
        )
        let controller = StubProcessController(current: replacement)
        #expect(PortActions.terminate(server(identity: identity), controller: controller) != .succeeded)
        #expect(controller.signaled.isEmpty)
    }

    @Test("A changed executable or user cannot signal", arguments: [true, false])
    func changedMetadata(changePath: Bool) {
        let replacement = ProcessIdentity(
            pid: identity.pid, startedSeconds: identity.startedSeconds,
            startedMicroseconds: identity.startedMicroseconds,
            userID: changePath ? identity.userID : 502,
            executablePath: changePath ? "/test/other" : identity.executablePath
        )
        let controller = StubProcessController(current: replacement)
        #expect(PortActions.terminate(server(identity: identity), controller: controller) != .succeeded)
        #expect(controller.signaled.isEmpty)
    }

    @Test("Matching identity reaches only the injected signal seam")
    func matchingIdentity() {
        let controller = StubProcessController(current: identity)
        #expect(PortActions.terminate(server(identity: identity), controller: controller) == .succeeded)
        #expect(controller.signaled == [identity.pid])
    }

    @Test("Signal failures retain a useful reason", arguments: [EPERM, ESRCH, EINVAL])
    func signalFailure(code: Int32) {
        let controller = StubProcessController(current: identity, errorCode: code)
        let outcome = PortActions.terminate(server(identity: identity), controller: controller)
        guard case .failed(let reason) = outcome else {
            Issue.record("Expected signal failure")
            return
        }
        #expect(reason.contains("4242"))
        #expect(!reason.isEmpty)
    }

    @Test("Process groups, init and the app itself are never signal targets", arguments: [-1, 0, 1])
    func unsafePID(pid: Int32) {
        let controller = StubProcessController(current: identity)
        #expect(PortActions.terminate(server(identity: identity, pid: pid), controller: controller) != .succeeded)
        #expect(controller.signaled.isEmpty)
    }

    @Test("A newly created process cannot inherit a row from an earlier scan")
    func predatesScan() {
        #expect(identity.predates(Date(timeIntervalSince1970: 101)))
        #expect(!identity.predates(Date(timeIntervalSince1970: 99)))
    }

    @Test("The live inspector can identify its own test process without signaling it")
    func readsOwnIdentity() throws {
        let observedAt = Date()
        let current = try #require(ProcessIdentity.read(for: getpid()))
        #expect(current.pid == getpid())
        #expect(current.userID == geteuid())
        #expect(current.predates(observedAt))
        #expect(current.executablePath.hasPrefix("/"))
        #expect(ProcessIdentity.read(for: getpid()) == current)

        let controller = StubProcessController(current: current)
        #expect(PortActions.terminate(server(identity: current, pid: getpid()), controller: controller) != .succeeded)
        #expect(controller.signaled.isEmpty)
    }
}

@Suite("Kernel argument-buffer boundaries")
struct ProcessArgumentsTests {
    private func buffer(_ arguments: [String], environment: [String] = []) -> [UInt8] {
        var argc = Int32(arguments.count)
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array("/test/node".utf8) + [0]
        for value in arguments + environment { bytes += Array(value.utf8) + [0] }
        return bytes
    }

    @Test("Interior and trailing empty arguments do not consume environment entries")
    func emptyArguments() {
        let arguments = ["node", "", "server.js", ""]
        let bytes = buffer(arguments, environment: ["SECRET_TOKEN=never-display", "OTHER=value"])
        #expect(ProcessArguments.parse(bytes) == arguments)
        let display = ProcessArguments.display(ProcessArguments.parse(bytes) ?? [])
        #expect(!display.contains("SECRET_TOKEN"))
        #expect(display == "node \"\" server.js \"\"")
    }

    @Test("An empty argv[0] fails closed instead of consuming environment values")
    func emptyFirstArgument() {
        let bytes = buffer(["", "server.js"], environment: ["SECRET_TOKEN=never-display"])
        #expect(ProcessArguments.parse(bytes) == nil)
    }

    @Test("Ambiguous executable padding omits metadata rather than guessing argv start")
    func ambiguousPadding() {
        var bytes = buffer(["node", "server.js"], environment: ["SECRET_TOKEN=never-display"])
        let afterExecutable = MemoryLayout<Int32>.size + "/test/node".utf8.count + 1
        bytes.insert(contentsOf: [0, 0], at: afterExecutable)
        #expect(ProcessArguments.parse(bytes) == nil)
    }

    @Test("argc is the hard boundary even without an extra separating NUL")
    func argumentCountBoundary() {
        #expect(ProcessArguments.parse(buffer(["node"], environment: ["TOKEN=secret"])) == ["node"])
    }

    @Test("A truncated argument fails closed")
    func truncatedArgument() {
        let bytes = buffer(["node", "server.js"])
        #expect(ProcessArguments.parse(Array(bytes.dropLast())) == nil)
    }

    @Test("Only the returned buffer size is read, never stale capacity")
    func respectsReturnedLength() {
        let bytes = buffer(["node", "server.js"])
        #expect(ProcessArguments.parse(bytes, count: bytes.count - 1) == nil)
    }

    @Test("Rejects invalid lengths and missing headers")
    func malformedBuffer() {
        #expect(ProcessArguments.parse([]) == nil)
        #expect(ProcessArguments.parse([0, 0, 0, 0, 0]) == nil)
        #expect(ProcessArguments.parse([255, 255, 255, 255, 0]) == nil)
        #expect(ProcessArguments.parse([1, 0, 0, 0, 65, 66]) == nil)
        #expect(ProcessArguments.parse([1, 0], count: 20) == nil)
    }
}

@Suite("lsof result classification")
struct DiscoveryResultTests {
    @Test("Status 1 is empty only with no diagnostics and no partial output")
    func emptyResult() throws {
        let result = CommandOutput(stdout: Data(), stderr: Data(), status: 1, terminationReason: .exit)
        #expect(try PortDiscovery.validatedOutput(result) == "")
    }

    @Test("Diagnostic failures are not mistaken for an empty list", arguments: [Int32(0), 1, 2])
    func diagnosticFailure(status: Int32) {
        let result = CommandOutput(stdout: Data(), stderr: Data("lsof: permission denied".utf8), status: status, terminationReason: .exit)
        #expect(throws: (any Error).self) { try PortDiscovery.validatedOutput(result) }
    }

    @Test("Status 1 with partial records is a failed scan")
    func partialFailure() {
        let result = CommandOutput(stdout: Data("p4242\ncnode\nn*:3000\n".utf8), stderr: Data(), status: 1, terminationReason: .exit)
        #expect(throws: (any Error).self) { try PortDiscovery.validatedOutput(result) }
    }

    @Test("Signals and unreadable output fail the scan")
    func malformedResult() {
        let signaled = CommandOutput(stdout: Data(), stderr: Data(), status: SIGTERM, terminationReason: .uncaughtSignal)
        #expect(throws: (any Error).self) { try PortDiscovery.validatedOutput(signaled) }
        let invalid = CommandOutput(stdout: Data([0xff]), stderr: Data(), status: 0, terminationReason: .exit)
        #expect(throws: (any Error).self) { try PortDiscovery.validatedOutput(invalid) }
    }
}
