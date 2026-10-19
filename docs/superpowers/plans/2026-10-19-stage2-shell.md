# Disk Atlas — 2. Aşama (Uygulama kabuğu) Uygulama Planı

> **Uygulayıcı için:** ZORUNLU ALT-BECERİ: `superpowers:executing-plans` (kullanıcı native yöntemi seçti ve bu planı önceden onayladı). Adımlar `- [ ]` ile izlenir.

**Hedef:** Çift tıklayınca açılan, kendi diskini tarayıp (ilerleme + iptal) mevcut arayüzde gösteren, taramaları `~/Library/Application Support/DiskAtlas/scans` altına kaydeden imzasız `DiskAtlas.app`.

**Mimari:** Saf Swift mantığı `DiskAtlasCore` içinde (ReportStore, PermissionProbe, ekran verisi, köprü yönlendiricisi, asset çözümleyici) ve birim testli. `DiskAtlasApp` (AppKit) yalnızca pencere, `WKWebView`, URL şeması ve köprü yapıştırıcısıdır. Arayüz `Resources/web/` altında HTML/CSS/JS; iki arka uç: `FileBackend` (JSON açma) ve `NativeBackend` (köprü). Yerel sunucu yoktur.

**Teknoloji:** Swift 6.1 (Swift 5 dil modu), AppKit, WebKit, XCTest, Node (arayüz testi), bash.

**Spec:** `docs/superpowers/specs/2026-10-19-disk-atlas-mac-app-design.md` (bölüm 3, 3.1, 4.1, 5, 7, 10/aşama 2). Önceki plan: `2026-10-19-stage1-core.md`.

## Global Kısıtlar

