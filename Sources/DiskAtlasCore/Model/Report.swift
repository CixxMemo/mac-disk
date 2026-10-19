public struct Node: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var bytes: Int64
    public var logical: Int64
    public var category: DiskCategory
    public var aggregate: Bool?
    public var children: [Node]?
}

public struct Candidate: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var bytes: Int64
    public var logical: Int64
    public var category: DiskCategory
    public var label: String
    public var note: String
}

public struct Stats: Codable, Equatable, Sendable {
    public var entries: Int
    public var files: Int
    public var folders: Int
    public var errors: Int
    public var symlinks: Int
    public var otherMounts: Int
    public var cloudPlaceholders: Int
    public var hardlinkRepeats: Int
}

public struct ScanErrorEntry: Codable, Equatable, Sendable {
    public var path: String
    public var reason: String
}

public struct DiskUsage: Codable, Equatable, Sendable {
    public var total: Int64
    public var free: Int64
    public var used: Int64
}

public struct Measurement: Codable, Equatable, Sendable {
    public var unit: String
    public var allocated: String
    public var scopeRoot: String
    public var directoryBlocksIncluded: Bool
    public var hardlinksCountedOnce: Bool
    public var symlinksFollowed: Bool
    public var otherVolumesFollowed: Bool
    public var fileContentsOpened: Bool
    public var treeDepth: Int
    public var maxChildren: Int
    public var caveat: String
}

/// Şema 1 (Python) alanlarının üst kümesi. `created` Python'un ISO metnini kayıpsız saklamak için String.
public struct Report: Codable, Equatable, Sendable {
    public var schema: Int
    public var app: String
    public var demo: Bool
    public var created: String
    public var scope: String
    public var platform: String
    public var incomplete: Bool
    public var seconds: Double
    public var disk: DiskUsage
    public var tree: Node
    public var categories: [String: Int64]
    public var candidates: [Candidate]
    public var largest: [Node]
    public var stats: Stats
    public var errors: [ScanErrorEntry]
    public var measurement: Measurement
    // Şema 2
    public var folderIndex: [String: Int64]?
    public var unreadable: [String]?
    public var legacy: Bool?
    /// Taramanın başında Tam Disk Erişimi durumu (`granted`/`denied`/`unknown`); `denied` ise sonuç kısmidir.
    public var fullDiskAccess: String?
}

extension Report {
    /// Şema 1 raporunu şema 2'ye yükseltir: klasör dizini yoktur (`folderIndex == nil`),
    /// okunamayan yollar yalnızca kayıtlı ilk hatalardan türetilir.
    public func upgradedToSchema2() -> Report {
        guard schema < 2 else { return self }
        var copy = self
        copy.schema = 2
        copy.legacy = true
        copy.unreadable = errors.map(\.path)
        return copy
    }
}
