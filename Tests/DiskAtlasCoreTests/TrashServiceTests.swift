import XCTest
@testable import DiskAtlasCore

final class TrashServiceTests: XCTestCase {
    private struct FailingTrasher: Trasher {
        func trash(_ path: String) throws -> String? { throw CocoaError(.fileWriteNoPermission) }
    }

    private var home: TempTree!
    private var aux: TempTree!

    override func setUpWithError() throws {
        home = try TempTree()
        aux = try TempTree()
    }

    private func candidate(_ relative: String, safety: Safety = .safe, bytes: Int64 = 100) -> TrashCandidate {
        TrashCandidate(path: home.path(relative), name: relative, bytes: bytes, safety: safety)
    }

    private var logURL: URL { URL(fileURLWithPath: aux.path("logs/actions.log")) }

    private func service(protected: [String] = [], trasher: Trasher? = nil, log: URL? = nil) -> TrashService {
        TrashService(policy: TrashPolicy(home: home.path(), applications: nil, protectedPaths: protected),
                     trasher: trasher ?? DirectoryTrasher(directory: aux.path("trash")), log: ActionLog(url: log ?? logURL))
    }

    private func plan(_ service: TrashService, _ relatives: [String], allowed: [TrashCandidate]) -> TrashPlan {
        service.plan(scanId: "scan-1", requested: relatives.map { home.path($0) }, allowed: allowed)
    }

    func testPlanAcceptsAllowedFolder() throws {
        try home.file(".npm/cache/a", size: 10)
        let plan = plan(service(), [".npm"], allowed: [candidate(".npm", bytes: 777)])
        XCTAssertEqual(plan.items.map(\.status), [.accepted])
        XCTAssertEqual(plan.totalBytes, 777)
        XCTAssertFalse(plan.needsAcknowledge)
        XCTAssertEqual(plan.acceptedCount, 1)
    }

    func testPlanRejectsPathOutsideAllowedSet() throws {
        try home.file("other/x", size: 10)
        let plan = plan(service(), ["other"], allowed: [candidate(".npm")])
        XCTAssertEqual(plan.items.map(\.status), [.rejected])
        XCTAssertEqual(plan.totalBytes, 0)
        XCTAssertNotNil(plan.items[0].reason)
    }

    func testPlanRejectsPolicyViolations() throws {
        try home.dir("Documents/proj")
        let plan = plan(service(), ["Documents/proj"], allowed: [candidate("Documents/proj")])
        XCTAssertEqual(plan.items.map(\.status), [.rejected])
    }

    func testPlanRejectsMissingFolder() {
        let plan = plan(service(), [".npm"], allowed: [candidate(".npm")])
        XCTAssertEqual(plan.items.map(\.status), [.rejected])
    }

    func testPlanRejectsSymlink() throws {
        try home.dir("real")
        try home.symlink(".npm", to: home.path("real"))
        let plan = plan(service(), [".npm"], allowed: [candidate(".npm")])
        XCTAssertEqual(plan.items.map(\.status), [.rejected])
    }

    func testPlanRejectsSymlinkedAncestor() throws {
        try home.dir("elsewhere/cache")
        try home.symlink("link", to: home.path("elsewhere"))
        let plan = plan(service(), ["link/cache"], allowed: [candidate("link/cache")])
        XCTAssertEqual(plan.items.map(\.status), [.rejected])
    }

    func testPlanMarksNestedAsCoveredAndCountsOnce() throws {
        try home.file(".gradle/caches/x", size: 10)
        let allowed = [candidate(".gradle", safety: .review, bytes: 900), candidate(".gradle/caches", bytes: 400)]
        let plan = plan(service(), [".gradle/caches", ".gradle", ".gradle"], allowed: allowed)
        XCTAssertEqual(plan.items.count, 2, "tekrar tek sayılır")
        XCTAssertEqual(plan.items.first { $0.path == home.path(".gradle") }?.status, .accepted)
        XCTAssertEqual(plan.items.first { $0.path == home.path(".gradle/caches") }?.status, .covered)
        XCTAssertEqual(plan.totalBytes, 900)
        XCTAssertTrue(plan.needsAcknowledge)
    }

