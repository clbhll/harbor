import Darwin
import Foundation
import Testing

@testable import Harbor

/// Returns canned details so parsing can be exercised without live pids.
private struct StubInspector: ProcessInspecting {
    var byPID: [Int32: ProcessDetails] = [:]
    var fallback: ProcessDetails = .unknown

    func details(for pid: Int32) -> ProcessDetails {
        byPID[pid] ?? fallback
    }
}

/// Counts how many times a pid was looked up, to prove we don't re-read argv
/// for a process that holds several listening sockets.
private final class CountingInspector: ProcessInspecting, @unchecked Sendable {
    private(set) var lookups: [Int32: Int] = [:]

    func details(for pid: Int32) -> ProcessDetails {
        lookups[pid, default: 0] += 1
        return .unknown
    }
}

@Suite("lsof field parsing")
struct ParseLsofTests {

    @Test("Parses a single listening socket")
    func singleSocket() {
        let output = """
        p4242
        cnode
        f13
        n*:3000
        """

        let servers = PortDiscovery.parseLsof(output, inspector: StubInspector())

        #expect(servers.count == 1)
        #expect(servers[0].pid == 4242)
        #expect(servers[0].port == 3000)
        #expect(servers[0].address == "*")
        #expect(servers[0].processName == "node")
    }

    @Test("Command name persists across several sockets for one process")
    func commandCarriesAcrossSockets() {
        let output = """
        p1022
        cControlCenter
        f10
        n*:7000
        f12
        n*:5000
        """

        let servers = PortDiscovery.parseLsof(output, inspector: StubInspector())

        #expect(servers.count == 2)
        #expect(servers.allSatisfy { $0.processName == "ControlCenter" })
        #expect(Set(servers.map(\.port)) == [5000, 7000])
    }

    @Test("Collapses duplicate fds on the same endpoint")
    func dedupesRepeatedEndpoint() {
        // rapportd really does report the same endpoint on two descriptors.
        let output = """
        p940
        crapportd
        f11
        n*:63313
        f18
        n*:63313
        """

        let servers = PortDiscovery.parseLsof(output, inspector: StubInspector())

        #expect(servers.count == 1)
        #expect(servers[0].port == 63313)
    }

    @Test("Keeps IPv4 and IPv6 rows for the same port distinct")
    func keepsDistinctAddresses() {
        let output = """
        p500
        cnode
        f3
        n127.0.0.1:8080
        f4
        n[::1]:8080
        """

        let servers = PortDiscovery.parseLsof(output, inspector: StubInspector())

        #expect(servers.count == 2)
        #expect(Set(servers.map(\.address)) == ["127.0.0.1", "::1"])
    }

    @Test("Looks up process details once per pid, not once per socket")
    func inspectsEachPIDOnce() {
        let output = """
        p77
        cnode
        f3
        n*:3000
        f4
        n*:3001
        f5
        n*:3002
        """

        let inspector = CountingInspector()
        let servers = PortDiscovery.parseLsof(output, inspector: inspector)

        #expect(servers.count == 3)
        #expect(inspector.lookups[77] == 1)
    }

    @Test("Excludes Harbor's own process")
    func excludesSelf() {
        let output = """
        p\(getpid())
        cHarbor
        f9
        n*:9999
        p777
        cnode
        f3
        n*:3000
        """

        let servers = PortDiscovery.parseLsof(output, inspector: StubInspector())

        #expect(servers.count == 1)
        #expect(servers[0].pid == 777)
    }

    @Test("Sorts by port, then by name")
    func sortsByPortThenName() {
        let output = """
        p1
        czeta
        f1
        n*:8080
        p2
        calpha
        f1
        n*:8080
        p3
        cmiddle
        f1
        n*:80
        """

        let servers = PortDiscovery.parseLsof(output, inspector: StubInspector())

        #expect(servers.map(\.port) == [80, 8080, 8080])
        #expect(servers.map(\.processName) == ["middle", "alpha", "zeta"])
    }

    @Test("Ignores name lines with no preceding pid or command")
    func ignoresOrphanNameLines() {
        let output = """
        n*:1234
        f3
        p900
        n*:5678
        """

        let servers = PortDiscovery.parseLsof(output, inspector: StubInspector())

        // The first has no pid; the second has a pid but no command yet.
        #expect(servers.isEmpty)
    }

    @Test("Carries inspector details onto the server")
    func attachesProcessDetails() {
        let output = """
        p31
        cpython3
        f3
        n*:5000
        """

        let inspector = StubInspector(byPID: [
            31: ProcessDetails(
                executablePath: "/usr/bin/python3",
                commandLine: "/usr/bin/python3 /Users/me/serve.py"
            )
        ])

        let servers = PortDiscovery.parseLsof(output, inspector: inspector)

        #expect(servers.count == 1)
        #expect(servers[0].executablePath == "/usr/bin/python3")
        #expect(servers[0].commandLine == "/usr/bin/python3 /Users/me/serve.py")
    }

    @Test("Tolerates empty output")
    func emptyOutput() {
        #expect(PortDiscovery.parseLsof("", inspector: StubInspector()).isEmpty)
    }
}

@Suite("Endpoint parsing")
struct ParseEndpointTests {

    @Test("Wildcard address")
    func wildcard() throws {
        let endpoint = try #require(PortDiscovery.parseEndpoint("*:3000"))
        #expect(endpoint.address == "*")
        #expect(endpoint.port == 3000)
    }

