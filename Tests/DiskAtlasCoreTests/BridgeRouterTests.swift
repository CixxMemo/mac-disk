import XCTest
@testable import DiskAtlasCore

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [[String: Any]] = []

    func append(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lock.lock(); events.append(object); lock.unlock()
    }

    func wait(for name: String, timeout: TimeInterval = 10) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let found = events.first { $0["event"] as? String == name }
            lock.unlock()
            if let found { return found }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

final class BridgeRouterTests: XCTestCase {
    private var tree: TempTree!
    private var storeDirectory: URL!
    private var store: ReportStore!
    fileprivate var log: EventLog!

    override func setUpWithError() throws {
        tree = try TempTree()
        storeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("diskatlas-bridge-\(UUID().uuidString)")
        store = ReportStore(directory: storeDirectory)
        log = EventLog()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeDirectory)
    }

    private func fixtureReport() throws -> Report {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "legacy-schema1", withExtension: "json", subdirectory: "Fixtures"))
        return try ReportCodec.decode(try Data(contentsOf: url))
    }

    private func makeRouter(permission: @escaping @Sendable () -> PermissionStatus = { .granted },
                            openSettings: @escaping @Sendable () -> Void = {},
                            runner: @escaping ScanRunner = BridgeRouter.defaultRunner) throws -> BridgeRouter {
        let log = self.log!
        return BridgeRouter(store: store, rules: try RuleSet.bundled(),
                            roots: ScanRoots(data: tree.path(), home: tree.path("home"), excluded: ["/excluded"]),
                            appInfo: AppInfo(version: "9.9", macOS: "15.0"),
                            permission: permission, openFullDiskAccess: openSettings,
                            emit: { log.append($0) }, runner: runner)
    }

    private func send(_ router: BridgeRouter, _ type: String, _ payload: [String: Any] = [:], id: String = "1") throws -> [String: Any] {
        let message = try JSONSerialization.data(withJSONObject: ["id": id, "type": type, "payload": payload])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: router.handle(message)) as? [String: Any])
    }

    private func assertError(_ response: [String: Any], contains text: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response["ok"] as? Bool, false, file: file, line: line)
        let message = response["error"] as? String ?? ""
        XCTAssertFalse(message.isEmpty, file: file, line: line)
        if let text { XCTAssertTrue(message.contains(text), message, file: file, line: line) }
    }

    func testRejectsMalformedMessages() throws {
        let router = try makeRouter()
        let garbage = [Data([0xff, 0x00, 0x7b]), Data("{}".utf8), Data(#"{"id":"1"}"#.utf8), Data(#"{"type":"listScans"}"#.utf8),
                       Data(#"{"id":5,"type":"listScans"}"#.utf8), Data("[]".utf8), Data()]
        for message in garbage {
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: router.handle(message)) as? [String: Any])
            assertError(response)
        }
        assertError(try send(router, "listScans", id: String(repeating: "a", count: 65)))
        assertError(try send(router, "doesNotExist"), contains: "Bilinmeyen")
        assertError(try send(router, "startScan", ["scope": "/etc"]), contains: "kapsam")
        assertError(try send(router, "startScan"), contains: "kapsam")
        assertError(try send(router, "loadScan", ["id": 5]))
        XCTAssertFalse(router.isScanning)
    }

    func testStartScanSavesReportAndEmitsDone() throws {
        let file = try tree.file("a.bin", size: 4000)
        let router = try makeRouter()
        let started = try send(router, "startScan", ["scope": "data"])
        XCTAssertEqual(started["ok"] as? Bool, true)
        let done = try XCTUnwrap(log.wait(for: "scanDone"))
        let id = try XCTUnwrap(done["id"] as? String)
        XCTAssertFalse(router.isScanning)

        let list = try XCTUnwrap(try send(router, "listScans")["data"] as? [[String: Any]])
        XCTAssertEqual(list.map { $0["id"] as? String }, [id])

        let loaded = try send(router, "loadScan", ["id": id])
        let report = try XCTUnwrap(loaded["data"] as? [String: Any])
        let rootNode = try XCTUnwrap(report["tree"] as? [String: Any])
        XCTAssertEqual((rootNode["bytes"] as? NSNumber)?.int64Value, TestSupport.allocated(file))
        XCTAssertNil(report["folderIndex"])
    }

    func testSecondStartScanIsRejectedWhileRunning() throws {
        let gate = DispatchSemaphore(value: 0)
        let report = try fixtureReport()
        let router = try makeRouter(runner: { _, _, _, _ in gate.wait(); return report })
        XCTAssertEqual(try send(router, "startScan", ["scope": "data"])["ok"] as? Bool, true)
        XCTAssertTrue(router.isScanning)
        assertError(try send(router, "startScan", ["scope": "data"], id: "2"), contains: "zaten sürüyor")
        gate.signal()
        XCTAssertNotNil(log.wait(for: "scanDone"))
        XCTAssertFalse(router.isScanning)
        XCTAssertEqual(try send(router, "listScans")["data"].flatMap { ($0 as? [Any])?.count }, 1)
    }

    func testCancelPassesFlagToRunnerAndSavesPartialReport() throws {
        var partial = try fixtureReport()
        partial.incomplete = true
        let report = partial
        let router = try makeRouter(runner: { _, _, isCancelled, _ in
            let deadline = Date().addingTimeInterval(10)
            while !isCancelled() && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            return report
        })
        XCTAssertEqual(try send(router, "cancelScan")["ok"] as? Bool, true)  // taramaz iken zararsız
        XCTAssertEqual(try send(router, "startScan", ["scope": "data"])["ok"] as? Bool, true)
        XCTAssertEqual(try send(router, "cancelScan", id: "3")["ok"] as? Bool, true)
        let done = try XCTUnwrap(log.wait(for: "scanDone"))
        let loaded = try store.load(id: try XCTUnwrap(done["id"] as? String))
        XCTAssertTrue(loaded.incomplete)
    }

    func testScanFailureEmitsScanFailedAndAllowsRetry() throws {
        let router = try makeRouter(runner: { _, _, _, _ in throw ScanFailure.rootUnreadable("/x") })
        XCTAssertEqual(try send(router, "startScan", ["scope": "data"])["ok"] as? Bool, true)
        let failed = try XCTUnwrap(log.wait(for: "scanFailed"))
        XCTAssertTrue((failed["message"] as? String ?? "").contains("/x"))
        XCTAssertFalse(router.isScanning)
        XCTAssertEqual(try send(router, "startScan", ["scope": "data"], id: "2")["ok"] as? Bool, true)
    }

    func testLoadScanRejectsTraversalAndUnknownIDs() throws {
        let router = try makeRouter()
        for bad in ["../x", "/etc/passwd", "scan-1/../2", ""] {
            assertError(try send(router, "loadScan", ["id": bad]), contains: "Geçersiz")
        }
        assertError(try send(router, "loadScan", ["id": "scan-123"]), contains: "bulunamadı")
    }

    func testPermissionOpenSettingsAndAppInfo() throws {
        let opened = Box(0)
        let router = try makeRouter(permission: { .denied }, openSettings: { opened.value += 1 })
        let status = try send(router, "permissionStatus")
        XCTAssertEqual((status["data"] as? [String: Any])?["status"] as? String, "denied")
        XCTAssertEqual(try send(router, "openFullDiskAccess")["ok"] as? Bool, true)
        XCTAssertEqual(opened.value, 1)
        let info = try XCTUnwrap(try send(router, "appInfo")["data"] as? [String: Any])
        XCTAssertEqual(info["version"] as? String, "9.9")
        XCTAssertEqual(info["macOS"] as? String, "15.0")
    }

    func testScopesAndExclusionsReachTheRunner() throws {
        let captured = Box<[ScanOptions]>([])
        let report = try fixtureReport()
        let router = try makeRouter(runner: { options, _, _, _ in captured.value.append(options); return report })
        XCTAssertEqual(try send(router, "startScan", ["scope": "home"])["ok"] as? Bool, true)
        XCTAssertNotNil(log.wait(for: "scanDone"))
        let options = try XCTUnwrap(captured.value.first)
        XCTAssertEqual(options.root, tree.path("home"))
        XCTAssertTrue(options.excludedPaths.contains("/excluded"))
        XCTAssertTrue(options.excludedPaths.contains(store.directoryPath))
        XCTAssertLessThanOrEqual(options.progressInterval, 1, "ilerleme en az saniyede bir bildirilmeli")
    }

    func testProgressEventsAreForwarded() throws {
        let report = try fixtureReport()
        let router = try makeRouter(runner: { _, _, _, progress in
            progress(ScanProgress(records: 42, errors: 3, currentPath: "/Users/x", elapsed: 1.5))
            return report
        })
        XCTAssertEqual(try send(router, "startScan", ["scope": "data"])["ok"] as? Bool, true)
        let event = try XCTUnwrap(log.wait(for: "scanProgress"))
        XCTAssertEqual(event["records"] as? Int, 42)
        XCTAssertEqual(event["errors"] as? Int, 3)
        XCTAssertEqual(event["folder"] as? String, "/Users/x")
        XCTAssertEqual(event["elapsed"] as? Double, 1.5)
    }

    func testSavedReportRecordsFullDiskAccessAtScanTime() throws {
        let report = try fixtureReport()
        for (status, expected) in [(PermissionStatus.denied, "denied"), (.granted, "granted")] {
            let router = try makeRouter(permission: { status }, runner: { _, _, _, _ in report })
            XCTAssertEqual(try send(router, "startScan", ["scope": "data"], id: expected)["ok"] as? Bool, true)
            let done = try XCTUnwrap(log.wait(for: "scanDone"))
            let id = try XCTUnwrap(done["id"] as? String)
            XCTAssertEqual(try store.load(id: id).fullDiskAccess, expected)
            log = EventLog()
        }
    }

    // MARK: Geçmiş: compare ve deleteScan

    private func saveScan(created: String, index: [String: Int64]?) throws -> String {
        var report = try fixtureReport()
        report.schema = 2
        report.created = created
        report.folderIndex = index
        report.tree.bytes = index?.values.reduce(0, +) ?? 0
        return try store.save(report)
    }

    func testCompareOrdersByCreatedAndReturnsDiff() throws {
        let mib: Int64 = 1024 * 1024
        let older = try saveScan(created: "2026-10-18T08:00:00.000000+00:00", index: ["/a": 10 * mib])
        let newer = try saveScan(created: "2026-10-19T08:00:00.000000+00:00", index: ["/a": 14 * mib])
        let router = try makeRouter()
        let response = try send(router, "compare", ["older": newer, "newer": older])  // kasıtlı ters sırada
        XCTAssertEqual(response["ok"] as? Bool, true)
        let data = try XCTUnwrap(response["data"] as? [String: Any])
        XCTAssertEqual(data["olderId"] as? String, older)
        XCTAssertEqual(data["newerId"] as? String, newer)
        XCTAssertEqual(data["olderCreated"] as? String, "2026-10-18T08:00:00.000000+00:00")
        let diff = try XCTUnwrap(data["diff"] as? [String: Any])
        let items = try XCTUnwrap(diff["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["path"] as? String, "/a")
        XCTAssertEqual((items[0]["delta"] as? NSNumber)?.int64Value, 4 * mib)
        XCTAssertEqual(items[0]["status"] as? String, "grew")
    }

    func testCompareRejectsSameInvalidAndMissingIDs() throws {
        let id = try saveScan(created: "2026-10-18T08:00:00.000000+00:00", index: [:])
        let router = try makeRouter()
        assertError(try send(router, "compare", ["older": id, "newer": id]), contains: "İki farklı")
        assertError(try send(router, "compare", ["older": id, "newer": "../x"]), contains: "Geçersiz")
        assertError(try send(router, "compare", ["older": id, "newer": "scan-999"]), contains: "bulunamadı")
        assertError(try send(router, "compare", ["older": id]))
        assertError(try send(router, "compare", ["older": 1, "newer": 2]))
    }

    func testCompareLegacyScanGivesClearError() throws {
        let legacy = try saveScan(created: "2026-10-17T08:00:00.000000+00:00", index: nil)
        let good = try saveScan(created: "2026-10-19T08:00:00.000000+00:00", index: ["/a": 2_000_000])
        assertError(try send(try makeRouter(), "compare", ["older": legacy, "newer": good]), contains: "karşılaştırma için gerekli")
    }

    func testDeleteScanRemovesFromListAndRejectsBadIDs() throws {
        let keep = try saveScan(created: "2026-10-18T08:00:00.000000+00:00", index: [:])
        let drop = try saveScan(created: "2026-10-19T08:00:00.000000+00:00", index: [:])
        let router = try makeRouter()
        XCTAssertEqual(try send(router, "deleteScan", ["id": drop])["ok"] as? Bool, true)
        let list = try XCTUnwrap(try send(router, "listScans")["data"] as? [[String: Any]])
        XCTAssertEqual(list.map { $0["id"] as? String }, [keep])
        assertError(try send(router, "deleteScan", ["id": drop]), contains: "bulunamadı")
        for bad in ["../x", "/etc/passwd", ""] { assertError(try send(router, "deleteScan", ["id": bad]), contains: "Geçersiz") }
        assertError(try send(router, "deleteScan"))
    }

    func testDeleteScanWorksWhileScanning() throws {
        let saved = try saveScan(created: "2026-10-18T08:00:00.000000+00:00", index: [:])
        let gate = DispatchSemaphore(value: 0)
        let report = try fixtureReport()
        let router = try makeRouter(runner: { _, _, _, _ in gate.wait(); return report })
        XCTAssertEqual(try send(router, "startScan", ["scope": "data"])["ok"] as? Bool, true)
        XCTAssertEqual(try send(router, "deleteScan", ["id": saved], id: "2")["ok"] as? Bool, true)
        gate.signal()
        XCTAssertNotNil(log.wait(for: "scanDone"))
    }

    // MARK: Uygulamalar: homePath ve loadScan yükü

    func testStartScanRecordsHomePath() throws {
        let report = try fixtureReport()
        let router = try makeRouter(runner: { _, _, _, _ in report })
        XCTAssertEqual(try send(router, "startScan", ["scope": "data"])["ok"] as? Bool, true)
        let done = try XCTUnwrap(log.wait(for: "scanDone"))
        XCTAssertEqual(try store.load(id: try XCTUnwrap(done["id"] as? String)).homePath, tree.path("home"))
    }

    func testLoadScanIncludesAppsAndUIFindings() throws {
        var report = try fixtureReport()
        report.schema = 2
        report.homePath = "/Users/me"
        report.folderIndex = ["/Users/me/Library/Android/sdk": 14_000_000_000, "/Users/me/.npm": 3_000_000_000]
        let id = try store.save(report)
        let data = try XCTUnwrap(try send(try makeRouter(), "loadScan", ["id": id])["data"] as? [String: Any])
        let apps = try XCTUnwrap((data["apps"] as? [String: Any])?["apps"] as? [[String: Any]])
        XCTAssertTrue(apps.contains { $0["name"] as? String == "Android" })
        let ui = try XCTUnwrap(data["ui"] as? [String: Any])
        XCTAssertEqual(ui["homePath"] as? String, "/Users/me")
        let findings = try XCTUnwrap(ui["findings"] as? [[String: Any]])
        XCTAssertTrue(findings.contains { ($0["path"] as? String)?.hasSuffix("/Android/sdk") == true })
        XCTAssertNil(data["folderIndex"])
    }

    func testLoadScanOfScanWithoutFolderIndexOmitsAppsAndUI() throws {
        let id = try store.save(try fixtureReport())      // şema 1, klasör dizini yok
        let data = try XCTUnwrap(try send(try makeRouter(), "loadScan", ["id": id])["data"] as? [String: Any])
        XCTAssertNil(data["apps"])
        XCTAssertNil(data["ui"])
        XCTAssertNotNil(data["tree"])
    }
}
