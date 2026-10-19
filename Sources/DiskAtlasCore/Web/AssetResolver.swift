import Foundation

public struct Asset: Sendable, Equatable {
    public var url: URL
    public var mimeType: String
}

/// Uygulama paketindeki arayüz dosyalarını URL yolundan çözer. Yalnızca `root` altındaki, gizli olmayan
/// düz dosyalar sunulur; `..`, sembolik bağlantıyla dışarı çıkış ve klasörler reddedilir.
public struct AssetResolver: Sendable {
    private let root: URL
    private static let mimeTypes = [
        "html": "text/html", "css": "text/css", "js": "text/javascript", "json": "application/json",
        "svg": "image/svg+xml", "png": "image/png", "woff2": "font/woff2",
    ]

    public init(root: URL) {
        self.root = root.resolvingSymlinksInPath()
    }

    public func resolve(path: String) -> Asset? {
        let relative = (path.isEmpty || path == "/") ? "index.html" : String(path.dropFirst(path.hasPrefix("/") ? 1 : 0))
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { return nil }
        let candidate = parts.reduce(root) { $0.appendingPathComponent(String($1)) }.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        let mime = Self.mimeTypes[candidate.pathExtension.lowercased()] ?? "application/octet-stream"
        return Asset(url: candidate, mimeType: mime)
    }
}
