import XCTest
@testable import DiskAtlasCore

final class AssetResolverTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("diskatlas-assets-\(UUID().uuidString)")
        root = base.appendingPathComponent("web")
        outside = base.appendingPathComponent("secret")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        for name in ["index.html", "app.css", "app.js", "sub/data.json", "logo.svg", "x.png", "f.woff2", "blob.xyz", ".hidden"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("passwd"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("evil"), withDestinationURL: outside)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func testResolveServesIndexAndAssets() throws {
        let resolver = AssetResolver(root: root)
        XCTAssertEqual(resolver.resolve(path: "/")?.url.lastPathComponent, "index.html")
        XCTAssertEqual(resolver.resolve(path: "")?.url.lastPathComponent, "index.html")
        XCTAssertEqual(resolver.resolve(path: "/app.js")?.url.lastPathComponent, "app.js")
        XCTAssertEqual(resolver.resolve(path: "/sub/data.json")?.url.lastPathComponent, "data.json")
    }

    func testResolveRejectsTraversalHiddenDirectoriesAndMissing() throws {
        let resolver = AssetResolver(root: root)
        for bad in ["/../secret/passwd", "/sub/../../secret/passwd", "/.hidden", "/missing.js", "/sub", "/./app.js", "//app.js", "/sub/"] {
            XCTAssertNil(resolver.resolve(path: bad), bad)
        }
    }

    func testResolveRejectsSymlinkEscape() throws {
        XCTAssertNil(AssetResolver(root: root).resolve(path: "/evil/passwd"))
    }

    func testResolveMimeTypes() throws {
        let resolver = AssetResolver(root: root)
        let expected = ["/": "text/html", "/app.css": "text/css", "/app.js": "text/javascript", "/sub/data.json": "application/json",
                        "/logo.svg": "image/svg+xml", "/x.png": "image/png", "/f.woff2": "font/woff2", "/blob.xyz": "application/octet-stream"]
        for (path, mime) in expected {
            XCTAssertEqual(resolver.resolve(path: path)?.mimeType, mime, path)
        }
    }
}
