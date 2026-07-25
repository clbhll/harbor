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

    /// Sends SIGTERM directly rather than shelling out to `/bin/kill` and blocking
    /// the main thread on `waitUntilExit`. Returns false if the signal was refused
    /// (most often EPERM — the process belongs to another user).
    @discardableResult
    static func terminate(_ server: ListeningServer) -> Bool {
        kill(server.pid, SIGTERM) == 0
    }

    static func terminationFailureMessage(for server: ListeningServer) -> String {
        switch errno {
        case EPERM:
            return "Not permitted to terminate \(server.displayName) (pid \(server.pid))."
        case ESRCH:
            return "\(server.displayName) (pid \(server.pid)) is no longer running."
        default:
            return "Couldn't terminate \(server.displayName) (pid \(server.pid))."
        }
    }

    private static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
