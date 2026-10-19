# Aşama 5 — Temizlik (Çöp Sepeti) Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (native) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kullanıcı, tarama sonuçlarında tanınan klasörleri seçip yalnızca Çöp Sepeti'ne taşıyabilsin; hiçbir şey kalıcı silinmesin.

**Architecture:** Yetki Swift tarafındadır. JS yalnızca `scanId` ve yol listesi gönderir; `BridgeRouter` yolları taramanın kataloğundan türetilen izin kümesiyle eşler (`CleanupCatalog`), `TrashPolicy` (sözcüksel kurallar) ve `TrashService` (dosya sistemi kontrolü, plan→onay, günlük) uygular. İki aşamalı akış: `planTrash` → (kullanıcı onayı) → `confirmTrash`. Taşıma `Trasher` arkasındadır; testler ve self-test gerçek Çöp Sepeti'ne yazmaz.

**Tech Stack:** Swift 5 modu (Swift 6.1 araç zinciri), XCTest, vanilla JS + Node test düzeneği (`Tests/web`).

**Spec:** `docs/superpowers/specs/2026-10-19-disk-atlas-mac-app-design.md`; kararlar `docs/HANDOFF.md` "5. aşama" bölümü (kullanıcı hepsini önerildiği gibi onayladı, 2026-10-19).

