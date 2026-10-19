public enum PermissionStatus: String, Codable, Sendable {
    case granted, denied, unknown
}

/// Tam Disk Erişimi olup olmadığını, yalnızca o izinle listelenebilen TCC klasörünü
/// listelemeyi deneyerek anlar. Dosya içeriği okunmaz.
public struct PermissionProbe: Sendable {
    private let fileSystem: FileSystem
    private let probePath: String

    public init(fileSystem: FileSystem = RealFileSystem(),
                probePath: String = "/Library/Application Support/com.apple.TCC") {
        self.fileSystem = fileSystem
        self.probePath = probePath
    }

    public func fullDiskAccess() -> PermissionStatus {
        do {
            _ = try fileSystem.listDirectory(probePath)
            return .granted
        } catch let error as FileSystemError {
            return error.reason.hasPrefix("PermissionError") ? .denied : .unknown
        } catch {
            return .unknown
        }
    }
}
