import AppKit
import WebKit

/// `--self-test`: arayüzü gerçek köprü üzerinden sınar, ekran görüntüsü alır ve çıkar.
/// Karşılama ekranını `<snapshot>-welcome.png`, taramadan sonraki panoyu `<snapshot>` olarak kaydeder.
final class SelfTest {
    struct Failure: Error { var message: String }

    private let host: WebHost
    private let config: LaunchConfig
    private var results: [String: Any] = [:]

    init(host: WebHost, config: LaunchConfig) {
        self.host = host
        self.config = config
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + config.timeout) { [self] in finish(ok: false, reason: "zaman aşımı") }
        host.onLoadFinished = { [self] in
            host.onLoadFinished = nil
            Task { @MainActor in await run() }
        }
    }

    @MainActor private func run() async {
        do {
            _ = try await host.webView.callAsyncJavaScript("await window.diskAtlasReady; return true;", contentWorld: .page)
            if let path = config.snapshotPath { try await snapshot(to: Self.suffixed(path, "-welcome")) }
            results["welcomeVisible"] = try await evaluate("!document.getElementById('welcome').classList.contains('hidden')")
            results["permissionTitle"] = try await evaluate("document.getElementById('permissionTitle').textContent")
            // Uygulamalar/Tanınmayan sınaması için kural kataloğuyla eşleşen (ve eşleşmeyen) klasörler.
            if let root = config.scanRoot {
                func write(_ relative: String, megabytes: Double) throws {
                    let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? Data(count: Int(megabytes * 1_048_576)).write(to: url, options: .withoutOverwriting)
                }
                try write(".npm/_cacache/blob", megabytes: 2)
                try write("Library/Android/sdk/platform", megabytes: 3)
                try write("Library/Caches/com.spotify.client/Data", megabytes: 2)
                try write("Library/Caches/Other/cache.bin", megabytes: 2)
                try write("Library/Application Support/Mystery/data.bin", megabytes: 110)
            }
            _ = try await evaluate("document.getElementById('scanBtn').click()")
            let deadline = Date().addingTimeInterval(config.timeout - 5)
            while Date() < deadline {
                // Durum tek sorguda okunur: iki ayrı sorgu arasında ekran değişebilir.
                let state = try await evaluate("""
                ({ dashboard: !document.getElementById('dashboard').classList.contains('hidden'),
                   scanning: !document.getElementById('scanning').classList.contains('hidden'),
                   message: document.getElementById('message').classList.contains('hidden') ? '' : document.getElementById('message').textContent })
                """) as? [String: Any] ?? [:]
                let dashboard = state["dashboard"] as? Bool == true
                let scanning = state["scanning"] as? Bool == true
                let message = state["message"] as? String ?? ""
                if dashboard && !scanning { break }
                if !dashboard && !scanning && !message.isEmpty {
                    results["message"] = message
                    return finish(ok: false, reason: "tarama hata mesajı gösterdi")
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            results["dashboardVisible"] = try await evaluate("!document.getElementById('dashboard').classList.contains('hidden')")
            results["message"] = try await evaluate("document.getElementById('message').classList.contains('hidden') ? '' : document.getElementById('message').textContent")
            results["scannedValue"] = try await evaluate("document.getElementById('scannedValue').textContent")
            results["filesText"] = try await evaluate("document.getElementById('filesText').textContent")
            results["scanMeta"] = try await evaluate("document.getElementById('scanMeta').textContent")
            results["appInfo"] = try await evaluate("document.getElementById('appInfoText').textContent")
            if let path = config.snapshotPath { try await snapshot(to: path) }
            guard results["dashboardVisible"] as? Bool == true else { return finish(ok: false, reason: "pano görünmedi") }

            // Uygulamalar ve Tanınmayan görünümleri
            guard try await waitFor("!document.getElementById('appsNav').classList.contains('hidden')") else {
                return finish(ok: false, reason: "Uygulamalar sekmesi görünmedi")
            }
            _ = try await evaluate("document.getElementById('appsNav').click()")
            guard try await waitFor("document.getElementById('appsList').children.length >= 2") else {
                return finish(ok: false, reason: "Uygulamalar listesi boş")
            }
            _ = try await evaluate("document.querySelector('#appsList .app-head').click(); true")
            let appRows = try await evaluate("[...document.getElementById('appsList').children].map(r => r.querySelector('.app-name').textContent)") as? [String] ?? []
            results["appNames"] = appRows
            results["firstAppDetail"] = try await evaluate("document.querySelector('#appsList .app-details').textContent.slice(0, 160)")
            if let path = config.snapshotPath { try await snapshot(to: Self.suffixed(path, "-apps")) }
            _ = try await evaluate("document.getElementById('unrecognizedNav').click()")
            guard try await waitFor("document.getElementById('unrecognizedBody').children.length >= 1") else {
                return finish(ok: false, reason: "Tanınmayan listesi boş")
            }
            let unknownRows = try await evaluate("[...document.getElementById('unrecognizedBody').children].map(r => r.textContent)") as? [String] ?? []
            results["unrecognizedRows"] = unknownRows
            if let path = config.snapshotPath { try await snapshot(to: Self.suffixed(path, "-unrecognized")) }
            guard appRows.contains("Android"), appRows.contains("JavaScript araçları"), unknownRows.contains(where: { $0.contains("Mystery") }) else {
                return finish(ok: false, reason: "beklenen araçlar veya tanınmayan klasör listede yok")
            }
            _ = try await evaluate("document.querySelector('[data-view=history]').classList.contains('hidden')")

            // İkinci tarama (kök altına ≥ 2 MiB'lık bir klasör eklenir), ardından Geçmiş'te karşılaştırma.
            if let root = config.scanRoot {
                let folder = URL(fileURLWithPath: root).appendingPathComponent("selftest-grow")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(count: 3 * 1024 * 1024).write(to: folder.appendingPathComponent("big.bin"))
            }
            _ = try await evaluate("document.getElementById('scanBtn').click()")
            guard try await waitFor("!document.getElementById('dashboard').classList.contains('hidden') && document.getElementById('scanning').classList.contains('hidden')") else {
                return finish(ok: false, reason: "ikinci tarama bitmedi")
            }
            _ = try await evaluate("document.getElementById('historyNav').click()")
            guard try await waitFor("document.getElementById('historyList').children.length >= 2") else {
                return finish(ok: false, reason: "geçmiş listesi iki taramayı göstermedi")
            }
            results["historyRows"] = try await evaluate("[...document.getElementById('historyList').children].map(r => r.textContent)")
            if let path = config.snapshotPath { try await snapshot(to: Self.suffixed(path, "-history")) }
            _ = try await evaluate("(() => { const b = [...document.querySelectorAll('#historyList input')]; b[0].click(); b[1].click(); document.getElementById('compareBtn').click(); return true; })()")
            guard try await waitFor("!document.getElementById('compareResult').classList.contains('hidden') && document.querySelectorAll('#compareBody tr').length >= 1") else {
                return finish(ok: false, reason: "karşılaştırma sonucu görünmedi")
            }
            let rows = try await evaluate("[...document.querySelectorAll('#compareBody tr')].map(r => r.textContent)") as? [String] ?? []
            results["compareRows"] = rows
            results["compareSummary"] = try await evaluate("document.getElementById('compareSummary').textContent")
            _ = try await evaluate("document.getElementById('compareResult').scrollIntoView(); true")
            if let path = config.snapshotPath { try await snapshot(to: Self.suffixed(path, "-compare")) }
            let grew = rows.contains { $0.contains("selftest-grow") && $0.contains("Yeni") }
            finish(ok: grew, reason: grew ? nil : "büyüyen klasör karşılaştırmada görünmedi")
        } catch {
            finish(ok: false, reason: "\(error)")
        }
    }

    /// Koşul doğru olana kadar 0,2 sn aralıkla sorar; süre dolarsa `false` döner.
    @MainActor private func waitFor(_ condition: String) async throws -> Bool {
        let deadline = Date().addingTimeInterval(max(10, config.timeout / 3))
        while Date() < deadline {
            if try await evaluate(condition) as? Bool == true { return true }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    @MainActor private func evaluate(_ script: String) async throws -> Any? {
        try await host.webView.callAsyncJavaScript("return \(script)", contentWorld: .page)
    }

    @MainActor private func snapshot(to path: String) async throws {
        try await Task.sleep(nanoseconds: 600_000_000)  // requestAnimationFrame ile çizilen harita için
        let image = try await host.webView.takeSnapshot(configuration: WKSnapshotConfiguration())
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw Failure(message: "Ekran görüntüsü PNG'ye çevrilemedi.")
        }
        try png.write(to: URL(fileURLWithPath: path))
    }

    private static func suffixed(_ path: String, _ suffix: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent + suffix + "." + url.pathExtension
        return url.deletingLastPathComponent().appendingPathComponent(name).path
    }

    private func finish(ok: Bool, reason: String?) {
        let errors = host.consoleErrors
        let success = ok && errors.isEmpty
        var report = results
        report["ok"] = success
        report["consoleErrors"] = errors
        if let reason { report["reason"] = reason }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
        exit(success ? 0 : 1)
    }
}
