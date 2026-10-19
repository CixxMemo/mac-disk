import XCTest
@testable import DiskAtlasCore

private final class GateTrasher: Trasher, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    func trash(_ path: String) throws -> String? {
        started.signal()
        proceed.wait()
        return nil
    }
}

final class BridgeCleanupTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000
    private var tree: TempTree!
    private var aux: TempTree!
    private var store: ReportStore!
    private var home: String { tree.path("home") }

    override func setUpWithError() throws {
        tree = try TempTree()
        aux = try TempTree()
        store = ReportStore(directory: URL(fileURLWithPath: aux.path("scans")))
        try tree.file("home/.npm/cache/a", size: 100)
        try tree.file("home/.gradle/b", size: 100)
        try tree.file("home/other/c", size: 100)
        try tree.file("home/Documents/d", size: 100)
    }

    private func savedScan(index: [String: Int64]? = nil) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "legacy-schema1", withExtension: "json", subdirectory: "Fixtures"))
        var report = try ReportCodec.decode(try Data(contentsOf: url))
        report.schema = 2
        report.homePath = home
        report.candidates = []
        report.folderIndex = index ?? [home + "/.npm": 3 * gb, home + "/.gradle": 2 * gb, home + "/Documents": 5 * gb]
        return try store.save(report)
    }

    private func router(trasher: Trasher? = nil, enabled: Bool = true,
                        runner: @escaping ScanRunner = BridgeRouter.defaultRunner) throws -> BridgeRouter {
        BridgeRouter(store: store, rules: try RuleSet.bundled(),
                     roots: ScanRoots(data: home, home: home, excluded: [], applications: home + "/Applications"),
                     appInfo: AppInfo(version: "1", macOS: "15"), permission: { .granted }, openFullDiskAccess: {},
                     emit: { _ in }, runner: runner,
                     trasher: enabled ? (trasher ?? DirectoryTrasher(directory: aux.path("trash"))) : nil,
                     actionLogURL: enabled ? URL(fileURLWithPath: aux.path("actions.log")) : nil)
    }

    private func send(_ router: BridgeRouter, _ type: String, _ payload: [String: Any] = [:]) throws -> [String: Any] {
        let message = try JSONSerialization.data(withJSONObject: ["id": "1", "type": type, "payload": payload])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: router.handle(message)) as? [String: Any])
    }

    private func data(_ response: [String: Any]) throws -> [String: Any] {
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        return try XCTUnwrap(response["data"] as? [String: Any])
    }

    private func assertError(_ response: [String: Any], contains text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response["ok"] as? Bool, false, "\(response)", file: file, line: line)
        XCTAssertTrue((response["error"] as? String ?? "").contains(text), "\(response)", file: file, line: line)
    }

    func testCapabilitiesReflectConfiguration() throws {
        XCTAssertEqual(try data(send(try router(), "capabilities"))["cleanup"] as? Bool, true)
        XCTAssertEqual(try data(send(try router(enabled: false), "capabilities"))["cleanup"] as? Bool, false)
    }

    func testPlanThenConfirmMovesFolder() throws {
        let id = try savedScan()
        let router = try router()
        let plan = try data(send(router, "planTrash", ["scanId": id, "paths": [home + "/.npm"]]))
        let items = try XCTUnwrap(plan["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["status"] as? String }, ["accepted"])
        XCTAssertEqual((plan["totalBytes"] as? NSNumber)?.int64Value, 3 * gb)
        XCTAssertEqual(plan["needsAcknowledge"] as? Bool, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.npm"), "plan hiçbir şeyi taşımaz")

        let outcome = try data(send(router, "confirmTrash", ["planId": try XCTUnwrap(plan["planId"] as? String), "acknowledgeReview": false]))
        XCTAssertEqual((outcome["results"] as? [[String: Any]])?.map { $0["ok"] as? Bool }, [true])
        XCTAssertEqual((outcome["movedBytes"] as? NSNumber)?.int64Value, 3 * gb)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.npm"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: aux.path("trash/.npm/cache/a")))
        XCTAssertTrue(try String(contentsOfFile: aux.path("actions.log"), encoding: .utf8).contains("\"trashed\""))
    }

    func testPlanRejectsArbitraryPaths() throws {
        let id = try savedScan()
        let router = try router()
        let paths = ["/etc", home, home + "/.npm/../Documents", home + "/other", home + "/Documents", "/System/Library"]
        let plan = try data(send(router, "planTrash", ["scanId": id, "paths": paths]))
        XCTAssertEqual((plan["items"] as? [[String: Any]])?.map { $0["status"] as? String }, Array(repeating: "rejected", count: paths.count))
        XCTAssertEqual((plan["acceptedCount"] as? NSNumber)?.intValue, 0)
        assertError(try send(router, "confirmTrash", ["planId": try XCTUnwrap(plan["planId"] as? String), "acknowledgeReview": true]), contains: "Taşınacak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/Documents/d"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/other/c"))
    }

    func testPlanRejectsBadInput() throws {
        let id = try savedScan()
        let router = try router()
        assertError(try send(router, "planTrash", ["scanId": "scan-999", "paths": [home + "/.npm"]]), contains: "bulunamadı")
        assertError(try send(router, "planTrash", ["scanId": "../x", "paths": [home + "/.npm"]]), contains: "Geçersiz")
        assertError(try send(router, "planTrash", ["paths": [home + "/.npm"]]), contains: "Geçersiz")
        assertError(try send(router, "planTrash", ["scanId": id, "paths": []]), contains: "en az bir")
        assertError(try send(router, "planTrash", ["scanId": id, "paths": [5]]), contains: "Geçersiz")
        assertError(try send(router, "planTrash", ["scanId": id, "paths": (0..<201).map { "/x\($0)" }]), contains: "en fazla")
    }

    func testConfirmUnknownOrReusedPlanFails() throws {
        let id = try savedScan()
        let router = try router()
        assertError(try send(router, "confirmTrash", ["planId": "nope", "acknowledgeReview": false]), contains: "Plan bulunamadı")
        let plan = try data(send(router, "planTrash", ["scanId": id, "paths": [home + "/.npm"]]))
        let planId = try XCTUnwrap(plan["planId"] as? String)
        _ = try data(send(router, "confirmTrash", ["planId": planId, "acknowledgeReview": false]))
        assertError(try send(router, "confirmTrash", ["planId": planId, "acknowledgeReview": false]), contains: "Plan bulunamadı")
    }

    func testReviewNeedsAcknowledgementAndKeepsPlan() throws {
        let id = try savedScan()
        let router = try router()
        let plan = try data(send(router, "planTrash", ["scanId": id, "paths": [home + "/.gradle"]]))
        XCTAssertEqual(plan["needsAcknowledge"] as? Bool, true)
        let planId = try XCTUnwrap(plan["planId"] as? String)
        assertError(try send(router, "confirmTrash", ["planId": planId, "acknowledgeReview": false]), contains: "onay")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.gradle"))
        XCTAssertEqual((try data(send(router, "confirmTrash", ["planId": planId, "acknowledgeReview": true]))["failedCount"] as? NSNumber)?.intValue, 0)
    }

    func testCleanupDisabledWithoutTrasher() throws {
        let id = try savedScan()
        assertError(try send(try router(enabled: false), "planTrash", ["scanId": id, "paths": [home + "/.npm"]]), contains: "kapalı")
    }

    func testCleanupBlockedWhileScanning() throws {
        let id = try savedScan()
        let gate = DispatchSemaphore(value: 0)
        let report = try store.load(id: id)
        let router = try router(runner: { _, _, _, _ in gate.wait(); return report })
        XCTAssertEqual(try send(router, "startScan", ["scope": "data"])["ok"] as? Bool, true)
        assertError(try send(router, "planTrash", ["scanId": id, "paths": [home + "/.npm"]]), contains: "Tarama sürerken")
        gate.signal()
        for _ in 0..<500 where router.isScanning { Thread.sleep(forTimeInterval: 0.01) }
    }

    func testScanBlockedWhileCleaning() throws {
        let id = try savedScan()
        let trasher = GateTrasher()
        let router = try router(trasher: trasher)
        let plan = try data(send(router, "planTrash", ["scanId": id, "paths": [home + "/.npm"]]))
        let planId = try XCTUnwrap(plan["planId"] as? String)
        let done = expectation(description: "confirm")
        DispatchQueue.global().async {
            _ = try? self.send(router, "confirmTrash", ["planId": planId, "acknowledgeReview": false])
            done.fulfill()
        }
        XCTAssertEqual(trasher.started.wait(timeout: .now() + 5), .success)
        assertError(try send(router, "startScan", ["scope": "data"]), contains: "Temizlik sürerken")
        assertError(try send(router, "planTrash", ["scanId": id, "paths": [home + "/.npm"]]), contains: "Temizlik sürüyor")
        trasher.proceed.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(try send(router, "startScan", ["scope": "data"])["ok"] as? Bool, true)
        for _ in 0..<500 where router.isScanning { Thread.sleep(forTimeInterval: 0.01) }
    }

    func testPolicyAloneRejectsDangerousCatalogAcceptedPaths() throws {
        // Tarayıcı adayları izin kümesine girer; yine de ana klasör, kapsayıcı ve kişisel klasörler politika tarafından reddedilmeli.
        try tree.file("home/Library/Caches/x", size: 10)
        try tree.file("home/Documents/x/node_modules/m", size: 10)
        let url = try XCTUnwrap(Bundle.module.url(forResource: "legacy-schema1", withExtension: "json", subdirectory: "Fixtures"))
        var report = try ReportCodec.decode(try Data(contentsOf: url))
        report.schema = 2
        report.homePath = home
        report.folderIndex = [home + "/other": gb]
        func candidate(_ path: String) -> Candidate { Candidate(name: "x", path: path, bytes: gb, logical: gb, category: .cache, label: "l", note: "n") }
        report.candidates = [candidate(home), candidate(home + "/Library/Caches"), candidate(home + "/Documents/x/node_modules")]
        let id = try store.save(report)
        let router = try router()
        let paths = [home, home + "/Library/Caches", home + "/Documents/x/node_modules"]
        let plan = try data(send(router, "planTrash", ["scanId": id, "paths": paths]))
        let items = try XCTUnwrap(plan["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["status"] as? String }, ["rejected", "rejected", "rejected"])
        let reasons = items.compactMap { $0["reason"] as? String }
        XCTAssertTrue(reasons[0].contains("Ana klasörün"), reasons[0])
        XCTAssertTrue(reasons[1].contains("kendisi taşınamaz"), reasons[1])
        XCTAssertTrue(reasons[2].contains("Kişisel"), reasons[2])
    }

    func testConfirmIsBlockedWhileScanning() throws {
        let id = try savedScan()
        let gate = DispatchSemaphore(value: 0)
        let report = try store.load(id: id)
        let router = try router(runner: { _, _, _, _ in gate.wait(); return report })
        let plan = try data(send(router, "planTrash", ["scanId": id, "paths": [home + "/.npm"]]))
        XCTAssertEqual(try send(router, "startScan", ["scope": "data"])["ok"] as? Bool, true)
        assertError(try send(router, "confirmTrash", ["planId": try XCTUnwrap(plan["planId"] as? String), "acknowledgeReview": false]), contains: "Tarama sürerken")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.npm"))
        gate.signal()
        for _ in 0..<500 where router.isScanning { Thread.sleep(forTimeInterval: 0.01) }
    }

    func testLoadScanReportsBlockedPathsAndStaleAfterMove() throws {
        let id = try savedScan(index: [home + "/.npm": 3 * gb, home + "/Library/Caches": 2 * gb])
        let router = try router()
        var loaded = try data(send(router, "loadScan", ["id": id]))
        var cleanup = try XCTUnwrap(loaded["cleanup"] as? [String: Any])
        XCTAssertEqual(Set((cleanup["blocked"] as? [String: String] ?? [:]).keys), [home + "/Library/Caches"])
        XCTAssertEqual(cleanup["stale"] as? Bool, false)
        let plan = try data(send(router, "planTrash", ["scanId": id, "paths": [home + "/.npm"]]))
        _ = try data(send(router, "confirmTrash", ["planId": try XCTUnwrap(plan["planId"] as? String), "acknowledgeReview": false]))
        loaded = try data(send(router, "loadScan", ["id": id]))
        cleanup = try XCTUnwrap(loaded["cleanup"] as? [String: Any])
        XCTAssertEqual(cleanup["stale"] as? Bool, true, "taşımadan sonra aynı tarama tekrar açılsa da güncel değil sayılır")
    }
}
