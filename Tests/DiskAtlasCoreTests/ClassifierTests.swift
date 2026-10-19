import XCTest
@testable import DiskAtlasCore

final class ClassifierTests: XCTestCase {
    private func makeClassifier() throws -> Classifier {
        Classifier(rules: try RuleSet.bundled())
    }

    func testClassifyMatchesPythonTable() throws {
        let classifier = try makeClassifier()
        let table: [(String, DiskCategory?, DiskCategory)] = [
            ("/Users/x/p/node_modules", nil, .dependencies),
            ("/Users/x/p/node_modules/a/b", .dependencies, .dependencies),
            ("/Applications/Foo.app", nil, .system),
            ("/Applications/Foo.app/Contents/x", nil, .system),
            ("/System/Volumes/Data/Users/x/.lmstudio/models/m", nil, .models),
            ("/Library/Caches", nil, .cache),
            ("/Library/Foo", nil, .system),
            ("/usr", nil, .system),
            ("/usrx/y", nil, .personal),
            ("/Users/x/p/.next", nil, .build),
            ("/Users/x/DerivedData", nil, .build),
            ("/Users/x/Documents/a.txt", nil, .personal),
            ("/Users/x/Documents", .system, .system),
        ]
        for (path, inherited, expected) in table {
            XCTAssertEqual(classifier.classify(path: path, inherited: inherited), expected,
                           "\(path) inherited=\(String(describing: inherited))")
        }
    }

    func testDisplayPathStripsDataVolumePrefix() throws {
        let classifier = try makeClassifier()
        XCTAssertEqual(classifier.displayPath("/System/Volumes/Data"), "/")
        XCTAssertEqual(classifier.displayPath("/System/Volumes/Data/Users/x"), "/Users/x")
        XCTAssertEqual(classifier.displayPath("/Users/x"), "/Users/x")
        XCTAssertEqual(classifier.displayPath("/System/Volumes/DataFoo"), "/System/Volumes/DataFoo")
    }

    func testBundledRulesLoad() throws {
        let rules = try RuleSet.bundled()
        XCTAssertEqual(rules.stickyCategories.count, 4)
        XCTAssertEqual(rules.rules.count, 6)
        XCTAssertEqual(rules.fallback, .personal)
    }
}
