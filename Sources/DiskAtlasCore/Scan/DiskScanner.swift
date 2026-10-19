import Foundation
import Darwin

/// `scanner.py` içindeki `Scanner` ile aynı kuralları uygular. Tek iş parçacığı; dizin girdileri
/// bayt sırasına göre gezilir, böylece sabit bağlantıların hangi klasöre yazıldığı deterministiktir.
public final class DiskScanner {
    private struct LinkKey: Hashable {
        var device: Int32
        var inode: UInt64
    }

    /// En büyük N dosyayı tutan küçük min-yığın (`scanner.py` içindeki `heapq` ile aynı sıralama: bayt, sıra no).
    private struct LargestFiles {
        struct Entry {
            var bytes: Int64
            var serial: Int
            var node: Node
        }

        static let capacity = 150
        private var heap: [Entry] = []

        private static func less(_ a: Entry, _ b: Entry) -> Bool {
            a.bytes != b.bytes ? a.bytes < b.bytes : a.serial < b.serial
        }

        mutating func offer(_ entry: Entry) {
            if heap.count < Self.capacity {
                heap.append(entry)
                var i = heap.count - 1
                while i > 0, Self.less(heap[i], heap[(i - 1) / 2]) {
                    heap.swapAt(i, (i - 1) / 2)
                    i = (i - 1) / 2
                }
            } else if Self.less(heap[0], entry) {
                heap[0] = entry
                var i = 0
                while true {
                    let left = 2 * i + 1, right = left + 1
                    var smallest = i
                    if left < heap.count, Self.less(heap[left], heap[smallest]) { smallest = left }
                    if right < heap.count, Self.less(heap[right], heap[smallest]) { smallest = right }
                    if smallest == i { break }
                    heap.swapAt(i, smallest)
                    i = smallest
                }
            }
        }

        func descending() -> [Node] {
            heap.sorted { Self.less($1, $0) }.map(\.node)
        }
    }

    private static let maxDepth = 8
    private static let maxChildren = 40
    private static let candidateThreshold: Int64 = 10 * 1024 * 1024
    /// `folderIndex`e giren en küçük klasör boyutu; karşılaştırma bu eşiğin altını göremez.
    public static let folderIndexThreshold: Int64 = 1024 * 1024
    private static let candidateNote = "Yalnızca dosya yoluna göre sınıflandırıldı. İçerik okunmadı; gereksiz olduğu veya yeniden indirilebileceği doğrulanmadı. Alan kesin kazanım değildir."
    private static let candidateLabels: [DiskCategory: String] = [
        .cache: "Önbellek · uygulamayla doğrula",
        .build: "Derleme çıktısı · projeyle doğrula",
        .dependencies: "Bağımlılık · inceleme gerekli",
        .models: "AI modeli · inceleme gerekli",
    ]
    private static let caveat = "APFS shared clone extents may be counted more than once; protected data and snapshots are outside the scan."

    private let options: ScanOptions
    private let classifier: Classifier
    private let fileSystem: FileSystem
    private let now: () -> Double

    // Çalıştırma durumu (her `run` başında sıfırlanır).
    private var isCancelled: () -> Bool = { false }
    private var progress: ((ScanProgress) -> Void)?
    private var started = 0.0
    private var lastProgress = 0.0
    private var stopped = false
    private var rootFailed = false
    private var rootDevice: Int32 = 0
    private var stats = Stats(entries: 0, files: 0, folders: 0, errors: 0, symlinks: 0,
                              otherMounts: 0, cloudPlaceholders: 0, hardlinkRepeats: 0)
    private var errors: [ScanErrorEntry] = []
    private var unreadable: [String] = []
    private var categories: [String: Int64] = [:]
    private var seenLinks: Set<LinkKey> = []
    private var excluded: Set<String> = []
    private var largest = LargestFiles()
    private var serial = 0
    private var candidates: [Candidate] = []
    private var folderIndex: [String: Int64] = [:]

    public init(options: ScanOptions, classifier: Classifier, fileSystem: FileSystem = RealFileSystem(),
                now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.options = options
        self.classifier = classifier
        self.fileSystem = fileSystem
        self.now = now
    }

