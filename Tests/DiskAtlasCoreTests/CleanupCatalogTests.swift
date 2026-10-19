import XCTest
@testable import DiskAtlasCore

final class CleanupCatalogTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000
    private let text = "Yeterince uzun bir açıklama metni burada."

    private func component(_ id: String, _ paths: [String], safety: Safety) -> ComponentRule {
        ComponentRule(id: id, name: "Ad \(id)", paths: paths, names: nil, children: nil, safety: safety, category: .cache,
                      what: "\(id) nedir", why: text, ifRemoved: text)
    }

    private func rules() throws -> RuleSet {
        var set = try RuleSet.bundled()
        set.apps = [AppRule(id: "t", name: "Test", tone: "dev", components: [
            component("review", ["~/a"], safety: .review),
            component("safe", ["~/b"], safety: .safe),
            component("never", ["~/Documents"], safety: .never),
            component("saves", ["~/Library/Application Support/minecraft/saves"], safety: .never),
        ])]
        return set
    }

    private func report(_ index: [String: Int64]?, candidates: [Candidate] = []) throws -> Report {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "legacy-schema1", withExtension: "json", subdirectory: "Fixtures"))
        var report = try ReportCodec.decode(try Data(contentsOf: url))
        report.schema = 2
        report.folderIndex = index
        report.homePath = "/Users/me"
        report.candidates = candidates
        return report
    }

    private func candidate(_ path: String, bytes: Int64) -> Candidate {
        Candidate(name: "Aday", path: path, bytes: bytes, logical: bytes, category: .cache, label: "x", note: "not")
    }

    func testCandidatesExcludeNeverComponents() throws {
        let index = ["/Users/me/a": 3 * gb, "/Users/me/b": 2 * gb, "/Users/me/Documents": 20 * gb]
        let result = CleanupCatalog.candidates(report: try report(index), rules: try rules())
        XCTAssertEqual(Set(result.map(\.path)), ["/Users/me/a", "/Users/me/b"])
    }

    func testSafeComponentKeepsSafetyAndFullBytes() throws {
        let index = ["/Users/me/a": 3 * gb, "/Users/me/b": 2 * gb]
        let result = CleanupCatalog.candidates(report: try report(index), rules: try rules())
        let safe = try XCTUnwrap(result.first { $0.path == "/Users/me/b" })
        XCTAssertEqual(safe.safety, .safe)
        XCTAssertEqual(safe.bytes, 2 * gb)
        XCTAssertEqual(safe.name, "Ad safe")
        XCTAssertEqual(result.first { $0.path == "/Users/me/a" }?.safety, .review)
    }

    func testScannerCandidateIsReviewAndNotDuplicated() throws {
        let index = ["/Users/me/a": 3 * gb, "/Users/me/a/inner": gb, "/Users/me/x": gb]
        let candidates = [candidate("/Users/me/a", bytes: 3 * gb), candidate("/Users/me/a/inner", bytes: gb),
                          candidate("/Users/me/x", bytes: gb)]
        let result = CleanupCatalog.candidates(report: try report(index, candidates: candidates), rules: try rules())
        XCTAssertEqual(result.filter { $0.path == "/Users/me/a" }.count, 1)
        XCTAssertNil(result.first { $0.path == "/Users/me/a/inner" }, "kataloğun kapsadığı alt klasör ayrıca eklenmez")
        let extra = try XCTUnwrap(result.first { $0.path == "/Users/me/x" })
        XCTAssertEqual(extra.safety, .review)
    }

    func testProtectedPathsExpandHome() throws {
        let protected = CleanupCatalog.protectedPaths(rules: try rules(), home: "/Users/me")
        XCTAssertTrue(protected.contains("/Users/me/Documents"))
        XCTAssertTrue(protected.contains("/Users/me/Library/Application Support/minecraft/saves"))
        XCTAssertFalse(protected.contains("/Users/me/a"))
    }

    func testLegacyReportHasNoCandidates() throws {
        XCTAssertEqual(CleanupCatalog.candidates(report: try report(nil), rules: try rules()), [])
    }

    func testScannerCandidatesRespectExcludeUnder() throws {
        var set = try RuleSet.bundled()
        set.apps = [AppRule(id: "js", name: "JS", tone: "dev", components: [
            ComponentRule(id: "nm", name: "node_modules", paths: nil, names: ["node_modules"], children: nil, safety: .safe, category: .dependencies,
                          what: "x nedir", why: text, ifRemoved: text, excludeUnder: ["~/.nvm"])])]
        let candidates = [candidate("/Users/me/.nvm/versions/node/v20/lib/node_modules", bytes: 20_000_000),
                          candidate("/Users/me/.nvm", bytes: 30_000_000), candidate("/Users/me/proj/x", bytes: 20_000_000)]
        let index = ["/Users/me/proj": gb]
        let result = CleanupCatalog.candidates(report: try report(index, candidates: candidates), rules: set)
        XCTAssertEqual(result.map(\.path), ["/Users/me/proj/x"], "global araç kurulumları taşınabilir öğe olmaz")
        XCTAssertTrue(CleanupCatalog.isExcludedCandidate("/Users/me/.nvm/a", rules: set, home: "/Users/me"))
        XCTAssertFalse(CleanupCatalog.isExcludedCandidate("/Users/me/.nvmx", rules: set, home: "/Users/me"))
    }
}
