import AppKit
import UniformTypeIdentifiers

/// Icon lookup is a synchronous IconServices + disk round-trip. It used to run
/// inside `ServerRowView.body`, so it re-ran on every hover in and out and on
/// every row rebuild. Icons for a given binary don't change while we're open,
/// so resolve once and hand back the same `NSImage`.
@MainActor
enum AppIconCache {
    /// Every row draws at the same size; there's no reason to key on it.
    static let size: CGFloat = 32

    /// Pruning only kicks in past this many entries. Evicting on exact
    /// per-scan membership would thrash — a dev server that restarts between
    /// scans would lose its icon and pay the full lookup again the moment it
    /// comes back.
    private static let pruneThreshold = 64

    private static var cache: [String: NSImage] = [:]

    static func icon(forExecutableAt path: String?) -> NSImage {
        let key = path ?? ""
        if let cached = cache[key] { return cached }

        let image = resized(resolve(path))
        cache[key] = image
        return image
    }

    /// Drops icons for executables that are no longer listening, once the cache
    /// has grown enough to be worth the sweep.
    static func prune(keeping servers: [ListeningServer]) {
        guard cache.count > pruneThreshold else { return }

        var live = Set(servers.map { $0.executablePath ?? "" })
        live.insert("")  // the generic fallback is always worth keeping
        cache = cache.filter { live.contains($0.key) }
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

    private static func resized(_ image: NSImage) -> NSImage {
        let target = NSSize(width: size, height: size)
        return NSImage(size: target, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }
}
