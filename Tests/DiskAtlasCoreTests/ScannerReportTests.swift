import XCTest
@testable import DiskAtlasCore

final class ScannerReportTests: XCTestCase {
    private func scan(_ tree: TempTree, options: ScanOptions? = nil, isCancelled: @escaping () -> Bool = { false },
                      now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
                      progress: ((ScanProgress) -> Void)? = nil) throws -> Report {
        try DiskScanner(options: options ?? ScanOptions(root: tree.path()), classifier: try TestSupport.classifier(), now: now)
            .run(isCancelled: isCancelled, progress: progress)
    }

    private func scanFake(_ fake: FakeFileSystem, options: ScanOptions = ScanOptions(root: "/r")) throws -> Report {
        try DiskScanner(options: options, classifier: try TestSupport.classifier(), fileSystem: fake).run()
    }

    func testKeepsTop40AndAggregatesRest() throws {
        let tree = try TempTree()
        for i in 0..<45 { try tree.file("many/f\(i).bin", size: 4000) }
        let report = try scan(tree)
        let many = try XCTUnwrap(report.tree.children?.first)
        XCTAssertEqual(many.children?.count, 41)
        XCTAssertEqual(many.children?.last?.aggregate, true)
        XCTAssertEqual(many.children?.last?.name, "Diğer 5 öğe")
        XCTAssertEqual(many.children?.reduce(0) { $0 + $1.bytes }, many.bytes)
    }

    func testDeepTreeSizesAreCompleteBeyondDepth8() throws {
        let tree = try TempTree()
        let leaf = try tree.file((0..<12).map { "d\($0)" }.joined(separator: "/") + "/leaf.bin", size: 4000)
        let report = try scan(tree)
        XCTAssertEqual(report.tree.bytes, TestSupport.allocated(leaf))
        var node = report.tree
        for _ in 0..<8 { node = try XCTUnwrap(node.children?.first) }
        XCTAssertNil(node.children)
    }

    func testVeryDeepTreeDoesNotOverflowStack() throws {
        let tree = try TempTree()
        let leaf = try tree.file(Array(repeating: "d", count: 300).joined(separator: "/") + "/leaf.bin", size: 100)
        let report = try scan(tree)
        XCTAssertEqual(report.tree.bytes, TestSupport.allocated(leaf))
        XCTAssertEqual(report.incomplete, false)
    }

    func testDeepTreeScanSurvivesSmallThreadStack() throws {
        let tree = try TempTree()
        let leaf = try tree.file(Array(repeating: "d", count: 300).joined(separator: "/") + "/leaf.bin", size: 100)
        var result: Result<Report, Error>?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = Result { try DiskScanner(options: ScanOptions(root: tree.path()), classifier: try TestSupport.classifier()).run() }
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
        let report = try XCTUnwrap(result).get()
        XCTAssertEqual(report.tree.bytes, TestSupport.allocated(leaf))
    }

    func testZeroByteChildrenAreNotListed() throws {
        let tree = try TempTree()
        try tree.dir("empty")
        try tree.file("zero.txt", size: 0)
        try tree.file("real.bin", size: 4000)
        let report = try scan(tree)
        XCTAssertEqual(report.tree.children?.map(\.name), ["real.bin"])
    }

    func testCandidateThresholdAndLabel() throws {
        let tree = try TempTree()
        try tree.file("a/node_modules/big.bin", size: 10 * 1024 * 1024 + 1)
        try tree.file("b/node_modules/small.bin", size: 9 * 1024 * 1024)
        try tree.file("c/node_modules/node_modules/big.bin", size: 11 * 1024 * 1024)
        let report = try scan(tree)
        XCTAssertEqual(report.candidates.map(\.path), [tree.path("c/node_modules"), tree.path("a/node_modules")])
        XCTAssertEqual(report.candidates.first?.label, "Bağımlılık · inceleme gerekli")
        XCTAssertEqual(report.candidates.first?.category, .dependencies)
        XCTAssertTrue(report.candidates.first?.note.hasPrefix("Yalnızca dosya yoluna göre sınıflandırıldı.") ?? false)
    }

    func testLargestKeeps150BiggestFiles() throws {
        let fake = FakeFileSystem()
        fake.addDir("/r", children: (0..<200).map { String(format: "f%03d", $0) })
        for i in 0..<200 { fake.addFile(String(format: "/r/f%03d", i), size: Int64(i * 100), blocks: Int64(i + 1)) }
        let report = try scanFake(fake)
        XCTAssertEqual(report.largest.count, 150)
        XCTAssertEqual(report.largest.first?.bytes, 200 * 512)
        XCTAssertEqual(report.largest.last?.bytes, 51 * 512)
        XCTAssertEqual(report.largest.map(\.bytes), report.largest.map(\.bytes).sorted(by: >))
    }

