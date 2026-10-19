import Foundation
@testable import DiskAtlasCore

/// Diskte üretilemeyen durumlar için (bulut yer tutucusu, başka volume, kaybolan girdi).
final class FakeFileSystem: FileSystem, @unchecked Sendable {
    struct Entry {
        var stat: FileStat?
        var children: [String] = []
        var listError: String?
    }

    private(set) var entries: [String: Entry] = [:]
    private(set) var listed: [String] = []
    private var nextInode: UInt64 = 1

    func addDir(_ path: String, children: [String], device: Int32 = 1, dataless: Bool = false, listError: String? = nil) {
        entries[path] = Entry(stat: FileStat(kind: .directory, device: device, inode: take(), linkCount: 2,
                                             size: 0, blocks: 0, isDataless: dataless),
                              children: children, listError: listError)
    }

    func addFile(_ path: String, size: Int64 = 4096, blocks: Int64 = 8, device: Int32 = 1) {
        entries[path] = Entry(stat: FileStat(kind: .regular, device: device, inode: take(), linkCount: 1,
                                             size: size, blocks: blocks, isDataless: false))
    }

    private func take() -> UInt64 { defer { nextInode += 1 }; return nextInode }

    func lstat(_ path: String) throws -> FileStat {
        guard let stat = entries[path]?.stat else {
            throw FileSystemError(reason: "FileNotFoundError: No such file or directory")
        }
        return stat
    }

    func listDirectory(_ path: String) throws -> [String] {
        listed.append(path)
        guard let entry = entries[path] else { throw FileSystemError(reason: "FileNotFoundError: No such file or directory") }
        if let message = entry.listError { throw FileSystemError(reason: message) }
        return entry.children
    }
}
