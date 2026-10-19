import Foundation

public struct ScanRoots: Sendable {
    public var data: String
    public var home: String
    public var excluded: [String]
    /// Uygulama paketlerinin bulunduğu klasör (yalnızca doğrudan `.app` alt öğeleri taşınabilir).
    public var applications: String

    public init(data: String, home: String, excluded: [String] = [], applications: String = "/Applications") {
        self.data = data
        self.home = home
        self.excluded = excluded
        self.applications = applications
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
    private let trasher: Trasher?
    private let actionLogURL: URL?

    private struct PendingPlan {
        var plan: TrashPlan
        var service: TrashService
    }
    private static let planLifetime: TimeInterval = 600
    private static let maxPlans = 5
    private static let maxTrashPaths = 200

    private let lock = NSLock()
    private var scanning = false
    private var cleaning = false
    private var cancelRequested = false
    private var pendingPlans: [String: PendingPlan] = [:]
    private var cleanedScans = Set<String>()

    public init(store: ReportStore, rules: RuleSet, roots: ScanRoots, appInfo: AppInfo,
                permission: @escaping @Sendable () -> PermissionStatus,
                openFullDiskAccess: @escaping @Sendable () -> Void,
                emit: @escaping @Sendable (Data) -> Void,
                runner: @escaping ScanRunner = BridgeRouter.defaultRunner,
                trasher: Trasher? = nil, actionLogURL: URL? = nil) {
        self.trasher = trasher
        self.actionLogURL = actionLogURL
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
        case "capabilities": return try JSONEncoder().encode(["cleanup": cleanupEnabled])
        case "planTrash": return try planTrash(scanId: payload["scanId"] as? String, paths: payload["paths"])
        case "confirmTrash": return try confirmTrash(planId: payload["planId"] as? String, acknowledge: payload["acknowledgeReview"] as? Bool ?? false)
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
            lock.lock()
            let stale = cleanedScans.contains(id)
            lock.unlock()
            return try JSONEncoder().encode(DisplayEnvelope(report: try store.load(id: id), rules: rules,
                                                            policy: cleanupEnabled ? makePolicy() : nil, stale: stale))
        } catch ReportStoreError.invalidID {
            throw Failure(message: "Geçersiz tarama kimliği.")
        } catch ReportStoreError.notFound {
            throw Failure(message: "Tarama bulunamadı.")
        } catch {
            throw Failure(message: "Tarama okunamadı.")
        }
    }

    // MARK: Temizlik (Çöp Sepeti)

    private var cleanupEnabled: Bool { trasher != nil && actionLogURL != nil }

    private struct PlanResponse: Encodable {
        var planId: String
        var items: [TrashPlanItem]
        var totalBytes: Int64
        var needsAcknowledge: Bool
        var acceptedCount: Int
    }

    private func planTrash(scanId: String?, paths: Any?) throws -> Data {
        guard let trasher, let actionLogURL else { throw Failure(message: "Temizlik bu kurulumda kapalı.") }
        guard let scanId else { throw Failure(message: "Geçersiz tarama kimliği.") }
        guard let requested = paths as? [String] else { throw Failure(message: "Geçersiz yol listesi.") }
        guard !requested.isEmpty else { throw Failure(message: "Taşımak için en az bir öğe seç.") }
        guard requested.count <= Self.maxTrashPaths else { throw Failure(message: "Tek seferde en fazla \(Self.maxTrashPaths) öğe taşınabilir.") }
        try requireIdle()

        let report: Report
        do { report = try store.load(id: scanId) }
        catch ReportStoreError.invalidID { throw Failure(message: "Geçersiz tarama kimliği.") }
        catch ReportStoreError.notFound { throw Failure(message: "Tarama bulunamadı.") }
        catch { throw Failure(message: "Tarama okunamadı.") }

        // Yetki sunucudadır: izin kümesi ve korumalı yollar taramanın kataloğundan, kök bu bilgisayarın ana klasöründen gelir.
        let service = TrashService(policy: makePolicy(), trasher: trasher, log: ActionLog(url: actionLogURL))
        let plan = service.plan(scanId: scanId, requested: requested, allowed: CleanupCatalog.candidates(report: report, rules: rules))

        lock.lock()
        let now = Date()
        pendingPlans = pendingPlans.filter { now.timeIntervalSince($0.value.plan.created) < Self.planLifetime }
        while pendingPlans.count >= Self.maxPlans, let oldest = pendingPlans.min(by: { $0.value.plan.created < $1.value.plan.created }) {
            pendingPlans[oldest.key] = nil
        }
        pendingPlans[plan.id] = PendingPlan(plan: plan, service: service)
        lock.unlock()
        return try JSONEncoder().encode(PlanResponse(planId: plan.id, items: plan.items, totalBytes: plan.totalBytes,
                                                     needsAcknowledge: plan.needsAcknowledge, acceptedCount: plan.acceptedCount))
    }

