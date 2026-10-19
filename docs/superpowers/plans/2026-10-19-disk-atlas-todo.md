# Disk Atlas — Geliştirme To-Do

Spec: `docs/superpowers/specs/2026-10-19-disk-atlas-mac-app-design.md` (bölüm 10)

**Çalışma kuralı.** Her aşamanın kendi ayrıntılı planı vardır. Bir aşama bitmeden sonrakinin planı yazılmaz, çünkü ayrıntılar öncekinin sonuçlarına bağlıdır. Her aşama sonunda sizin onayınız ve (belirtilen yerde) kuzenin Mac'inde deneme vardır.

Durum: `[ ]` yapılmadı · `[~]` sürüyor · `[x]` bitti

---

## Başlamadan önce
- [x] Tasarım belgesi yazıldı ve karar kayıtları işlendi
- [x] `git init`, `.gitignore`, ilk commit
- [ ] **Bu To-Do ve 1. aşama planının sizce onaylanması** ← şu an burada

## Aşama 1 — Çekirdek (Swift kütüphanesi)
Ayrıntılı plan: `docs/superpowers/plans/2026-10-19-stage1-core.md`
- [x] G1: Paket iskeleti, rapor modeli, eski rapor içe aktarma
- [x] G2: Kural dosyasıyla sınıflandırıcı (`rules.json`)
- [x] G3: Dosya sistemi soyutlaması ve tarayıcı çekirdeği
- [x] G4: Kırpma, adaylar, en büyük dosyalar, iptal, şema 2 alanları
- [x] G5: Python eşdeğerlik testi ve `disk-atlas-scan` aracı
- **Bitti sayılır:** `swift test` yeşil; `/Applications` üzerinde Swift ve Python toplamı %0,1 içinde; gerçek Python raporu içe aktarılıyor.

