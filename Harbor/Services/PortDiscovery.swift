import Darwin
import Foundation

// MARK: - Process inspection

struct ProcessDetails: Sendable {
    var executablePath: String?
    var commandLine: String?

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

    init() {
        buffer = [UInt8](repeating: 0, count: Self.argMax)
    }

    func details(for pid: Int32) -> ProcessDetails {
        ProcessDetails(executablePath: executablePath(for: pid), commandLine: commandLine(for: pid))
    }

    private func executablePath(for pid: Int32) -> String? {
        var path = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let length = path.withUnsafeMutableBytes { raw in
            proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: path.prefix(Int(length)), as: UTF8.self)
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

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return nil }

        // Layout: argc, exec_path, NUL padding, then argc NUL-separated args.
        var index = MemoryLayout<Int32>.size
        while index < bufferSize && buffer[index] != 0 { index += 1 }
        while index < bufferSize && buffer[index] == 0 { index += 1 }

        var args: [String] = []
        for _ in 0..<argc {
            guard index < bufferSize else { break }
            var end = index
            while end < bufferSize && buffer[end] != 0 { end += 1 }
            if end > index, let str = String(bytes: buffer[index..<end], encoding: .utf8) {
                args.append(str)
            }
            index = end + 1
            while index < bufferSize && buffer[index] == 0 { index += 1 }
        }

        return args.isEmpty ? nil : args.joined(separator: " ")
    }
}

// MARK: - Discovery

enum PortDiscovery {
    static func discover() throws -> [ListeningServer] {
        let output = try run("/usr/sbin/lsof", arguments: [
            "-nP",
            "-iTCP",
            "-sTCP:LISTEN",
            "-Fpcn"
        ])
        return parseLsof(output, inspector: LiveProcessInspector())
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
                        commandLine: details.commandLine
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

    private static func run(_ launchPath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Read before waiting — a full pipe buffer would deadlock the child.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // lsof returns 1 when nothing is listening; treat as empty success.
        if process.terminationStatus != 0 && process.terminationStatus != 1 {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DiscoveryError.commandFailed(message ?? "lsof exited \(process.terminationStatus)")
        }

        return String(data: data, encoding: .utf8) ?? ""
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
