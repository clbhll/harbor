import Foundation
import AppKit

struct ListeningServer: Identifiable, Hashable, Sendable {
    let id: String
    let pid: Int32
    let processName: String
    let port: Int
    let address: String
    let executablePath: String?
    let commandLine: String?

    var displayName: String {
        let base = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return "Unknown" }
        return base
    }

    var localhostURL: URL? {
        URL(string: "http://127.0.0.1:\(port)")
    }

    var openURLCandidates: [URL] {
        [
            URL(string: "http://localhost:\(port)"),
            URL(string: "http://127.0.0.1:\(port)"),
            address == "*" || address == "0.0.0.0" || address == "::"
                ? nil
                : URL(string: "http://\(address):\(port)")
        ].compactMap { $0 }
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

    var isLocalOnly: Bool {
        ["127.0.0.1", "::1", "localhost"].contains(address)
    }

    func appIcon(size: CGFloat = 28) -> NSImage {
        let fallback = NSWorkspace.shared.icon(forFileType: "public.unix-executable")
        guard let path = executablePath, FileManager.default.fileExists(atPath: path) else {
            return resized(fallback, size: size)
        }

        if let bundle = Bundle(path: path), bundle.bundleIdentifier != nil {
            return resized(NSWorkspace.shared.icon(forFile: path), size: size)
        }

        var url = URL(fileURLWithPath: path)
        for _ in 0..<6 {
            if url.pathExtension == "app" {
                return resized(NSWorkspace.shared.icon(forFile: url.path), size: size)
            }
            url.deleteLastPathComponent()
        }

        return resized(NSWorkspace.shared.icon(forFile: path), size: size)
    }

    private func resized(_ image: NSImage, size: CGFloat) -> NSImage {
        let target = NSSize(width: size, height: size)
        return NSImage(size: target, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }
}
