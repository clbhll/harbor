import Foundation
import Testing

@testable import Harbor

private enum ScannerTestError: LocalizedError {
    case unavailable

    var errorDescription: String? { "The test scan failed." }
}

/// A scan is released explicitly by its test. Results may also be queued for a
/// future call, so ordering assertions do not depend on sleeps or live lsof.
private actor ControlledScannerDiscovery {
    private(set) var callCount = 0
    private var pending: [Int: CheckedContinuation<[ListeningServer], any Error>] = [:]
    private var queued: [Int: Result<[ListeningServer], any Error>] = [:]
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func discover() async throws -> [ListeningServer] {
        callCount += 1
        let call = callCount
        let ready = startWaiters.filter { $0.0 <= call }
        startWaiters.removeAll { $0.0 <= call }
        for (_, waiter) in ready { waiter.resume() }

        if let result = queued.removeValue(forKey: call) { return try result.get() }
        return try await withCheckedThrowingContinuation { pending[call] = $0 }
    }

    func waitForCall(_ call: Int) async {
        guard callCount < call else { return }
        await withCheckedContinuation { startWaiters.append((call, $0)) }
    }

    func complete(_ call: Int, with result: Result<[ListeningServer], any Error>) {
        if let continuation = pending.removeValue(forKey: call) {
            continuation.resume(with: result)
        } else {
            queued[call] = result
        }
    }
}

@MainActor
private final class ScannerTestSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Suite("Port scanner state")
@MainActor
struct PortScannerTests {
    private func server(startedSeconds: UInt64 = 1, hasIdentity: Bool = true) -> ListeningServer {
        ListeningServer(
            id: "4242-127.0.0.1-3000",
            pid: 4242,
            processName: "node",
            port: 3000,
            address: "127.0.0.1",
            executablePath: "/test/node",
            commandLine: "/test/node server.js",
            processIdentity: hasIdentity ? ProcessIdentity(
                pid: 4242,
                startedSeconds: startedSeconds,
                startedMicroseconds: 0,
                userID: 501,
                executablePath: "/test/node"
            ) : nil
        )
    }

    private func scanner(_ source: ControlledScannerDiscovery) -> PortScanner {
        PortScanner(
            defaults: UserDefaults(suiteName: "Harbor.PortScannerTests.\(UUID().uuidString)")!,
            startPolling: false,
            discovery: { try await source.discover() }
        )
    }

    @Test("Concurrent refresh callers wait for the same actual scan")
    func refreshCoalescesAndWaits() async {
        let source = ControlledScannerDiscovery()
        let scanner = scanner(source)
        let expected = [server()]
        let first = Task { await scanner.refresh() }
        await source.waitForCall(1)

        let entered = ScannerTestSignal()
        var secondFinished = false
        let second = Task {
            entered.signal()
            let result = await scanner.refresh()
            secondFinished = true
            return result
        }
        await entered.wait()

        #expect(scanner.isRefreshing)
        #expect(!secondFinished)
        let callsBeforeCompletion = await source.callCount
        #expect(callsBeforeCompletion == 1)
        await source.complete(1, with: .success(expected))
        let firstResult = await first.value
        let secondResult = await second.value

        #expect(firstResult == .success(expected))
        #expect(secondResult == .success(expected))
        #expect(scanner.servers == expected)
        #expect(!scanner.isRefreshing)
        let totalCalls = await source.callCount
        #expect(totalCalls == 1)
    }

    @Test("Post-action confirmation does not consume an older scan as an attempt")
    func postActionRefreshStartsAfterInflightScan() async {
        let source = ControlledScannerDiscovery()
        let scanner = scanner(source)
        let target = server()
        let first = Task { await scanner.refresh() }
        await source.waitForCall(1)

        // A stale empty result must not prove the post-action process is gone.
        await source.complete(2, with: .success([target]))
        let entered = ScannerTestSignal()
        var confirmationFinished = false
        let confirmation = Task {
            entered.signal()
            let result = await scanner.refreshUntilGone(pid: target.pid, attempts: 1)
            confirmationFinished = true
            return result
        }
        await entered.wait()
        #expect(!confirmationFinished)
        await source.complete(1, with: .success([]))
        _ = await first.value
        let result = await confirmation.value

        #expect(result == .stillListening)
        #expect(scanner.servers == [target])
        let totalCalls = await source.callCount
        #expect(totalCalls == 2)
    }

