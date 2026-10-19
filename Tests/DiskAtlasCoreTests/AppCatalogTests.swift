import XCTest
@testable import DiskAtlasCore

final class AppCatalogTests: XCTestCase {
    private let mb: Int64 = 1_000_000
    private let gb: Int64 = 1_000_000_000
    private let text = "Yeterince uzun bir açıklama metni burada."

    private func path(_ id: String, _ paths: [String], safety: Safety = .review) -> ComponentRule {
        ComponentRule(id: id, name: id, paths: paths, names: nil, children: nil, safety: safety, category: .dependencies,
                      what: text, why: text, ifRemoved: text)
    }

    private func names(_ id: String, _ names: [String]) -> ComponentRule {
        ComponentRule(id: id, name: id, paths: nil, names: names, children: nil, safety: .safe, category: .dependencies,
                      what: text, why: text, ifRemoved: text)
    }

    private func children(_ id: String, _ parent: String) -> ComponentRule {
        ComponentRule(id: id, name: "Yüklü uygulama", paths: nil, names: nil, children: parent, safety: .review, category: .system,
                      what: text, why: text, ifRemoved: text)
    }

    private func app(_ id: String, _ components: ComponentRule...) -> AppRule {
        AppRule(id: id, name: id.capitalized, tone: "dev", components: components)
    }

    private func rules(_ apps: [AppRule]) throws -> RuleSet {
        var set = try RuleSet.bundled()
        set.apps = apps
        return set
    }

