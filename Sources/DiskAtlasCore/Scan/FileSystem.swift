import Foundation
import Darwin

public struct FileStat: Sendable, Equatable {
    public enum Kind: Sendable { case regular, directory, symlink, other }

    public var kind: Kind
    public var device: Int32
    public var inode: UInt64
    public var linkCount: Int
    public var size: Int64
    public var blocks: Int64
    public var isDataless: Bool

    public init(kind: Kind, device: Int32, inode: UInt64, linkCount: Int, size: Int64, blocks: Int64, isDataless: Bool) {
        self.kind = kind
        self.device = device
        self.inode = inode
        self.linkCount = linkCount
        self.size = size
        self.blocks = blocks
        self.isDataless = isDataless
    }
}

/// `reason`, Python raporlarındaki gibi `"PermissionError: Operation not permitted"` biçimindedir.
public struct FileSystemError: Error, Equatable, Sendable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
}

public protocol FileSystem: Sendable {
    func lstat(_ path: String) throws -> FileStat
    /// Dizindeki ad listesi (`.` ve `..` hariç). Sıralama çağıranın işidir.
    func listDirectory(_ path: String) throws -> [String]
}

/// Yalnızca metaveri okur: `lstat(2)` ve dizin listesi. Dosya içeriği hiç açılmaz.
public struct RealFileSystem: FileSystem {
    private static let datalessFlag: UInt32 = 0x4000_0000  // SF_DATALESS

    public init() {}

    public func lstat(_ path: String) throws -> FileStat {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { throw Self.error(errno) }
        let kind: FileStat.Kind
        switch st.st_mode & S_IFMT {
        case S_IFREG: kind = .regular
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        return FileStat(kind: kind, device: st.st_dev, inode: UInt64(st.st_ino), linkCount: Int(st.st_nlink),
                        size: Int64(st.st_size), blocks: Int64(st.st_blocks),
                        isDataless: st.st_flags & Self.datalessFlag != 0)
    }

    public func listDirectory(_ path: String) throws -> [String] {
        guard let dir = opendir(path) else { throw Self.error(errno) }
        defer { closedir(dir) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        if errno != 0 { throw Self.error(errno) }
        return names
    }

    private static func error(_ code: Int32) -> FileSystemError {
        let kind: String
        switch code {
        case EACCES, EPERM: kind = "PermissionError"
        case ENOENT: kind = "FileNotFoundError"
        case ENOTDIR: kind = "NotADirectoryError"
        case EISDIR: kind = "IsADirectoryError"
        default: kind = "OSError"
        }
        return FileSystemError(reason: "\(kind): \(String(cString: strerror(code)))")
    }
}
