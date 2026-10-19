import Foundation

/// Çöp Sepeti'ne taşıma için sözcüksel (dosya sistemine bakmayan) kurallar. `check`, izin varsa `nil`, yoksa Türkçe neden döner.
public struct TrashPolicy: Sendable {
    public let homePath: String
    public let applicationsPath: String?
    private let home: String
    private let applications: String?
    private let protectedPaths: [String]

    /// Ana klasöre göre: kendisi taşınamayan kapsayıcı klasörler (içindekiler ayrı öğe olarak taşınabilir).
    private static let containers: Set<String> = ["library", "library/caches", "library/application support", "library/containers",
                                                  "downloads", "applications"]
    /// Ana klasöre göre: kendisi ve altındakiler taşınamayan kişisel/gizli yollar.
    private static let protectedRelative = ["documents", "desktop", "pictures", "movies", "music", ".trash", ".ssh", ".gnupg",
                                            "library/keychains", "library/mobile documents", "library/cloudstorage",
                                            "library/messages", "library/mail", "library/safari"]

    public init(home: String, applications: String?, protectedPaths: [String]) {
        self.homePath = Self.trimmed(home)
        self.applicationsPath = applications.map(Self.trimmed)
        self.home = Self.trimmed(home).lowercased()
        self.applications = applications.map { Self.trimmed($0).lowercased() }
        self.protectedPaths = protectedPaths.map { Self.trimmed($0).lowercased() }
    }

    public func check(_ path: String) -> String? {
        guard path.hasPrefix("/"), path == "/" || !path.hasSuffix("/"), !path.contains("\0") else {
            return "Yol geçerli bir mutlak yol değil."
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return "Yol geçerli bir mutlak yol değil." }
        let lower = path.lowercased()

        if lower == home { return "Ana klasörün kendisi taşınamaz." }
        if lower.hasPrefix(home + "/") {
            let relative = String(lower.dropFirst(home.count + 1))
            if Self.containers.contains(relative) {
                return "Bu klasörün kendisi taşınamaz; içindeki öğeleri ayrı ayrı seç."
            }
            if Self.protectedRelative.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) {
                return "Kişisel veya gizli bir klasör; Disk Atlas buradan hiçbir şey taşımaz."
            }
        } else if let applications, lower.hasPrefix(applications + "/"), lower.hasSuffix(".app"),
                  !lower.dropFirst(applications.count + 1).contains("/") {
            // doğrudan uygulama paketi
        } else {
            return "Bu konum Disk Atlas'ın temizleyebileceği yerlerin dışında."
        }

        for protected in protectedPaths {
            if lower == protected || lower.hasPrefix(protected + "/") { return "Korumalı bir klasör; taşınamaz." }
            if protected.hasPrefix(lower + "/") { return "İçinde korumalı bir klasör var; taşınamaz." }
        }
        return nil
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
