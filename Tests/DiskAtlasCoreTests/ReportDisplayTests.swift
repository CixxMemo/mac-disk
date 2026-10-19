import XCTest
@testable import DiskAtlasCore

final class ReportDisplayTests: XCTestCase {
    private let mib: Int64 = 1024 * 1024

    private func report(children: [Int64]) throws -> Report {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "legacy-schema1", withExtension: "json", subdirectory: "Fixtures"))
        var report = try ReportCodec.decode(try Data(contentsOf: url))
        let nodes = children.enumerated().map {
            Node(name: "c\($0.offset)", path: "/c\($0.offset)", bytes: $0.element, logical: $0.element, category: .personal)
        }
        report.tree = Node(name: "Data", path: "/", bytes: children.reduce(0, +), logical: children.reduce(0, +),
                           category: .personal, children: nodes.shuffled())
        report.folderIndex = ["/c0": 1]
        report.unreadable = ["/x"]
        return report
    }

    func testForDisplayKeepsTop16AndFoldsRest() throws {
        let sizes = (0..<20).map { Int64(20 - $0) * 3 * mib }
        let display = try report(children: sizes).forDisplay()
        let children = try XCTUnwrap(display.tree.children)
        XCTAssertEqual(children.count, 17)
        XCTAssertEqual(children.prefix(16).map(\.bytes), Array(sizes.prefix(16)))
        let aggregate = try XCTUnwrap(children.last)
        XCTAssertEqual(aggregate.aggregate, true)
        XCTAssertEqual(aggregate.name, "Diğer 4 öğe")
        XCTAssertEqual(aggregate.path, "/")
        XCTAssertEqual(aggregate.bytes, sizes.suffix(4).reduce(0, +))
        XCTAssertEqual(children.reduce(0) { $0 + $1.bytes }, display.tree.bytes)
    }

    func testForDisplayFoldsSmallChildrenAfterTheFirstThree() throws {
        let display = try report(children: [10 * mib, 9 * mib, 8 * mib, 1024, 512, 100]).forDisplay()
        let children = try XCTUnwrap(display.tree.children)
        XCTAssertEqual(children.map(\.bytes), [10 * mib, 9 * mib, 8 * mib, Int64(1024 + 512 + 100)])
        XCTAssertEqual(children.last?.name, "Diğer 3 öğe")
    }

    func testForDisplayKeepsFirstThreeEvenWhenSmallThenFolds() throws {
        let children = try XCTUnwrap(try report(children: [3000, 2000, 1000, 10]).forDisplay().tree.children)
        XCTAssertEqual(children.map(\.bytes), [3000, 2000, 1000, 10])
        XCTAssertEqual(children.prefix(3).map { $0.aggregate }, [nil, nil, nil])
        XCTAssertEqual(children.last?.aggregate, true)
        XCTAssertEqual(children.last?.name, "Diğer 1 öğe")
    }

    func testForDisplayStripsHeavyFieldsAndDropsEmptyChildren() throws {
        let display = try report(children: []).forDisplay()
        XCTAssertNil(display.folderIndex)
        XCTAssertNil(display.unreadable)
        XCTAssertNil(display.tree.children)
    }

    func testForDisplayRecursesIntoChildren() throws {
        var base = try report(children: [10 * mib])
        let grandchildren = (0..<20).map {
            Node(name: "g\($0)", path: "/c0/g\($0)", bytes: 3 * mib, logical: 3 * mib, category: .personal)
        }
        base.tree.children?[0].children = grandchildren
        let first = try XCTUnwrap(base.forDisplay().tree.children?.first)
        XCTAssertEqual(first.children?.count, 17)
    }
}
