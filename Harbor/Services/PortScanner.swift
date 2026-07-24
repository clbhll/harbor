import Foundation
import Combine
import Darwin
import SwiftUI

@MainActor
final class PortScanner: ObservableObject {
    @Published private(set) var servers: [ListeningServer] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published var query: String = ""
    @Published var hideSystemProcesses = true

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 2.5

    private static let systemProcessNames: Set<String> = [
        "launchd", "rapportd", "ControlCe", "ControlCenter", "sharingd",
        "identityservice", "syspolicyd", "mDNSResponder", "configd",
        "AirPlayXPCHelper", "remoted", "bluetoothd"
    ]

    var filteredServers: [ListeningServer] {
        servers.filter { server in
            if hideSystemProcesses {
                let name = server.processName.lowercased()
                if Self.systemProcessNames.contains(where: { name.hasPrefix($0.lowercased()) }) {
                    return false
                }
                if server.executablePath?.hasPrefix("/System/") == true {
                    return false
                }
                if server.executablePath?.hasPrefix("/usr/libexec/") == true {
                    return false
                }
            }

            if !query.isEmpty {
                let q = query.lowercased()
                let haystack = "\(server.displayName) \(server.port) \(server.address) \(server.pid) \(server.commandLine ?? "")"
                    .lowercased()
                if !haystack.contains(q) { return false }
            }
            return true
        }
    }

    init() {
        Task { await refresh() }
        startPolling()
    }

    deinit {
        timer?.invalidate()
    }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
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
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                servers = discovered
            }
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum PortDiscovery {
    static func discover() throws -> [ListeningServer] {
        let output = try run("/usr/sbin/lsof", arguments: [
            "-nP",
            "-iTCP",
            "-sTCP:LISTEN",
            "-Fpcn"
        ])
        return parseLsof(output)
    }

    private static func parseLsof(_ output: String) -> [ListeningServer] {
        var currentPID: Int32?
        var currentName: String?
        var servers: [ListeningServer] = []
        var seen = Set<String>()

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
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
                    let endpoint = parseEndpoint(value)
                else { continue }

                if name == "Harbor" { continue }

                let id = "\(pid)-\(endpoint.address)-\(endpoint.port)"
                guard seen.insert(id).inserted else { continue }

                let path = executablePath(for: pid)
                let command = commandLine(for: pid)

                servers.append(
                    ListeningServer(
                        id: id,
                        pid: pid,
                        processName: friendlyName(processName: name, path: path, command: command),
                        port: endpoint.port,
                        address: endpoint.address,
                        executablePath: path,
                        commandLine: command
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

    private static func parseEndpoint(_ raw: String) -> (address: String, port: Int)? {
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
        guard let port = Int(cleaned[cleaned.index(after: colon)...]) else { return nil }
        return (address, port)
    }

    private static func friendlyName(processName: String, path: String?, command: String?) -> String {
        if let path,
           let appURL = enclosingApp(for: path),
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

    private static func enclosingApp(for path: String) -> URL? {
        var url = URL(fileURLWithPath: path)
        for _ in 0..<8 {
            if url.pathExtension == "app" { return url }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }

    private static func executablePath(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func commandLine(for pid: Int32) -> String? {
        var argMax: Int32 = 0
        var sizeOf = MemoryLayout<Int32>.size
        sysctlbyname("kern.argmax", &argMax, &sizeOf, nil, 0)
        guard argMax > 0 else { return nil }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        var bufferSize = buffer.count

        let result = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, UInt32(mib.count), raw.baseAddress, &bufferSize, nil, 0)
        }
        guard result == 0, bufferSize > MemoryLayout<Int32>.size else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        while index < bufferSize && buffer[index] != 0 { index += 1 }
        while index < bufferSize && buffer[index] == 0 { index += 1 }

        var args: [String] = []
        for _ in 0..<argc {
            guard index < bufferSize else { break }
            var end = index
            while end < bufferSize && buffer[end] != 0 { end += 1 }
            if end > index {
                let slice = buffer[index..<end]
                if let str = String(bytes: slice, encoding: .utf8) {
                    args.append(str)
                }
            }
            index = end + 1
            while index < bufferSize && buffer[index] == 0 { index += 1 }
        }

        return args.isEmpty ? nil : args.joined(separator: " ")
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
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

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
