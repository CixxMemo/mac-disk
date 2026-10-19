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
    }

    public struct UI: Encodable, Equatable {
        public var homePath: String
        public var findings: [Finding]
    }

    private static let minFindingBytes: Int64 = 150_000_000
    private static let maxFindings = 100

    public let report: Report
    public let apps: AppsReport?
    public let ui: UI?

    public init(report: Report, rules: RuleSet) {
        self.report = report
        let apps = AppCatalog.build(report: report, rules: rules)
        self.apps = apps
        self.ui = apps.map { Self.makeUI($0, candidates: report.candidates) }
    }

    /// Bulgular klasör başınadır ve TAM klasör boyutunu taşır (iç içe seçimler arayüzde bir kez sayılır).
    /// Tarayıcının `candidates` listesindeki, katalog bulgularının kapsamadığı klasörler de eklenir (`build_ui.py` ile aynı).
    private static func makeUI(_ apps: AppsReport, candidates: [Candidate]) -> UI {
        var findings: [Finding] = []
        for component in apps.apps.flatMap(\.components) where component.safety != .never {
            for (path, bytes) in zip(component.paths, component.pathBytes) where bytes >= minFindingBytes {
                let name = component.paths.count > 1 ? "\(component.name) · \(tail(path))" : component.name
                findings.append(Finding(name: name, path: path, bytes: bytes, category: component.category.rawValue,
                                        group: component.safety == .safe ? "cache" : "review", note: component.what))
            }
        }
        let covered = findings.map(\.path)
        for candidate in candidates where candidate.bytes >= minFindingBytes {
            if covered.contains(where: { candidate.path == $0 || candidate.path.hasPrefix($0 + "/") }) { continue }
            findings.append(Finding(name: candidate.name, path: candidate.path, bytes: candidate.bytes, category: candidate.category.rawValue,
                                    group: candidate.category == .cache || candidate.category == .build ? "cache" : "review",
                                    note: candidate.note))
        }
        findings.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        return UI(homePath: apps.homePath, findings: Array(findings.prefix(maxFindings)))
    }

    private static func tail(_ path: String) -> String {
        path.split(separator: "/").suffix(2).joined(separator: "/")
    }

    private enum Keys: String, CodingKey { case apps, ui }

    public func encode(to encoder: Encoder) throws {
        try report.forDisplay().encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encodeIfPresent(apps, forKey: .apps)
        try container.encodeIfPresent(ui, forKey: .ui)
    }
}
