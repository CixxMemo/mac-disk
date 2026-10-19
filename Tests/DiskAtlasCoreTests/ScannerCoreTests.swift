import XCTest
import Darwin
@testable import DiskAtlasCore

final class ScannerCoreTests: XCTestCase {
    private func scan(_ tree: TempTree, excluded: [String] = []) throws -> Report {
        let options = ScanOptions(root: tree.path(), excludedPaths: excluded)
        return try DiskScanner(options: options, classifier: try TestSupport.classifier()).run()
    }

    private func scanFake(_ fake: FakeFileSystem, root: String = "/r") throws -> Report {
        try DiskScanner(options: ScanOptions(root: root), classifier: try TestSupport.classifier(), fileSystem: fake).run()
    }

    func testSumsAllocatedAndLogicalSizes() throws {
        let tree = try TempTree()
        let a = try tree.file("a.bin", size: 5000)
        let c = try tree.file("b/c.bin", size: 10000)
        let report = try scan(tree)
        XCTAssertEqual(report.tree.bytes, TestSupport.allocated(a) + TestSupport.allocated(c))
        XCTAssertEqual(report.tree.logical, 15000)
        XCTAssertEqual(report.stats.files, 2)
        XCTAssertEqual(report.stats.folders, 2)
    }

    func testCategoriesFollowFolderNames() throws {
        let tree = try TempTree()
        let x = try tree.file("node_modules/x.bin", size: 3000)
        let y = try tree.file("y.txt", size: 3000)
        let report = try scan(tree)
        XCTAssertEqual(report.categories["dependencies"], TestSupport.allocated(x))
        XCTAssertEqual(report.categories["personal"], TestSupport.allocated(y))
    }

    func testSymlinksAreCountedButNotFollowed() throws {
        let tree = try TempTree()
        let target = try tree.file("target.bin", size: 4000)
        try tree.symlink("link", to: target)
        let report = try scan(tree)
        XCTAssertEqual(report.stats.symlinks, 1)
        XCTAssertEqual(report.tree.bytes, TestSupport.allocated(target))
    }

    func testHardlinkCountedOnce() throws {
        let tree = try TempTree()
        let first = try tree.file("f1.bin", size: 4000)
        try tree.hardlink("f2.bin", to: first)
        let report = try scan(tree)
        XCTAssertEqual(report.tree.bytes, TestSupport.allocated(first))
        XCTAssertEqual(report.stats.hardlinkRepeats, 1)
        XCTAssertEqual(report.stats.files, 2)
    }

    func testUnreadableDirectoryRecordedAndScanContinues() throws {
        let tree = try TempTree()
        let ok = try tree.file("ok.bin", size: 4000)
        try tree.file("locked/hidden.bin", size: 4000)
        XCTAssertEqual(chmod(tree.path("locked"), 0o000), 0)
        defer { chmod(tree.path("locked"), 0o755) }
        let report = try scan(tree)
        XCTAssertEqual(report.stats.errors, 1)
        XCTAssertEqual(report.errors.first?.path, tree.path("locked"))
        XCTAssertEqual(report.tree.bytes, TestSupport.allocated(ok))
    }

    func testRootMissingThrowsRootUnreadable() throws {
        let options = ScanOptions(root: "/nonexistent-\(UUID().uuidString)")
        let scanner = DiskScanner(options: options, classifier: try TestSupport.classifier())
        XCTAssertThrowsError(try scanner.run()) { error in
            XCTAssertEqual(error as? ScanFailure, .rootUnreadable(options.root))
        }
    }

    func testUnreadableRootThrowsRootUnreadable() throws {
        let tree = try TempTree()
        try tree.file("a.bin", size: 100)
        XCTAssertEqual(chmod(tree.path(), 0o000), 0)
        defer { chmod(tree.path(), 0o755) }
        XCTAssertThrowsError(try scan(tree)) { error in
            XCTAssertEqual(error as? ScanFailure, .rootUnreadable(tree.path()))
        }
    }

    func testOddFilenamesDoNotCrash() throws {
        let tree = try TempTree()
        let names = ["cafe\u{301}.txt", "with space.txt", "new\nline.txt", "emoji-\u{1F600}.txt"]
        for name in names { try tree.file(name, size: 100) }
        let report = try scan(tree)
        XCTAssertEqual(Set(report.tree.children?.map(\.name) ?? []), Set(names))
        XCTAssertEqual(report.stats.files, names.count)
        XCTAssertEqual(report.stats.errors, 0)
    }

    func testVanishingEntryIsAnErrorNotACrash() throws {
        let fake = FakeFileSystem()
        fake.addDir("/r", children: ["gone", "ok"])
        fake.addFile("/r/ok")
        let report = try scanFake(fake)
        XCTAssertEqual(report.stats.errors, 1)
        XCTAssertEqual(report.errors.first?.path, "/r/gone")
        XCTAssertEqual(report.tree.bytes, 8 * 512)
    }

    func testDatalessDirectoryIsNotEnumerated() throws {
        let fake = FakeFileSystem()
        fake.addDir("/r", children: ["cloud"])
        fake.addDir("/r/cloud", children: ["secret"], dataless: true)
        fake.addFile("/r/cloud/secret")
        let report = try scanFake(fake)
        XCTAssertFalse(fake.listed.contains("/r/cloud"))
        XCTAssertEqual(report.stats.cloudPlaceholders, 1)
        XCTAssertEqual(report.errors.first?.reason, "Bulut klasörü: içerik indirmemek için alt öğeler taranmadı.")
    }

    func testOtherDeviceIsSkipped() throws {
        let fake = FakeFileSystem()
        fake.addDir("/r", children: ["vol"])
        fake.addDir("/r/vol", children: ["f"], device: 2)
        fake.addFile("/r/vol/f", device: 2)
        let report = try scanFake(fake)
        XCTAssertEqual(report.stats.otherMounts, 1)
        XCTAssertEqual(report.tree.bytes, 0)
    }

    func testExcludedPathsAreSkipped() throws {
        let tree = try TempTree()
        let keep = try tree.file("keep/a.bin", size: 4000)
        try tree.file("reports/b.bin", size: 4000)
        let report = try scan(tree, excluded: [tree.path("reports")])
        XCTAssertEqual(report.tree.bytes, TestSupport.allocated(keep))
    }
}
