import Foundation
import Darwin
@testable import DiskAtlasCore

/// Geçici dizinde gerçek dosya ağacı kurar. Yalnızca temporaryDirectory altına yazar.
final class TempTree {
    let root: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("diskatlas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath()
    }

    deinit {
        // Okunamayan klasör bıraktıysa silinebilsin diye izinleri geri ver.
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            for case let rel as String in walker { chmod(path(rel), 0o755) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func path(_ relative: String = "") -> String {
        relative.isEmpty ? root.path : root.appendingPathComponent(relative).path
    }

    func dir(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ relative: String, size: Int) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: full, contents: Data(repeating: 0x61, count: size)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return full
    }

    func symlink(_ relative: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path(relative), withDestinationPath: target)
    }

    func hardlink(_ relative: String, to existing: String) throws {
        try FileManager.default.linkItem(atPath: existing, toPath: path(relative))
    }
}

enum TestSupport {
    /// Geçici dizin `/private/...` altında olduğundan sistem öneki kuralını atan sınıflandırıcı.
    static func classifier() throws -> Classifier {
        var rules = try RuleSet.bundled()
        rules.rules = rules.rules.filter { $0.pathPrefixAny == nil }
        return Classifier(rules: rules)
    }

    /// Dosyanın ayrılan baytı (st_blocks * 512), kod yolundan bağımsız hesaplanır.
    static func allocated(_ path: String) -> Int64 {
        var st = Darwin.stat()
        precondition(Darwin.lstat(path, &st) == 0)
        return Int64(st.st_blocks) * 512
    }
}
