import Foundation

/// `loadScan` yanıtı: arayüze hafifletilmiş rapor (`Report.forDisplay()`) + `apps` (Uygulamalar/Tanınmayan verisi)
/// + arayüzün mevcut "Yakından bakılacaklar" biçimi (`ui`). Klasör dizini olmayan taramalarda `apps`/`ui` yoktur.
public struct DisplayEnvelope: Encodable {
    public struct Finding: Encodable, Equatable {
        public var name: String
        public var path: String
        public var bytes: Int64
        public var category: String
        public var group: String
        public var note: String
        public var safety: String
    }

    public struct UI: Encodable, Equatable {
        public var homePath: String
        public var findings: [Finding]
    }

    private static let minFindingBytes: Int64 = 150_000_000
    private static let maxFindings = 100

    /// Temizlik bilgisi: politikanın her zaman reddedeceği yollar (arayüz bunlara seçim kutusu göstermez) ve taramanın,
    /// içinden öğe taşındığı için güncel olmadığı bilgisi.
    public struct Cleanup: Encodable, Equatable {
        public var blocked: [String: String]
        public var stale: Bool
    }

    public let report: Report
    public let apps: AppsReport?
    public let ui: UI?
    public let cleanup: Cleanup?

    public init(report: Report, rules: RuleSet, policy: TrashPolicy? = nil, stale: Bool = false) {
        self.report = report
        let apps = AppCatalog.build(report: report, rules: rules)
        self.apps = apps
        self.ui = apps.map { Self.makeUI($0, candidates: report.candidates, rules: rules) }
        if let policy {
            var blocked: [String: String] = [:]
            for candidate in CleanupCatalog.candidates(report: report, rules: rules) {
                if let reason = policy.check(candidate.path) { blocked[candidate.path] = reason }
            }
            self.cleanup = Cleanup(blocked: blocked, stale: stale)
        } else {
            self.cleanup = nil
        }
    }

    /// Bulgular klasör başınadır ve TAM klasör boyutunu taşır (iç içe seçimler arayüzde bir kez sayılır).
    /// Tarayıcının `candidates` listesindeki, katalog bulgularının kapsamadığı klasörler de eklenir (`build_ui.py` ile aynı).
    private static func makeUI(_ apps: AppsReport, candidates: [Candidate], rules: RuleSet) -> UI {
        var findings: [Finding] = []
        for component in apps.apps.flatMap(\.components) where component.safety != .never {
            for (path, bytes) in zip(component.paths, component.pathBytes) where bytes >= minFindingBytes {
                let name = component.paths.count > 1 ? "\(component.name) · \(tail(path))" : component.name
                findings.append(Finding(name: name, path: path, bytes: bytes, category: component.category.rawValue,
                                        group: component.safety == .safe ? "cache" : "review", note: component.what,
                                        safety: component.safety.rawValue))
            }
        }
        let covered = findings.map(\.path)
        for candidate in candidates where candidate.bytes >= minFindingBytes {
            if CleanupCatalog.isExcludedCandidate(candidate.path, rules: rules, home: apps.homePath) { continue }
            if covered.contains(where: { candidate.path == $0 || candidate.path.hasPrefix($0 + "/") }) { continue }
            findings.append(Finding(name: candidate.name, path: candidate.path, bytes: candidate.bytes, category: candidate.category.rawValue,
                                    group: candidate.category == .cache || candidate.category == .build ? "cache" : "review",
                                    note: candidate.note, safety: Safety.review.rawValue))
        }
        findings.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        return UI(homePath: apps.homePath, findings: Array(findings.prefix(maxFindings)))
    }

    private static func tail(_ path: String) -> String {
        path.split(separator: "/").suffix(2).joined(separator: "/")
    }

    private enum Keys: String, CodingKey { case apps, ui, cleanup }

    public func encode(to encoder: Encoder) throws {
        try report.forDisplay().encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encodeIfPresent(apps, forKey: .apps)
        try container.encodeIfPresent(ui, forKey: .ui)
        try container.encodeIfPresent(cleanup, forKey: .cleanup)
    }
}