- macOS 14+, Apple Silicon. Ad-hoc imza (`codesign -s -`), notarization yok, App Store yok.
- WebView yalnızca paketteki içeriği yükler (`diskatlas://app/...`). Harici gezinme iptal edilir. CSP: `default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'none'`. Ağ erişimi yok.
- JS'ten gelen hiçbir yol dosya sistemine verilmez: tarama kökü yalnızca `"data"` veya `"home"` kapsamıdır, rapor kimliği doğrulanır.
- Köprü mesajı `{id, type, payload}`; yanıt `{id, ok, data|error}` (JSON metni). Olaylar `{event, ...}`.
- Şema 2 raporları arayüze `Report.forDisplay()` ile (sıkıştırılmış ağaç, `folderIndex`/`unreadable` olmadan) gider. Arayüz şema 1 ve 2'yi kabul eder.
- Kullanıcıya görünen metin Türkçe. Paket kimliği `local.diskatlas.app`, sürüm `0.2.0`.
- Mevcut Python aracı (`scanner.py`, `build_ui.py`, `Disk-Atlas.template.html`) değişmez.
- Testler gerçek kullanıcı dosyalarına yazmaz (geçici dizin). Her görev commit ile biter; mesaj sonuna `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus

1. JS'ten gelen bozuk/uzun/bilinmeyen köprü mesajı: çökmez, `ok:false` döner. Test: Görev 3.
2. Rapor kimliğinde yol gezinmesi (`../x`, `/etc/passwd`): reddedilir. Test: Görev 1, 3.
3. Tarama sürerken ikinci `startScan`: reddedilir, ilki bozulmaz. Test: Görev 3.
4. Tam Disk Erişimi yokken: arayüz "kısmi" uyarısı ve izin rehberi gösterir, tarama yine başlatılabilir. Test: Görev 3, 4.
5. Bozuk/eksik kayıtlı tarama dosyası: liste çökmeden diğerlerini gösterir. Test: Görev 1.

---

### Task 1: ReportStore (tarama kaydı)

**Files:**
- Create: `Sources/DiskAtlasCore/Store/ReportStore.swift`
- Test: `Tests/DiskAtlasCoreTests/ReportStoreTests.swift`

**Interfaces:**
- Consumes: `Report`, `ReportCodec` (1. aşama)
- Produces:
  - `public struct ScanSummary: Codable, Equatable, Sendable { id: String; created: String; scope: String; incomplete: Bool; allocatedBytes: Int64; schema: Int }`
  - `public enum ReportStoreError: Error, Equatable { case invalidID(String); case notFound(String) }`
  - `public final class ReportStore: @unchecked Sendable { init(directory: URL); static func defaultDirectory() -> URL; func save(_ report: Report) throws -> String; func list() -> [ScanSummary]; func load(id: String) throws -> Report; static func isValid(id: String) -> Bool }`

`save` `<id>.json` ve `<id>.meta.json` (özet) yazar (atomik). Kimlik: `"scan-"` + `created` içindeki rakamlar ve `T`; dosya varsa `-N` eki. Geçerli kimlik: `^scan-[0-9T]{1,40}(-[0-9]{1,4})?$`. `list` yalnızca okunabilir `.meta.json` dosyalarını döner, yeniden eskiye sıralı.

- [ ] **Adım 1: Başarısız testleri yaz:** `testSaveListLoadRoundTrip` (1. aşamadaki `legacy-schema1.json` fixture'ı ile), `testListIsNewestFirst`, `testSameTimestampGetsDistinctIDs`, `testLoadRejectsPathTraversalIDs` (`"../x"`, `"/etc/passwd"`, `""`, `"scan-1/../2"` → `invalidID`), `testLoadMissingThrowsNotFound`, `testListSkipsCorruptMeta`.
- [ ] **Adım 2:** `swift test --filter ReportStoreTests` → derleme hatası.
- [ ] **Adım 3: Uygula.**
- [ ] **Adım 4:** `swift test --filter ReportStoreTests` → PASS.
- [ ] **Adım 5: Commit** `feat(core): add ReportStore`.

---

### Task 2: İzin sondası, ekran verisi, kural yükleme, asset çözümleyici

**Files:**
- Create: `Sources/DiskAtlasCore/Platform/PermissionProbe.swift`, `Sources/DiskAtlasCore/Model/Report+Display.swift`, `Sources/DiskAtlasCore/Web/AssetResolver.swift`
- Modify: `Sources/DiskAtlasCore/Classify/RuleSet.swift` (`load(from:)`)
- Test: `Tests/DiskAtlasCoreTests/PermissionProbeTests.swift`, `ReportDisplayTests.swift`, `AssetResolverTests.swift`, `ClassifierTests.swift`

**Interfaces:**
- Consumes: `FileSystem`, `FakeFileSystem`, `Report`, `Node`
- Produces:
  - `public enum PermissionStatus: String, Codable, Sendable { case granted, denied, unknown }`
  - `public struct PermissionProbe: Sendable { init(fileSystem: FileSystem = RealFileSystem(), probePath: String = "/Library/Application Support/com.apple.TCC"); func fullDiskAccess() -> PermissionStatus }` — listeleme başarılı → `granted`; hata metni `PermissionError` ile başlıyorsa `denied`; diğer hata → `unknown`.
  - `extension Report { public func forDisplay() -> Report }` — Python `build_ui.compact_tree` ile aynı: çocuklar boyuta göre azalan; ilk 16 içinde (`i < 3` veya `bytes >= 2 MiB`) olanlar tutulur, kalanı `"Diğer N öğe"` (`aggregate: true`, yol = üst yol, kategori = üst kategori) düğümünde toplanır; özyinelemeli; `folderIndex`, `unreadable` `nil`.
  - `public static func RuleSet.load(from url: URL) throws -> RuleSet`; `bundled()` bunu kullanır.
  - `public struct AssetResolver: Sendable { init(root: URL); func resolve(path: String) -> Asset? }`, `public struct Asset { url: URL; mimeType: String }` — `/` → `index.html`; `..`, mutlak/gizli yol, kök dışı (sembolik bağlantı dahil) ve olmayan dosya `nil`; MIME: html, css, js (`text/javascript`), json, svg, png, woff2.

- [ ] **Adım 1: Başarısız testleri yaz:** `testFullDiskAccessGrantedDeniedUnknown` (Fake: başarı / `PermissionError: Operation not permitted` / `FileNotFoundError...`), `testForDisplayKeepsTop16AndFoldsSmall` (20 çocuk; beklenen: 16 tutulur + aggregate, bayt toplamı korunur, 4. çocuktan sonra 2 MiB altı olanlar katlanır), `testForDisplayStripsHeavyFields`, `testRuleSetLoadFromURL`, `testResolveServesIndexAndAssets`, `testResolveRejectsTraversalAndSymlinkEscape`, `testResolveMimeTypes`.
- [ ] **Adım 2:** `swift test` → ilgili testler FAIL/derleme hatası.
- [ ] **Adım 3: Uygula.**
- [ ] **Adım 4:** `swift test` → hepsi PASS.
- [ ] **Adım 5: Commit** `feat(core): add permission probe, display payload and asset resolver`.

---

### Task 3: Köprü yönlendiricisi

**Files:**
- Create: `Sources/DiskAtlasCore/Bridge/BridgeRouter.swift`
- Test: `Tests/DiskAtlasCoreTests/BridgeRouterTests.swift`

**Interfaces:**
- Consumes: `ReportStore`, `RuleSet`, `Classifier`, `DiskScanner`, `ScanOptions`, `PermissionStatus`, `Report.forDisplay()`
- Produces:
  - `public struct ScanRoots: Sendable { data: String; home: String; excluded: [String]; init(...) }`
  - `public struct AppInfo: Codable, Sendable { version: String; macOS: String }`
  - `public typealias ScanRunner = @Sendable (ScanOptions, Classifier, @escaping () -> Bool, @escaping (ScanProgress) -> Void) throws -> Report` (varsayılan: gerçek `DiskScanner`)
  - `public final class BridgeRouter: @unchecked Sendable { init(store: ReportStore, rules: RuleSet, roots: ScanRoots, appInfo: AppInfo, permission: @escaping @Sendable () -> PermissionStatus, openFullDiskAccess: @escaping @Sendable () -> Void, emit: @escaping @Sendable (Data) -> Void, runner: @escaping ScanRunner = BridgeRouter.defaultRunner); func handle(_ message: Data) -> Data; var isScanning: Bool { get } }`

İstek türleri ve yanıtlar (`data`): `startScan{scope:"data"|"home"}` → `{started:true}`; `cancelScan` → `{}`; `listScans` → `[ScanSummary]`; `loadScan{id}` → `Report.forDisplay()`; `permissionStatus` → `{status}`; `openFullDiskAccess` → `{}`; `appInfo` → `AppInfo`. Olaylar: `{"event":"scanProgress","records":N,"errors":N,"folder":"...","elapsed":S}`, `{"event":"scanDone","id":"..."}`, `{"event":"scanFailed","message":"..."}`. `startScan` `isScanning`'i eşzamanlı true yapar, taramayı arka planda koşturur, raporu `store.save` ile kaydeder, `scanDone` yayar; mağaza klasörü tarama dışında bırakılır (`roots.excluded` + mağaza yolu). İptal: bayrak `runner`'a `isCancelled` olarak geçer; kısmi rapor yine kaydedilir.
Hatalar (`ok:false`, Türkçe `error`): geçersiz JSON, `id` yok/64 karakterden uzun, bilinmeyen `type`, geçersiz `payload`/`scope`, geçersiz kimlik, bulunamayan tarama, `"Tarama zaten sürüyor."`.

- [ ] **Adım 1: Başarısız testleri yaz:** `testRejectsMalformedMessages` (rastgele bayt, `{}`, eksik id, 65 karakterli id, bilinmeyen tür, `startScan` scope `"/etc"`), `testStartScanSavesReportAndEmitsDone` (geçici ağaç ve kök, olay beklenir; `listScans` 1 kayıt; `loadScan` ağaç bayt toplamı doğru), `testSecondStartScanIsRejectedWhileRunning` (runner semafor ile bekler), `testCancelPassesFlagToRunnerAndSavesPartialReport`, `testScanFailureEmitsScanFailed` (runner hata atar), `testLoadScanRejectsTraversalID`, `testPermissionAndOpenSettingsAndAppInfo`, `testStoreDirectoryIsExcludedFromScan`.
- [ ] **Adım 2:** `swift test --filter BridgeRouterTests` → FAIL.
- [ ] **Adım 3: Uygula.**
- [ ] **Adım 4:** `swift test` → hepsi PASS.
- [ ] **Adım 5: Commit** `feat(core): add bridge router`.

---

### Task 4: Web arayüzü (bölme, arka uç soyutlaması, tarama ekranları)

**Files:**
- Create: `Resources/web/index.html`, `Resources/web/app.css`, `Resources/web/app.js` (şablondan `scripts/split_web.py` ile bir kez üretilir, sonra elle düzenlenir), `Tests/web/ui.test.cjs`
- Modify: `verify_ui.cjs` (yeni dosya yapısı; eski gömülü `Disk-Atlas.html` yerine `Resources/web` + en yeni `reports/*.json`)
- Create: `scripts/split_web.py` (tek seferlik bölme betiği; çıktı depoya girer, betik de kalır)

**Interfaces:**
- Consumes: köprü sözleşmesi (Görev 3), `Report` şema 2 alanları
- Produces (JS): `const backend = window.webkit?.messageHandlers?.diskatlas ? nativeBackend : fileBackend`; `nativeBackend.request(type, payload) -> Promise<data>` (JSON metni çözer, `ok:false` → `Error(error)`); `window.diskAtlasEvent(event)`; `validate` şema 1 ve 2'yi kabul eder; yeni kimlikler: `scanBtn`, `scanning`, `scanProgressText`, `cancelScanBtn`, `permissionCard`, `permissionText`, `openSettingsBtn`, `startScanBtn`, `appInfoText`.

Davranış: Yerel modda açılışta `permissionStatus` + `listScans`; kayıt varsa en yenisini `loadScan` ile açar, yoksa karşılama + izin kartı gösterir (`denied` ise "Tam Disk Erişimi yok: tarama kısmi olacak" + "Ayarları Aç"). "Tara" düğmesi `startScan{scope:"data"}`; `scanProgress` olayları ilerleme metnini günceller; `scanDone{id}` → `loadScan` → pano; `scanFailed` → mesaj; "İptal" → `cancelScan`. Dosya modunda `scanBtn` gizli, davranış eskisi gibi. Tarama bilgisi sayfası `appInfo` sürümünü gösterir. CSP meta etiketi yukarıdaki global kısıttaki gibi, `connect-src 'none'`.

- [ ] **Adım 1:** `scripts/split_web.py` ile şablondan `index.html/app.css/app.js` üret (CSS ve JS'i dışa taşı, `/*__REPORT_DATA__*/` gömmesini kaldır). Mevcut `verify_ui.cjs`'i yeni yapıya uyarla; şu an çalıştırınca bölme tamamlanana kadar bazı kontroller başarısız olabilir.
- [ ] **Adım 2: Başarısız testleri yaz** (`Tests/web/ui.test.cjs`, sahte DOM + sahte köprü): `nativeBootShowsPermissionCardAndWelcomeWhenNoScans`, `deniedPermissionShowsPartialWarning`, `scanButtonSendsStartScanAndShowsProgress`, `scanDoneLoadsReportAndShowsDashboard`, `cancelButtonSendsCancelScan`, `scanFailedShowsMessage`, `bridgeErrorShowsMessage`, `validateAcceptsSchema2`, `fileModeHidesScanButton`.
- [ ] **Adım 3:** `node Tests/web/ui.test.cjs` → FAIL.
- [ ] **Adım 4: Uygula** (HTML, CSS, JS).
- [ ] **Adım 5:** `node Tests/web/ui.test.cjs && node verify_ui.cjs` → PASS.
- [ ] **Adım 6: Commit** `feat(web): split UI, add native backend and scan screens`.

---

### Task 5: Uygulama kabuğu (AppKit + WebKit) ve kendi kendini sınama

**Files:**
- Create: `Sources/DiskAtlasApp/main.swift`, `AppDelegate.swift`, `WebHost.swift` (WKWebView, şema işleyici, gezinme politikası, köprü yapıştırıcısı), `SelfTest.swift`
- Modify: `Package.swift` (yürütülebilir hedef `DiskAtlasApp`, `Core`'a bağlı)

**Interfaces:**
- Consumes: `BridgeRouter`, `ReportStore`, `PermissionProbe`, `AssetResolver`, `RuleSet.load(from:)`
- Produces: ikili `DiskAtlasApp`; `--self-test --scan-root PATH --snapshot OUT.png [--timeout N]` kipi: pencereyi açar, arayüzdeki "Tara"yı gerçek köprü üzerinden `PATH` kökünde (yalnızca bu bayrakla geçerli) çalıştırır, panonun göründüğünü ve konsol hatası olmadığını doğrular, PNG kaydeder, tek satır JSON yazar, başarıda çıkış kodu 0.

Davranış: tek ana pencere (en az 960×640, başlık "Disk Atlas"), standart menü (Uygulama, Düzen: Kes/Kopyala/Yapıştır/Tümünü Seç, Pencere). Web kökü: `DISKATLAS_WEB_DIR` ortam değişkeni, yoksa `Bundle.main.resourceURL/web`. Kurallar: `Bundle.main.resourceURL/rules.json`. Gezinme: `diskatlas` dışı her şey iptal. `openFullDiskAccess`: `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`. Konsol hataları ve `window.onerror` yerel tarafa iletilir.

- [ ] **Adım 1:** Hedefi ve kabuğu uygula (derleme: `swift build --product DiskAtlasApp` temiz). Bu görevin birim testi yoktur; mantık Core'da test edildi, doğrulama Görev 6'daki gerçek çalıştırmadır.
- [ ] **Adım 2:** `DISKATLAS_WEB_DIR=Resources/web .build/debug/DiskAtlasApp --self-test --scan-root <geçici ağaç> --snapshot <png>` → çıkış 0, JSON'da `"ok":true`.
- [ ] **Adım 3: Commit** `feat(app): add AppKit shell with WebKit host and self-test mode`.

---

### Task 6: `.app` paketleme ve doğrulama

**Files:**
- Create: `scripts/build_app.sh`, `scripts/Info.plist.template`
- Modify: `.gitignore` (`dist/`)

**Interfaces:**
- Consumes: derlenmiş `DiskAtlasApp`, `Resources/web/`, `Sources/DiskAtlasCore/Resources/rules.json`
- Produces: `dist/DiskAtlas.app`, `dist/DiskAtlas.zip`

`build_app.sh`: `swift build -c release --product DiskAtlasApp`; `Contents/MacOS/DiskAtlas`, `Contents/Resources/web/*`, `Contents/Resources/rules.json`, `Contents/Info.plist` (`CFBundleIdentifier local.diskatlas.app`, `CFBundleName "Disk Atlas"`, `CFBundleExecutable DiskAtlas`, `CFBundleShortVersionString 0.2.0`, `LSMinimumSystemVersion 14.0`, `NSHighResolutionCapable`); `codesign --force --deep -s -`; `codesign --verify --strict`; `ditto -c -k --keepParent` ile zip. Betik başarısızlıkta durur (`set -euo pipefail`).

- [ ] **Adım 1:** `bash scripts/build_app.sh` → `dist/DiskAtlas.app` ve `.zip` oluşur; `codesign --verify --strict dist/DiskAtlas.app` çıkış 0.
- [ ] **Adım 2:** Paketlenmiş uygulamada kendi kendini sınama: `dist/DiskAtlas.app/Contents/MacOS/DiskAtlas --self-test --scan-root <geçici ağaç> --snapshot <png>` → çıkış 0. PNG'yi aç ve pano/ilerleme düzenini gözle kontrol et.
- [ ] **Adım 3:** İlk kurulum simülasyonu: kopyaya `xattr -w com.apple.quarantine "0081;00000000;Safari;"` ver, `spctl --assess --type execute` sonucunu kaydet (beklenen: reddedilir, yani "Yine de Aç" uyarısı çıkar); Tam Disk Erişimi sondasının bu Mac'te döndürdüğü durumu kaydet.
- [ ] **Adım 4:** `swift test && node Tests/web/ui.test.cjs && node verify_ui.cjs` → hepsi PASS.
- [ ] **Adım 5: Commit** `feat: add build_app.sh packaging`.

---

## Öz değerlendirme

- **Spec kapsamı (aşama 2):** web bölme (G4), `FileBackend`/`NativeBackend` (G4), `verify_ui.cjs` uyarlama (G4), `ReportStore` (G1), Swift kabuğu/WKWebView/dış gezinme engeli (G5), köprü (`startScan`, `cancelScan`, olaylar, `permissionStatus`, `openFullDiskAccess`; `listScans`/`loadScan` pano için gerekli, `deleteScan`/`compare` 3. aşama) (G3), karşılama/izin, ilerleme, pano (G4), `build_app.sh` (G6), kendi Mac'inizde ilk kurulum simülasyonu (G6), Tarama bilgisinde sürüm (G4).
- **Bilinçli ertelenenler:** `revealInFinder`, `deleteScan`, `compare`, geçmiş sekmesi (3. aşama); uygulama simgesi ve koyu tema (6. aşama); gerçek kuzen testi (6. aşama).
- **Doğrulanamayanlar:** Tam Disk Erişimi sondasının izinli/izinsiz davranışı yalnızca bu Mac'te gözlemlenir; Gatekeeper iletişim kutusu otomatikleştirilemez (yalnızca `spctl` sonucu kaydedilir).
