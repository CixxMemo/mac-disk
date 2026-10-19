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
        self.ui = apps.map { Self.makeUI($0) }
    }

    private static func makeUI(_ apps: AppsReport) -> UI {
        let findings = apps.apps.flatMap(\.components)
            .filter { $0.safety != .never && $0.bytes >= minFindingBytes }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
            .prefix(maxFindings)
            .map { Finding(name: $0.name, path: $0.paths.first ?? "", bytes: $0.bytes, category: $0.category.rawValue,
                           group: $0.safety == .safe ? "cache" : "review", note: $0.what) }
        return UI(homePath: apps.homePath, findings: Array(findings))
    }

    private enum Keys: String, CodingKey { case apps, ui }

    public func encode(to encoder: Encoder) throws {
        try report.forDisplay().encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encodeIfPresent(apps, forKey: .apps)
        try container.encodeIfPresent(ui, forKey: .ui)
    }
}