    /// Taramayı 64 MiB yığınlı ayrı bir iş parçacığında çalıştırır: özyineleme, çağıranın yığın boyutundan
    /// bağımsız olarak en derin yola (PATH_MAX ≈ 511 düzey) yeter. `isCancelled` ve `progress` o iş
    /// parçacığında çağrılır.
    public func run(isCancelled: @escaping () -> Bool = { false },
                    progress: ((ScanProgress) -> Void)? = nil) throws -> Report {
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            outcome.result = Result { try execute(isCancelled: isCancelled, progress: progress) }
            done.signal()
        }
        thread.stackSize = Self.scanStackSize
        thread.start()
        done.wait()
        return try outcome.result!.get()
    }

    private final class Outcome: @unchecked Sendable {
        var result: Result<Report, Error>?
    }

    private static let scanStackSize = 64 * 1024 * 1024

    private func execute(isCancelled: @escaping () -> Bool, progress: ((ScanProgress) -> Void)?) throws -> Report {
        var root = URL(fileURLWithPath: options.root).standardizedFileURL.path
        guard var rootStat = try? fileSystem.lstat(root) else { throw ScanFailure.rootUnreadable(options.root) }
        if rootStat.kind == .symlink {
            // Kök bir sembolik bağlantıysa (örn. /tmp) hedefi taranır; kökün altındakiler yine izlenmez.
            guard let resolved = Self.realPath(root), let resolvedStat = try? fileSystem.lstat(resolved) else {
                throw ScanFailure.rootUnreadable(options.root)
            }
            root = resolved
            rootStat = resolvedStat
        }
        reset(rootDevice: rootStat.device, isCancelled: isCancelled, progress: progress)
        guard let tree = scan(path: root, depth: 0, inherited: nil, insideCandidate: false, stat: rootStat),
              !rootFailed else {
            throw ScanFailure.rootUnreadable(options.root)
        }
        let elapsed = now() - started
        let disk = Self.diskUsage(at: root)
        return Report(
            schema: 2, app: "Disk Atlas", demo: false, created: Self.timestamp(Date()), scope: classifier.displayPath(root),
            platform: "darwin", incomplete: stopped, seconds: (elapsed * 100).rounded() / 100,
            disk: disk, tree: tree, categories: categories,
            candidates: candidates.enumerated().sorted {
                $0.element.bytes != $1.element.bytes ? $0.element.bytes > $1.element.bytes : $0.offset < $1.offset
            }.map(\.element),
            largest: largest.descending(), stats: stats, errors: errors,
            measurement: Measurement(unit: "bytes", allocated: "st_blocks * 512", scopeRoot: root,
                                     directoryBlocksIncluded: false, hardlinksCountedOnce: true,
                                     symlinksFollowed: false, otherVolumesFollowed: false,
                                     fileContentsOpened: false, treeDepth: Self.maxDepth,
                                     maxChildren: Self.maxChildren, caveat: Self.caveat),
            folderIndex: folderIndex, unreadable: unreadable, legacy: nil)
    }

    private func reset(rootDevice: Int32, isCancelled: @escaping () -> Bool, progress: ((ScanProgress) -> Void)?) {
        self.rootDevice = rootDevice
        self.isCancelled = isCancelled
        self.progress = progress
        started = now()
        lastProgress = started
        stopped = false
        rootFailed = false
        stats = Stats(entries: 0, files: 0, folders: 0, errors: 0, symlinks: 0,
                      otherMounts: 0, cloudPlaceholders: 0, hardlinkRepeats: 0)
        errors = []
        unreadable = []
        categories = Dictionary(uniqueKeysWithValues: DiskCategory.allCases.map { ($0.rawValue, Int64(0)) })
        seenLinks = []
        // Kökle aynı biçimde normalleştirilir (Foundation /private/var yerine /var yazar).
        let normalized = options.excludedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        excluded = Set(normalized + normalized.map { options.dataVolumePrefix + $0 })
        largest = LargestFiles()
        serial = 0
        candidates = []
        folderIndex = [:]
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return formatter.string(from: date)
    }

    /// `shutil.disk_usage` ile aynı hesap: toplam, kullanılabilir (`f_bavail`) ve kullanılan (`f_blocks - f_bfree`).
    /// `statvfs` başarısız olursa üçü de 0 döner; arayüz `total == 0` durumunu işlemelidir.
    private static func diskUsage(at path: String) -> DiskUsage {
        var info = statvfs()
        guard statvfs(path, &info) == 0 else { return DiskUsage(total: 0, free: 0, used: 0) }
        let unit = Int64(info.f_frsize)
        return DiskUsage(total: Int64(info.f_blocks) * unit, free: Int64(info.f_bavail) * unit,
                         used: (Int64(info.f_blocks) - Int64(info.f_bfree)) * unit)
    }

    private func recordError(_ path: String, _ reason: String) {
        let shown = classifier.displayPath(path)
        stats.errors += 1
        unreadable.append(shown)
        if errors.count < 100 { errors.append(ScanErrorEntry(path: shown, reason: reason)) }
    }

    private func join(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    private func baseName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        let name = String(path[path.index(after: slash)...])
        return name.isEmpty ? "/" : name
    }

    /// Süre, kayıt sınırı veya iptal: ilk tetiklenmede taramayı durdurur. Kök hiçbir zaman durdurulmaz,
    /// böylece iptal edilen tarama da geçerli (kısmi) bir rapor verir.
    private func shouldStop(depth: Int, path: String) -> Bool {
        guard depth > 0 else { return false }
        let t = now()
        if stopped || t - started >= options.seconds || stats.entries >= options.maxEntries || isCancelled() {
            stopped = true
            return true
        }
        if t - lastProgress >= options.progressInterval {
            progress?(ScanProgress(records: stats.entries, errors: stats.errors,
                                   currentPath: classifier.displayPath(path), elapsed: t - started))
            lastProgress = t
        }
        return false
    }

    private func scan(path: String, depth: Int, inherited: DiskCategory?, insideCandidate: Bool, stat info: FileStat) -> Node? {
        if shouldStop(depth: depth, path: path) { return nil }
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
            serial += 1
            largest.offer(LargestFiles.Entry(bytes: node.bytes, serial: serial, node: node))
            return node
        }
        guard info.kind == .directory else { return nil }
        stats.folders += 1
        if info.isDataless {
            if depth == 0 { rootFailed = true }
            recordError(path, "Bulut klasörü: içerik indirmemek için alt öğeler taranmadı.")
            return node
        }
        let isCandidate = Self.candidateLabels[category] != nil && !insideCandidate
        var children: [Node] = []
        do {
            let names = try fileSystem.listDirectory(path)
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for name in names {
                if stopped { break }
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
                if let child = scan(path: childPath, depth: depth + 1, inherited: category,
                                    insideCandidate: insideCandidate || isCandidate, stat: childStat) {
                    node.bytes += child.bytes
                    node.logical += child.logical
                    if depth < Self.maxDepth && child.bytes > 0 { children.append(child) }
                }
            }
        } catch let error as FileSystemError {
            if depth == 0 { rootFailed = true }
            recordError(path, error.reason)
        } catch {
            if depth == 0 { rootFailed = true }
            recordError(path, "OSError: \(error)")
        }
        if depth < Self.maxDepth { node.children = pruned(children, parent: node) }
        if node.bytes >= Self.folderIndexThreshold { folderIndex[node.path] = node.bytes }
        if isCandidate && node.bytes >= Self.candidateThreshold, let label = Self.candidateLabels[category] {
            candidates.append(Candidate(name: node.name, path: node.path, bytes: node.bytes, logical: node.logical,
                                        category: category, label: label, note: Self.candidateNote))
        }
        return node
    }

    /// Boyuta göre azalan sırada ilk 40 çocuğu tutar, kalanları "Diğer N öğe" düğümünde toplar.
    private func pruned(_ children: [Node], parent: Node) -> [Node] {
        let ordered = children.enumerated().sorted {
            $0.element.bytes != $1.element.bytes ? $0.element.bytes > $1.element.bytes : $0.offset < $1.offset
        }.map(\.element)
        var kept = Array(ordered.prefix(Self.maxChildren))
        let rest = ordered.dropFirst(Self.maxChildren)
        if !rest.isEmpty {
            kept.append(Node(name: "Diğer \(rest.count) öğe", path: parent.path,
                             bytes: rest.reduce(0) { $0 + $1.bytes }, logical: rest.reduce(0) { $0 + $1.logical },
                             category: parent.category, aggregate: true, children: nil))
        }
        return kept
    }
}
