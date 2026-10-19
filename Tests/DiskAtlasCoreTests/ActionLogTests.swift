import XCTest
@testable import DiskAtlasCore

final class ActionLogTests: XCTestCase {
    private func entry(_ path: String, result: String = "trashed") -> ActionLogEntry {
        ActionLogEntry(time: "2026-10-19T10:00:00Z", scan: "scan-1", path: path, bytes: 5, safety: "güvenli", result: result, detail: nil)
    }

    func testAppendsLinesAndKeepsOldOnes() throws {
        let tree = try TempTree()
        let url = URL(fileURLWithPath: tree.path("sub/actions.log"))
        let log = ActionLog(url: url)
        try log.prepare()
        try log.append(entry("/a"))
        try ActionLog(url: url).append(entry("/b", result: "failed"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let decoded = try lines.map { try JSONDecoder().decode(ActionLogEntry.self, from: Data($0.utf8)) }
        XCTAssertEqual(decoded.map(\.path), ["/a", "/b"])
        XCTAssertEqual(decoded[1].result, "failed")
    }

    func testPrepareFailsWhenParentIsAFile() throws {
        let tree = try TempTree()
        try tree.file("blocker", size: 1)
        let log = ActionLog(url: URL(fileURLWithPath: tree.path("blocker/actions.log")))
        XCTAssertThrowsError(try log.prepare())
    }
}
