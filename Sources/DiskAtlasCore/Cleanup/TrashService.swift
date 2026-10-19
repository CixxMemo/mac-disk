import Foundation

/// Bir yolu Çöp Sepeti'ne (veya testlerde başka bir klasöre) taşır; yeni konumu döner.
public protocol Trasher: Sendable {
    func trash(_ path: String) throws -> String?
}

/// Gerçek Çöp Sepeti: yalnızca `FileManager.trashItem` (kalıcı silme yok; "Geri Koy" çalışır).
public struct FileManagerTrasher: Trasher {
    public init() {}

    public func trash(_ path: String) throws -> String? {
        var result: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
        return (result as URL?)?.path
    }
}

/// Test ve `--self-test` için: öğeyi gerçek Çöp Sepeti yerine verilen klasöre taşır, hiçbir şeyin üzerine yazmaz.
public struct DirectoryTrasher: Trasher {
    private let directory: String

    public init(directory: String) {
        self.directory = directory
    }

    public func trash(_ path: String) throws -> String? {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let name = (path as NSString).lastPathComponent
        var target = (directory as NSString).appendingPathComponent(name)
        var counter = 1
        while FileManager.default.fileExists(atPath: target) || (try? FileManager.default.destinationOfSymbolicLink(atPath: target)) != nil {
            counter += 1
            target = (directory as NSString).appendingPathComponent("\(name) \(counter)")
        }
        try FileManager.default.moveItem(atPath: path, toPath: target)
        return target
    }
}

public struct FileFingerprint: Equatable, Sendable {
    var device: Int32
    var inode: UInt64
    var kind: FileStat.Kind
}

public struct TrashPlanItem: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case accepted, rejected, covered }

    public var path: String
    public var name: String
    public var bytes: Int64
    public var safety: Safety?
    public var status: Status
    public var reason: String?
    var fingerprint: FileFingerprint? = nil

    enum CodingKeys: String, CodingKey { case path, name, bytes, safety, status, reason }
}

public struct TrashPlan: Sendable {
    public var id: String
    public var scanId: String
    public var items: [TrashPlanItem]
    public var created: Date

    public var accepted: [TrashPlanItem] { items.filter { $0.status == .accepted } }
    public var acceptedCount: Int { accepted.count }
    public var totalBytes: Int64 { accepted.reduce(0) { $0 + $1.bytes } }
    public var needsAcknowledge: Bool { accepted.contains { $0.safety == .review } }
}

public struct TrashResult: Codable, Equatable, Sendable {
    public var path: String
    public var ok: Bool
    public var reason: String?
    public var trashedTo: String?
}

public struct TrashOutcome: Codable, Equatable, Sendable {
    public var results: [TrashResult]
    public var movedBytes: Int64
    public var failedCount: Int
}

public enum TrashError: Error, Equatable {
    case acknowledgementRequired
    case logUnavailable
    case nothingToDo
}

/// İki aşamalı taşıma: `plan` (hiçbir şeye dokunmaz) → kullanıcı onayı → `execute` (her öğeyi yeniden doğrular).
public final class TrashService: @unchecked Sendable {
    private let policy: TrashPolicy
    private let fileSystem: FileSystem
    private let trasher: Trasher
    private let log: ActionLog

    public init(policy: TrashPolicy, fileSystem: FileSystem = RealFileSystem(), trasher: Trasher, log: ActionLog) {
        self.policy = policy
        self.fileSystem = fileSystem
        self.trasher = trasher
        self.log = log
    }

