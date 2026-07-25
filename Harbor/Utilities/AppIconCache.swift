import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Icon lookup is a synchronous IconServices + disk round-trip. It used to run
/// inside `ServerRowView.body`, so it re-ran on every hover in and out and on
/// every row rebuild. Icons for a given binary don't change while we're open,
/// so resolve once and hand back the same `NSImage`.
@MainActor
enum AppIconCache {
    private static var cache: [Key: NSImage] = [:]

    private struct Key: Hashable {
        let path: String
        let size: CGFloat
    }

    static func icon(forExecutableAt path: String?, size: CGFloat) -> NSImage {
        let key = Key(path: path ?? "", size: size)
        if let cached = cache[key] { return cached }

        let image = resized(resolve(path), size: size)
        cache[key] = image
        return image
    }

    /// Frees icons for executables that are no longer listening.
    static func retain(pathsIn servers: [ListeningServer]) {
        var live = Set(servers.map { $0.executablePath ?? "" })
        live.insert("")  // the generic fallback is always worth keeping
        cache = cache.filter { live.contains($0.key.path) }
    }

    private static func resolve(_ path: String?) -> NSImage {
        guard let path, FileManager.default.fileExists(atPath: path) else {
            return NSWorkspace.shared.icon(for: .unixExecutable)
        }

        if let bundle = Bundle(path: path), bundle.bundleIdentifier != nil {
            return NSWorkspace.shared.icon(forFile: path)
        }

        if let app = BundlePath.enclosingApp(for: path) {
            return NSWorkspace.shared.icon(forFile: app.path)
        }

        return NSWorkspace.shared.icon(forFile: path)
    }

    private static func resized(_ image: NSImage, size: CGFloat) -> NSImage {
        let target = NSSize(width: size, height: size)
        return NSImage(size: target, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }
}