## Global Constraints
- Silme yalnızca `FileManager.trashItem`. Kodda `removeItem`, `unlink`, `rmdir`, `remove(` YOK (tek istisna: `ReportStore`, uygulamanın kendi tarama kaydı; `NoDeleteTests` ile doğrulanır).
- Çöp Sepeti boşaltılmaz. Arayüzde "yer açmaz" uyarısı ve üst çubukta "Silme: yalnızca Çöp Sepeti".
- Seçilebilir: yalnızca "Yakından bakılacaklar" bulguları ve Uygulamalar bileşen yolları; `asla` düzeyi, Tanınmayan klasörler ve Büyük dosyalar seçilemez.
- Eylem: `güvenli` tek onay; `incele` ek onay kutusu; `asla` reddedilir. Kataloğa uymayan tarayıcı adayları `incele` sayılır.
- Yol yalnızca ana klasör altında veya `/Applications/<ad>.app` ise taşınır; sembolik bağlantı, başka birim, korumalı yol reddedilir.
- Testler yalnızca geçici klasörde çalışır; gerçek Çöp Sepeti ve gerçek ana klasör kullanılmaz (`Trasher` sahtesi/`DirectoryTrasher`).
- Tarama sürerken temizlik, temizlik sürerken tarama başlatılamaz. Taşımadan sonra o tarama "güncel değil" sayılır; yeniden tarama istenir.
- Boyutlar ondalık GB; metinler Türkçe, tanımlayıcılar İngilizce. Commit sonuna `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus
1. Seçilen klasörün İÇİNDE `asla` bir klasör varsa (`minecraft` ⊃ `minecraft/saves`) → reddedilir (Task 2).
2. Plandan sonra yol sembolik bağlantıya dönüşür veya bir üst klasörü bağlantıdır → bağlantı izlenmez, taşınmaz (Task 3).
3. Plan ile onay arasında öğe silinir/başka dosyayla (farklı inode) değiştirilir → atlanır, hata değil "değişti" sonucu (Task 3).
4. JS rastgele yol yollar (`/etc`, ana klasörün kendisi, `..`, yabancı `scanId`) → hiçbir koşulda yürütülmez (Task 4).
5. Günlük dosyası yazılamıyor → hiçbir şey taşınmaz (Task 3); ebeveyn+çocuk birlikte seçilirse tek taşıma, bayt bir kez sayılır (Task 3).

## Dosya yapısı
- Create `Sources/DiskAtlasCore/Cleanup/CleanupCatalog.swift` — izin kümesi (`TrashCandidate`) ve korumalı yollar.
- Create `Sources/DiskAtlasCore/Cleanup/TrashPolicy.swift` — sözcüksel kurallar.
- Create `Sources/DiskAtlasCore/Cleanup/ActionLog.swift` — `actions.log` (satır başına JSON).
- Create `Sources/DiskAtlasCore/Cleanup/TrashService.swift` — `Trasher`, plan, yürütme.
- Modify `Sources/DiskAtlasCore/Apps/DisplayEnvelope.swift` (`Finding.safety`), `Bridge/BridgeRouter.swift`, `ScanRoots`.
- Modify `Sources/DiskAtlasApp/{WebHost,AppDelegate,SelfTest}.swift`, `Resources/web/{index.html,app.css,app.js}`.
- Tests: `CleanupCatalogTests`, `TrashPolicyTests`, `ActionLogTests`, `TrashServiceTests`, `NoDeleteTests`, `BridgeRouterTests` (ek), `Tests/web/ui.test.cjs` (ek).

---

### Task 1: İzin kümesi ve bulgularda güvenlik düzeyi

**Files:** Create `Cleanup/CleanupCatalog.swift`; Modify `Apps/DisplayEnvelope.swift`; Test `CleanupCatalogTests.swift`, `DisplayEnvelopeTests.swift`.

**Interfaces:**
- Produces: `public struct TrashCandidate: Codable, Equatable, Sendable { path: String; name: String; bytes: Int64; safety: Safety }`
- Produces: `CleanupCatalog.candidates(report: Report, rules: RuleSet) -> [TrashCandidate]` — `AppCatalog.build` bileşenlerinin `safety != .never` olan her yolu (`bytes` = `pathBytes`, ad: birden çok yolda `"<ad> · <son iki parça>"`) + `report.candidates` içinden bunların kapsamadığı (aynı yol veya altı değil) adaylar `.review`; yola göre tekrarsız. `folderIndex` yoksa `[]`.
- Produces: `CleanupCatalog.protectedPaths(rules: RuleSet, home: String) -> [String]` — `asla` bileşenlerin `paths` listesi, `~/` ana klasörle genişletilmiş.
- Modifies: `DisplayEnvelope.Finding` yeni alan `safety: String` (`"güvenli"`/`"incele"`); katalog bulgusunda bileşenin düzeyi, tarayıcı adayında `"incele"`.

- [ ] **Step 1: Testler** — `testCandidatesExcludeNeverComponents` (ana klasör altında `Documents` 500 MB indekste → izin kümesinde yok), `testSafeComponentKeepsSafety` (`.npm` → `.safe`), `testScannerCandidateIsReviewAndNotDuplicated` (kataloğun kapsadığı aday tekrar etmez; kapsanmayan `.review`), `testProtectedPathsExpandHome` (`<home>/Documents` ve `<home>/Library/Application Support/minecraft/saves` listede), `testLegacyReportHasNoCandidates`; `DisplayEnvelopeTests`: bulgu `safety` değerleri.
- [ ] **Step 2:** `swift test --filter "CleanupCatalogTests|DisplayEnvelopeTests"` → FAIL (tür yok).
- [ ] **Step 3:** Uygula; `DisplayEnvelope.makeUI` bulgu üretirken `safety` doldurur.
- [ ] **Step 4:** Aynı komut → PASS. Tüm `swift test` yeşil.
- [ ] **Step 5:** Commit `feat: cleanup candidate set and finding safety`.

### Task 2: `TrashPolicy` (sözcüksel kurallar)

**Files:** Create `Cleanup/TrashPolicy.swift`; Test `TrashPolicyTests.swift`.

**Interfaces:**
- Produces: `public struct TrashPolicy: Sendable { init(home: String, applications: String?, protectedPaths: [String]); func check(_ path: String) -> String? }` — `nil` izin, aksi halde Türkçe red nedeni.

Kurallar (hepsi büyük/küçük harf duyarsız karşılaştırılır; hepsi için test): mutlak, `..`/`.`/boş parça/sondaki `/` yok; yol ana klasör altında VEYA `applications` altında doğrudan `*.app`; ana klasörün kendisi ve şu kapsayıcılar reddedilir: `Library`, `Library/Caches`, `Library/Application Support`, `Library/Containers`, `Downloads`, `Applications`; şu yollar ve altı reddedilir: `Documents`, `Desktop`, `Pictures`, `Movies`, `Music`, `.Trash`, `.ssh`, `.gnupg`, `Library/Keychains`, `Library/Mobile Documents`, `Library/CloudStorage`, `Library/Messages`, `Library/Mail`, `Library/Safari`; `protectedPaths` içindeki yol veya altı reddedilir; `protectedPaths` içindeki bir yolun ÜST klasörü reddedilir ("içinde korumalı klasör var").

- [ ] **Step 1: Testler** — `testRejectsOutsideHome` (`/etc/hosts`, `/opt/homebrew`), `testRejectsHomeAndContainers`, `testRejectsPersonalAndSecretFolders`, `testRejectsTrash`, `testRejectsNonCanonicalPaths` (`<home>/a/../b`, `<home>/a/`, göreli yol), `testAllowsCacheFolders` (`<home>/.npm`, `<home>/Library/Caches/pip`), `testApplicationsOnlyDirectAppBundles` (`/Applications/Foo.app` izinli; `/Applications`, `/Applications/Foo.app/Contents`, `/Applications/Utilities` red), **`testRejectsParentOfProtectedPath`** (`protectedPaths=[<home>/Library/Application Support/minecraft/saves]` iken `<home>/Library/Application Support/minecraft` red; `.../minecraft/mods` izinli), `testCaseInsensitive`.
- [ ] **Step 2:** FAIL doğrula. **Step 3:** uygula. **Step 4:** PASS. **Step 5:** Commit `feat: trash policy`.

### Task 3: `ActionLog` ve `TrashService`

**Files:** Create `Cleanup/ActionLog.swift`, `Cleanup/TrashService.swift`; Test `ActionLogTests.swift`, `TrashServiceTests.swift`, `NoDeleteTests.swift`.

**Interfaces:**
- Produces: `public struct ActionLogEntry: Codable, Equatable, Sendable { time: String (ISO8601), scan: String, path: String, bytes: Int64, safety: String, result: String ("trashed"|"failed"|"skipped"), detail: String? }`
- Produces: `public final class ActionLog: @unchecked Sendable { init(url: URL); func prepare() throws; func append(_ entry: ActionLogEntry) throws }` — klasörü oluşturur, dosyaya satır sonu ile tek satır JSON ekler (üzerine yazmaz).
- Produces: `public protocol Trasher: Sendable { func trash(_ path: String) throws -> String? }`; `public struct FileManagerTrasher: Trasher` (`FileManager.default.trashItem`, dönen yeni konum); `public struct DirectoryTrasher: Trasher { init(directory: String) }` (self-test/test: `moveItem` ile klasöre taşır, ad çakışırsa sayı ekler).
- Produces: `public struct TrashPlanItem: Codable, Equatable, Sendable { path, name: String; bytes: Int64; safety: Safety?; status: Status (accepted|rejected|covered); reason: String? }` (cihaz/inode parmak izi JSON'a girmez).
- Produces: `public struct TrashPlan: Sendable { id: String; scanId: String; items: [TrashPlanItem]; var totalBytes: Int64 (yalnızca accepted); var needsAcknowledge: Bool (accepted içinde .review); var acceptedCount: Int }`
- Produces: `TrashResult { path: String; ok: Bool; reason: String?; trashedTo: String? }`, `TrashOutcome { results: [TrashResult]; movedBytes: Int64; failedCount: Int }`, `enum TrashError: Error, Equatable { acknowledgementRequired, logUnavailable, nothingToDo }`
- Produces: `TrashService(policy: TrashPolicy, fileSystem: FileSystem = RealFileSystem(), trasher: Trasher, log: ActionLog)`; `plan(scanId: String, requested: [String], allowed: [TrashCandidate]) -> TrashPlan`; `execute(_ plan: TrashPlan, acknowledgeReview: Bool) throws -> TrashOutcome`.

Davranış: `plan` — istenen yol `allowed` içinde (tam eşleşme) değilse `rejected` ("Bu öğe taramadaki temizlenebilir öğeler arasında değil."); `policy.check` reddi; `lstat` yok → "artık yok"; sembolik bağlantı/diğer tür → red; cihaz kökle (ana klasör veya `/Applications`) aynı değil → "başka birim"; kökten ebeveyne kadar her ara klasör sembolik bağlantı ise red; kabul edilen bir öğenin üst klasörü de kabul edilmişse alt öğe `covered` (bayt sayılmaz); tekrarlar tek. `execute` — önce `log.prepare()` (hata → `logUnavailable`, hiçbir şey taşınmaz); `needsAcknowledge && !acknowledgeReview` → `acknowledgementRequired`; kabul edilen yoksa `nothingToDo`; her öğe için yeniden `policy.check` + `lstat` + parmak izi (cihaz, inode, tür) eşleşmesi, sonra `trasher.trash`; sonuç günlüğe yazılır (günlük yazımı başarısızsa kalan öğeler `skipped`/başarısız sayılır, taşınmaz).

- [ ] **Step 1: Testler** (`TempTree` + `DirectoryTrasher`, sahte `Trasher` hata için): `ActionLogTests` — satır ekler, eski satırları korur, geçerli JSON, `prepare` ebeveyn bir dosyaysa fırlatır. `TrashServiceTests` — `testPlanAcceptsAllowedFolder`, `testPlanRejectsPathOutsideAllowedSet`, `testPlanRejectsSymlink` (**odak 2**), `testPlanRejectsSymlinkedAncestor` (**odak 2**), `testPlanMarksNestedAsCoveredAndCountsOnce` (**odak 5**), `testExecuteMovesAndLogs`, `testExecuteRequiresAcknowledgementForReview`, `testExecuteSkipsItemReplacedAfterPlan` (inode değişir; **odak 3**), `testExecuteSkipsItemThatBecameSymlink` (**odak 2**), `testExecuteReportsTrasherFailurePerItem`, `testExecuteDoesNothingWhenLogUnavailable` (**odak 5**; dosyalar yerinde), `testNeverSafetyCannotBeAccepted`. `NoDeleteTests` — `Sources/**/*.swift` içinde `removeItem(`, `unlink(`, `rmdir(`, `.remove(` yalnızca `Store/ReportStore.swift` içinde geçer (`#filePath`'ten kök bulunur).
- [ ] **Step 2:** FAIL. **Step 3:** uygula. **Step 4:** PASS + tüm testler. **Step 5:** Commit `feat: trash service with plan, revalidation and action log`.

### Task 4: Köprü ve uygulama bağlantısı

**Files:** Modify `Bridge/BridgeRouter.swift`, `ScanRoots`, `Sources/DiskAtlasApp/{WebHost,AppDelegate}.swift`; Test `BridgeRouterTests.swift`.

**Interfaces:**
- Consumes: Task 1–3 türleri.
- Modifies: `ScanRoots.init(data:home:excluded:applications: String = "/Applications")`; `BridgeRouter.init(..., trasher: Trasher? = nil, actionLogURL: URL? = nil)`; ikisinden biri `nil` ise temizlik kapalıdır.
- Produces (köprü): `capabilities` → `{"cleanup": Bool}`; `planTrash` `{scanId: String, paths: [String]}` (1…200 yol) → `{planId, items: [TrashPlanItem], totalBytes, needsAcknowledge, acceptedCount}`; `confirmTrash` `{planId, acknowledgeReview: Bool}` → `TrashOutcome`. Plan bellekte en çok 5 adet, 10 dakika geçerli, onayda tüketilir (ikinci onay "Plan bulunamadı"). `planTrash`/`confirmTrash` tarama sürerken "Tarama sürerken temizlik yapılamaz."; `startScan` temizlik sürerken "Temizlik sürerken tarama başlatılamaz." Politika kökü `roots.home` (rapordaki `homePath` DEĞİL); `protectedPaths` ve izin kümesi `store.load(scanId)` raporundan.
- AppDelegate: normal kipte `FileManagerTrasher()` ve `~/Library/Application Support/DiskAtlas/actions.log`; self-test'te `DirectoryTrasher(directory: <store-dir>/trash-sim)`, günlük `<store-dir>/actions.log`, `applications = <root>/Applications`.

- [ ] **Step 1: Testler** (geçici ana klasör, sahte `ScanRunner` ile kayıt oluşturur, `DirectoryTrasher`): `testCapabilitiesReflectConfiguration`, `testPlanThenConfirmMovesFolder`, `testPlanRejectsArbitraryPaths` (**odak 4**: `/etc`, ana klasör, `<home>/x/../Documents`, tarama kataloğunda olmayan yol → hepsi `rejected`, yürütülmez), `testPlanRejectsUnknownScanId` (**odak 4**), `testConfirmUnknownOrReusedPlanFails`, `testReviewNeedsAcknowledgement`, `testCleanupBlockedWhileScanning`, `testScanBlockedWhileCleaning`, `testCleanupDisabledWithoutTrasher`.
- [ ] **Step 2:** FAIL. **Step 3:** uygula (`confirmTrash` zaten arka kuyrukta çağrılır; `cleaning` bayrağı `lock` altında). **Step 4:** PASS + `swift build` (App hedefi). **Step 5:** Commit `feat: planTrash/confirmTrash bridge`.

### Task 5: Arayüz

**Files:** Modify `Resources/web/{index.html,app.css,app.js}`; Test `Tests/web/ui.test.cjs` (+ gerekirse `harness.cjs`).

**Interfaces:**
- Consumes: Task 4 köprü iletileri; bulgularda `safety`.
- Davranış: `capabilities.cleanup` doğruysa ve tarama kayıt kimliğiyle açıldıysa (`currentScanId`) temizlik açık; dosyadan açılan rapor ve Python raporu için kapalı. Seçim kümesi `selected` yol kümesidir; seçilebilir öğeler `cleanable` (Map: yol → `{name, bytes, safety}`): bulgular + `data.apps` bileşen yolları (`asla` hariç). Uygulamalar sekmesindeki her yola onay kutusu. Alt çubuk `#cleanupBar` (seçim varken görünür): "N öğe · X GB" + "Çöp Sepeti’ne taşı…" + "Seçimi temizle". Düğmeye basınca `planTrash`; onay penceresi: kabul edilenler (ad, boyut, rozet), reddedilenler (neden), toplam, uyarı "Dosyalar silinmez, Çöp Sepeti’ne taşınır; Çöp Sepeti’ni boşaltana kadar yer açılmaz", `needsAcknowledge` ise onay kutusu işaretlenmeden "Taşı" pasif. Sonuç penceresi: satır satır başarılı/hata + "Geri koymak için Çöp Sepeti’nde öğeye sağ tıklayıp Geri Koy’u seç." Başarıdan sonra tarama "güncel değil": seçim temizlenir, alt çubuk "Bu tarama güncel değil" + "Yeniden tara" gösterir ve taşıma düğmeleri kapanır. Tarama sürerken temizlik düğmeleri pasif. Üst çubuk rozeti temizlik açıkken "Silme: yalnızca Çöp Sepeti", kapalıyken "Salt okunur". Yardım metnindeki "hiçbir şeyi silmez" benzeri ifadeler gerçeğe uyarlanır.

- [ ] **Step 1: Testler (ui.test.cjs)** — `bulgulardaki safety doğrulanır`; `temizlik kapalıyken (köprü yok / dosyadan açma) alt çubuk gizli`; `Uygulamalar sekmesinde onay kutusu yalnızca asla olmayan yollarda`; `seçim planTrash'e yalnız yol ve scanId gönderir` (sahte köprü kaydeder); `incele öğesi için onay kutusu işaretlenmeden Taşı pasif`; `reddedilen öğe nedeniyle gösterilir`; `başarıdan sonra tarama güncel değil ve düğmeler kapalı`; `tarama sürerken düğmeler pasif`; `üst çubuk metni`; iç içe seçimin toplamı bir kez sayılır.
- [ ] **Step 2:** `node --test Tests/web/ui.test.cjs` FAIL. **Step 3:** uygula. **Step 4:** PASS; `node verify_ui.cjs` "DOM checks complete". **Step 5:** Commit `feat: cleanup UI (selection, plan dialog, result)`.

### Task 6: Uçtan uca sınama, belgeler, inceleme

**Files:** Modify `Sources/DiskAtlasApp/SelfTest.swift`, `CLAUDE.md`, `docs/HANDOFF.md`, ana To-Do (aşama 5 işaretleri), tasarım belgesi (karar 8: Temizlik), `scripts/build_app.sh` (gerekirse).

- [ ] **Step 1:** Self-test: tarama sonrası Uygulamalar sekmesinde `.npm` (güvenli) bileşeninin onay kutusunu işaretle, `cleanupBtn`'e bas, plan penceresini PNG'ye al (`-cleanup`), "Taşı"ya bas; kontroller: `<root>/.npm` yok, `<store-dir>/trash-sim` altında var, `actions.log` bir `trashed` satırı içerir, alt çubukta "güncel değil", sonuç `cleanupOk:true`. Gerçek Çöp Sepeti'ne yazılmadığı doğrulanır.
- [ ] **Step 2:** `swift test`, `node --test Tests/web/ui.test.cjs`, `node verify_ui.cjs`, `bash scripts/build_app.sh`, paketli `--self-test` (geçici klasör) → hepsi yeşil, çıkış 0 ve `ok:true`.
- [ ] **Step 3:** Belgeler: CLAUDE.md "Silme/taşıma henüz yok" satırı ve komut/mimari özeti güncellenir; HANDOFF.md aşama 5 sonuçları ve **doğrulanmadı** listesi (gerçek `trashItem` ve "Geri Koy" yalnızca kullanıcı denemesiyle doğrulanır); To-Do işaretleri; tasarım belgesine karar 8.
- [ ] **Step 4:** Opus alt-ajanıyla bağımsız tam dal incelemesi; bulgular test-önce düzeltilir (Review Focus ve `NoDeleteTests` tekrar).
- [ ] **Step 5:** Commit `docs: stage 5 cleanup`; `git status` temiz; push/birleştirme yapılmaz (kullanıcı GitHub Desktop ile).