    func testFolderIndexHoldsFoldersAtLeast1MiBAndUnreadableIsUncapped() throws {
        let fake = FakeFileSystem()
        let locked = (0..<150).map { "l\($0)" }
        fake.addDir("/r", children: ["big", "small"] + locked)
        fake.addDir("/r/big", children: ["f"])
        fake.addFile("/r/big/f", size: 2 * 1024 * 1024, blocks: 4096)
        fake.addDir("/r/small", children: ["f"])
        fake.addFile("/r/small/f")
        for name in locked { fake.addDir("/r/\(name)", children: [], listError: "PermissionError: Operation not permitted") }
        let report = try scanFake(fake)
        XCTAssertEqual(report.folderIndex?["/r/big"], 4096 * 512)
        XCTAssertNotNil(report.folderIndex?["/r"])
        XCTAssertNil(report.folderIndex?["/r/small"])
        XCTAssertEqual(report.unreadable?.count, 150)
        XCTAssertEqual(report.errors.count, 100)
        XCTAssertEqual(report.stats.errors, 150)
    }

    func testCancellationReturnsIncompleteReport() throws {
        let tree = try TempTree()
        for i in 0..<10 { try tree.file("d\(i)/f.bin", size: 4000) }
        var calls = 0
        let report = try scan(tree, isCancelled: { calls += 1; return calls > 3 })
        XCTAssertTrue(report.incomplete)
        XCTAssertLessThan(report.stats.files, 10)
        let decoded = try ReportCodec.decode(try ReportCodec.encode(report))
        XCTAssertEqual(decoded, report)
    }

    func testMaxEntriesStopsScanAndMarksIncomplete() throws {
        let tree = try TempTree()
        for i in 0..<10 { try tree.file("f\(i).bin", size: 4000) }
        let report = try scan(tree, options: ScanOptions(root: tree.path(), maxEntries: 5))
        XCTAssertTrue(report.incomplete)
        XCTAssertEqual(report.stats.entries, 5)
    }

    func testSecondsLimitStopsScanAndMarksIncomplete() throws {
        let tree = try TempTree()
        for i in 0..<10 { try tree.file("f\(i).bin", size: 4000) }
        var clock = 0.0
        let report = try scan(tree, options: ScanOptions(root: tree.path(), seconds: 150),
                              now: { defer { clock += 100 }; return clock })
        XCTAssertTrue(report.incomplete)
        XCTAssertLessThan(report.stats.files, 10)
    }

    func testProgressCallbackFires() throws {
        let tree = try TempTree()
        for i in 0..<5 { try tree.file("f\(i).bin", size: 4000) }
        var clock = 0.0
        var seen: [ScanProgress] = []
        _ = try scan(tree, options: ScanOptions(root: tree.path(), progressInterval: 1),
                     now: { defer { clock += 1 }; return clock }, progress: { seen.append($0) })
        XCTAssertFalse(seen.isEmpty)
        XCTAssertGreaterThan(seen.last?.records ?? 0, 0)
    }

    func testReportMetadataIsFilled() throws {
        let tree = try TempTree()
        try tree.file("a.bin", size: 4000)
        let report = try scan(tree)
        XCTAssertEqual(report.schema, 2)
        XCTAssertEqual(report.app, "Disk Atlas")
        XCTAssertEqual(report.platform, "darwin")
        XCTAssertEqual(report.measurement.treeDepth, 8)
        XCTAssertEqual(report.measurement.maxChildren, 40)
        XCTAssertEqual(report.scope, tree.path())
        XCTAssertGreaterThan(report.disk.total, 0)
        XCTAssertLessThanOrEqual(report.disk.free, report.disk.total)
        XCTAssertNotNil(report.created.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}\+00:00$"#, options: .regularExpression))
        XCTAssertFalse(report.measurement.caveat.isEmpty)
    }

    func testRepeatedScansAreIdentical() throws {
        let tree = try TempTree()
        let first = try tree.file("a.bin", size: 4000)
        try tree.hardlink("b.bin", to: first)
        try tree.hardlink("c.bin", to: first)
        for i in 0..<50 { try tree.file("many/f\(i).bin", size: 4000) }
        var one = try scan(tree), two = try scan(tree)
        one.created = ""; two.created = ""; one.seconds = 0; two.seconds = 0
        XCTAssertEqual(one, two)
        // Sabit bağlantılarda bayt sırasına göre ilk ad ("a.bin") sayılır.
        XCTAssertEqual(one.tree.children?.map(\.name).filter { ["a.bin", "b.bin", "c.bin"].contains($0) }, ["a.bin"])
    }

    func testOutputRoundTripsThroughCodec() throws {
        let tree = try TempTree()
        try tree.file("node_modules/x.bin", size: 4000)
        try tree.file("y.bin", size: 4000)
        let report = try scan(tree)
        XCTAssertEqual(try ReportCodec.decode(try ReportCodec.encode(report)), report)
    }
}
