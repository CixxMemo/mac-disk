import XCTest
@testable import DiskAtlasCore

final class ReportStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("diskatlas-store-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(created: String? = nil) throws -> Report {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "legacy-schema1", withExtension: "json", subdirectory: "Fixtures"))
        var report = try ReportCodec.decode(try Data(contentsOf: url))
        if let created { report.created = created }
        return report
    }

    func testSaveListLoadRoundTrip() throws {
        let store = ReportStore(directory: directory)
        let report = try fixture()
        let id = try store.save(report)
        XCTAssertTrue(ReportStore.isValid(id: id), id)
        let summaries = store.list()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].id, id)
        XCTAssertEqual(summaries[0].created, report.created)
        XCTAssertEqual(summaries[0].scope, "/")
        XCTAssertEqual(summaries[0].incomplete, false)
        XCTAssertEqual(summaries[0].allocatedBytes, 12288)
        XCTAssertEqual(summaries[0].schema, 1)
        XCTAssertEqual(try store.load(id: id), report)
    }

    func testListIsNewestFirst() throws {
        let store = ReportStore(directory: directory)
        let old = try store.save(try fixture(created: "2026-10-18T08:00:00.000000+00:00"))
        let new = try store.save(try fixture(created: "2026-10-19T08:00:00.000000+00:00"))
        let mid = try store.save(try fixture(created: "2026-10-18T20:00:00.000000+00:00"))
        XCTAssertEqual(store.list().map(\.id), [new, mid, old])
    }

    func testSameTimestampGetsDistinctIDs() throws {
        let store = ReportStore(directory: directory)
        let report = try fixture()
        let first = try store.save(report)
        let second = try store.save(report)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(ReportStore.isValid(id: second), second)
        XCTAssertEqual(try store.load(id: first), try store.load(id: second))
        XCTAssertEqual(store.list().count, 2)
    }

    func testLoadRejectsPathTraversalIDs() throws {
        let store = ReportStore(directory: directory)
        for bad in ["../x", "/etc/passwd", "", "scan-1/../2", "scan-", "scan-1.json", "SCAN-1", String(repeating: "1", count: 80)] {
            XCTAssertThrowsError(try store.load(id: bad), bad) { error in
                XCTAssertEqual(error as? ReportStoreError, .invalidID(bad))
            }
        }
    }

    func testLoadMissingThrowsNotFound() throws {
        let store = ReportStore(directory: directory)
        XCTAssertThrowsError(try store.load(id: "scan-1")) { error in
            XCTAssertEqual(error as? ReportStoreError, .notFound("scan-1"))
        }
    }

    func testListSkipsCorruptMeta() throws {
        let store = ReportStore(directory: directory)
        let id = try store.save(try fixture())
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("scan-9.meta.json"))
        XCTAssertEqual(store.list().map(\.id), [id])
    }

    func testListOnMissingDirectoryIsEmpty() throws {
        XCTAssertEqual(ReportStore(directory: directory).list(), [])
    }
}
