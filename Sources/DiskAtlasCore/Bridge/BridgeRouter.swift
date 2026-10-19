import Foundation

public struct ScanRoots: Sendable {
    public var data: String
    public var home: String
    public var excluded: [String]

    public init(data: String, home: String, excluded: [String] = []) {
        self.data = data
        self.home = home
        self.excluded = excluded
    }
}

public struct AppInfo: Codable, Sendable, Equatable {
    public var version: String
    public var macOS: String

    public init(version: String, macOS: String) {
        self.version = version
        self.macOS = macOS
    }
}

public typealias ScanRunner = @Sendable (ScanOptions, Classifier, @escaping () -> Bool, @escaping (ScanProgress) -> Void) throws -> Report

/// Arayüz (JS) ile Swift arasındaki köprünün mantığı. Girdi ve çıktı JSON metnidir; WebKit'ten bağımsızdır.
/// JS'e güvenilmez: her mesaj doğrulanır, dosya yolu JS'ten alınmaz (kapsam ve kimlik doğrulanır).
public final class BridgeRouter: @unchecked Sendable {
    public static let defaultRunner: ScanRunner = { options, classifier, isCancelled, progress in
        try DiskScanner(options: options, classifier: classifier).run(isCancelled: isCancelled, progress: progress)
    }

    private struct Failure: Error { var message: String }

    private let store: ReportStore
    private let rules: RuleSet
    private let classifier: Classifier
    private let roots: ScanRoots
    private let appInfo: AppInfo
    private let permission: @Sendable () -> PermissionStatus
    private let openFullDiskAccess: @Sendable () -> Void
    private let emit: @Sendable (Data) -> Void
    private let runner: ScanRunner

    private let lock = NSLock()
    private var scanning = false
    private var cancelRequested = false

    public init(store: ReportStore, rules: RuleSet, roots: ScanRoots, appInfo: AppInfo,
                permission: @escaping @Sendable () -> PermissionStatus,
                openFullDiskAccess: @escaping @Sendable () -> Void,
                emit: @escaping @Sendable (Data) -> Void,
                runner: @escaping ScanRunner = BridgeRouter.defaultRunner) {
        self.store = store
        self.rules = rules
        self.classifier = Classifier(rules: rules)
        self.roots = roots
        self.appInfo = appInfo
        self.permission = permission
        self.openFullDiskAccess = openFullDiskAccess
        self.emit = emit
        self.runner = runner
    }

