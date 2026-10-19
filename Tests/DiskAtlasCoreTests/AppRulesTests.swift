import XCTest
@testable import DiskAtlasCore

final class AppRulesTests: XCTestCase {
    private func component(_ id: String, paths: [String]? = ["~/x"], names: [String]? = nil, children: String? = nil,
                           what: String = "Bu bileşenin ne olduğunu anlatan yeterince uzun bir metin.") -> ComponentRule {
        ComponentRule(id: id, name: id, paths: paths, names: names, children: children, safety: .safe, category: .cache,
                      what: what, why: "Neden bu türde olduğunu anlatan yeterince uzun bir metin.",
                      ifRemoved: "Silinirse ne olacağını anlatan yeterince uzun bir metin.")
    }

    private func rules(_ apps: [AppRule]) throws -> RuleSet {
        var set = try RuleSet.bundled()
        set.apps = apps
        return set
    }

    func testBundledCatalogIsValid() throws {
        let set = try RuleSet.bundled()
        XCTAssertNoThrow(try set.validateCatalog())
        let apps = try XCTUnwrap(set.apps)
        XCTAssertGreaterThanOrEqual(apps.count, 15)
        XCTAssertGreaterThanOrEqual(apps.flatMap(\.components).count, 40)
    }

    func testCatalogHasTheExpectedTools() throws {
        let names = Set(try XCTUnwrap(try RuleSet.bundled().apps).map(\.name))
        for expected in ["Android", "Xcode ve iOS simülatörleri", "JavaScript araçları", "Python", "Docker", "VS Code",
                         "Yerel yapay zekâ modelleri", "Google Chrome", "Kişisel klasörler", "Yüklü uygulamalar"] {
            XCTAssertTrue(names.contains(expected), expected)
        }
    }

    func testPersonalFoldersAreNeverSafe() throws {
        let byID = Dictionary(uniqueKeysWithValues: try XCTUnwrap(try RuleSet.bundled().apps).flatMap(\.components).map { ($0.id, $0) })
        for id in ["documents", "desktop", "pictures", "movies", "music", "mail", "messages", "chrome-profile"] {
            XCTAssertEqual(byID[id]?.safety, .never, id)
        }
        XCTAssertEqual(byID["caches-other"]?.safety, .safe)
        XCTAssertEqual(byID["xcode-derived-data"]?.safety, .safe)
        XCTAssertEqual(byID["node-modules"]?.safety, .safe)
        XCTAssertEqual(byID["android-sdk"]?.safety, .review)
    }

    func testEveryComponentOffersExactlyOneMatcherAndTrimmedTexts() throws {
        for component in try XCTUnwrap(try RuleSet.bundled().apps).flatMap(\.components) {
            let matchers = [component.paths != nil, component.names != nil, component.children != nil].filter { $0 }.count
            XCTAssertEqual(matchers, 1, component.id)
            for text in [component.what, component.why, component.ifRemoved] {
                XCTAssertGreaterThanOrEqual(text.trimmingCharacters(in: .whitespacesAndNewlines).count, 20, component.id)
            }
        }
    }

    func testValidationRejectsDuplicateIDsAndTraversalAndBadShapes() throws {
        func invalid(_ apps: [AppRule], _ note: String) throws {
            XCTAssertThrowsError(try rules(apps).validateCatalog(), note) { error in
                XCTAssertTrue(error is RuleCatalogError, note)
            }
        }
        let ok = AppRule(id: "a", name: "A", tone: "dev", components: [component("c1")])
        XCTAssertNoThrow(try rules([ok]).validateCatalog())
        try invalid([ok, AppRule(id: "a", name: "A2", tone: "dev", components: [component("c2")])], "duplicate app id")
        try invalid([AppRule(id: "a", name: "A", tone: "dev", components: [component("c1"), component("c1")])], "duplicate component id")
        try invalid([AppRule(id: "a", name: "A", tone: "nope", components: [component("c1")])], "bad tone")
        try invalid([AppRule(id: "a", name: "A", tone: "dev", components: [component("c1", paths: ["~/a/../b"])])], "traversal")
        try invalid([AppRule(id: "a", name: "A", tone: "dev", components: [component("c1", paths: ["relative/path"])])], "relative path")
        try invalid([AppRule(id: "a", name: "A", tone: "dev", components: [component("c1", paths: nil)])], "no matcher")
        try invalid([AppRule(id: "a", name: "A", tone: "dev", components: [component("c1", names: ["x"])])], "two matchers")
        try invalid([AppRule(id: "a", name: "A", tone: "dev", components: [component("c1", paths: nil, names: ["Node_Modules"])])], "uppercase name")
        try invalid([AppRule(id: "a", name: "A", tone: "dev", components: [component("c1", what: "kısa")])], "short text")
    }

    func testOldRulesWithoutAppsStillLoad() throws {
        let json = #"{"stickyCategories":["cache"],"rules":[],"fallback":"personal"}"#
        let set = try JSONDecoder().decode(RuleSet.self, from: Data(json.utf8))
        XCTAssertNil(set.apps)
        XCTAssertNoThrow(try set.validateCatalog())
    }
}
