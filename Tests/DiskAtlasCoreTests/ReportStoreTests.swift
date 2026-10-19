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

    func testSummaryRecordsAccessAndComparability() throws {
        let store = ReportStore(directory: directory)
        var comparable = try fixture()
        comparable.schema = 2
        comparable.folderIndex = ["/": 12288]
        comparable.fullDiskAccess = "denied"
        let id = try store.save(comparable)
        let summary = try XCTUnwrap(store.list().first { $0.id == id })
        XCTAssertEqual(summary.comparable, true)
        XCTAssertEqual(summary.fullDiskAccess, "denied")

        let legacyID = try store.save(try fixture(created: "2026-09-01T00:00:00.000000+00:00").upgradedToSchema2())
        let legacy = try XCTUnwrap(store.list().first { $0.id == legacyID })
        XCTAssertEqual(legacy.comparable, false)
        XCTAssertNil(legacy.fullDiskAccess)
    }

    func testOldMetaWithoutNewFieldsStillListed() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = #"{"id":"scan-5","created":"2026-10-01T00:00:00","scope":"/","incomplete":false,"allocatedBytes":1,"schema":2}"#
        try Data(old.utf8).write(to: directory.appendingPathComponent("scan-5.meta.json"))
        let summary = try XCTUnwrap(ReportStore(directory: directory).list().first)
        XCTAssertEqual(summary.id, "scan-5")
        XCTAssertNil(summary.comparable)
    }

    func testDeleteRemovesReportAndMeta() throws {
        let store = ReportStore(directory: directory)
        let keep = try store.save(try fixture(created: "2026-10-01T00:00:00.000000+00:00"))
        let drop = try store.save(try fixture(created: "2026-10-02T00:00:00.000000+00:00"))
        try store.delete(id: drop)
        XCTAssertEqual(store.list().map(\.id), [keep])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(drop).json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(drop).meta.json").path))
        XCTAssertNoThrow(try store.load(id: keep))
    }

    func testDeleteRejectsInvalidAndMissingIDs() throws {
        let store = ReportStore(directory: directory)
        for bad in ["../x", "/etc/passwd", "", "scan-1/../2"] {
            XCTAssertThrowsError(try store.delete(id: bad), bad) { XCTAssertEqual($0 as? ReportStoreError, .invalidID(bad)) }
        }
        XCTAssertThrowsError(try store.delete(id: "scan-77")) { XCTAssertEqual($0 as? ReportStoreError, .notFound("scan-77")) }
    }

    func testFolderIndexThresholdIsOneMiB() {
        XCTAssertEqual(DiskScanner.folderIndexThreshold, 1024 * 1024)
    }
}
