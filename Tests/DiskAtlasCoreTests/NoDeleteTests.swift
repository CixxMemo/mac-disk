import XCTest

/// Kalıcı silme çağrıları yalnızca `ReportStore` içinde (uygulamanın kendi tarama kaydı) bulunabilir.
final class NoDeleteTests: XCTestCase {
    func testNoPermanentDeletionOutsideReportStore() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let forbidden = ["removeItem(", "unlink(", "rmdir(", ".remove(", "removeItems(", "FileManager.default.remove"]
        var checked = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            checked += 1
            if url.lastPathComponent == "ReportStore.swift" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for word in forbidden {
                XCTAssertFalse(text.contains(word), "\(url.lastPathComponent) içinde yasaklı çağrı: \(word)")
            }
        }
        XCTAssertGreaterThan(checked, 10, "Sources klasörü bulunamadı")
    }
}
