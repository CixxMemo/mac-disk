import Foundation

public struct ComponentEntry: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var bytes: Int64
    /// Eşleşen gerçek klasörler (en büyükten, en fazla 5).
    public var paths: [String]
    /// `paths` ile aynı sırada, her klasörün TAM boyutu (iç içe bileşenler düşülmemiş hali).
    public var pathBytes: [Int64]
    public var safety: Safety
    public var category: DiskCategory
    public var what: String
    public var why: String
    public var ifRemoved: String
}

public struct AppEntry: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var tone: String
    public var bytes: Int64
    public var components: [ComponentEntry]
}

public struct UnrecognizedFolder: Codable, Equatable, Sendable {
    public var path: String
    public var bytes: Int64
    /// `bytes` eksi doğrudan (indeksli) alt klasörlerin toplamı: klasörün kendi, başka yerde açıklanmayan payı.
    public var ownBytes: Int64
}

public struct AppsReport: Codable, Equatable, Sendable {
    public var homePath: String
    public var apps: [AppEntry]
    public var unrecognized: [UnrecognizedFolder]
    public var recognizedBytes: Int64
}

/// Bir taramanın klasör dizinini (`folderIndex`) kural kataloğuyla eşleştirir. Aynı bayt iki yerde sayılmaz:
/// en özel (iç) eşleşme sahiplenir, üst klasörün bileşeni yalnızca kalanı gösterir.
public enum AppCatalog {
    private struct Match {
        var appIndex: Int
        var componentIndex: Int
        var path: String
        var lower: String
        var bytes: Int64
        var priority: Int          // 2: açık yol, 1: ad kuralı, 0: alt klasör kuralı
        var childName: String?
    }

    public static func build(report: Report, rules: RuleSet, minUnrecognizedBytes: Int64 = 100_000_000,
                             minChildBytes: Int64 = 100_000_000, limit: Int = 100) -> AppsReport? {
        guard let index = report.folderIndex else { return nil }
        let home = report.homePath ?? largestUserFolder(in: index) ?? ""
        let apps = rules.apps ?? []

        var lowerIndex: [String: (path: String, bytes: Int64)] = [:]
        for (path, bytes) in index {
            let lower = path.lowercased()
            if let existing = lowerIndex[lower], existing.bytes > bytes || (existing.bytes == bytes && existing.path <= path) { continue }
            lowerIndex[lower] = (path, bytes)
        }

        // 1) Adaylar
        var candidates: [Match] = []
        for (ai, app) in apps.enumerated() {
            for (ci, component) in app.components.enumerated() {
                if let paths = component.paths {
                    for raw in paths {
                        guard let expanded = expand(raw, home: home), let hit = lowerIndex[expanded.lowercased()] else { continue }
                        candidates.append(Match(appIndex: ai, componentIndex: ci, path: hit.path, lower: expanded.lowercased(),
                                                bytes: hit.bytes, priority: 2, childName: nil))
                    }
                }
                if let wanted = component.names.map(Set.init) {
                    for (lower, hit) in lowerIndex where wanted.contains(lastComponent(lower)) {
                        candidates.append(Match(appIndex: ai, componentIndex: ci, path: hit.path, lower: lower,
                                                bytes: hit.bytes, priority: 1, childName: nil))
                    }
                }
                if let parent = component.children, let expanded = expand(parent, home: home) {
                    let parentLower = expanded.lowercased()
                    for (lower, hit) in lowerIndex where hit.bytes >= minChildBytes && parentPath(of: lower) == parentLower {
                        var name = lastComponent(hit.path)
                        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
                        candidates.append(Match(appIndex: ai, componentIndex: ci, path: hit.path, lower: lower,
                                                bytes: hit.bytes, priority: 0, childName: name))
                    }
                }
            }
        }

        // 2) Aynı klasörü birden çok kural eşleştirirse yüksek öncelikli (sonra kural sırası) kazanır.
        var byLower: [String: Match] = [:]
        for match in candidates {
            if let existing = byLower[match.lower], existing.priority >= match.priority { continue }
            byLower[match.lower] = match
        }

        // 2b) Ad kuralları (node_modules, __pycache__ ...) yalnızca kişisel klasörlerden veya sahipsiz alandan pay alır:
        //     uygulama paketlerinin (.app), araç/eklenti klasörlerinin ve `excludeUnder` yollarının içindekiler
        //     bulundukları yerde kalır, yeniden oluşturulabilir diye etiketlenmez.
        for match in byLower.values where match.priority == 1 {
            let rule = apps[match.appIndex].components[match.componentIndex]
            var excluded = match.lower.contains(".app/")
            if !excluded {
                excluded = (rule.excludeUnder ?? []).contains { raw in
                    guard let expanded = expand(raw, home: home)?.lowercased() else { return false }
                    return match.lower == expanded || match.lower.hasPrefix(expanded + "/")
                }
            }
            if !excluded, let ancestor = nearestAncestor(of: match.lower, in: byLower), let outer = byLower[ancestor],
               apps[outer.appIndex].tone != "personal" {
                excluded = true
            }
            if excluded { byLower[match.lower] = nil }
        }

        // 3) Aynı bileşenin içindeki iç eşleşmeler (iç içe node_modules) ayrıca sayılmaz.
        var kept = byLower
        for match in byLower.values {
            if let ancestor = nearestAncestor(of: match.lower, in: byLower), let outer = byLower[ancestor],
               outer.appIndex == match.appIndex, outer.componentIndex == match.componentIndex {
                kept[match.lower] = nil
            }
        }

        // 4) Üst klasörün bileşeni, içindeki başka bileşenlerin baytını düşer (en yakın üst eşleşmeden).
        var claimed: [String: Int64] = [:]
        for match in kept.values {
            if let ancestor = nearestAncestor(of: match.lower, in: kept) { claimed[ancestor, default: 0] += match.bytes }
        }

        // 5) Bileşen kayıtları
        struct Piece { var path: String; var bytes: Int64; var raw: Int64 }
        var grouped: [Int: [Int: [Piece]]] = [:]
        var childEntries: [Int: [ComponentEntry]] = [:]
        for match in kept.values {
            let effective = max(0, match.bytes - (claimed[match.lower] ?? 0))
            guard effective > 0 else { continue }
            let rule = apps[match.appIndex].components[match.componentIndex]
            if let childName = match.childName {
                childEntries[match.appIndex, default: []].append(entry(rule, id: "\(rule.id)/\(childName)", name: childName,
                                                                         bytes: effective, paths: [match.path], pathBytes: [match.bytes]))
            } else {
                grouped[match.appIndex, default: [:]][match.componentIndex, default: []].append(Piece(path: match.path, bytes: effective, raw: match.bytes))
            }
        }
        var appEntries: [AppEntry] = []
        for (ai, app) in apps.enumerated() {
            var components = childEntries[ai] ?? []
            for (ci, pieces) in grouped[ai] ?? [:] {
                let sorted = pieces.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
                components.append(entry(app.components[ci], id: app.components[ci].id, name: app.components[ci].name,
                                        bytes: sorted.reduce(0) { $0 + $1.bytes }, paths: Array(sorted.prefix(5).map(\.path)),
                                        pathBytes: Array(sorted.prefix(5).map(\.raw))))
            }
            guard !components.isEmpty else { continue }
            components.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
            appEntries.append(AppEntry(id: app.id, name: app.name, tone: app.tone,
                                       bytes: components.reduce(0) { $0 + $1.bytes }, components: components))
        }
        appEntries.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }

