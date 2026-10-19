import XCTest
@testable import DiskAtlasCore

final class DifferTests: XCTestCase {
    private let mib: Int64 = 1024 * 1024
    private let gib: Int64 = 1024 * 1024 * 1024

    private func report(_ index: [String: Int64]?, unreadable: [String] = [], incomplete: Bool = false,
                        used: Int64 = 100, treeBytes: Int64 = 50, access: String? = nil, scope: String = "/") throws -> Report {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "legacy-schema1", withExtension: "json", subdirectory: "Fixtures"))
        var report = try ReportCodec.decode(try Data(contentsOf: url))
        report.schema = 2
        report.folderIndex = index
        report.unreadable = unreadable
        report.incomplete = incomplete
        report.disk.used = used
        report.tree.bytes = treeBytes
        report.fullDiskAccess = access
        report.scope = scope
        return report
    }

    func testGrewShrankNewGone() throws {
        let older = try report(["/a": 10 * mib, "/b": 8 * mib, "/c": 5 * mib])
        let newer = try report(["/a": 14 * mib, "/b": 3 * mib, "/d": 2 * mib])
        let diff = try Differ.compare(older: older, newer: newer)
        XCTAssertEqual(diff.items.map(\.path), ["/b", "/c", "/a", "/d"])
        XCTAssertEqual(diff.items.map(\.status), [.shrank, .gone, .grew, .new])
        XCTAssertEqual(diff.items.map(\.delta), [-5 * mib, -5 * mib, 4 * mib, 2 * mib])
        XCTAssertEqual(diff.items[1].before, 5 * mib)
        XCTAssertNil(diff.items[1].after)
        XCTAssertNil(diff.items[3].before)
        XCTAssertEqual(diff.items[3].after, 2 * mib)
        XCTAssertEqual(diff.totalItems, 4)
        XCTAssertTrue(diff.items.allSatisfy { $0.reason == nil })
    }

    func testIdenticalScansGiveNoItemsAndZeroUnexplained() throws {
        let scan = try report(["/a": 10 * mib, "/b": 8 * mib])
        let diff = try Differ.compare(older: scan, newer: scan)
        XCTAssertEqual(diff.items, [])
        XCTAssertEqual(diff.totalItems, 0)
        XCTAssertEqual(diff.unexplained, 0)
        XCTAssertEqual(diff.warnings, [])
    }

    func testItemsSortedByAbsoluteDeltaAndTruncated() throws {
        let older = try report(["/a": 10 * mib, "/b": 8 * mib, "/c": 5 * mib])
        let newer = try report(["/a": 14 * mib, "/b": 3 * mib, "/d": 2 * mib])
        let diff = try Differ.compare(older: older, newer: newer, limit: 2)
        XCTAssertEqual(diff.items.map(\.path), ["/b", "/c"])
        XCTAssertEqual(diff.totalItems, 4)
    }

    func testIncompleteScanMakesEverythingUncertain() throws {
        let older = try report(["/a": 10 * mib])
        let newer = try report(["/a": 14 * mib, "/b": 2 * mib], incomplete: true)
        let diff = try Differ.compare(older: older, newer: newer)
        XCTAssertEqual(diff.items.map(\.status), [.uncertain, .uncertain])
        XCTAssertTrue(diff.items.allSatisfy { $0.reason == "Tarama yarım kaldı" })
        XCTAssertEqual(diff.items.map(\.delta), [4 * mib, 2 * mib])
    }

    func testUnreadablePathAndAncestorsAreUncertain() throws {
        let sizes: [String: Int64] = ["/": 100 * mib, "/Users": 50 * mib, "/Users/x": 20 * mib, "/Users/x/Library": 10 * mib,
                                      "/Users/xy": 5 * mib, "/Users/y": 5 * mib, "/Other": 5 * mib]
        let older = try report(sizes)
        let newer = try report(sizes.mapValues { $0 + 3 * mib }, unreadable: ["/Users/x/Library/Mail"])
        let diff = try Differ.compare(older: older, newer: newer)
        let status = Dictionary(uniqueKeysWithValues: diff.items.map { ($0.path, $0.status) })
        for path in ["/", "/Users", "/Users/x", "/Users/x/Library"] {
            XCTAssertEqual(status[path], .uncertain, path)
        }
        for path in ["/Users/xy", "/Users/y", "/Other"] {
            XCTAssertEqual(status[path], .grew, path)
        }
        XCTAssertEqual(diff.items.first { $0.path == "/Users/x" }?.reason, "Okunamayan klasör içeriyor")
    }

    func testUnreadableInOlderScanAlsoCounts() throws {
        let older = try report(["/Users/x": 20 * mib, "/Other": 5 * mib], unreadable: ["/Users/x/secret"])
        let newer = try report(["/Users/x": 25 * mib, "/Other": 9 * mib])
        let status = Dictionary(uniqueKeysWithValues: try Differ.compare(older: older, newer: newer).items.map { ($0.path, $0.status) })
        XCTAssertEqual(status["/Users/x"], .uncertain)
        XCTAssertEqual(status["/Other"], .grew)
    }

    func testWarningsForDifferentAccessAndScope() throws {
        let older = try report([:], access: "granted", scope: "/")
        let newer = try report([:], access: "denied", scope: "/Users/x")
        let warnings = try Differ.compare(older: older, newer: newer).warnings
        XCTAssertEqual(warnings.count, 2)
        XCTAssertTrue(warnings.contains { $0.contains("Tam Disk Erişimi") })
        XCTAssertTrue(warnings.contains { $0.contains("kapsam") })
        XCTAssertEqual(try Differ.compare(older: try report([:], access: nil), newer: try report([:], access: "denied")).warnings, [])
    }

    func testUnexplainedDifference() throws {
        let older = try report([:], used: 100 * gib, treeBytes: 50 * gib)
        let newer = try report([:], used: 110 * gib, treeBytes: 53 * gib)
        let diff = try Differ.compare(older: older, newer: newer)
        XCTAssertEqual(diff.measuredDelta, 3 * gib)
        XCTAssertEqual(diff.diskUsedDelta, 10 * gib)
        XCTAssertEqual(diff.unexplained, 7 * gib)
    }

    func testLegacyReportIsNotComparable() throws {
        let good = try report(["/a": mib])
        let legacy = try report(nil)
        XCTAssertThrowsError(try Differ.compare(older: legacy, newer: good)) { XCTAssertEqual($0 as? DiffError, .notComparable("older")) }
        XCTAssertThrowsError(try Differ.compare(older: good, newer: legacy)) { XCTAssertEqual($0 as? DiffError, .notComparable("newer")) }
        XCTAssertTrue(DiffError.notComparable("older").description.contains("karşılaştırma"))
    }
}
