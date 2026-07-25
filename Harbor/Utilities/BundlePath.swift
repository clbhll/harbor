import Foundation

enum BundlePath {
    /// How far up from an executable we'll look for the `.app` that contains it.
    /// `Foo.app/Contents/MacOS/Foo` is 3, so 8 leaves room for helpers nested
    /// inside `Contents/Frameworks/…` without walking to the filesystem root.
    private static let maxAncestorDepth = 8

    /// Walks up from an executable path to the `.app` bundle enclosing it, if any.
    static func enclosingApp(for path: String) -> URL? {
        var url = URL(fileURLWithPath: path)
        for _ in 0..<maxAncestorDepth {
            if url.pathExtension == "app" { return url }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }
}