        // 6) Tanınmayan klasörler: sahiplenilmemiş, sistem olmayan, kendi payı büyük olanlar.
        let classifier = Classifier(rules: rules)
        var childSums: [String: Int64] = [:]
        for (lower, hit) in lowerIndex {
            if let parent = parentPath(of: lower) { childSums[parent, default: 0] += hit.bytes }
        }
        let homeLower = home.lowercased()
        var unrecognized: [UnrecognizedFolder] = []
        for (lower, hit) in lowerIndex {
            if hit.path == "/" || lower == "/users" || lower == homeLower { continue }
            let own = max(0, hit.bytes - (childSums[lower] ?? 0))
            guard own >= minUnrecognizedBytes, !isInside(lower, kept) else { continue }
            if classifier.classify(path: hit.path, inherited: nil) == .system { continue }
            unrecognized.append(UnrecognizedFolder(path: hit.path, bytes: hit.bytes, ownBytes: own))
        }
        unrecognized.sort { $0.ownBytes != $1.ownBytes ? $0.ownBytes > $1.ownBytes : $0.path < $1.path }

        return AppsReport(homePath: home, apps: appEntries, unrecognized: Array(unrecognized.prefix(limit)),
                          recognizedBytes: appEntries.reduce(0) { $0 + $1.bytes })
    }

    private static func entry(_ rule: ComponentRule, id: String, name: String, bytes: Int64, paths: [String], pathBytes: [Int64]) -> ComponentEntry {
        ComponentEntry(id: id, name: name, bytes: bytes, paths: paths, pathBytes: pathBytes, safety: rule.safety, category: rule.category,
                       what: rule.what, why: rule.why, ifRemoved: rule.ifRemoved)
    }

    private static func expand(_ path: String, home: String) -> String? {
        guard path.hasPrefix("~/") else { return path }
        return home.isEmpty ? nil : home + String(path.dropFirst(1))
    }

    private static func lastComponent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    private static func parentPath(of path: String) -> String? {
        guard path != "/", let slash = path.lastIndex(of: "/") else { return nil }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    private static func nearestAncestor(of path: String, in matches: [String: Match]) -> String? {
        var current = path
        while let parent = parentPath(of: current) {
            if matches[parent] != nil { return parent }
            current = parent
        }
        return nil
    }

    private static func isInside(_ path: String, _ matches: [String: Match]) -> Bool {
        var current = path
        while true {
            if matches[current] != nil { return true }
            guard let parent = parentPath(of: current) else { return false }
            current = parent
        }
    }

    /// Eski raporlarda (`homePath` yok): `/Users/<ad>` klasörlerinden en büyüğü.
    private static func largestUserFolder(in index: [String: Int64]) -> String? {
        index.filter { key, _ in
            let parts = key.split(separator: "/", omittingEmptySubsequences: true)
            return parts.count == 2 && parts[0] == "Users" && parts[1] != "Shared"
        }.max { $0.value < $1.value }?.key
    }
}
