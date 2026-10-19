import Foundation

/// Bir bileşenin kaldırılmasının ne kadar güvenli olduğunu anlatan bilgi (5. aşamaya kadar yalnızca gösterilir).
public enum Safety: String, Codable, Sendable {
    case safe = "güvenli"
    case review = "incele"
    case never = "asla"
}

/// Bir araca ait tek bir klasör grubu. `paths`, `names` ve `children` alanlarından tam olarak biri dolu olur.
public struct ComponentRule: Codable, Sendable {
    public var id: String
    public var name: String
    /// `~/...` (kullanıcı klasörü) veya `/...` (mutlak) yollar.
    public var paths: [String]?
    /// Derinlikten bağımsız klasör adları (küçük harf); yalnızca en dıştaki eşleşme sayılır.
    public var names: [String]?
    /// Bu klasörün doğrudan alt klasörlerinin her biri ayrı bileşen olur (örn. `/Applications`).
    public var children: String?
    public var safety: Safety
    public var category: DiskCategory
    public var what: String
    public var why: String
    public var ifRemoved: String
}

public struct AppRule: Codable, Sendable {
    public var id: String
    public var name: String
    /// Arayüzdeki renk grubu: `personal, dev, android, ai, cache, system`.
    public var tone: String
    public var components: [ComponentRule]
}

public enum RuleCatalogError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let message): return "Geçersiz kural kataloğu: \(message)"
        }
    }
}

extension RuleSet {
    public static let catalogTones: Set<String> = ["personal", "dev", "android", "ai", "cache", "system"]

    /// Kataloğun kurallarını denetler; ilk hatada `RuleCatalogError.invalid` fırlatır.
    public func validateCatalog() throws {
        var appIDs = Set<String>(), componentIDs = Set<String>()
        for app in apps ?? [] {
            guard !app.id.isEmpty, appIDs.insert(app.id).inserted else { throw RuleCatalogError.invalid("tekrar eden araç kimliği: \(app.id)") }
            guard Self.catalogTones.contains(app.tone) else { throw RuleCatalogError.invalid("\(app.id): bilinmeyen renk grubu \(app.tone)") }
            guard !app.components.isEmpty else { throw RuleCatalogError.invalid("\(app.id): bileşen yok") }
            for component in app.components {
                let id = component.id
                guard !id.isEmpty, componentIDs.insert(id).inserted else { throw RuleCatalogError.invalid("tekrar eden bileşen kimliği: \(id)") }
                let matchers = [component.paths != nil, component.names != nil, component.children != nil].filter { $0 }.count
                guard matchers == 1 else { throw RuleCatalogError.invalid("\(id): tam olarak bir eşleştirici gerekli") }
                for path in (component.paths ?? []) + (component.children.map { [$0] } ?? []) {
                    try Self.validatePath(path, in: id)
                }
                if let paths = component.paths, paths.isEmpty { throw RuleCatalogError.invalid("\(id): boş yol listesi") }
                if let names = component.names {
                    guard !names.isEmpty, names.allSatisfy({ !$0.isEmpty && !$0.contains("/") && $0 == $0.lowercased() }) else {
                        throw RuleCatalogError.invalid("\(id): ad kuralları küçük harfli ve '/' içermeyen metinler olmalı")
                    }
                }
                for text in [component.what, component.why, component.ifRemoved]
                where text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
                    throw RuleCatalogError.invalid("\(id): açıklama metinleri en az 20 karakter olmalı")
                }
            }
        }
    }

    private static func validatePath(_ path: String, in id: String) throws {
        guard path.hasPrefix("~/") || path.hasPrefix("/") else { throw RuleCatalogError.invalid("\(id): yol '~/' veya '/' ile başlamalı: \(path)") }
        guard !path.split(separator: "/").contains("..") else { throw RuleCatalogError.invalid("\(id): yolda '..' olamaz: \(path)") }
    }
}
