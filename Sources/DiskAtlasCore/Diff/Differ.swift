import Foundation

public enum DiffStatus: String, Codable, Sendable {
    case grew, shrank, new, gone, uncertain
}

public struct DiffItem: Codable, Equatable, Sendable {
    public var path: String
    public var before: Int64?
    public var after: Int64?
    public var delta: Int64
    public var status: DiffStatus
    /// Yalnızca `uncertain` için: neden belirsiz olduğu.
    public var reason: String?
}

public struct ScanDiff: Codable, Equatable, Sendable {
    public var measuredDelta: Int64
    public var diskUsedDelta: Int64
    /// Disk doluluğu farkı ile ölçülen dosya farkı arasındaki bölüm (anlık görüntüler, korumalı alanlar vb.).
    public var unexplained: Int64
    public var warnings: [String]
    public var items: [DiffItem]
    /// Kırpmadan önceki değişen klasör sayısı.
    public var totalItems: Int
}

public enum DiffError: Error, Equatable, CustomStringConvertible {
    /// `"older"` veya `"newer"`: klasör dizini olmayan (eski sürümden) tarama.
    case notComparable(String)

    public var description: String {
        switch self {
        case .notComparable(let which):
            return "\(which == "older" ? "Eski" : "Yeni") tarama karşılaştırma için gerekli ayrıntıyı içermiyor (eski sürümden)."
        }
    }
}

/// İki taramayı klasör düzeyinde karşılaştırır. Yanıltıcı sonuçtan kaçınır: yarım tarama ve okunamayan
/// klasörler `uncertain` olur, "silindi" denmez. Dizin yalnızca ≥ 1 MiB klasörleri içerdiği için
/// `new`/`gone` "eşiği geçti/eşiğin altına indi" anlamını da taşıyabilir.
public enum Differ {
    public static func compare(older: Report, newer: Report, limit: Int = 500) throws -> ScanDiff {
        guard let before = older.folderIndex else { throw DiffError.notComparable("older") }
        guard let after = newer.folderIndex else { throw DiffError.notComparable("newer") }
        let incomplete = older.incomplete || newer.incomplete
        let doubtful = affectedPaths(of: (older.unreadable ?? []) + (newer.unreadable ?? []))

        var items: [DiffItem] = []
        for path in Set(before.keys).union(after.keys) {
            let was = before[path], now = after[path]
            let delta = (now ?? 0) - (was ?? 0)
            if delta == 0 { continue }
            let status: DiffStatus
            var reason: String?
            if incomplete {
                status = .uncertain
                reason = "Tarama yarım kaldı"
            } else if doubtful.contains(path) {
                status = .uncertain
                reason = "Okunamayan klasör içeriyor"
            } else if was == nil {
                status = .new
            } else if now == nil {
                status = .gone
            } else {
                status = delta > 0 ? .grew : .shrank
            }
            items.append(DiffItem(path: path, before: was, after: now, delta: delta, status: status, reason: reason))
        }
        items.sort { abs($0.delta) != abs($1.delta) ? abs($0.delta) > abs($1.delta) : $0.path < $1.path }

        var warnings: [String] = []
        if let a = older.fullDiskAccess, let b = newer.fullDiskAccess, a != b {
            warnings.append("Tam Disk Erişimi durumu iki taramada farklı; fark gerçek değişimi yansıtmayabilir.")
        }
        if older.scope != newer.scope {
            warnings.append("İki taramanın kapsamı farklı; yalnızca ortak klasörler karşılaştırılabilir.")
        }
        let measured = newer.tree.bytes - older.tree.bytes
        let used = newer.disk.used - older.disk.used
        return ScanDiff(measuredDelta: measured, diskUsedDelta: used, unexplained: used - measured, warnings: warnings,
                        items: Array(items.prefix(max(0, limit))), totalItems: items.count)
    }

    /// Okunamayan yolların kendisi ve bütün üst klasörleri (bileşen bileşen; `/Users/xy`, `/Users/x`in üstü değildir).
    private static func affectedPaths(of unreadable: [String]) -> Set<String> {
        var result: Set<String> = []
        for path in unreadable {
            result.insert("/")
            var current = ""
            for component in path.split(separator: "/") {
                current += "/" + component
                result.insert(current)
            }
        }
        return result
    }
}
