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
            _ = try await evaluate("document.getElementById('scanBtn').click()")
            let deadline = Date().addingTimeInterval(config.timeout - 5)
            while Date() < deadline {
                if try await evaluate("!document.getElementById('dashboard').classList.contains('hidden')") as? Bool == true { break }
                if try await evaluate("!document.getElementById('message').classList.contains('hidden')") as? Bool == true {
                    results["message"] = try await evaluate("document.getElementById('message').textContent")
                    return finish(ok: false, reason: "tarama hata mesajı gösterdi")
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            results["dashboardVisible"] = try await evaluate("!document.getElementById('dashboard').classList.contains('hidden')")
            results["scannedValue"] = try await evaluate("document.getElementById('scannedValue').textContent")
            results["filesText"] = try await evaluate("document.getElementById('filesText').textContent")
            results["scanMeta"] = try await evaluate("document.getElementById('scanMeta').textContent")
            results["appInfo"] = try await evaluate("document.getElementById('appInfoText').textContent")
            if let path = config.snapshotPath { try await snapshot(to: path) }
            let dashboard = results["dashboardVisible"] as? Bool == true
            finish(ok: dashboard, reason: dashboard ? nil : "pano görünmedi")
        } catch {
            finish(ok: false, reason: "\(error)")
        }
    }

    @MainActor private func evaluate(_ script: String) async throws -> Any? {
        try await host.webView.callAsyncJavaScript("return \(script)", contentWorld: .page)
    }

    @MainActor private func snapshot(to path: String) async throws {
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
