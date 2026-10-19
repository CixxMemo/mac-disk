import XCTest

/// Kalıcı silme/yeniden adlandırma çağrıları yalnızca izin verilen dosyalarda bulunabilir:
/// `Store/ReportStore.swift` (uygulamanın kendi tarama kaydı) ve `Cleanup/TrashService.swift` (`trashItem`, test klasörüne `moveItem`).
final class NoDeleteTests: XCTestCase {
    func testNoPermanentDeletionOutsideAllowedFiles() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let forbidden = ["removeItem(", "removeItems(", "unlink(", "unlinkat(", "rmdir(", ".remove(", "removefile(", "replaceItem",
                         "rename(", "renameat(", "renamex_np(", "FileManager.default.remove"]
        let bareRemove = try NSRegularExpression(pattern: #"(?<![A-Za-z_.])remove\("#)
        let bareMove = try NSRegularExpression(pattern: #"(?<![A-Za-z_])moveItem\("#)
        var checked = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            checked += 1
            let relative = String(url.path.dropFirst(sources.path.count + 1))
            let text = try String(contentsOf: url, encoding: .utf8)
            if relative != "DiskAtlasCore/Store/ReportStore.swift" {
                for word in forbidden { XCTAssertFalse(text.contains(word), "\(relative) içinde yasaklı çağrı: \(word)") }
                XCTAssertNil(bareRemove.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "\(relative) içinde remove(")
            }
            if relative != "DiskAtlasCore/Cleanup/TrashService.swift" {
                XCTAssertFalse(text.contains("trashItem("), "\(relative) içinde trashItem")
                XCTAssertNil(bareMove.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "\(relative) içinde moveItem")
            }
        }
        XCTAssertGreaterThan(checked, 10, "Sources klasörü bulunamadı")
    }
}