    public func plan(scanId: String, requested: [String], allowed: [TrashCandidate]) -> TrashPlan {
        let byPath = Dictionary(allowed.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [TrashPlanItem] = []
        var seen = Set<String>()
        for path in requested where seen.insert(path).inserted {
            guard let candidate = byPath[path] else {
                items.append(TrashPlanItem(path: path, name: (path as NSString).lastPathComponent, bytes: 0, safety: nil, status: .rejected,
                                           reason: "Bu öğe taramadaki temizlenebilir öğeler arasında değil."))
                continue
            }
            var item = TrashPlanItem(path: path, name: candidate.name, bytes: candidate.bytes, safety: candidate.safety, status: .rejected)
            switch inspect(path) {
            case .failure(let failure): item.reason = failure.description
            case .success(let fingerprint):
                item.status = .accepted
                item.fingerprint = fingerprint
            }
            items.append(item)
        }
        // Başka bir kabul edilen öğenin içindeki öğe ayrıca taşınmaz ve bayt bir kez sayılır.
        let acceptedPaths = items.filter { $0.status == .accepted }.map(\.path)
        for index in items.indices where items[index].status == .accepted {
            if acceptedPaths.contains(where: { $0 != items[index].path && items[index].path.hasPrefix($0 + "/") }) {
                items[index].status = .covered
                items[index].reason = "Seçilen üst klasörün içinde; ayrıca taşınmaz."
            }
        }
        return TrashPlan(id: UUID().uuidString, scanId: scanId, items: items, created: Date())
    }

    public func execute(_ plan: TrashPlan, acknowledgeReview: Bool) throws -> TrashOutcome {
        guard plan.acceptedCount > 0 else { throw TrashError.nothingToDo }
        guard !plan.needsAcknowledge || acknowledgeReview else { throw TrashError.acknowledgementRequired }
        do { try log.prepare() } catch { throw TrashError.logUnavailable }

        var results: [TrashResult] = []
        var moved: Int64 = 0
        var logBroken = false
        for item in plan.accepted {
            var result = TrashResult(path: item.path, ok: false, reason: nil, trashedTo: nil)
            var logResult = "failed"
            if logBroken {
                result.reason = "Günlük yazılamadığı için bu öğe atlandı."
                results.append(result)
                continue
            }
            if let reason = revalidate(item) {
                result.reason = reason
                logResult = "skipped"
            } else {
                do {
                    result.trashedTo = try trasher.trash(item.path)
                    result.ok = true
                    moved += item.bytes
                    logResult = "trashed"
                } catch {
                    result.reason = "Taşınamadı: \(error.localizedDescription)"
                }
            }
            let entry = ActionLogEntry(time: ISO8601DateFormatter().string(from: Date()), scan: plan.scanId, path: item.path,
                                       bytes: item.bytes, safety: item.safety?.rawValue ?? "", result: logResult,
                                       detail: result.ok ? result.trashedTo : result.reason)
            do { try log.append(entry) } catch { logBroken = true }
            results.append(result)
        }
        return TrashOutcome(results: results, movedBytes: moved, failedCount: results.filter { !$0.ok }.count)
    }

    private func revalidate(_ item: TrashPlanItem) -> String? {
        if let reason = policy.check(item.path) { return reason }
        switch inspect(item.path) {
        case .failure(let failure): return failure.description
        case .success(let fingerprint):
            return fingerprint == item.fingerprint ? nil : "Plandan sonra değişti; bu öğe taşınmadı."
        }
    }

    /// Yolun gerçekten taşınabilir olduğunu dosya sisteminden doğrular ve parmak izini döner.
    private func inspect(_ path: String) -> Result<FileFingerprint, Failure> {
        if let reason = policy.check(path) { return .failure(Failure(reason)) }
        let lower = path.lowercased()
        let root: String
        if lower.hasPrefix(policy.homePath.lowercased() + "/") {
            root = policy.homePath
        } else if let applications = policy.applicationsPath {
            root = applications
        } else {
            return .failure(Failure("Bu konum Disk Atlas'ın temizleyebileceği yerlerin dışında."))
        }
        guard let rootStat = try? fileSystem.lstat(root) else { return .failure(Failure("Kök klasör okunamadı.")) }
        // Köke kadar olan ara klasörler gerçek klasör olmalı: bağlantı üzerinden başka yere taşınmaz.
        var current = root
        let relative = path.dropFirst(root.count).split(separator: "/")
        for component in relative.dropLast() {
            current += "/" + component
            guard let stat = try? fileSystem.lstat(current), stat.kind == .directory else {
                return .failure(Failure("Yolun bir parçası sembolik bağlantı veya klasör değil; taşınmaz."))
            }
        }
        let stat: FileStat
        do { stat = try fileSystem.lstat(path) } catch let error as FileSystemError {
            return .failure(Failure(error.reason.hasPrefix("FileNotFoundError") ? "Öğe artık yok." : "Öğe okunamadı."))
        } catch { return .failure(Failure("Öğe okunamadı.")) }
        switch stat.kind {
        case .symlink: return .failure(Failure("Sembolik bağlantı; izlenmez ve taşınmaz."))
        case .other: return .failure(Failure("Dosya türü desteklenmiyor."))
        case .regular, .directory: break
        }
        guard stat.device == rootStat.device else { return .failure(Failure("Başka bir birimde; taşınmaz.")) }
        return .success(FileFingerprint(device: stat.device, inode: stat.inode, kind: stat.kind))
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