    @Test("Cancelling one refresh waiter does not cancel a shared scan")
    func cancelledWaiterDoesNotCancelSharedScan() async {
        let source = ControlledScannerDiscovery()
        let scanner = scanner(source)
        let expected = [server()]
        let first = Task { await scanner.refresh() }
        await source.waitForCall(1)
        let entered = ScannerTestSignal()
        let second = Task {
            entered.signal()
            return await scanner.refresh()
        }
        await entered.wait()
        second.cancel()
        await source.complete(1, with: .success(expected))
        let firstResult = await first.value
        let secondResult = await second.value

        #expect(firstResult == .success(expected))
        #expect(secondResult == .cancelled)
        #expect(scanner.servers == expected)
        #expect(scanner.isDiscoveryTrusted)
        #expect(!scanner.isRefreshing)
    }

    @Test("Cancelled post-action refresh never reports that a process disappeared")
    func cancellationDoesNotConfirmDisappearance() async {
        let source = ControlledScannerDiscovery()
        let scanner = scanner(source)
        let confirmation = Task { await scanner.refreshUntilGone(pid: 4242, attempts: 1) }
        await source.waitForCall(1)
        confirmation.cancel()
        await source.complete(1, with: .success([]))
        let result = await confirmation.value
        #expect(result == .cancelled)
    }

    @Test("Discovery failure keeps the last good rows and timestamp")
    func failurePreservesLastGoodDiscovery() async {
        let source = ControlledScannerDiscovery()
        let scanner = scanner(source)
        let target = server()
        await source.complete(1, with: .success([target]))
        await scanner.refresh()
        let previousUpdate = scanner.lastUpdated
        #expect(scanner.canTerminate(target))

        await source.complete(2, with: .failure(ScannerTestError.unavailable))
        let result = await scanner.refresh()
        #expect(result == .failure)
        #expect(scanner.servers == [target])
        #expect(scanner.filteredServers == [target])
        #expect(scanner.lastUpdated == previousUpdate)
        #expect(scanner.discoveryErrorMessage == "The test scan failed.")
        #expect(!scanner.canTerminate(target))

        scanner.dismissDiscoveryError()
        #expect(scanner.discoveryErrorMessage == nil)
        #expect(!scanner.isDiscoveryTrusted)
        #expect(!scanner.canTerminate(target))
    }

    @Test("Successful polling clears discovery errors but preserves action errors")
    func actionFailureSurvivesSuccessfulPolling() async {
        let source = ControlledScannerDiscovery()
        let scanner = scanner(source)
        scanner.report("The process identity changed.")
        await source.complete(1, with: .failure(ScannerTestError.unavailable))
        await scanner.refresh()
        #expect(scanner.discoveryErrorMessage != nil)

        await source.complete(2, with: .success([server()]))
        await scanner.refresh()
        #expect(scanner.discoveryErrorMessage == nil)
        #expect(scanner.actionErrorMessage == "The process identity changed.")
        #expect(scanner.isDiscoveryTrusted)
    }

    @Test("Each banner dismissal affects only that error category")
    func errorDismissalsAreIndependent() async {
        let source = ControlledScannerDiscovery()
        let scanner = scanner(source)
        await source.complete(1, with: .failure(ScannerTestError.unavailable))
        await scanner.refresh()
        scanner.report("Termination was rejected.")
        scanner.dismissActionError()
        #expect(scanner.actionErrorMessage == nil)
        #expect(scanner.discoveryErrorMessage != nil)

        scanner.report("Termination was rejected again.")
        scanner.dismissDiscoveryError()
        #expect(scanner.discoveryErrorMessage == nil)
        #expect(scanner.actionErrorMessage == "Termination was rejected again.")
        #expect(!scanner.isDiscoveryTrusted)
    }

