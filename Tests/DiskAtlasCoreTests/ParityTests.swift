import XCTest
import Darwin
@testable import DiskAtlasCore

/// Swift tarayıcısını `scanner.py` ile aynı ağaçta karşılaştırır. Python yalnızca okuma yapar.
final class ParityTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func runPython(on root: String) throws -> [String: Any] {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { throw XCTSkip("python3 yok") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [repoRoot.appendingPathComponent("Tests/Parity/py_scan.py").path, root]
        process.environment = ["PYTHONDONTWRITEBYTECODE": "1", "PATH": "/usr/bin:/bin"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            XCTFail("py_scan.py çıkış kodu \(process.terminationStatus): \(String(decoding: errData, as: UTF8.self))")
            throw CocoaError(.executableRuntimeMismatch)
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func swiftReport(_ tree: TempTree) throws -> Report {
        let classifier = Classifier(rules: try RuleSet.bundled())
        return try DiskScanner(options: ScanOptions(root: tree.path()), classifier: classifier).run()
    }

    private func int(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? -1 }

    private func flatten(_ node: Node, into map: inout [String: String]) {
        map[node.path + (node.aggregate == true ? "#agg" : "")] = "\(node.bytes)|\(node.logical)|\(node.category.rawValue)|\(node.name)"
        for child in node.children ?? [] { flatten(child, into: &map) }
    }

    private func flatten(_ node: [String: Any], into map: inout [String: String]) {
        let aggregate = (node["aggregate"] as? Bool) == true
        map[(node["path"] as? String ?? "") + (aggregate ? "#agg" : "")] =
            "\(int(node["bytes"]))|\(int(node["logical"]))|\(node["category"] as? String ?? "")|\(node["name"] as? String ?? "")"
        for child in node["children"] as? [[String: Any]] ?? [] { flatten(child, into: &map) }
    }

    private func statsDictionary(_ stats: Stats) throws -> [String: Int64] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stats)) as? [String: Any] ?? [:]
        return object.mapValues { int($0) }
    }

    private func assertTotalsMatch(_ swift: Report, _ python: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let tree = try XCTUnwrap(python["tree"] as? [String: Any])
        XCTAssertEqual(swift.tree.bytes, int(tree["bytes"]), "kök bayt", file: file, line: line)
        XCTAssertEqual(swift.tree.logical, int(tree["logical"]), "kök mantıksal", file: file, line: line)
        let categories = (python["categories"] as? [String: Any] ?? [:]).mapValues { int($0) }
        XCTAssertEqual(swift.categories, categories, "kategoriler", file: file, line: line)
        let stats = (python["stats"] as? [String: Any] ?? [:]).mapValues { int($0) }
        XCTAssertEqual(try statsDictionary(swift.stats), stats, "sayaçlar", file: file, line: line)
    }

    func testSwiftScannerMatchesPythonOnFixtureTree() throws {
        let tree = try TempTree()
        try tree.file("docs/readme.txt", size: 5000)
        try tree.file("docs/notes/n.txt", size: 12000)
        try tree.file("proj/node_modules/big.bin", size: 10 * 1024 * 1024 + 1000)
        try tree.file("proj/src/main.c", size: 2000)
        try tree.file(".cache/c.bin", size: 4000)
        try tree.file("Applications/Foo.app/Contents/bin", size: 8000)
        for i in 0..<45 { try tree.file("many/f\(i).bin", size: 4096 * i + 1) }
        try tree.dir("empty")
        try tree.symlink("link", to: tree.path("docs/readme.txt"))

        let python = try runPython(on: tree.path())
        let swift = try swiftReport(tree)
        try assertTotalsMatch(swift, python)

        var swiftNodes: [String: String] = [:], pythonNodes: [String: String] = [:]
        flatten(swift.tree, into: &swiftNodes)
        flatten(try XCTUnwrap(python["tree"] as? [String: Any]), into: &pythonNodes)
        XCTAssertEqual(swiftNodes, pythonNodes, "ağaç düğümleri")
        XCTAssertGreaterThan(pythonNodes.count, 50, "karşılaştırma boş olmamalı")
        XCTAssertTrue(pythonNodes.keys.contains { $0.hasSuffix("#agg") }, "40'tan fazla çocuk kırpılmış olmalı")

        let pythonCandidates = (python["candidates"] as? [[String: Any]] ?? []).map {
            "\($0["path"] ?? "")|\(int($0["bytes"]))|\(int($0["logical"]))|\($0["category"] ?? "")|\($0["label"] ?? "")|\($0["note"] ?? "")"
        }
        let swiftCandidates = swift.candidates.map {
            "\($0.path)|\($0.bytes)|\($0.logical)|\($0.category.rawValue)|\($0.label)|\($0.note)"
        }
        XCTAssertEqual(swiftCandidates, pythonCandidates, "adaylar")
        XCTAssertEqual(swiftCandidates.count, 1)

        let pythonLargest = (python["largest"] as? [[String: Any]] ?? []).map { "\(int($0["bytes"]))|\($0["path"] ?? "")" }.sorted()
        XCTAssertEqual(swift.largest.map { "\($0.bytes)|\($0.path)" }.sorted(), pythonLargest, "en büyük dosyalar")
        XCTAssertEqual((python["errors"] as? [Any])?.count, 0)
        XCTAssertEqual(swift.errors.count, 0)
    }

    func testHardlinkAndErrorTotalsMatchPython() throws {
        let tree = try TempTree()
        let first = try tree.file("a.bin", size: 4000)
        try tree.hardlink("hl1.bin", to: first)
        try tree.hardlink("hl2.bin", to: first)
        try tree.file("b/c.bin", size: 8000)
        try tree.file("locked/hidden.bin", size: 4000)
        XCTAssertEqual(chmod(tree.path("locked"), 0o000), 0)
        defer { chmod(tree.path("locked"), 0o755) }

        let python = try runPython(on: tree.path())
        let swift = try swiftReport(tree)
        try assertTotalsMatch(swift, python)
        XCTAssertEqual(swift.stats.hardlinkRepeats, 2)
        let pythonErrors = (python["errors"] as? [[String: Any]] ?? []).map { "\($0["path"] ?? "")|\($0["reason"] ?? "")" }
        XCTAssertEqual(swift.errors.map { "\($0.path)|\($0.reason)" }, pythonErrors, "hata kayıtları")
        XCTAssertEqual(pythonErrors.count, 1)
    }
}
