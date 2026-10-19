import Foundation

public enum DiffStatus: String, Codable, Sendable {
    case grew, shrank, new, gone, uncertain
}

public struct DiffItem: Codable, Equatable, Sendable {
    public var path: String
    public var before: Int64?
    public var after: Int64?
    public var delta: Int64
    /// `delta` eksi doğrudan alt klasörlerin `delta` toplamı: değişimin bu klasöre ait (alt klasörlerce açıklanmayan) payı.
    public var ownDelta: Int64
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

/// İki taramayı klasör düzeyinde karşılaştırır. Yanıltıcı sonuçtan kaçınır: yarım tarama, farklı kapsam,
/// okunamayan klasörler ve onların alt/üst klasörleri `uncertain` olur, "silindi" denmez. Dizin yalnızca ≥ 1 MiB klasörleri içerdiği için
/// `new`/`gone` "eşiği geçti/eşiğin altına indi" anlamını da taşıyabilir.
public enum Differ {
    public static func compare(older: Report, newer: Report, limit: Int = 500) throws -> ScanDiff {
        guard let before = older.folderIndex else { throw DiffError.notComparable("older") }
        guard let after = newer.folderIndex else { throw DiffError.notComparable("newer") }
        let incomplete = older.incomplete || newer.incomplete
        let scopeDiffers = older.scope != newer.scope
        let unreadable = Set((older.unreadable ?? []) + (newer.unreadable ?? []))
        let ancestors = affectedPaths(of: unreadable)

        var deltas: [String: Int64] = [:]
        for path in Set(before.keys).union(after.keys) {
            let delta = (after[path] ?? 0) - (before[path] ?? 0)
            if delta != 0 { deltas[path] = delta }
        }
        var childSums: [String: Int64] = [:]
        for (path, delta) in deltas {
            if let parent = parentPath(of: path) { childSums[parent, default: 0] += delta }
        }

        var items: [DiffItem] = []
        for (path, delta) in deltas {
            let was = before[path], now = after[path]
            let status: DiffStatus
            var reason: String?
            if incomplete {
                status = .uncertain
                reason = "Tarama yarım kaldı"
            } else if scopeDiffers {
                status = .uncertain
                reason = "Kapsamlar farklı"
            } else if ancestors.contains(path) {
                status = .uncertain
                reason = "Okunamayan klasör içeriyor"
            } else if isInside(path, unreadable) {
                status = .uncertain
                reason = "Okunamayan klasörün içinde"
            } else if was == nil {
                status = .new
            } else if now == nil {
                status = .gone
            } else {
                status = delta > 0 ? .grew : .shrank
            }
            items.append(DiffItem(path: path, before: was, after: now, delta: delta,
                                  ownDelta: delta - (childSums[path] ?? 0), status: status, reason: reason))
        }
        items.sort {
            if abs($0.ownDelta) != abs($1.ownDelta) { return abs($0.ownDelta) > abs($1.ownDelta) }
            if abs($0.delta) != abs($1.delta) { return abs($0.delta) > abs($1.delta) }
            return $0.path < $1.path
        }

        var warnings: [String] = []
        if let a = older.fullDiskAccess, let b = newer.fullDiskAccess, a != b {
            warnings.append("Tam Disk Erişimi durumu iki taramada farklı; fark gerçek değişimi yansıtmayabilir.")
        }
        if scopeDiffers {
            warnings.append("İki taramanın kapsamı farklı; klasör karşılaştırması ve toplam farklar güvenilir değil.")
        }
        if incomplete {
            warnings.append("Taramalardan biri yarım kaldı; ölçülen ve açıklanamayan fark güvenilir değil.")
        }
        let measured = newer.tree.bytes - older.tree.bytes
        let used = newer.disk.used - older.disk.used
        return ScanDiff(measuredDelta: measured, diskUsedDelta: used, unexplained: used - measured, warnings: warnings,
                        items: Array(items.prefix(max(0, limit))), totalItems: items.count)
    }

    private static func parentPath(of path: String) -> String? {
        guard path != "/", let slash = path.lastIndex(of: "/") else { return nil }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    /// Yol kendisi veya üst klasörlerinden biri `set` içinde mi (bileşen bileşen)?
    private static func isInside(_ path: String, _ set: Set<String>) -> Bool {
        var current = path
        while true {
            if set.contains(current) { return true }
            guard let parent = parentPath(of: current) else { return false }
            current = parent
        }
    }

    /// Okunamayan yolların kendisi ve bütün üst klasörleri (bileşen bileşen; `/Users/xy`, `/Users/x`in üstü değildir).
    private static func affectedPaths(of unreadable: Set<String>) -> Set<String> {
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
