import XCTest
@testable import DiskAtlasCore

final class ReportCodecTests: XCTestCase {
    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "legacy-schema1", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testDecodesLegacySchema1Fixture() throws {
        let report = try ReportCodec.decode(try fixtureData())
        XCTAssertEqual(report.schema, 1)
        XCTAssertEqual(report.tree.children?.count, 2)
        XCTAssertEqual(report.categories["dependencies"], 8192)
        XCTAssertEqual(report.created, "2026-10-17T20:39:38.770478+00:00")
    }

    func testRoundTripKeepsReportEqual() throws {
        let original = try ReportCodec.decode(try fixtureData())
        let again = try ReportCodec.decode(try ReportCodec.encode(original))
        XCTAssertEqual(again, original)
    }

    func testUpgradeMarksLegacyAndKeepsUnreadableFromErrors() throws {
        let upgraded = try ReportCodec.decode(try fixtureData()).upgradedToSchema2()
        XCTAssertEqual(upgraded.schema, 2)
        XCTAssertEqual(upgraded.legacy, true)
        XCTAssertEqual(upgraded.unreadable, ["/gizli"])
        XCTAssertNil(upgraded.folderIndex)
    }

    func testDecodesNewestRealReportWhenPresent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reports = root.appendingPathComponent("reports")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: reports.path)) ?? []
        let newest = names.filter { $0.hasPrefix("disk-atlas-") && $0.hasSuffix(".json") }.sorted().last
        guard let newest else { throw XCTSkip("reports/ altında gerçek rapor yok") }
        let report = try ReportCodec.decode(try Data(contentsOf: reports.appendingPathComponent(newest)))
        XCTAssertGreaterThan(report.tree.bytes, 0)
    }
}
