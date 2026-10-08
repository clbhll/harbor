import Foundation
import Observation

@MainActor
@Observable
final class PortScanner {
    typealias Discovery = @Sendable () async throws -> [ListeningServer]

    enum RefreshResult: Equatable, Sendable {
        case success([ListeningServer])
        case failure
        case cancelled
    }

    enum ProcessRefreshResult: Equatable, Sendable {
        case noLongerListening
        case stillListening
        case discoveryFailed
        case cancelled
    }

    private(set) var servers: [ListeningServer] = []

    /// Cache the filtered list rather than rebuilding it for every row.
    private(set) var filteredServers: [ListeningServer] = []

    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    private(set) var discoveryErrorMessage: String?
    private(set) var actionErrorMessage: String?
    /// Kept separately from the banner: dismissing an error must not make
    /// last-known process information safe to act on again.
    private(set) var isDiscoveryTrusted = false

    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            applyFilters()
        }
    }

    var hideSystemProcesses: Bool {
        didSet {
            guard hideSystemProcesses != oldValue else { return }
            defaults.set(hideSystemProcesses, forKey: Self.hideSystemDefaultsKey)
            applyFilters()
        }
    }

    /// Background polling is slower while the panel is closed.
    var isPanelVisible = false {
        didSet {
            guard isPanelVisible != oldValue else { return }
            startPolling(immediate: isPanelVisible)
        }
    }

    static let hideSystemDefaultsKey = "hideSystemProcesses"

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<RefreshResult, Never>?
    private let discovery: Discovery
    private let pollingEnabled: Bool
    private static let activeInterval: Duration = .milliseconds(2500)
    private static let idleInterval: Duration = .seconds(20)

    private static let systemProcessNames: Set<String> = [
        "launchd", "rapportd", "controlcenter", "sharingd",
        "identityservice", "syspolicyd", "mdnsresponder", "configd",
        "airplayxpchelper", "remoted", "bluetoothd"
    ]

    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        startPolling: Bool = true,
        discovery: @escaping Discovery = { try await PortDiscovery.discover() }
    ) {
        self.defaults = defaults
        self.discovery = discovery
        pollingEnabled = startPolling
        hideSystemProcesses = defaults.object(forKey: Self.hideSystemDefaultsKey) as? Bool ?? true
        self.startPolling(immediate: true)
    }

    // MARK: - Polling

    private var pollingInterval: Duration {
        isPanelVisible ? Self.activeInterval : Self.idleInterval
    }

    private func startPolling(immediate: Bool) {
        guard pollingEnabled else { return }
        pollTask?.cancel()

        pollTask = Task { [weak self] in
            var shouldScan = immediate
            while !Task.isCancelled {
                if shouldScan { await self?.refresh() }
                shouldScan = true

                // Do not keep the scanner alive across the polling sleep.
                guard let interval = self?.pollingInterval else { return }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    /// Every caller waits for a real result, including callers that arrive
    /// during a scan. Cancelling one waiter does not cancel discovery needed
    /// by the other waiters or by polling.
    @discardableResult
    func refresh() async -> RefreshResult {
        guard !Task.isCancelled else { return .cancelled }
        let task = scanTask ?? beginScan()
        let result = await task.value
        return Task.isCancelled ? .cancelled : result
    }

    private func beginScan() -> Task<RefreshResult, Never> {
        isRefreshing = true
        let discovery = discovery
        let task = Task { [weak self] in
            let result: RefreshResult
            do {
                let discovered = try await discovery()
                try Task.checkCancellation()
                result = .success(discovered)
            } catch is CancellationError {
                result = .cancelled
            } catch {
                self?.discoveryErrorMessage = error.localizedDescription
                result = .failure
            }

            self?.finishScan(result)
            return result
        }
        scanTask = task
        return task
    }

    private func finishScan(_ result: RefreshResult) {
        switch result {
        case .success(let discovered):
            servers = discovered
            AppIconCache.prune(keeping: discovered)
            applyFilters()
            lastUpdated = Date()
            discoveryErrorMessage = nil
            isDiscoveryTrusted = true
        case .failure, .cancelled:
            // Retain the last good list and timestamp, but never treat a failed
            // or cancelled observation as evidence that a process is gone.
            isDiscoveryTrusted = false
        }
        // Action errors belong to the action that failed, not to this scan.
        scanTask = nil
        isRefreshing = false
    }

    /// Confirm disappearance using a scan launched after this method is called.
    /// An older in-flight scan may have observed the process before SIGTERM;
    /// wait for it, then perform at least one post-action scan. Only completed
    /// post-action scans count toward the retry limit.
    @discardableResult
    func refreshUntilGone(pid: Int32, identity: ProcessIdentity? = nil, attempts: Int = 6) async -> ProcessRefreshResult {
        guard !Task.isCancelled else { return .cancelled }
        if let priorScan = scanTask {
            _ = await priorScan.value
            guard !Task.isCancelled else { return .cancelled }
        }

        for attempt in 0..<max(1, attempts) {
            if attempt > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return .cancelled
                }
            }
            switch await refresh() {
            case .success(let discovered):
                let candidates = discovered.filter { $0.pid == pid }
                if candidates.isEmpty { return .noLongerListening }
                if let identity {
                    // A reused PID is not the process the user confirmed. An
                    // unreadable identity cannot prove either outcome.
                    guard candidates.allSatisfy({ $0.processIdentity != nil }) else {
                        return .discoveryFailed
                    }
                    if !candidates.contains(where: { $0.processIdentity == identity }) {
                        return .noLongerListening
                    }
                }
            case .failure:
                return .discoveryFailed
            case .cancelled:
                return .cancelled
            }
        }
        return .stillListening
    }

    /// The action layer must still revalidate identity immediately before
    /// signaling. This guard prevents offering termination for stale UI rows.
    func canTerminate(_ server: ListeningServer) -> Bool {
        isDiscoveryTrusted && !isRefreshing && server.processIdentity != nil
            && servers.contains(server)
    }

    func report(_ message: String) {
        actionErrorMessage = message
    }

    func dismissActionError() {
        actionErrorMessage = nil
    }

    func dismissDiscoveryError() {
        discoveryErrorMessage = nil
    }

    // MARK: - Filtering

    private func applyFilters() {
        let needle = query.lowercased()

        filteredServers = servers.filter { server in
            if hideSystemProcesses && Self.isSystemProcess(server) { return false }
            if !needle.isEmpty && !server.searchHaystack.contains(needle) { return false }
            return true
        }
    }

    private static func isSystemProcess(_ server: ListeningServer) -> Bool {
        let name = server.processName.lowercased()
        if systemProcessNames.contains(where: { name.hasPrefix($0) }) { return true }
        if let path = server.executablePath {
            if path.hasPrefix("/System/") { return true }
            if path.hasPrefix("/usr/libexec/") { return true }
        }
        return false
    }
}