    public var isScanning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return scanning
    }

    public func handle(_ message: Data) -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any] else {
            return failure(id: "", "Geçersiz köprü mesajı.")
        }
        guard let id = object["id"] as? String, !id.isEmpty, id.count <= 64 else {
            return failure(id: "", "Köprü mesajında geçerli bir kimlik yok.")
        }
        guard let type = object["type"] as? String else { return failure(id: id, "Köprü mesajında tür yok.") }
        let payload = object["payload"] as? [String: Any] ?? [:]
        do {
            return success(id: id, try dispatch(type, payload))
        } catch let error as Failure {
            return failure(id: id, error.message)
        } catch {
            return failure(id: id, "İşlem başarısız oldu.")
        }
    }

    private func dispatch(_ type: String, _ payload: [String: Any]) throws -> Data {
        switch type {
        case "startScan": return try startScan(scope: payload["scope"] as? String)
        case "cancelScan":
            lock.lock()
            if scanning { cancelRequested = true }
            lock.unlock()
            return Data("{}".utf8)
        case "listScans": return try JSONEncoder().encode(store.list())
        case "loadScan": return try loadScan(id: payload["id"] as? String)
        case "deleteScan": return try deleteScan(id: payload["id"] as? String)
        case "compare": return try compare(older: payload["older"] as? String, newer: payload["newer"] as? String)
        case "permissionStatus": return try JSONEncoder().encode(["status": permission().rawValue])
        case "openFullDiskAccess":
            openFullDiskAccess()
            return Data("{}".utf8)
        case "appInfo": return try JSONEncoder().encode(appInfo)
        default: throw Failure(message: "Bilinmeyen köprü işlemi: \(type)")
        }
    }

    private func deleteScan(id: String?) throws -> Data {
        guard let id else { throw Failure(message: "Geçersiz tarama kimliği.") }
        do {
            try store.delete(id: id)
            return Data("{}".utf8)
        } catch ReportStoreError.invalidID {
            throw Failure(message: "Geçersiz tarama kimliği.")
        } catch ReportStoreError.notFound {
            throw Failure(message: "Tarama bulunamadı.")
        } catch {
            throw Failure(message: "Tarama silinemedi.")
        }
    }

    private struct CompareResponse: Encodable {
        var olderId: String
        var newerId: String
        var olderCreated: String
        var newerCreated: String
        var diff: ScanDiff
    }

    /// Kullanıcı hangisini önce seçerse seçsin eski/yeni `created`'a göre belirlenir.
    private func compare(older: String?, newer: String?) throws -> Data {
        guard let older, let newer else { throw Failure(message: "Karşılaştırmak için iki tarama seç.") }
        guard older != newer else { throw Failure(message: "İki farklı tarama seç.") }
        func load(_ id: String) throws -> Report {
            do { return try store.load(id: id) }
            catch ReportStoreError.invalidID { throw Failure(message: "Geçersiz tarama kimliği.") }
            catch ReportStoreError.notFound { throw Failure(message: "Tarama bulunamadı.") }
            catch { throw Failure(message: "Tarama okunamadı.") }
        }
        var pair = [(id: older, report: try load(older)), (id: newer, report: try load(newer))]
        if pair[0].report.created > pair[1].report.created { pair.swapAt(0, 1) }
        do {
            let diff = try Differ.compare(older: pair[0].report, newer: pair[1].report)
            return try JSONEncoder().encode(CompareResponse(olderId: pair[0].id, newerId: pair[1].id,
                                                            olderCreated: pair[0].report.created,
                                                            newerCreated: pair[1].report.created, diff: diff))
        } catch let error as DiffError {
            throw Failure(message: error.description)
        }
    }

    private func loadScan(id: String?) throws -> Data {
        guard let id else { throw Failure(message: "Geçersiz tarama kimliği.") }
        do {
            return try JSONEncoder().encode(DisplayEnvelope(report: try store.load(id: id), rules: rules))
        } catch ReportStoreError.invalidID {
            throw Failure(message: "Geçersiz tarama kimliği.")
        } catch ReportStoreError.notFound {
            throw Failure(message: "Tarama bulunamadı.")
        } catch {
            throw Failure(message: "Tarama okunamadı.")
        }
    }

    private func startScan(scope: String?) throws -> Data {
        let root: String
        switch scope {
        case "data": root = roots.data
        case "home": root = roots.home
        default: throw Failure(message: "Geçersiz tarama kapsamı.")
        }
        lock.lock()
        if scanning {
            lock.unlock()
            throw Failure(message: "Tarama zaten sürüyor.")
        }
        scanning = true
        cancelRequested = false
        lock.unlock()

        let options = ScanOptions(root: root, excludedPaths: roots.excluded + [store.directoryPath], progressInterval: 1)
        let access = permission()
        let home = classifier.displayPath(roots.home)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let finalEvent: [String: Any]
            do {
                var report = try runner(options, classifier, { [self] in
                    lock.lock()
                    defer { lock.unlock() }
                    return cancelRequested
                }, { [self] progress in
                    send(["event": "scanProgress", "records": progress.records, "errors": progress.errors,
                          "folder": progress.currentPath, "elapsed": progress.elapsed])
                })
                report.fullDiskAccess = access.rawValue
                report.homePath = home
                finalEvent = ["event": "scanDone", "id": try store.save(report)]
            } catch let failure as ScanFailure {
                finalEvent = ["event": "scanFailed", "message": failure.description]
            } catch {
                finalEvent = ["event": "scanFailed", "message": "Tarama başarısız oldu: \(error.localizedDescription)"]
            }
            lock.lock()
            scanning = false
            lock.unlock()
            send(finalEvent)
        }
        return Data(#"{"started":true}"#.utf8)
    }

    private func send(_ event: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: event) { emit(data) }
    }

    private func success(id: String, _ data: Data) -> Data {
        var out = Data(#"{"id":"#.utf8)
        out.append(jsonString(id))
        out.append(Data(#","ok":true,"data":"#.utf8))
        out.append(data)
        out.append(Data("}".utf8))
        return out
    }

    private func failure(id: String, _ message: String) -> Data {
        var out = Data(#"{"id":"#.utf8)
        out.append(jsonString(id))
        out.append(Data(#","ok":false,"error":"#.utf8))
        out.append(jsonString(message))
        out.append(Data("}".utf8))
        return out
    }

    private func jsonString(_ value: String) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
    }
}
