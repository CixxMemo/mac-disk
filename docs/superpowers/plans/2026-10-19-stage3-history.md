# Disk Atlas — 3. Aşama (Geçmiş ve karşılaştırma) Uygulama Planı

> **Uygulayıcı için:** ZORUNLU ALT-BECERİ: `superpowers:executing-plans` (kullanıcı native yöntemi seçti ve 3. aşamayı önceden onayladı). Adımlar `- [ ]` ile izlenir.

**Hedef:** Kayıtlı taramaları listeleyen, silebilen ve iki taramayı klasör düzeyinde karşılaştırıp "ne büyüdü?" sorusunu yanıtlayan "Geçmiş" sekmesi. Okunamayan veya yarım taramalar asla yanıltıcı "silindi" göstermez.

**Mimari:** Karşılaştırma mantığı `DiskAtlasCore` içinde saf bir `Differ`dır (WebKit'ten bağımsız, birim testli). Köprüye `deleteScan` ve `compare` eklenir. Arayüzde yeni bir `history` görünümü köprüyü kullanır. Karşılaştırma verisi, 1. aşamada tarama başına saklanan `folderIndex` (≥ 1 MiB klasörler: yol → bayt) ve `unreadable` listesidir.

**Teknoloji:** Swift 6.1 (Swift 5 modu), XCTest, vanilla JS, Node test koşucusu.

**Spec:** `docs/superpowers/specs/2026-10-19-disk-atlas-mac-app-design.md` (bölüm 3.3, 4.2 "Geçmiş", 8, 10/aşama 3). Önceki planlar: stage 1 ve 2.

## Global Kısıtlar

- Karşılaştırma durumları: `grew` (büyüdü), `shrank` (küçüldü), `new` (yeni), `gone` (kalktı), `uncertain` (belirsiz). Arayüz etiketleri Türkçe.
- "Diğer N öğe" grupları karşılaştırmaya girmez (`folderIndex` zaten grup içermez).
- Yarım (`incomplete`) tarama içeren her karşılaştırmada **tüm** öğeler `uncertain` olur. Okunamayan bir yol (`unreadable`) ve onun bütün üst klasörleri `uncertain` olur.
- `folderIndex` yalnızca ≥ 1 MiB klasörleri tutar (`DiskScanner.folderIndexThreshold`): "yeni" öğe "yeni veya 1 MiB üstüne çıktı", "kalktı" öğe "silindi veya 1 MiB altına indi" anlamına gelir; arayüz bunu açıkça yazar.
- `folderIndex` olmayan tarama (şema 1 / `legacy`) karşılaştırılamaz: net Türkçe hata.
- **Açıklanamayan fark** = (disk `used` farkı) − (ölçülen `tree.bytes` farkı). Arayüz bunu ayrı bir kartta gösterir.
- Silme yalnızca uygulamanın kendi tarama kayıtlarını kaldırır (`<id>.json` ve `<id>.meta.json`); kullanıcının dosyalarına dokunulmaz. Arayüz onay ister.
- Köprüde kimlikler `ReportStore.isValid` ile doğrulanır; JS'ten yol gelmez.
- Testler gerçek kullanıcı dosyalarına/kayıtlarına dokunmaz (geçici dizin). Her görev commit ile biter; mesaj sonuna `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Çalışma dalı `stage3-history`; birleştirme kullanıcının Pull Request akışıyla olur (ben push etmem).

## Review Focus

1. Aynı iki tarama (sıfır fark) karşılaştırması: boş liste, açıklanamayan fark 0. Test: Görev 2.
2. Sıra: kullanıcı yeni taramayı önce seçse de eski/yeni doğru belirlenir (`created`'a göre). Test: Görev 3.
3. Aynı taramayı iki kez seçmek ve geçersiz/olmayan kimlik: `ok:false`. Test: Görev 3.
4. Tam Disk Erişimi durumu farklı iki tarama: uyarı. Kapsamı (`scope`) farklı iki tarama: uyarı. Test: Görev 2.
5. Silinen taramanın hâlâ açık olan panoyu bozmaması ve liste yenilemesi. Test: Görev 4.

---

### Task 1: Saklama genişletmeleri (silme, özet alanları, eşik sabiti)

**Files:**
- Modify: `Sources/DiskAtlasCore/Store/ReportStore.swift`, `Sources/DiskAtlasCore/Scan/DiskScanner.swift`
- Test: `Tests/DiskAtlasCoreTests/ReportStoreTests.swift`

**Interfaces:**
- Consumes: `ReportStore`, `ScanSummary`, `Report`
- Produces:
  - `ScanSummary` yeni isteğe bağlı alanlar: `fullDiskAccess: String?`, `comparable: Bool?` (`save` içinde `report.folderIndex != nil`; alan eksik eski kayıtlar karşılaştırılabilir sayılır)
  - `ReportStore.delete(id: String) throws` — geçersiz kimlik `.invalidID`, olmayan `.notFound`; iki dosyayı da siler
  - `DiskScanner.folderIndexThreshold: Int64` (`public static`, 1 MiB; mevcut özel sabit herkese açık yapılır)

- [ ] **Adım 1: Başarısız testleri yaz:** `testSummaryRecordsAccessAndComparability` (şema 2 rapor `comparable == true`, `fullDiskAccess` aktarılır; `legacy-schema1` fixture'ı `upgradedToSchema2()` ile `comparable == false`), `testDeleteRemovesReportAndMeta`, `testDeleteRejectsInvalidAndMissingIDs`, `testOldMetaWithoutNewFieldsStillListed`.
- [ ] **Adım 2:** `swift test --filter ReportStoreTests` → FAIL/derleme hatası.
- [ ] **Adım 3: Uygula.**
- [ ] **Adım 4:** `swift test` → PASS.
- [ ] **Adım 5: Commit** `feat(core): store delete and richer scan summaries`.

---

### Task 2: Differ

**Files:**
- Create: `Sources/DiskAtlasCore/Diff/Differ.swift`
- Test: `Tests/DiskAtlasCoreTests/DifferTests.swift`

**Interfaces:**
- Consumes: `Report` (`folderIndex`, `unreadable`, `incomplete`, `fullDiskAccess`, `scope`, `disk`, `tree.bytes`, `legacy`)
- Produces:
  - `public enum DiffStatus: String, Codable, Sendable { case grew, shrank, new, gone, uncertain }`
  - `public struct DiffItem: Codable, Equatable, Sendable { path: String; before: Int64?; after: Int64?; delta: Int64; status: DiffStatus; reason: String? }` (`reason` yalnızca `uncertain` için)
  - `public struct ScanDiff: Codable, Equatable, Sendable { measuredDelta: Int64; diskUsedDelta: Int64; unexplained: Int64; warnings: [String]; items: [DiffItem]; totalItems: Int }`
  - `public enum DiffError: Error, Equatable { case notComparable(String) }` (`"older"`/`"newer"`; açıklama Türkçe)
  - `public enum Differ { public static func compare(older: Report, newer: Report, limit: Int = 500) throws -> ScanDiff }`

Kurallar: her iki rapor `folderIndex` taşımalı, aksi `notComparable`. `delta = (after ?? 0) − (before ?? 0)`; `delta == 0` öğeler dışarıda. `items` `|delta|` azalan, eşitlikte yol artan sıralı ve `limit` ile kırpılır (`totalItems` kırpılmamış sayı). Belirsizlik: yarım tarama → hepsi `uncertain` (`reason: "Tarama yarım kaldı"`); okunamayan yol ve üst klasörleri → `uncertain` (`reason: "Okunamayan klasör içeriyor"`). Uyarılar: `fullDiskAccess` farklıysa, `scope` farklıysa (metinler Türkçe, sabit). `unexplained = diskUsedDelta − measuredDelta`.

- [ ] **Adım 1: Başarısız testleri yaz:** `testGrewShrankNewGone`, `testIdenticalScansGiveNoItemsAndZeroUnexplained`, `testItemsSortedByAbsoluteDeltaAndTruncated` (limit 2, `totalItems` doğru), `testIncompleteScanMakesEverythingUncertain`, `testUnreadablePathAndAncestorsAreUncertain` (kardeş klasör etkilenmez), `testWarningsForDifferentAccessAndScope`, `testUnexplainedDifference` (`disk.used` +10 GiB, `tree.bytes` +3 GiB → 7 GiB), `testLegacyReportIsNotComparable` (older ve newer için ayrı), `testNewAndGoneAreAnnotatedWithBeforeAfter`.
- [ ] **Adım 2:** `swift test --filter DifferTests` → derleme hatası.
- [ ] **Adım 3: Uygula.**
- [ ] **Adım 4:** `swift test` → PASS.
- [ ] **Adım 5: Commit** `feat(core): add Differ`.

---

### Task 3: Köprü: `deleteScan` ve `compare`

**Files:**
- Modify: `Sources/DiskAtlasCore/Bridge/BridgeRouter.swift`
- Test: `Tests/DiskAtlasCoreTests/BridgeRouterTests.swift`

**Interfaces:**
- Consumes: `ReportStore.delete`, `Differ.compare`, `ScanDiff`
- Produces: istek `deleteScan{id}` → `{}`; `compare{older, newer}` (kimlikler) → `{olderId, newerId, olderCreated, newerCreated, diff: ScanDiff}`. Router iki kimliği `created`'a göre sıralar (kullanıcı hangisini önce seçerse seçsin). Hatalar Türkçe `ok:false`: aynı kimlik ("İki farklı tarama seç."), geçersiz/olmayan kimlik, `notComparable` ("Bu tarama karşılaştırma için gerekli ayrıntıyı içermiyor (eski sürümden)."). `deleteScan` tarama sürerken de çalışır.

- [ ] **Adım 1: Başarısız testleri yaz:** `testCompareOrdersByCreatedAndReturnsDiff` (iki rapor kaydedilir, yeni kimlik `older` alanında gönderilse de doğru sıralanır), `testCompareRejectsSameInvalidAndMissingIDs`, `testCompareLegacyScanGivesClearError`, `testDeleteScanRemovesFromListAndRejectsBadIDs`, `testDeleteScanWorksWhileScanning`.
- [ ] **Adım 2:** `swift test --filter BridgeRouterTests` → FAIL.
- [ ] **Adım 3: Uygula.**
- [ ] **Adım 4:** `swift test` → PASS.
- [ ] **Adım 5: Commit** `feat(core): bridge deleteScan and compare`.

---

### Task 4: "Geçmiş" arayüzü

**Files:**
- Modify: `Resources/web/index.html`, `Resources/web/app.css`, `Resources/web/app.js`
- Test: `Tests/web/ui.test.cjs`

**Interfaces:**
- Consumes: köprü `listScans` (`ScanSummary`: `id, created, scope, incomplete, allocatedBytes, schema, fullDiskAccess?, comparable?`), `loadScan`, `deleteScan`, `compare`
- Produces (JS kimlikleri): gezinme düğmesi `data-view="history"` (yalnızca yerel modda görünür), bölüm `view-history`, `historyList` (satırlarda onay kutusu, "Aç", "Sil"), `compareBtn`, `compareResult`, `compareSummary` (kartlar: ölçülen fark, disk doluluk farkı, açıklanamayan fark), `compareWarnings`, `compareBody` (tablo gövdesi), `compareFilter` (Hepsi/Büyüyenler/Küçülenler/Yeni-Kalkan/Belirsiz), `compareSearch`.

Davranış: `showView('history')` `listScans` ile listeyi yeniler (en yeni üstte; yarım ve izinsiz taramalara rozet; `comparable === false` olanın onay kutusu pasif). Tam iki onay kutusu seçilince `compareBtn` etkinleşir; tıklayınca `compare` çağrılır, sonuç tablosu `|fark|` sırasıyla çizilir. Fark biçimi: işaretli (`+`/`−`) ve `format()` ile; durum etiketleri: Büyüdü, Küçüldü, "Yeni / 1 MiB üstüne çıktı", "Kalktı / 1 MiB altına indi", Belirsiz (neden ipucu olarak). Uyarılar ve "Açıklanamayan fark" kartı açık metinle gösterilir. "Sil": onay penceresi ("Bu tarama kaydı silinecek. Dosyalarına dokunulmaz."), onaylanınca `deleteScan`, liste yenilenir; açık pano korunur. "Aç": `loadScan` ile panoya geçer. Köprü hatası toast/mesaj olarak görünür.

- [ ] **Adım 1: Başarısız testleri yaz** (sahte köprü): `historyTabVisibleOnlyInNativeMode`, `historyListsScansNewestFirstWithBadges`, `compareButtonNeedsExactlyTwoSelectionsAndNonComparableIsDisabled`, `compareRequestsAndRendersSortedTableWithSignedDeltas`, `compareShowsUnexplainedCardAndWarnings`, `compareFilterAndSearchNarrowRows`, `uncertainRowsShowReason`, `openScanLoadsReportAndSwitchesToExplorer`, `deleteAsksConfirmationThenRefreshesAndKeepsOpenDashboard`, `compareErrorIsShown`.
- [ ] **Adım 2:** `node --test Tests/web/ui.test.cjs` → FAIL.
- [ ] **Adım 3: Uygula** (HTML, CSS, JS).
- [ ] **Adım 4:** `node --test Tests/web/ui.test.cjs && node verify_ui.cjs` → PASS.
- [ ] **Adım 5: Commit** `feat(web): add history and comparison view`.

---

### Task 5: Uygulamada uçtan uca sınama ve paketleme

**Files:**
- Modify: `Sources/DiskAtlasApp/SelfTest.swift`, `docs/superpowers/plans/2026-10-19-disk-atlas-todo.md`

**Interfaces:**
- Consumes: Görev 1–4
- Produces: `--self-test` kipi artık ikinci bir tarama ve karşılaştırma da sınar: ilk tarama sonrası kök altına ≥ 2 MiB'lık bir dosya yazar (yalnızca `--scan-root` içine), ikinci taramayı başlatır, "Geçmiş"te iki taramayı seçip karşılaştırır, tabloda büyüyen klasörü ve açıklanamayan fark kartını doğrular, `<snapshot>-history.png` ve `<snapshot>-compare.png` kaydeder.

- [ ] **Adım 1:** Self-test'i genişlet, `swift build --product DiskAtlasApp` temiz.
- [ ] **Adım 2:** `bash scripts/build_app.sh` ve paketlenmiş uygulamayı (`env -i`, ortam değişkeni olmadan) `--self-test` ile çalıştır → çıkış 0, JSON `ok:true`, `consoleErrors: []`. İki PNG'yi aç ve düzeni gözle kontrol et.
- [ ] **Adım 3:** `swift test && node --test Tests/web/ui.test.cjs && node verify_ui.cjs` → hepsi PASS.
- [ ] **Adım 4:** To-Do'da 3. aşama maddelerini işaretle. **Commit** `feat: end-to-end history self-test`.

---

## Öz değerlendirme

- **Spec kapsamı (aşama 3, bölüm 3.3 ve 4.2):** Differ + durumlar + belirsizlik kuralları + açıklanamayan fark (G2), `listScans/deleteScan/compare` (G3, G1), Geçmiş sekmesi ve sıralanabilir tablo (G4), testler (G2, G3, G4), uçtan uca (G5).
- **Bilinçli ertelenenler:** dosya düzeyinde "eklendi/silindi" listesi (spec: yok), `revealInFinder`, karşılaştırma sonucunu dışa aktarma, grafik/zaman çizgisi.
- **Dürüst sınırlar:** Eşik (1 MiB) nedeniyle "yeni/kalkan" öğeler yaklaşıktır ve arayüzde öyle etiketlenir. Eski (şema 1) içe aktarılan raporlar karşılaştırılamaz.
