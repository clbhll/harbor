import Foundation
import AppKit

enum PortActions {
    static func openInBrowser(_ server: ListeningServer) {
        guard let url = server.openURLCandidates.first else { return }
        NSWorkspace.shared.open(url)
    }

    static func copyURL(_ server: ListeningServer) {
        guard let url = server.openURLCandidates.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    static func copyPort(_ server: ListeningServer) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(server.port), forType: .string)
    }

    static func revealInFinder(_ server: ListeningServer) {
        guard let path = server.executablePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @discardableResult
    static func terminate(_ server: ListeningServer) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = ["-TERM", String(server.pid)]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
