public struct ScanOptions: Sendable {
    public var root: String
    public var seconds: Double
    public var maxEntries: Int
    /// Ölçüme katılmayan mutlak yollar (örn. rapor klasörü).
    public var excludedPaths: [String]
    public var dataVolumePrefix: String
    public var progressInterval: Double

    public init(root: String, seconds: Double = 900, maxEntries: Int = 5_000_000, excludedPaths: [String] = [],
                dataVolumePrefix: String = "/System/Volumes/Data", progressInterval: Double = 10) {
        self.root = root
        self.seconds = seconds
        self.maxEntries = maxEntries
        self.excludedPaths = excludedPaths
        self.dataVolumePrefix = dataVolumePrefix
        self.progressInterval = progressInterval
    }
}

public struct ScanProgress: Sendable, Equatable {
    public var records: Int
    public var errors: Int
    public var currentPath: String
    public var elapsed: Double
}

public enum ScanFailure: Error, Equatable, CustomStringConvertible {
    case rootUnreadable(String)

    public var description: String { "Tarama kökü okunamadı; rapor oluşturulmadı." }
}
