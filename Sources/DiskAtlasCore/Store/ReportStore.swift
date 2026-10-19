import Foundation

public struct ScanSummary: Codable, Equatable, Sendable {
    public var id: String
    public var created: String
    public var scope: String
    public var incomplete: Bool
    public var allocatedBytes: Int64
    public var schema: Int
}

public enum ReportStoreError: Error, Equatable {
    case invalidID(String)
    case notFound(String)
}

/// Taramaları bir klasörde `<id>.json` (rapor) ve `<id>.meta.json` (özet) olarak saklar.
/// Kimlik dosya adına dönüştüğü için yalnızca `scan-<rakam/T>` biçimi kabul edilir.
public final class ReportStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    public var directoryPath: String { directory.path }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiskAtlas/scans", isDirectory: true)
    }

    public static func isValid(id: String) -> Bool {
        id.range(of: #"^scan-[0-9T]{1,40}(-[0-9]{1,4})?$"#, options: .regularExpression) != nil
    }

    public func save(_ report: Report) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digits = report.created.filter { $0.isNumber || $0 == "T" }.prefix(40)
        let stem = "scan-" + (digits.isEmpty ? "0" : String(digits))
        var id = stem
        var counter = 0
        while FileManager.default.fileExists(atPath: file(id, "json").path) {
            counter += 1
            id = "\(stem)-\(counter)"
        }
        let summary = ScanSummary(id: id, created: report.created, scope: report.scope, incomplete: report.incomplete,
                                  allocatedBytes: report.tree.bytes, schema: report.schema)
        try ReportCodec.encode(report).write(to: file(id, "json"), options: .atomic)
        try JSONEncoder().encode(summary).write(to: file(id, "meta.json"), options: .atomic)
        return id
    }

    /// Okunabilir özet dosyalarını yeniden eskiye döner; bozuk olanlar atlanır.
    public func list() -> [ScanSummary] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let summaries = names.filter { $0.hasSuffix(".meta.json") }.compactMap { name -> ScanSummary? in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let summary = try? JSONDecoder().decode(ScanSummary.self, from: data),
                  Self.isValid(id: summary.id) else { return nil }
            return summary
        }
        return summaries.sorted { $0.created != $1.created ? $0.created > $1.created : $0.id > $1.id }
    }

    public func load(id: String) throws -> Report {
        guard Self.isValid(id: id) else { throw ReportStoreError.invalidID(id) }
        guard let data = try? Data(contentsOf: file(id, "json")) else { throw ReportStoreError.notFound(id) }
        return try ReportCodec.decode(data)
    }

    private func file(_ id: String, _ ext: String) -> URL {
        directory.appendingPathComponent("\(id).\(ext)")
    }
}
