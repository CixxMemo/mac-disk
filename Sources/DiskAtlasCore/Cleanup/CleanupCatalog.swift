import Foundation

/// Çöp Sepeti'ne taşınabilecek bir öğe. Arayüz yalnızca yol gönderir; ad, boyut ve düzey buradan (Swift'ten) gelir.
public struct TrashCandidate: Codable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var bytes: Int64
    public var safety: Safety
}

/// Bir taramadan, taşınabilir öğelerin izin kümesini ve korumalı yolları türetir.
public enum CleanupCatalog {
    /// Katalog bileşenlerinin (`asla` hariç) her yolu + kataloğun kapsamadığı tarayıcı adayları (`incele`).
    public static func candidates(report: Report, rules: RuleSet) -> [TrashCandidate] {
        guard let apps = AppCatalog.build(report: report, rules: rules) else { return [] }
        var result: [TrashCandidate] = []
        var seen = Set<String>()
        var covered: [String] = []
        for component in apps.apps.flatMap(\.components) {
            covered.append(contentsOf: component.paths)
            guard component.safety != .never else { continue }
            for (path, bytes) in zip(component.paths, component.pathBytes) where seen.insert(path).inserted {
                let name = component.paths.count > 1 ? "\(component.name) · \(tail(path))" : component.name
                result.append(TrashCandidate(path: path, name: name, bytes: bytes, safety: component.safety))
            }
        }
        for candidate in report.candidates where !seen.contains(candidate.path) {
            if isExcludedCandidate(candidate.path, rules: rules, home: apps.homePath) { continue }
            if covered.contains(where: { candidate.path == $0 || candidate.path.hasPrefix($0 + "/") }) { continue }
            seen.insert(candidate.path)
            result.append(TrashCandidate(path: candidate.path, name: candidate.name, bytes: candidate.bytes, safety: .review))
        }
        return result
    }

    /// Katalogdaki ad kurallarının `excludeUnder` yolları (global araç kurulumları gibi): bunların altındaki tarayıcı adayları
    /// de yeniden oluşturulabilir sayılmaz ve taşınabilir öğe olmaz.
    public static func isExcludedCandidate(_ path: String, rules: RuleSet, home: String) -> Bool {
        let lower = path.lowercased()
        for component in (rules.apps ?? []).flatMap(\.components) {
            for raw in component.excludeUnder ?? [] {
                let expanded = (raw.hasPrefix("~/") ? home + String(raw.dropFirst(1)) : raw).lowercased()
                if lower == expanded || lower.hasPrefix(expanded + "/") { return true }
            }
        }
        return false
    }

    /// `asla` bileşenlerin yolları (`~/` ana klasörle genişletilmiş). Bu yollar ve üst klasörleri taşınamaz.
    public static func protectedPaths(rules: RuleSet, home: String) -> [String] {
        var paths: [String] = []
        for component in (rules.apps ?? []).flatMap(\.components) where component.safety == .never {
            for raw in component.paths ?? [] {
                if raw.hasPrefix("~/") { paths.append(home + String(raw.dropFirst(1))) } else { paths.append(raw) }
            }
        }
        return paths
    }

    static func tail(_ path: String) -> String {
        path.split(separator: "/").suffix(2).joined(separator: "/")
    }
}
