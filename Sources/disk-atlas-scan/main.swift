import Foundation
import DiskAtlasCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let usage = "Kullanım: disk-atlas-scan --out DOSYA.json [--root YOL] [--seconds N] [--max-entries N]"
var root = FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : NSHomeDirectory()
var output: String?
var seconds = 900.0
var maxEntries = 5_000_000

var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    switch flag {
    case "--root", "--out", "--seconds", "--max-entries":
        guard let value = arguments.popFirst() else { fail("\(flag) için değer gerekli.\n\(usage)") }
        switch flag {
        case "--root": root = value
        case "--out": output = value
        case "--seconds":
            guard let parsed = Double(value) else { fail("--seconds sayı olmalı.") }
            seconds = parsed
        default:
            guard let parsed = Int(value) else { fail("--max-entries sayı olmalı.") }
            maxEntries = parsed
        }
    default:
        fail("Bilinmeyen seçenek: \(flag)\n\(usage)")
    }
}
guard let output else { fail(usage) }
guard !FileManager.default.fileExists(atPath: output) else { fail("Çıktı dosyası zaten var, üzerine yazılmaz: \(output)") }

struct Summary: Codable {
    var json: String
    var seconds: Double
    var stats: Stats
    var allocatedBytes: Int64
    var disk: DiskUsage
    var incomplete: Bool
}

do {
    let classifier = Classifier(rules: try RuleSet.bundled())
    let scanner = DiskScanner(options: ScanOptions(root: root, seconds: seconds, maxEntries: maxEntries),
                              classifier: classifier)
    let report = try scanner.run(progress: { progress in
        let line = "\(progress.records) kayıt; \(progress.errors) hata; \(progress.currentPath)\n"
        FileHandle.standardError.write(Data(line.utf8))
    })
    guard FileManager.default.createFile(atPath: output, contents: try ReportCodec.encode(report)) else {
        fail("Rapor yazılamadı: \(output)")
    }
    let summary = Summary(json: output, seconds: report.seconds, stats: report.stats,
                          allocatedBytes: report.tree.bytes, disk: report.disk, incomplete: report.incomplete)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(summary), as: UTF8.self))
} catch let error as ScanFailure {
    fail(error.description)
} catch {
    fail("Hata: \(error)")
}
