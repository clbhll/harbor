import Darwin
import Foundation

// MARK: - Process inspection

struct ProcessDetails: Sendable {
    var executablePath: String?
    var commandLine: String?
    var identity: ProcessIdentity? = nil

    static let unknown = ProcessDetails(executablePath: nil, commandLine: nil)
}

/// Seam so `PortDiscovery.parseLsof` can be tested without live pids.
protocol ProcessInspecting {
    func details(for pid: Int32) -> ProcessDetails
}

/// Reads `proc_pidpath` and `KERN_PROCARGS2` for a pid.
///
/// `KERN_PROCARGS2` wants a buffer of `kern.argmax` bytes, which is 1 MiB on a
/// stock Mac. This used to be queried and allocated per pid per scan — 30 MiB of
/// churn every 2.5s on a busy machine. `argMax` is a boot constant and the buffer
/// is reused across every pid in a scan, so a scan now allocates it once.
final class LiveProcessInspector: ProcessInspecting {
    private static let argMax: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.argmax", &value, &size, nil, 0) == 0, value > 0 else {
            return 256 * 1024
        }
        return Int(value)
    }()

    private var buffer: [UInt8]
    private let scanStartedAt: Date

    init(scanStartedAt: Date = Date()) {
        self.scanStartedAt = scanStartedAt
        buffer = [UInt8](repeating: 0, count: Self.argMax)
    }

    func details(for pid: Int32) -> ProcessDetails {
        guard let before = ProcessIdentity.read(for: pid), before.predates(scanStartedAt) else {
            return .unknown
        }
        let command = commandLine(for: pid)
        guard ProcessIdentity.read(for: pid) == before else { return .unknown }
        return ProcessDetails(executablePath: before.executablePath, commandLine: command, identity: before)
    }

    /// Returns nil for processes we can't read — non-root can only pull argv for
    /// its own uid, so system daemons legitimately come back empty.
    private func commandLine(for pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var bufferSize = buffer.count

        let result = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, UInt32(mib.count), raw.baseAddress, &bufferSize, nil, 0)
        }
        guard result == 0, bufferSize > MemoryLayout<Int32>.size else { return nil }

        guard let arguments = ProcessArguments.parse(buffer, count: bufferSize) else { return nil }
        return ProcessArguments.display(arguments)
    }
}

// MARK: - Discovery

enum PortDiscovery {
    static func discover() async throws -> [ListeningServer] {
        let startedAt = Date()
        let result = try await CommandRunner.run(launchPath: "/usr/sbin/lsof", arguments: [
            "-nP",
            "-iTCP",
            "-sTCP:LISTEN",
            "-Fpcn"
        ])
        let output = try validatedOutput(result)
        try Task.checkCancellation()
        return parseLsof(output, inspector: LiveProcessInspector(scanStartedAt: startedAt))
    }

    /// Parses `lsof -F` field output. Each record is a set of one-character-tagged
    /// lines: `p` pid, `c` command, `f` fd, `n` name. `p` and `c` persist until the
    /// next occurrence, so a process with several listening sockets emits one `p`/`c`
    /// pair followed by several `f`/`n` pairs.
    static func parseLsof(_ output: String, inspector: ProcessInspecting) -> [ListeningServer] {
        var currentPID: Int32?
        var currentName: String?
        var servers: [ListeningServer] = []
        var seen = Set<String>()
        var detailsByPID: [Int32: ProcessDetails] = [:]
        let ownPID = getpid()

        for line in output.split(whereSeparator: \.isNewline) {
            guard let flag = line.first else { continue }
            let value = String(line.dropFirst())

            switch flag {
            case "p":
                currentPID = Int32(value)
                currentName = nil
            case "c":
                currentName = value
            case "n":
                guard
                    let pid = currentPID,
                    let name = currentName,
                    pid != ownPID,
                    let endpoint = parseEndpoint(value)
                else { continue }

                // A process can hold several fds on one endpoint (IPv4 + IPv6
                // sharing a port is routine); collapse those into one row.
                let id = "\(pid)-\(endpoint.address)-\(endpoint.port)"
                guard seen.insert(id).inserted else { continue }

                let details = detailsByPID[pid] ?? {
                    let looked = inspector.details(for: pid)
                    detailsByPID[pid] = looked
                    return looked
                }()

                servers.append(
                    ListeningServer(
                        id: id,
                        pid: pid,
                        processName: friendlyName(
                            processName: name,
                            path: details.executablePath,
                            command: details.commandLine
                        ),
                        port: endpoint.port,
                        address: endpoint.address,
                        executablePath: details.executablePath,
                        commandLine: details.commandLine,
                        processIdentity: details.identity
                    )
                )
            default:
                continue
            }
        }

        return servers.sorted {
            if $0.port != $1.port { return $0.port < $1.port }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Handles `*:3000`, `127.0.0.1:8080`, and bracketed IPv6 `[::1]:8080`.
    static func parseEndpoint(_ raw: String) -> (address: String, port: Int)? {
        let cleaned = raw.split(separator: "->", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? raw

        if cleaned.hasPrefix("[") {
            guard let close = cleaned.firstIndex(of: "]") else { return nil }
            let address = String(cleaned[cleaned.index(after: cleaned.startIndex)..<close])
            let rest = cleaned[cleaned.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (address, port)
        }

        guard let colon = cleaned.lastIndex(of: ":") else { return nil }
        let address = String(cleaned[..<colon])
        guard !address.isEmpty, let port = Int(cleaned[cleaned.index(after: colon)...]) else { return nil }
        return (address, port)
    }

    /// `lsof` gives us the executable name; we can usually do better — the
    /// enclosing app's display name, or the script a runtime is executing.
    static func friendlyName(processName: String, path: String?, command: String?) -> String {
        if let path,
           let appURL = BundlePath.enclosingApp(for: path),
           let bundle = Bundle(url: appURL) {
            if let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !display.isEmpty {
                return display
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !name.isEmpty {
                return name
            }
        }

        if let command, !command.isEmpty {
            let tokens = command.split(separator: " ").map(String.init)
            if let nodeIdx = tokens.firstIndex(where: { $0.hasSuffix("/node") || $0 == "node" }),
               nodeIdx + 1 < tokens.count {
                let script = URL(fileURLWithPath: tokens[nodeIdx + 1]).lastPathComponent
                if !script.isEmpty && script != "node" {
                    return "node · \(script)"
                }
            }
            if let pythonIdx = tokens.firstIndex(where: { $0.contains("python") }),
               pythonIdx + 1 < tokens.count {
                let script = URL(fileURLWithPath: tokens[pythonIdx + 1]).lastPathComponent
                if script.hasSuffix(".py") {
                    return "python · \(script)"
                }
            }
        }

        return processName
    }

    /// lsof uses status 1 for both an empty match and failures. Diagnostics or
    /// partial output cannot prove an empty scan, even when the status is 0/1.
    static func validatedOutput(_ result: CommandOutput) throws -> String {
        let diagnostic = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.terminationReason == .exit else {
            throw DiscoveryError.commandFailed("Port discovery was interrupted.")
        }
        guard diagnostic.isEmpty else {
            throw DiscoveryError.commandFailed(diagnostic)
        }
        if result.status == 1 && result.stdout.isEmpty { return "" }
        guard result.status == 0 else {
            throw DiscoveryError.commandFailed("lsof exited \(result.status); keeping the last successful scan.")
        }
        guard let output = String(data: result.stdout, encoding: .utf8) else {
            throw DiscoveryError.commandFailed("Port discovery returned unreadable output.")
        }
        return output
    }
}

enum DiscoveryError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        }
    }
}