    @Test("IPv4 address")
    func ipv4() throws {
        let endpoint = try #require(PortDiscovery.parseEndpoint("127.0.0.1:8080"))
        #expect(endpoint.address == "127.0.0.1")
        #expect(endpoint.port == 8080)
    }

    @Test("Bracketed IPv6 address")
    func ipv6() throws {
        let endpoint = try #require(PortDiscovery.parseEndpoint("[::1]:8080"))
        #expect(endpoint.address == "::1")
        #expect(endpoint.port == 8080)
    }

    @Test("Bracketed IPv6 wildcard")
    func ipv6Wildcard() throws {
        let endpoint = try #require(PortDiscovery.parseEndpoint("[::]:443"))
        #expect(endpoint.address == "::")
        #expect(endpoint.port == 443)
    }

    @Test("Drops the peer half of a connected socket")
    func stripsPeer() throws {
        let endpoint = try #require(PortDiscovery.parseEndpoint("127.0.0.1:8080->127.0.0.1:52341"))
        #expect(endpoint.address == "127.0.0.1")
        #expect(endpoint.port == 8080)
    }

    @Test("Rejects malformed input", arguments: [
        "",
        "no-colon-here",
        "127.0.0.1:",
        "127.0.0.1:notaport",
        ":8080",
        "[::1",
        "[::1]8080"
    ])
    func rejectsMalformed(_ raw: String) {
        #expect(PortDiscovery.parseEndpoint(raw) == nil)
    }
}

@Suite("Friendly process names")
struct FriendlyNameTests {

    @Test("Names a node process after its script")
    func nodeScript() {
        let name = PortDiscovery.friendlyName(
            processName: "node",
            path: nil,
            command: "/usr/local/bin/node /Users/me/app/server.js"
        )
        #expect(name == "node · server.js")
    }

    @Test("Names a python process after its script")
    func pythonScript() {
        let name = PortDiscovery.friendlyName(
            processName: "python3",
            path: nil,
            command: "/usr/bin/python3 /Users/me/app/serve.py"
        )
        #expect(name == "python · serve.py")
    }

    @Test("Ignores a python invocation with no script")
    func pythonWithoutScript() {
        let name = PortDiscovery.friendlyName(
            processName: "python3",
            path: nil,
            command: "/usr/bin/python3 -m http.server"
        )
        #expect(name == "python3")
    }

    @Test("Falls back to the lsof command name")
    func fallsBack() {
        #expect(PortDiscovery.friendlyName(processName: "postgres", path: nil, command: nil) == "postgres")
        #expect(PortDiscovery.friendlyName(processName: "redis-server", path: nil, command: "") == "redis-server")
    }
}

@Suite("ListeningServer")
struct ListeningServerTests {

    private func server(
        pid: Int32 = 1,
        name: String = "node",
        port: Int = 3000,
        address: String = "*",
        command: String? = nil
    ) -> ListeningServer {
        ListeningServer(
            id: "\(pid)-\(address)-\(port)",
            pid: pid,
            processName: name,
            port: port,
            address: address,
            executablePath: nil,
            commandLine: command
        )
    }

    @Test("Labels wildcard binds", arguments: ["*", "0.0.0.0", "::", "::0"])
    func wildcardLabels(_ address: String) {
        #expect(server(address: address).addressLabel == "all interfaces")
    }

    @Test("Labels loopback binds", arguments: ["127.0.0.1", "::1", "localhost"])
    func loopbackLabels(_ address: String) {
        #expect(server(address: address).addressLabel == "localhost")
    }

    @Test("Passes through other addresses")
    func otherAddress() {
        #expect(server(address: "192.168.1.10").addressLabel == "192.168.1.10")
    }

    @Test("Always opens via localhost")
    func opensLocalhost() {
        #expect(server(port: 5173).openURL?.absoluteString == "http://localhost:5173")
    }

    @Test("Falls back to Unknown for a blank name")
    func blankName() {
        #expect(server(name: "   ").displayName == "Unknown")
    }

    @Test("Search haystack covers name, port, address, pid and command")
    func haystack() {
        let haystack = server(
            pid: 8231,
            name: "Node",
            port: 3000,
            address: "127.0.0.1",
            command: "/usr/bin/node /Users/me/App/Server.js"
        ).searchHaystack

        #expect(haystack.contains("node"))
        #expect(haystack.contains("3000"))
        #expect(haystack.contains("127.0.0.1"))
        #expect(haystack.contains("8231"))
        #expect(haystack.contains("server.js"))
        #expect(haystack == haystack.lowercased())
    }
}

@Suite("Bundle path walking")
struct BundlePathTests {

    @Test("Finds the enclosing app bundle")
    func findsApp() {
        let url = BundlePath.enclosingApp(for: "/Applications/Safari.app/Contents/MacOS/Safari")
        #expect(url?.path == "/Applications/Safari.app")
    }

    @Test("Returns the bundle itself when handed one")
    func returnsBundleItself() {
        #expect(BundlePath.enclosingApp(for: "/Applications/Safari.app")?.path == "/Applications/Safari.app")
    }

    @Test("Returns nil for a plain executable")
    func plainExecutable() {
        #expect(BundlePath.enclosingApp(for: "/usr/local/bin/node") == nil)
    }

    @Test("Gives up before walking to the filesystem root")
    func stopsBeforeRoot() {
        let deep = "/a/b/c/d/e/f/g/h/i/j/k/l/binary"
        #expect(BundlePath.enclosingApp(for: deep) == nil)
    }
}
