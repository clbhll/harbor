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

    enum TerminationOutcome {
        case succeeded
        case failed(reason: String)
    }

    /// Sends SIGTERM directly rather than shelling out to `/bin/kill` and blocking
    /// the main thread on `waitUntilExit`. `errno` is captured at the syscall and
    /// handed back as a value, so callers don't have to know not to disturb it.
    static func terminate(_ server: ListeningServer) -> TerminationOutcome {
        guard kill(server.pid, SIGTERM) != 0 else { return .succeeded }

        let code = errno
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
