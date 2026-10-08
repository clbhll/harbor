import AppKit
import Darwin
import Foundation

enum PortActions {
    static func openInBrowser(_ server: ListeningServer) {
        guard let url = server.openURL else { return }
        NSWorkspace.shared.open(url)
    }

    static func copyURL(_ server: ListeningServer) {
        guard let url = server.openURL else { return }
        copy(url.absoluteString)
    }

    static func copyPort(_ server: ListeningServer) {
        copy(String(server.port))
    }

    static func revealInFinder(_ server: ListeningServer) {
        guard let path = server.executablePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    enum TerminationOutcome: Equatable {
        case succeeded
        case failed(reason: String)
    }

    /// Revalidate the row at the last possible moment. Failed discovery,
    /// unreadable identity and reused PIDs must never turn into a blind signal.
    /// Public macOS kill(2) is PID-based, so this is a best-effort check rather
    /// than an atomic compare-and-signal; do not defer work between these calls.
    static func terminate(
        _ server: ListeningServer,
        controller: any ProcessControlling = LiveProcessController()
    ) -> TerminationOutcome {
        guard server.pid > 1, server.pid != getpid(),
              let expected = server.processIdentity, expected.pid == server.pid else {
            return .failed(reason: "Cannot verify \(server.displayName) (pid \(server.pid)). Refresh before trying again.")
        }
        guard let current = controller.identity(for: server.pid), current == expected else {
            return .failed(reason: "The process for \(server.displayName) (pid \(server.pid)) changed or is no longer verifiable. No signal was sent.")
        }
        guard let code = controller.sendTerminationSignal(to: server.pid) else { return .succeeded }
        let reason = switch code {
        case EPERM: "Not permitted to terminate \(server.displayName) (pid \(server.pid))."
        case ESRCH: "\(server.displayName) (pid \(server.pid)) is no longer running."
        default: "Couldn't terminate \(server.displayName) (pid \(server.pid))."
        }
        return .failed(reason: reason)
    }

    private static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}


/// The test seam never needs to call kill(2) or inspect a live user process.
protocol ProcessControlling {
    func identity(for pid: Int32) -> ProcessIdentity?
    /// nil means success; otherwise return errno captured at the syscall.
    func sendTerminationSignal(to pid: Int32) -> Int32?
}

struct LiveProcessController: ProcessControlling {
    func identity(for pid: Int32) -> ProcessIdentity? {
        ProcessIdentity.read(for: pid)
    }

    func sendTerminationSignal(to pid: Int32) -> Int32? {
        if kill(pid, SIGTERM) == 0 { return nil }
        return errno
    }
}
