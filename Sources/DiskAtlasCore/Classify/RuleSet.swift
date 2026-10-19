import Foundation

/// Tek bir sınıflandırma kuralı: `category` ve tam olarak bir eşleştirici alanı.
public struct Rule: Codable, Sendable {
    public var category: DiskCategory
    public var appBundleUnder: String?
    public var pathContainsAny: [String]?
    public var nameIn: [String]?
    public var pathPrefixAny: [String]?
}

public struct RuleSet: Codable, Sendable {
    public var stickyCategories: [DiskCategory]
    public var rules: [Rule]
    public var fallback: DiskCategory

    public static func bundled() throws -> RuleSet {
        guard let url = Bundle.module.url(forResource: "rules", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(from: url)
    }

    /// Paketli `.app` içinde `Bundle.module` yerine dosya yolu verilerek kullanılır.
    public static func load(from url: URL) throws -> RuleSet {
        try JSONDecoder().decode(RuleSet.self, from: Data(contentsOf: url))
    }
}