    @Test("Discovery cancellation preserves state and does not prove disappearance")
    func discoveryCancellationPreservesState() async {
        let source = ControlledScannerDiscovery()
        let scanner = scanner(source)
        let target = server()
        await source.complete(1, with: .success([target]))
        await scanner.refresh()
        let previousUpdate = scanner.lastUpdated

        await source.complete(2, with: .failure(CancellationError()))
        let result = await scanner.refreshUntilGone(pid: target.pid, attempts: 1)
        #expect(result == .cancelled)
        #expect(scanner.servers == [target])
        #expect(scanner.lastUpdated == previousUpdate)
        #expect(scanner.discoveryErrorMessage == nil)
        #expect(!scanner.isDiscoveryTrusted)
        #expect(!scanner.canTerminate(target))
    }

    @Test("Failed discovery cannot confirm disappearance from an empty last-known list")
    func failureDoesNotConfirmDisappearance() async {
        let source = ControlledScannerDiscovery()
        let scanner = scanner(source)
        await source.complete(1, with: .failure(ScannerTestError.unavailable))
        let result = await scanner.refreshUntilGone(pid: 4242, attempts: 1)
        #expect(result == .discoveryFailed)
        #expect(scanner.lastUpdated == nil)
    }

    @Test("Termination requires a current row with a known matching process identity")
    func terminationRequiresTrustedIdentity() async {
        let source = ControlledScannerDiscovery()
        let scanner = scanner(source)
        let current = server(startedSeconds: 2)
        await source.complete(1, with: .success([current]))
        await scanner.refresh()
        #expect(scanner.canTerminate(current))
        #expect(!scanner.canTerminate(server(startedSeconds: 1)))
        #expect(!scanner.canTerminate(server(hasIdentity: false)))

        await source.complete(2, with: .success([server(hasIdentity: false)]))
        await scanner.refresh()
        #expect(!scanner.canTerminate(server(hasIdentity: false)))
    }
    @Test("A confirmation snapshot cannot follow a reused row into a new process")
    func confirmationSnapshotRejectsReplacement() async {
        let source = ControlledScannerDiscovery()
        let scanner = scanner(source)
        let original = server(startedSeconds: 1)
        await source.complete(1, with: .success([original]))
        await scanner.refresh()
        let confirmationTarget = original

        let replacement = server(startedSeconds: 2)
        #expect(replacement.id == confirmationTarget.id)
        await source.complete(2, with: .success([replacement]))
        await scanner.refresh()
        #expect(!scanner.canTerminate(confirmationTarget))
        #expect(scanner.canTerminate(replacement))
        #expect(confirmationTarget.processIdentity == original.processIdentity)
    }

    @Test("Post-action confirmation distinguishes a replacement process from the target")
    func replacementDoesNotCountAsStillListening() async {
        let source = ControlledScannerDiscovery()
        let scanner = scanner(source)
        let original = server(startedSeconds: 1)
        await source.complete(1, with: .success([server(startedSeconds: 2)]))
        let result = await scanner.refreshUntilGone(pid: original.pid, identity: original.processIdentity, attempts: 1)
        #expect(result == .noLongerListening)
    }

    @Test("Post-action confirmation rejects an unreadable identity")
    func unknownIdentityDoesNotConfirmDisappearance() async {
        let source = ControlledScannerDiscovery()
        let scanner = scanner(source)
        let original = server()
        await source.complete(1, with: .success([server(hasIdentity: false)]))
        let result = await scanner.refreshUntilGone(pid: original.pid, identity: original.processIdentity, attempts: 1)
        #expect(result == .discoveryFailed)
    }

    @Test("Hide-system preference persists through the injected defaults store")
    func persistsDisplayPreference() throws {
        let suite = "Harbor.DisplayPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PortScanner(defaults: defaults, startPolling: false, discovery: { [] })
        #expect(first.hideSystemProcesses)
        first.hideSystemProcesses = false
        #expect(defaults.object(forKey: PortScanner.hideSystemDefaultsKey) as? Bool == false)

        let reopened = PortScanner(defaults: defaults, startPolling: false, discovery: { [] })
        #expect(!reopened.hideSystemProcesses)
        reopened.hideSystemProcesses = true
        #expect(defaults.object(forKey: PortScanner.hideSystemDefaultsKey) as? Bool == true)
    }

}
