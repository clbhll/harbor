import Foundation
import Observation

@MainActor
@Observable
final class PortScanner {
    private(set) var servers: [ListeningServer] = []

    /// Filtering used to be a computed property, which the view then called once
    /// per row to draw separators — an O(n²) sweep that rebuilt a search string
    /// for every server on every pass. It's now recomputed only when one of its
    /// three inputs changes.
    private(set) var filteredServers: [ListeningServer] = []

    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    private(set) var errorMessage: String?

    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            applyFilters()
        }
    }

    var hideSystemProcesses: Bool {
        didSet {
            guard hideSystemProcesses != oldValue else { return }
            UserDefaults.standard.set(hideSystemProcesses, forKey: Self.hideSystemDefaultsKey)
            applyFilters()
        }
    }

    /// The panel is closed almost all of the time, and a scan forks `lsof` and
    /// reads argv for every listening pid. While nobody is looking we only need
    /// the menu bar count to be roughly right, so we back off hard.
    var isPanelVisible = false {
        didSet {
            guard isPanelVisible != oldValue else { return }
            startPolling()
        }
    }

    static let hideSystemDefaultsKey = "hideSystemProcesses"

    private var pollTask: Task<Void, Never>?
    private static let activeInterval: Duration = .milliseconds(2500)
    private static let idleInterval: Duration = .seconds(20)

    private static let systemProcessNames: Set<String> = [
        "launchd", "rapportd", "controlcenter", "sharingd",
        "identityservice", "syspolicyd", "mdnsresponder", "configd",
        "airplayxpchelper", "remoted", "bluetoothd"
    ]

    init(defaults: UserDefaults = .standard) {
        // `object(forKey:)` rather than `bool(forKey:)` so a first launch keeps
        // the intended default of true instead of falling through to false.
        hideSystemProcesses = defaults.object(forKey: Self.hideSystemDefaultsKey) as? Bool ?? true
        startPolling()
    }

    // MARK: - Polling

    /// Deliberately no `deinit`. The old one invalidated a `Timer` from a
    /// nonisolated `deinit` while the property it touched was main-actor
    /// isolated — legal only because the project was in Swift 5 mode. The loop
    /// holds `self` weakly and exits on its own once the scanner goes away.
    private func startPolling() {
        pollTask?.cancel()

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = self.isPanelVisible ? Self.activeInterval : Self.idleInterval
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return  // cancelled
                }
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let discovered = try await Task.detached(priority: .utility) {
                try PortDiscovery.discover()
            }.value

            servers = discovered
            AppIconCache.retain(pathsIn: discovered)
            applyFilters()
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            // Keep the last good list on screen; the view surfaces this as a
            // banner rather than replacing everything with an error state.
            errorMessage = error.localizedDescription
        }
    }

    func report(_ message: String) {
        errorMessage = message
    }

    func dismissError() {
        errorMessage = nil
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