    func testExecuteMovesAndLogs() throws {
        try home.file(".npm/cache/a", size: 10)
        let service = service()
        let outcome = try service.execute(plan(service, [".npm"], allowed: [candidate(".npm", bytes: 500)]), acknowledgeReview: false)
        XCTAssertEqual(outcome.results.map(\.ok), [true])
        XCTAssertEqual(outcome.movedBytes, 500)
        XCTAssertEqual(outcome.failedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path(".npm")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(outcome.results[0].trashedTo)))
        let lines = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let entry = try JSONDecoder().decode(ActionLogEntry.self, from: Data(lines[0].utf8))
        XCTAssertEqual(entry.result, "trashed")
        XCTAssertEqual(entry.path, home.path(".npm"))
        XCTAssertEqual(entry.scan, "scan-1")
        XCTAssertEqual(entry.safety, "güvenli")
    }

    func testExecuteRequiresAcknowledgementForReview() throws {
        try home.file(".gradle/x", size: 10)
        let service = service()
        let plan = plan(service, [".gradle"], allowed: [candidate(".gradle", safety: .review)])
        XCTAssertThrowsError(try service.execute(plan, acknowledgeReview: false)) {
            XCTAssertEqual($0 as? TrashError, .acknowledgementRequired)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path(".gradle")))
        XCTAssertEqual(try service.execute(plan, acknowledgeReview: true).results.map(\.ok), [true])
    }

    func testExecuteSkipsItemReplacedAfterPlan() throws {
        try home.file(".npm/a", size: 10)
        let service = service()
        let plan = plan(service, [".npm"], allowed: [candidate(".npm")])
        try FileManager.default.removeItem(atPath: home.path(".npm"))
        try home.file(".npm/b", size: 10)          // aynı ad, yeni klasör (farklı inode)
        let outcome = try service.execute(plan, acknowledgeReview: false)
        XCTAssertEqual(outcome.results.map(\.ok), [false])
        XCTAssertEqual(outcome.failedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path(".npm/b")), "yeni öğe yerinde kalır")
    }

    func testExecuteSkipsItemThatBecameSymlink() throws {
        try home.file(".npm/a", size: 10)
        try home.dir("target")
        let service = service()
        let plan = plan(service, [".npm"], allowed: [candidate(".npm")])
        try FileManager.default.removeItem(atPath: home.path(".npm"))
        try home.symlink(".npm", to: home.path("target"))
        let outcome = try service.execute(plan, acknowledgeReview: false)
        XCTAssertEqual(outcome.results.map(\.ok), [false])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path("target")), "bağlantının gösterdiği yer dokunulmaz")
    }

    func testExecuteReportsTrasherFailurePerItem() throws {
        try home.file(".npm/a", size: 10)
        let service = service(trasher: FailingTrasher())
        let outcome = try service.execute(plan(service, [".npm"], allowed: [candidate(".npm")]), acknowledgeReview: false)
        XCTAssertEqual(outcome.results.map(\.ok), [false])
        XCTAssertEqual(outcome.movedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path(".npm")))
        let entry = try JSONDecoder().decode(ActionLogEntry.self, from: Data(try String(contentsOf: logURL, encoding: .utf8).utf8))
        XCTAssertEqual(entry.result, "failed")
    }

    func testExecuteDoesNothingWhenLogUnavailable() throws {
        try home.file(".npm/a", size: 10)
        try aux.file("blocker", size: 1)
        let service = service(log: URL(fileURLWithPath: aux.path("blocker/actions.log")))
        let plan = plan(service, [".npm"], allowed: [candidate(".npm")])
        XCTAssertThrowsError(try service.execute(plan, acknowledgeReview: false)) {
            XCTAssertEqual($0 as? TrashError, .logUnavailable)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path(".npm/a")))
    }

    func testExecuteWithoutAcceptedItemsThrows() throws {
        let service = service()
        let plan = plan(service, ["missing"], allowed: [candidate("missing")])
        XCTAssertThrowsError(try service.execute(plan, acknowledgeReview: true)) {
            XCTAssertEqual($0 as? TrashError, .nothingToDo)
        }
    }

    func testProtectedChildBlocksParent() throws {
        try home.dir("Library/Application Support/minecraft/saves")
        let protected = [home.path("Library/Application Support/minecraft/saves")]
        let service = service(protected: protected)
        let plan = plan(service, ["Library/Application Support/minecraft"], allowed: [candidate("Library/Application Support/minecraft", safety: .review)])
        XCTAssertEqual(plan.items.map(\.status), [.rejected])
    }

    func testDirectoryTrasherNeverOverwrites() throws {
        let trasher = DirectoryTrasher(directory: aux.path("trash"))
        try home.file("a/f", size: 1)
        let first = try XCTUnwrap(try trasher.trash(home.path("a")))
        try home.file("a/g", size: 1)
        let second = try XCTUnwrap(try trasher.trash(home.path("a")))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first + "/f"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second + "/g"))
    }
}
