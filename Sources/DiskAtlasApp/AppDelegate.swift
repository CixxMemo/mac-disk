import AppKit
import DiskAtlasCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var host: WebHost?
    private var selfTest: SelfTest?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = LaunchConfig.parse(CommandLine.arguments)
        NSApp.mainMenu = Self.buildMenu()
        do {
            let environment = ProcessInfo.processInfo.environment
            let resources = Bundle.main.resourceURL
            let webRoot = environment["DISKATLAS_WEB_DIR"].map { URL(fileURLWithPath: $0) }
                ?? resources?.appendingPathComponent("web") ?? URL(fileURLWithPath: "web")
            let rulesURL = environment["DISKATLAS_RULES"].map { URL(fileURLWithPath: $0) }
                ?? resources?.appendingPathComponent("rules.json") ?? URL(fileURLWithPath: "rules.json")
            let home = NSHomeDirectory()
            var dataRoot = FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : home
            var homeRoot = home
            var storeDirectory = ReportStore.defaultDirectory()
            if config.selfTest {
                // Sınama gerçek taramaları kirletmez: kök ve kayıt klasörü bayraklarla gelir.
                guard let root = config.scanRoot, let store = config.storeDirectory else {
                    throw SelfTest.Failure(message: "--self-test için --scan-root ve --store-dir gerekli.")
                }
                // Sınama kök altına örnek dosyalar yazar: gerçek ana klasörü kapsayan veya kök dizin olan bir yola izin verilmez.
                let standardized = URL(fileURLWithPath: root).standardizedFileURL.path
                let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
                if standardized == "/" || home == standardized || home.hasPrefix(standardized + "/") {
                    throw SelfTest.Failure(message: "--scan-root gerçek ana klasörünüzü içeremez; geçici bir klasör verin.")
                }
                dataRoot = root
                homeRoot = root
                storeDirectory = URL(fileURLWithPath: store)
            }
            let host = try WebHost(webRoot: webRoot, rulesURL: rulesURL, store: ReportStore(directory: storeDirectory),
                                   roots: ScanRoots(data: dataRoot, home: homeRoot))
            self.host = host
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Disk Atlas"
            window.minSize = NSSize(width: 960, height: 640)
            window.isReleasedWhenClosed = false
            window.contentView = host.webView
            if config.selfTest {
                window.center()
                window.orderFrontRegardless()
            } else {
                window.setFrameAutosaveName("DiskAtlasMain")
                if !window.setFrameUsingName("DiskAtlasMain") { window.center() }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            self.window = window
            host.load()
            if config.selfTest {
                selfTest = SelfTest(host: host, config: config)
                selfTest?.start()
            }
        } catch {
            let message = (error as? SelfTest.Failure)?.message ?? "Uygulama başlatılamadı: \(error)"
            FileHandle.standardError.write(Data((message + "\n").utf8))
            if config.selfTest { exit(1) }
            let alert = NSAlert()
            alert.messageText = "Disk Atlas başlatılamadı"
            alert.informativeText = message
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private static func buildMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, to menu: NSMenu, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        func submenu(_ title: String, build: (NSMenu) -> Void) {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            build(menu)
            item.submenu = menu
            main.addItem(item)
        }
        submenu("Disk Atlas") { menu in
            add("Disk Atlas Hakkında", to: menu, #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            menu.addItem(.separator())
            add("Disk Atlas’ı Gizle", to: menu, #selector(NSApplication.hide(_:)), "h")
            add("Diğerlerini Gizle", to: menu, #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            add("Tümünü Göster", to: menu, #selector(NSApplication.unhideAllApplications(_:)))
            menu.addItem(.separator())
            add("Disk Atlas’tan Çık", to: menu, #selector(NSApplication.terminate(_:)), "q")
        }
        submenu("Düzen") { menu in
            add("Kes", to: menu, #selector(NSText.cut(_:)), "x")
            add("Kopyala", to: menu, #selector(NSText.copy(_:)), "c")
            add("Yapıştır", to: menu, #selector(NSText.paste(_:)), "v")
            add("Tümünü Seç", to: menu, #selector(NSText.selectAll(_:)), "a")
        }
        submenu("Pencere") { menu in
            add("Küçült", to: menu, #selector(NSWindow.performMiniaturize(_:)), "m")
            add("Yakınlaştır", to: menu, #selector(NSWindow.performZoom(_:)))
        }
        return main
    }
}
