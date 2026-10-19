import Foundation

public struct ActionLogEntry: Codable, Equatable, Sendable {
    public var time: String
    public var scan: String
    public var path: String
    public var bytes: Int64
    public var safety: String
    /// `moving` (taşımadan önce niyet), sonra `trashed`, `failed` veya `skipped`.
    public var result: String
    public var detail: String?

    public init(time: String, scan: String, path: String, bytes: Int64, safety: String, result: String, detail: String?) {
        self.time = time
        self.scan = scan
        self.path = path
        self.bytes = bytes
        self.safety = safety
        self.result = result
        self.detail = detail
    }
}

/// Temizlik günlüğü (`actions.log`): satır başına bir JSON. Dosyanın üzerine yazılmaz, hep sonuna eklenir.
public final class ActionLog: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    /// Klasörü ve dosyayı hazırlar; yazılamıyorsa fırlatır (bu durumda hiçbir şey taşınmaz).
    public func prepare() throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.close()
    }

    public func append(_ entry: ActionLogEntry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(entry)
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