    private func makePolicy() -> TrashPolicy {
        let home = URL(fileURLWithPath: roots.home).standardizedFileURL.path
        return TrashPolicy(home: home, applications: roots.applications,
                           protectedPaths: CleanupCatalog.protectedPaths(rules: rules, home: home))
    }

    private func confirmTrash(planId: String?, acknowledge: Bool) throws -> Data {
        guard cleanupEnabled else { throw Failure(message: "Temizlik bu kurulumda kapalı.") }
        lock.lock()
        if scanning {
            lock.unlock()
            throw Failure(message: "Tarama sürerken temizlik yapılamaz.")
        }
        if cleaning {
            lock.unlock()
            throw Failure(message: "Temizlik sürüyor; bitmesini bekle.")
        }
        guard let planId, let pending = pendingPlans[planId],
              Date().timeIntervalSince(pending.plan.created) < Self.planLifetime else {
            pendingPlans[planId ?? ""] = nil
            lock.unlock()
            throw Failure(message: "Plan bulunamadı veya süresi doldu; öğeleri yeniden seç.")
        }
        if pending.plan.needsAcknowledge && !acknowledge {
            lock.unlock()
            throw Failure(message: "İncele düzeyindeki öğeler için ek onay gerekiyor.")
        }
        pendingPlans[planId] = nil
        cleaning = true
        lock.unlock()
        defer {
            lock.lock()
            cleaning = false
            lock.unlock()
        }
        do {
            let outcome = try pending.service.execute(pending.plan, acknowledgeReview: acknowledge)
            if outcome.results.contains(where: \.ok) {
                lock.lock()
                cleanedScans.insert(pending.plan.scanId)
                lock.unlock()
            }
            return try JSONEncoder().encode(outcome)
        } catch TrashError.logUnavailable {
            throw Failure(message: "Temizlik günlüğü yazılamadığı için hiçbir şey taşınmadı.")
        } catch TrashError.nothingToDo {
            throw Failure(message: "Taşınacak öğe yok.")
        } catch TrashError.acknowledgementRequired {
            throw Failure(message: "İncele düzeyindeki öğeler için ek onay gerekiyor.")
        }
    }

    private func requireIdle() throws {
        lock.lock()
        defer { lock.unlock() }
        if scanning { throw Failure(message: "Tarama sürerken temizlik yapılamaz.") }
        if cleaning { throw Failure(message: "Temizlik sürüyor; bitmesini bekle.") }
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
        if cleaning {
            lock.unlock()
            throw Failure(message: "Temizlik sürerken tarama başlatılamaz.")
        }
        scanning = true
        cancelRequested = false
        lock.unlock()

        let options = ScanOptions(root: root, excludedPaths: roots.excluded + [store.directoryPath], progressInterval: 1)
        let access = permission()
        // Tarayıcı kökü `standardizedFileURL` ile normalleştirir; ana klasör de aynı biçimde saklanır.
        let home = classifier.displayPath(URL(fileURLWithPath: roots.home).standardizedFileURL.path)
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
