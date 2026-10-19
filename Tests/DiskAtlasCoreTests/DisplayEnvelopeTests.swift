import XCTest
@testable import DiskAtlasCore

final class DisplayEnvelopeTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000
    private let mb: Int64 = 1_000_000
    private let text = "Yeterince uzun bir açıklama metni burada."

    private func component(_ id: String, _ paths: [String], safety: Safety, category: DiskCategory = .dependencies) -> ComponentRule {
        ComponentRule(id: id, name: "Ad \(id)", paths: paths, names: nil, children: nil, safety: safety, category: category,
                      what: "\(id) nedir", why: text, ifRemoved: text)
    }

    private func rules() throws -> RuleSet {
        var set = try RuleSet.bundled()
        set.apps = [AppRule(id: "t", name: "Test", tone: "dev", components: [
            component("big-review", ["~/a"], safety: .review),
            component("big-safe", ["~/b"], safety: .safe, category: .cache),
            component("big-never", ["~/c"], safety: .never, category: .personal),
            component("small-review", ["~/d"], safety: .review),
        ])]
        return set
    }

    private func report(_ index: [String: Int64]?) throws -> Report {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "legacy-schema1", withExtension: "json", subdirectory: "Fixtures"))
        var report = try ReportCodec.decode(try Data(contentsOf: url))
        report.schema = 2
        report.folderIndex = index
        report.homePath = "/Users/me"
        return report
    }

    private func json(_ envelope: DisplayEnvelope) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
    }

    func testEncodesReportFieldsPlusAppsAndUI() throws {
        let index = ["/Users/me/a": 3 * gb, "/Users/me/b": 2 * gb]
        let object = try json(DisplayEnvelope(report: try report(index), rules: try rules()))
        XCTAssertEqual(object["schema"] as? Int, 2)                 // rapor alanları aynı kaplamada
        XCTAssertNotNil(object["tree"])
        XCTAssertNil(object["folderIndex"], "heavy fields are stripped")
        let apps = try XCTUnwrap((object["apps"] as? [String: Any])?["apps"] as? [[String: Any]])
        XCTAssertEqual(apps.first?["name"] as? String, "Test")
        let ui = try XCTUnwrap(object["ui"] as? [String: Any])
        XCTAssertEqual(ui["homePath"] as? String, "/Users/me")
        XCTAssertEqual((ui["findings"] as? [[String: Any]])?.count, 2)
    }

    func testFindingsSkipNeverAndSmallAndMapSafetyToGroup() throws {
        let index = ["/Users/me/a": 3 * gb, "/Users/me/b": 2 * gb, "/Users/me/c": 20 * gb, "/Users/me/d": 100 * mb]
        let object = try json(DisplayEnvelope(report: try report(index), rules: try rules()))
        let findings = try XCTUnwrap((object["ui"] as? [String: Any])?["findings"] as? [[String: Any]])
        XCTAssertEqual(findings.map { $0["name"] as? String }, ["Ad big-review", "Ad big-safe"])
        XCTAssertEqual(findings.map { $0["group"] as? String }, ["review", "cache"])
        XCTAssertEqual(findings[0]["path"] as? String, "/Users/me/a")
        XCTAssertEqual(findings[0]["category"] as? String, "dependencies")
        XCTAssertEqual(findings[0]["note"] as? String, "big-review nedir")
        XCTAssertEqual((findings[0]["bytes"] as? NSNumber)?.int64Value, 3 * gb)
    }

    func testFindingsCarrySafetyAndScannerCandidatesAreReview() throws {
        var base = try report(["/Users/me/a": 3 * gb, "/Users/me/b": 2 * gb])
        base.candidates = [Candidate(name: ".next", path: "/Users/me/web/.next", bytes: 300 * mb, logical: 300 * mb,
                                     category: .build, label: "Derleme", note: "aday notu")]
        let object = try json(DisplayEnvelope(report: base, rules: try rules()))
        let findings = try XCTUnwrap((object["ui"] as? [String: Any])?["findings"] as? [[String: Any]])
        let safety = Dictionary(uniqueKeysWithValues: findings.map { ($0["path"] as! String, $0["safety"] as? String) })
        XCTAssertEqual(safety["/Users/me/a"], "incele")
        XCTAssertEqual(safety["/Users/me/b"], "güvenli")
        XCTAssertEqual(safety["/Users/me/web/.next"], "incele", "tarayıcı adayı hiçbir zaman 'güvenli' sayılmaz")
    }

    func testReportWithoutFolderIndexHasNoAppsOrUI() throws {
        let object = try json(DisplayEnvelope(report: try report(nil), rules: try rules()))
        XCTAssertNil(object["apps"])
        XCTAssertNil(object["ui"])
        XCTAssertNotNil(object["tree"])
    }

    func testFindingsAreEmittedPerPathWithFullFolderBytes() throws {
        var set = try RuleSet.bundled()
        set.apps = [AppRule(id: "t", name: "Test", tone: "dev", components: [
            component("multi", ["~/p1/m", "~/p2/m"], safety: .safe, category: .cache),
            component("caches", ["~/Library/Caches"], safety: .safe, category: .cache),
            component("spot", ["~/Library/Caches/spotify"], safety: .safe, category: .cache),
        ])]
        let index = ["/Users/me/p1/m": 2 * gb, "/Users/me/p2/m": 1 * gb, "/Users/me/Library/Caches": 15 * gb, "/Users/me/Library/Caches/spotify": 3 * gb]
        let object = try json(DisplayEnvelope(report: try report(index), rules: set))
        let findings = try XCTUnwrap((object["ui"] as? [String: Any])?["findings"] as? [[String: Any]])
        let byPath = Dictionary(uniqueKeysWithValues: findings.map { ($0["path"] as! String, ($0["bytes"] as! NSNumber).int64Value) })
        XCTAssertEqual(byPath["/Users/me/p1/m"], 2 * gb)
        XCTAssertEqual(byPath["/Users/me/p2/m"], 1 * gb)
        XCTAssertEqual(byPath["/Users/me/Library/Caches"], 15 * gb, "parent keeps its full folder size so selections can de-duplicate nesting")
        XCTAssertEqual(byPath["/Users/me/Library/Caches/spotify"], 3 * gb)
        let names = findings.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains { $0.contains("p1/m") }, "multi-path components are told apart by folder: \(names)")
    }

    func testScannerCandidatesAreMergedWhenNotCovered() throws {
        var base = try report(["/Users/me/a": 3 * gb])
        func candidate(_ path: String, _ bytes: Int64, _ category: DiskCategory) -> Candidate {
            Candidate(name: (path as NSString).lastPathComponent, path: path, bytes: bytes, logical: bytes, category: category,
                      label: "Önbellek", note: "aday notu")
        }
        base.candidates = [candidate("/Users/me/web/.next", 300 * mb, .build), candidate("/Users/me/a/inside", 400 * mb, .cache),
                           candidate("/Users/me/small/.cache", 100 * mb, .cache), candidate("/Users/me/lib/models", 900 * mb, .models)]
        let object = try json(DisplayEnvelope(report: base, rules: try rules()))
        let findings = try XCTUnwrap((object["ui"] as? [String: Any])?["findings"] as? [[String: Any]])
        let byPath = Dictionary(uniqueKeysWithValues: findings.map { ($0["path"] as! String, $0) })
        XCTAssertEqual(byPath["/Users/me/web/.next"]?["group"] as? String, "cache")
        XCTAssertEqual(byPath["/Users/me/lib/models"]?["group"] as? String, "review")
        XCTAssertEqual(byPath["/Users/me/web/.next"]?["note"] as? String, "aday notu")
        XCTAssertNil(byPath["/Users/me/a/inside"], "covered by a catalog finding")
        XCTAssertNil(byPath["/Users/me/small/.cache"], "below the 150 MB threshold")
    }
}
