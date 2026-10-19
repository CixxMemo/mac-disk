import Foundation

/// `scanner.py` içindeki `Scanner` ile aynı kuralları uygular. Tek iş parçacığı; dizin girdileri
/// bayt sırasına göre gezilir, böylece sabit bağlantıların hangi klasöre yazıldığı deterministiktir.
public final class DiskScanner {
    private struct LinkKey: Hashable {
        var device: Int32
        var inode: UInt64
    }

    private let options: ScanOptions
    private let classifier: Classifier
    private let fileSystem: FileSystem
    private let now: () -> Double

    private var rootDevice: Int32 = 0
    private var stats = Stats(entries: 0, files: 0, folders: 0, errors: 0, symlinks: 0,
                              otherMounts: 0, cloudPlaceholders: 0, hardlinkRepeats: 0)
    private var errors: [ScanErrorEntry] = []
    private var categories: [String: Int64] = [:]
    private var seenLinks: Set<LinkKey> = []
    private var excluded: Set<String> = []

    public init(options: ScanOptions, classifier: Classifier, fileSystem: FileSystem = RealFileSystem(),
                now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.options = options
        self.classifier = classifier
        self.fileSystem = fileSystem
        self.now = now
    }

    public func run(isCancelled: () -> Bool = { false }, progress: ((ScanProgress) -> Void)? = nil) throws -> Report {
        let root = URL(fileURLWithPath: options.root).standardizedFileURL.path
        guard let rootStat = try? fileSystem.lstat(root) else { throw ScanFailure.rootUnreadable(options.root) }
        rootDevice = rootStat.device
        categories = Dictionary(uniqueKeysWithValues: DiskCategory.allCases.map { ($0.rawValue, Int64(0)) })
        excluded = Set(options.excludedPaths + options.excludedPaths.map { options.dataVolumePrefix + $0 })
        guard let tree = scan(path: root, depth: 0, inherited: nil, stat: rootStat) else {
            throw ScanFailure.rootUnreadable(options.root)
        }
        return Report(
            schema: 2, app: "Disk Atlas", demo: false, created: "", scope: classifier.displayPath(root),
            platform: "darwin", incomplete: false, seconds: 0,
            disk: DiskUsage(total: 0, free: 0, used: 0), tree: tree, categories: categories,
            candidates: [], largest: [], stats: stats, errors: errors,
            measurement: Measurement(unit: "bytes", allocated: "st_blocks * 512", scopeRoot: root,
                                     directoryBlocksIncluded: false, hardlinksCountedOnce: true,
                                     symlinksFollowed: false, otherVolumesFollowed: false,
                                     fileContentsOpened: false, treeDepth: 8, maxChildren: 40, caveat: ""),
            folderIndex: nil, unreadable: nil, legacy: nil)
    }

    private func recordError(_ path: String, _ reason: String) {
        stats.errors += 1
        if errors.count < 100 { errors.append(ScanErrorEntry(path: classifier.displayPath(path), reason: reason)) }
    }

    private func join(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    private func baseName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        let name = String(path[path.index(after: slash)...])
        return name.isEmpty ? "/" : name
    }

    private func scan(path: String, depth: Int, inherited: DiskCategory?, stat info: FileStat) -> Node? {
        stats.entries += 1
        if info.kind == .symlink {
            stats.symlinks += 1
            return nil
        }
        if info.device != rootDevice {
            stats.otherMounts += 1
            return nil
        }
        let category = classifier.classify(path: path, inherited: inherited)
        var node = Node(name: baseName(path), path: classifier.displayPath(path), bytes: 0, logical: 0, category: category)
        if info.isDataless { stats.cloudPlaceholders += 1 }
        if info.kind == .regular {
            stats.files += 1
            if info.linkCount > 1 {
                if !seenLinks.insert(LinkKey(device: info.device, inode: info.inode)).inserted {
                    stats.hardlinkRepeats += 1
                    return nil
                }
            }
            node.bytes = info.blocks * 512
            node.logical = info.size
            categories[category.rawValue, default: 0] += node.bytes
            return node
        }
        guard info.kind == .directory else { return nil }
        stats.folders += 1
        if info.isDataless {
            recordError(path, "Bulut klasörü: içerik indirmemek için alt öğeler taranmadı.")
            return node
        }
        var children: [Node] = []
        do {
            let names = try fileSystem.listDirectory(path)
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for name in names {
                let childPath = join(path, name)
                if excluded.contains(childPath) { continue }
                let childStat: FileStat
                do { childStat = try fileSystem.lstat(childPath) } catch let error as FileSystemError {
                    recordError(childPath, error.reason)
                    continue
                } catch {
                    recordError(childPath, "OSError: \(error)")
                    continue
                }
                if let child = scan(path: childPath, depth: depth + 1, inherited: category, stat: childStat) {
                    node.bytes += child.bytes
                    node.logical += child.logical
                    children.append(child)
                }
            }
        } catch let error as FileSystemError {
            recordError(path, error.reason)
        } catch {
            recordError(path, "OSError: \(error)")
        }
        node.children = children
        return node
    }
}