## Aşama 2 — Uygulama kabuğu
Plan: `docs/superpowers/plans/2026-10-19-stage2-shell.md`
- [x] Web arayüzünü `Resources/web/` altında `index.html`, `app.css`, `app.js` olarak böl; `FileBackend` ile mevcut davranışı koru
- [x] `verify_ui.cjs`'i yeni dosya yapısına uyarla
- [x] `ReportStore`: taramaları `~/Library/Application Support/DiskAtlas/scans/` altına kaydet, listele, yükle
- [x] Swift uygulama kabuğu: pencere, menü, `WKWebView`, paketten yükleme, dış gezinmeyi engelleme
- [x] Köprü: mesaj doğrulama, `startScan`, `cancelScan`, `scanProgress/Done/Failed`, `permissionStatus`, `openFullDiskAccess`
- [x] Ekranlar: karşılama/izin rehberi, tarama ilerlemesi (iptal), pano
- [x] Tarama bilgisi sayfasında macOS ve uygulama sürümü (kuzenin ekran görüntüsüyle hata ayıklamak için)
- [x] `scripts/build_app.sh`: `.app` paketi, ad-hoc imza, zip
- [x] Kendi Mac'inizde `.app`'i aç, tara, ekran görüntüsüyle kontrol
- [x] İlk kurulum simülasyonu (kendi Mac'inizde): karantina bayrağı verilmiş `.app` ile Gatekeeper uyarısı, Tam Disk Erişimi verilmemiş durumda rehber ekranı ve "kısmi tarama" işareti
- [ ] **Sizin denemeniz:** `dist/DiskAtlas.app`'i Finder'dan aç, Tam Disk Erişimi vermeden gerçek bir tarama yap (macOS izin pencereleri çıkabilir), "Rapor aç" düğmesini dene. Kod tarafı otomatik testlerle doğrulandı; bu iki şey etkileşimli olduğu için yalnızca siz doğrulayabilirsiniz.
- **Bitti sayılır:** `.app` kendi Mac'inizde açılıyor, tarıyor ve izin yokken doğru davranıyor. Kuzene bu aşamada gönderilmez.

## Aşama 3 — Geçmiş ve karşılaştırma
Plan: `docs/superpowers/plans/2026-10-19-stage3-history.md`
- [x] `Differ`: durumlar `büyüdü/küçüldü/yeni/kalktı/belirsiz`, "Diğer N öğe" hariç, eksik/okunamayan tarama `belirsiz`
- [x] Açıklanamayan fark satırı (disk doluluğu farkı − ölçülen fark)
- [x] Köprü: `listScans`, `loadScan`, `deleteScan`, `compare`
- [x] "Geçmiş" sekmesi: tarama listesi, iki tarama seç, sıralanabilir fark tablosu
- [x] Testler: aggregate, yarım tarama, okunamayan klasör, yeni/kalkan klasör
- **Bitti sayılır:** iki gerçek tarama arasında "ne büyüdü" doğru ve yanıltıcı "silindi" göstermiyor.

## Aşama 4 — Uygulamalar ve Tanınmayan görünümleri
- [ ] `rules.json`'u araç kurallarıyla genişlet (Android, Xcode, VS Code, npm, Gradle, Docker, Homebrew, tarayıcı/uygulama verileri) ve her kurala açıklama ekle
- [ ] `build_ui.py`'deki sabit `specs` mantığını kural dosyasına taşı; ev klasörünü `/Users` en büyüğü yerine gerçek kullanıcıdan türet
- [ ] "Uygulamalar" sekmesi: gruplar, bileşenler, "nedir / neden bu kategoride / silinirse ne olur"
- [ ] "Tanınmayan" sekmesi: kurala uymayan en büyük klasörler
- **Bitti sayılır:** geliştirici olmayan bir Mac'te de anlamlı sonuç veriyor.

## Aşama 5 — Temizlik (Çöp Sepeti)
- [ ] `TrashService`: yalnızca `FileManager.trashItem`; yasaklı yollar, `lstat` yeniden kontrol, sembolik bağlantı/volume kontrolü
- [ ] Güvenlik düzeyleri (`güvenli / incele / asla`) `rules.json`'a işlenir
- [ ] `planTrash` → `confirmTrash` akışı, onay penceresi, ek onay kutusu (`incele`), satır satır sonuç
- [ ] `actions.log`; tarama sürerken temizlik kapalı
- [ ] Üst çubuk metni: "Silme: yalnızca Çöp Sepeti"; "yer açmaz" uyarısı
- [ ] Testler yalnızca geçici dizinde; kodda `rm`/`removeItem` yok (arama ile doğrulama)
- **Bitti sayılır:** seçilen güvenli öğeler Çöp Sepeti'ne gider, "Geri Koy" çalışır, yasaklı yollar reddedilir.

## Aşama 6 — Cila ve dağıtım
- [ ] Kısa Türkçe `OKU-BENI.md` (Yine de Aç, Tam Disk Erişimi, `xattr` yedeği); kuzen teknik biri olduğu için resimli rehber gerekmez
- [ ] **Nihai ürünü kuzene gönder (tek deneme):** uyarı + izin + tarama (sizin elinizde); sorun çıkarsa düzeltip yeni zip
- [ ] Gerekirse performans ölçümü; yavaşsa paralel tarama (deterministik sıralamayı bozmadan) değerlendirilir

---

## Açık noktalar
- Siz macOS 15.7 (Xcode 16.3), kuzen büyük olasılıkla en son macOS sürümünde. Eski SDK ile derlenen uygulamanın yeni macOS'ta çalışması beklenir ama burada doğrulanamaz; tek gerçek doğrulama 6. aşamadaki kuzen denemesi. Sorun çıkarsa düzeltilip yeni zip gönderilir.
- Paket kimliği `local.diskatlas.app` yer tutucu; sonradan değişirse izinler sıfırlanır, bu yüzden 2. aşamadan önce kesinleşmeli.
- Google Drive'daki tasarım belgesi kopyası elle güncel tutulur; spec değişirse yeniden yüklenmesi gerekir.
