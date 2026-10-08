import Foundation

struct ListeningServer: Identifiable, Hashable, Sendable {
    let id: String
    let pid: Int32
    let processName: String
    let port: Int
    let address: String
    let executablePath: String?
    let commandLine: String?
    let processIdentity: ProcessIdentity?

    /// Lowercased blob used for search. Built once per scan, on the background
    /// queue that produced the server, rather than once per keystroke per row.
    let searchHaystack: String

    init(
        id: String,
        pid: Int32,
        processName: String,
        port: Int,
        address: String,
        executablePath: String?,
        commandLine: String?,
        processIdentity: ProcessIdentity? = nil
    ) {
        self.id = id
        self.pid = pid
        self.processName = processName
        self.port = port
        self.address = address
        self.executablePath = executablePath
        self.commandLine = commandLine
        self.processIdentity = processIdentity
        self.searchHaystack = "\(processName) \(port) \(address) \(pid) \(commandLine ?? "")"
            .lowercased()
    }

    var displayName: String {
        let base = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return "Unknown" }
        return base
    }

    /// Where a click takes you. Everything Harbor lists is bound locally, so
    /// `localhost` is reachable regardless of the advertised bind address.
    var openURL: URL? {
        URL(string: "http://localhost:\(port)")
    }

    var addressLabel: String {
        switch address {
        case "*", "0.0.0.0", "::", "::0":
            return "all interfaces"
        case "127.0.0.1", "::1", "localhost":
            return "localhost"
        default:
            return address
        }
    }
}