    private func report(_ index: [String: Int64]?, home: String? = "/Users/me", total: Int64 = 1000 * 1_000_000_000) throws -> Report {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "legacy-schema1", withExtension: "json", subdirectory: "Fixtures"))
        var report = try ReportCodec.decode(try Data(contentsOf: url))
        report.schema = 2
        report.folderIndex = index
        report.homePath = home
        report.tree.bytes = total
        return report
    }

    private func entries(_ report: AppsReport) -> [String: ComponentEntry] {
        Dictionary(uniqueKeysWithValues: report.apps.flatMap(\.components).map { ($0.id, $0) })
    }

    func testMatchesPathsAndGroupsComponentsUnderTheirApp() throws {
        let set = try rules([app("android", path("sdk", ["~/Library/Android/sdk"]), path("avd", ["~/.android/avd"]))])
        let result = try XCTUnwrap(AppCatalog.build(report: try report(["/Users/me/Library/Android/sdk": 14 * gb, "/Users/me/.android/avd": 8 * gb]), rules: set))
        XCTAssertEqual(result.apps.count, 1)
        XCTAssertEqual(result.apps[0].bytes, 22 * gb)
        XCTAssertEqual(result.apps[0].components.map(\.id), ["sdk", "avd"])
        XCTAssertEqual(result.apps[0].components[0].paths, ["/Users/me/Library/Android/sdk"])
        XCTAssertEqual(result.recognizedBytes, 22 * gb)
        XCTAssertEqual(result.homePath, "/Users/me")
    }

    func testNestedRulesDoNotDoubleCountAndMostSpecificWinsRegardlessOfOrder() throws {
        let index = ["/Users/me/Library/Caches": 15 * gb, "/Users/me/Library/Caches/com.spotify.client": 3 * gb]
        let general = app("general", path("caches-other", ["~/Library/Caches"], safety: .safe))
        let specific = app("spotify", path("spotify-cache", ["~/Library/Caches/com.spotify.client"], safety: .safe))
        for apps in [[general, specific], [specific, general]] {
            let result = try XCTUnwrap(AppCatalog.build(report: try report(index), rules: try rules(apps)))
            let byID = entries(result)
            XCTAssertEqual(byID["spotify-cache"]?.bytes, 3 * gb)
            XCTAssertEqual(byID["caches-other"]?.bytes, 12 * gb)
            XCTAssertEqual(result.recognizedBytes, 15 * gb)
        }
    }

    func testExplicitPathBeatsChildrenRule() throws {
        let set = try rules([app("xcode", path("xcode-app", ["/Applications/Xcode.app"])), app("installed", children("installed-apps", "/Applications"))])
        let result = try XCTUnwrap(AppCatalog.build(report: try report(["/Applications/Xcode.app": 12 * gb, "/Applications/Foo.app": 300 * mb]), rules: set))
        XCTAssertEqual(result.apps.flatMap(\.components).map(\.name).sorted(), ["Foo", "xcode-app"])
        XCTAssertEqual(result.recognizedBytes, 12 * gb + 300 * mb)
    }

    func testNamesRuleCountsOnlyOutermostFolders() throws {
        let index = ["/Users/me/p1/node_modules": 2 * gb, "/Users/me/p1/node_modules/a/node_modules": 500 * mb,
                     "/Users/me/p2/node_modules": 1 * gb]
        let result = try XCTUnwrap(AppCatalog.build(report: try report(index), rules: try rules([app("js", names("node-modules", ["node_modules"]))])))
        let component = try XCTUnwrap(entries(result)["node-modules"])
        XCTAssertEqual(component.bytes, 3 * gb)
        XCTAssertEqual(Set(component.paths), ["/Users/me/p1/node_modules", "/Users/me/p2/node_modules"])
    }

    func testChildrenRuleMakesOneComponentPerAppAboveThreshold() throws {
        let index = ["/Applications/Foo.app": 300 * mb, "/Applications/Bar.app": 200 * mb, "/Applications/Small.app": 50 * mb]
        let result = try XCTUnwrap(AppCatalog.build(report: try report(index), rules: try rules([app("installed", children("installed-apps", "/Applications"))])))
        XCTAssertEqual(result.apps[0].components.map(\.name), ["Foo", "Bar"])
        XCTAssertEqual(result.apps[0].components[0].paths, ["/Applications/Foo.app"])
    }

    func testCaseInsensitivePathMatching() throws {
        let index = ["/Users/me/Library/Caches/com.Spotify.Client": 2 * gb]
        let result = try XCTUnwrap(AppCatalog.build(report: try report(index), rules: try rules([app("spotify", path("spotify-cache", ["~/Library/Caches/com.spotify.client"]))])))
        XCTAssertEqual(entries(result)["spotify-cache"]?.bytes, 2 * gb)
        XCTAssertEqual(entries(result)["spotify-cache"]?.paths, ["/Users/me/Library/Caches/com.Spotify.Client"])
    }

    func testHomeIsTakenFromReportAndFallsBackToLargestUserFolder() throws {
        let set = try rules([app("docs", path("documents", ["~/Documents"]))])
        let index = ["/Users/cousin/Documents": 5 * gb, "/Users/me/Documents": 9 * gb, "/Users/cousin": 20 * gb, "/Users/me": 50 * gb, "/Users/Shared": 90 * gb]
        let fromReport = try XCTUnwrap(AppCatalog.build(report: try report(index, home: "/Users/cousin"), rules: set))
        XCTAssertEqual(entries(fromReport)["documents"]?.bytes, 5 * gb)
        let fallback = try XCTUnwrap(AppCatalog.build(report: try report(index, home: nil), rules: set))
        XCTAssertEqual(fallback.homePath, "/Users/me")
        XCTAssertEqual(entries(fallback)["documents"]?.bytes, 9 * gb)
    }

    func testComponentsNeverExceedMeasuredTotalAndEmptyOnesAreOmitted() throws {
        let index = ["/": 100 * gb, "/Users/me/p/a": 5 * gb, "/Users/me/p/a/b": 5 * gb, "/Users/me/Library/Caches": 15 * gb,
                     "/Users/me/Library/Caches/x": 4 * gb]
        let set = try rules([app("one", path("a", ["~/p/a"])), app("two", path("b", ["~/p/a/b"])),
                             app("three", path("caches", ["~/Library/Caches"]), path("x", ["~/Library/Caches/x"]))])
        let result = try XCTUnwrap(AppCatalog.build(report: try report(index, total: 100 * gb), rules: set))
        XCTAssertNil(entries(result)["a"], "a is fully explained by b")
        XCTAssertFalse(result.apps.contains { $0.id == "one" }, "an app without components is omitted")
        XCTAssertEqual(entries(result)["b"]?.bytes, 5 * gb)
        XCTAssertLessThanOrEqual(result.recognizedBytes, 100 * gb)
        XCTAssertEqual(result.recognizedBytes, 20 * gb)
    }

    func testUnrecognizedExcludesClaimedSystemAndTooSmall() throws {
        let index = ["/Users/me/Library/Application Support/Foo": 5 * gb, "/Users/me/Library/Caches/com.spotify.client": 3 * gb,
                     "/System/Library/Foo": 3 * gb, "/Users/me/tiny": 50 * mb]
        let set = try rules([app("spotify", path("spotify-cache", ["~/Library/Caches/com.spotify.client"]))])
        let result = try XCTUnwrap(AppCatalog.build(report: try report(index), rules: set))
        XCTAssertEqual(result.unrecognized.map(\.path), ["/Users/me/Library/Application Support/Foo"])
        XCTAssertEqual(result.unrecognized[0].bytes, 5 * gb)
        XCTAssertEqual(result.unrecognized[0].ownBytes, 5 * gb)
    }

    func testUnrecognizedUsesOwnBytesNotAncestors() throws {
        let index = ["/Users/me/Library": 20 * gb, "/Users/me/Library/Application Support/Foo": 12 * gb,
                     "/Users/me/Library/Application Support/Foo/data": 12 * gb, "/Users/me/Library/Application Support": 15 * gb]
        let result = try XCTUnwrap(AppCatalog.build(report: try report(index), rules: try rules([app("x", path("x", ["~/nothing"]))])))
        XCTAssertEqual(result.unrecognized.map(\.path),
                       ["/Users/me/Library/Application Support/Foo/data", "/Users/me/Library", "/Users/me/Library/Application Support"])
        XCTAssertEqual(result.unrecognized.map(\.ownBytes), [12 * gb, 5 * gb, 3 * gb])
        XCTAssertFalse(result.unrecognized.contains { $0.path.hasSuffix("/Foo") }, "Foo is fully explained by its child")
    }

    func testNilWithoutFolderIndex() throws {
        XCTAssertNil(AppCatalog.build(report: try report(nil), rules: try RuleSet.bundled()))
    }

    func testBundledCatalogRunsOnARealisticIndex() throws {
        let index = ["/": 200 * gb, "/Users/me": 130 * gb, "/Users/me/Library/Android/sdk": 14 * gb, "/Users/me/.npm": 3 * gb,
                     "/Users/me/Documents": 12 * gb, "/Users/me/Documents/p/node_modules": 2 * gb,
                     "/Users/me/Library/Caches": 15 * gb, "/Users/me/Library/Caches/com.spotify.client": 2 * gb,
                     "/Applications/Xcode.app": 10 * gb, "/Applications/Notion.app": 300 * mb]
        let result = try XCTUnwrap(AppCatalog.build(report: try report(index, total: 200 * gb), rules: try RuleSet.bundled()))
        let byID = entries(result)
        XCTAssertEqual(byID["android-sdk"]?.bytes, 14 * gb)
        XCTAssertEqual(byID["npm-cache"]?.bytes, 3 * gb)
        XCTAssertEqual(byID["documents"]?.bytes, 10 * gb)          // node_modules düşüldü
        XCTAssertEqual(byID["node-modules"]?.bytes, 2 * gb)
        XCTAssertEqual(byID["caches-other"]?.bytes, 13 * gb)
        XCTAssertEqual(byID["xcode-app"]?.bytes, 10 * gb)
        XCTAssertEqual(byID["installed-apps-system/Notion"]?.bytes, 300 * mb)
        XCTAssertLessThanOrEqual(result.recognizedBytes, 200 * gb)
    }
}
