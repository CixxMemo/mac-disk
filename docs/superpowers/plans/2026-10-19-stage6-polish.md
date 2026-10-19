# Aşama 6 — Cila ve Dağıtım Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (native). Steps use checkbox (`- [ ]`) syntax.

**Goal:** Kuzene gönderilecek nihai paketi hazırlamak: simge, sürüm, Türkçe okunur kılavuz, zip içeriği ve son doğrulama. Kod davranışı değişmez.

**Architecture:** Yalnızca paketleme ve belge işleri. Simge `scripts/make_icon.py` ile üretilir (PIL), `Resources/AppIcon.icns` olarak commit edilir; `build_app.sh` simgeyi ve `OKU-BENI.md`'yi pakete ekler ve bir kontrol betiği (`scripts/check_dist.sh`) çıktıyı doğrular.

**Tech Stack:** bash, Python 3 + PIL (yalnızca geliştirici makinesinde), `iconutil`, `sips`, `plutil`, `codesign`.

**Spec:** `docs/superpowers/specs/2026-10-19-disk-atlas-mac-app-design.md` (bölüm 7 Dağıtım, 10 Aşamalar); kararlar bu plandaki "Onay bekleyen kararlar".

## Onay bekleyen kararlar (önerim yanında; kullanıcı onayı gelmeden başlanmaz)
1. **Sürüm:** `1.0.0` (nihai ürün). Alternatif: `0.3.0`.
2. **Simge:** marka işareti (4 renkli yuvarlak kare, `.brand-mark` renkleriyle) koyu yeşil (`#293e32`) yuvarlatılmış zeminde.
3. **OKU-BENI.md zip içinde, `DiskAtlas.app` yanında** gider.
4. **Koyu tema: kapsam dışı** (38 KB CSS'in iki kez bakımı; kuzen teknik biri, hobi proje).
5. **Performans/paralel tarama: kapsam dışı** (Swift tarayıcı Python'dan ≈%25 yavaş ama ölçülmüş ve yeterli; deterministik sıralamayı bozma riski).
6. **Paket kimliği `local.diskatlas.app` kesinleşir** (değişirse izinler sıfırlanır).
7. **Kuzene göndermeden önce sizin Çöp Sepeti denemeniz** (gerçek `trashItem` ve "Geri Koy" yalnızca böyle doğrulanır).

## Global Constraints
- Kod davranışı, köprü, kurallar ve testler değişmez; `swift test` 177, web 68 test ve self-test aynen yeşil kalır.
- Gerçek kullanıcı verisine dokunulmaz; denemeler geçici klasörde. `rm`, `git push`, birleştirme, branch silme yapılmaz.
- Metinler Türkçe, kısa ve teknik kuzene göre; resimli rehber yok.
- Commit sonuna `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus
1. `OKU-BENI.md` komutları gerçekten çalışır olmalı: `xattr -dr com.apple.quarantine`, Ayarlar yolu (macOS 15 adları); yanlış yol kuzeni takar.
2. Zip açılınca `DiskAtlas.app` imzası bozulmamış olmalı (`codesign --verify --strict`, `ditto --norsrc`).
3. Simge tüm boyutlarda (16–1024) üretilmeli; `Info.plist` `CFBundleIconFile` adı dosyayla eşleşmeli, yoksa genel simge görünür.
4. Sürüm numarası uygulamada (Tarama bilgisi), `Info.plist`'te ve zip adında tutarlı olmalı.
5. `build_app.sh` temiz klonda (`dist/` yokken) çalışmalı.

---

### Task 1: Simge

**Files:** Create `scripts/make_icon.py`, `Resources/AppIcon.icns`; Modify `scripts/Info.plist.template`, `scripts/build_app.sh`; Test `scripts/check_dist.sh` (Task 3'te genişler).

**Interfaces:**
- Produces: `python3 scripts/make_icon.py <çıkış.icns>` — 1024 px ana çizimden 16, 32, 64, 128, 256, 512, 1024 (ve @2x karşılıkları) boyutlu `.iconset` üretir, `iconutil -c icns` ile birleştirir.
- Produces: `Info.plist`'e `CFBundleIconFile` = `AppIcon`; `build_app.sh` `Resources/AppIcon.icns` dosyasını pakete `Contents/Resources/AppIcon.icns` olarak kopyalar.

- [ ] **Step 1: Test** — `scripts/check_dist.sh` içinde (henüz yok, önce yaz): `dist/DiskAtlas.app/Contents/Resources/AppIcon.icns` var mı ve `Info.plist` `CFBundleIconFile` = `AppIcon` mu. Çalıştır → FAIL (dosya yok).
- [ ] **Step 2:** `make_icon.py` yaz (yuvarlatılmış kare zemin `#293e32`, ortada 2×2 kare, renkler `app.css` `.brand-mark i` ile aynı, hafif −6° dönüş); `Resources/AppIcon.icns` üret; plist ve `build_app.sh`'yi güncelle.
- [ ] **Step 3:** `iconutil -c iconset Resources/AppIcon.icns` ile geri aç, `sips -g pixelWidth` ile 16…1024 boyutların hepsinin bulunduğunu doğrula; `bash scripts/build_app.sh` ve `check_dist.sh` → PASS.
- [ ] **Step 4:** Commit `feat: app icon`.

### Task 2: OKU-BENI.md ve sürüm

**Files:** Create `docs/OKU-BENI.md`; Modify `scripts/build_app.sh` (varsayılan sürüm, zip içeriği); Test `scripts/check_dist.sh`.

**Interfaces:**
- `docs/OKU-BENI.md` bölümleri: Ne işe yarar / ne yapmaz (yalnızca ad, yol, boyut okur; içerik açmaz; ağa bir şey göndermez; silme yalnızca onaylı Çöp Sepeti'ne taşıma); **İlk açılış** (zip'i aç, uygulamayı Uygulamalar'a taşı, çift tıkla, uyarı → Ayarlar → Gizlilik ve Güvenlik → "Yine de Aç"; olmazsa `xattr -dr com.apple.quarantine /Applications/DiskAtlas.app`); **Tam Disk Erişimi** (neden, nasıl, izin verdikten sonra uygulamayı yeniden aç); **Kullanım** (Tara, sekmeler, Çöp Sepeti'ne taşıma ve Geri Koy, "Yer açmaz" uyarısı); **Dosyalar** (`~/Library/Application Support/DiskAtlas/scans` ve `actions.log`; silmek serbest); **Sorun olursa** ("Tarama bilgisi" sekmesinin ekran görüntüsü + macOS sürümü).
- `build_app.sh`: varsayılan sürüm onaylanan değer; zip, `DiskAtlas.app` ve `OKU-BENI.md` içeren bir klasörü `ditto -c -k --norsrc --keepParent` ile paketler (`dist/DiskAtlas.zip`).

- [ ] **Step 1: Test** — `check_dist.sh`: zip'i geçici klasöre açar; `DiskAtlas.app` ve `OKU-BENI.md` var; `codesign --verify --strict` zip'ten açılan kopyada geçer; `Info.plist` sürümü `OKU-BENI.md`'de yazan sürümle aynı; kılavuzdaki `xattr` komutu ile Ayarlar yolu metinleri (`Yine de Aç`, `Tam Disk Erişimi`) bulunur. → FAIL.
- [ ] **Step 2:** Kılavuzu yaz (≤ 1 sayfa, madde madde), `build_app.sh`'yi güncelle.
- [ ] **Step 3:** `bash scripts/build_app.sh && bash scripts/check_dist.sh` → PASS. Zip içinden çıkan uygulamada `--self-test` (geçici klasör) → `ok:true`, Tarama bilgisi sürümü doğru.
- [ ] **Step 4:** Commit `docs: OKU-BENI and 1.0.0 packaging`.

### Task 3: Son doğrulama ve devir

**Files:** Modify `scripts/check_dist.sh`, `docs/superpowers/plans/2026-10-19-disk-atlas-todo.md`, `CLAUDE.md`, `docs/HANDOFF.md`.

- [ ] **Step 1:** Tüm paketleri çalıştır: `swift test`, `node --test Tests/web/ui.test.cjs`, `node verify_ui.cjs`, temiz klonda `bash scripts/build_app.sh && bash scripts/check_dist.sh`, zip'ten açılmış uygulamada `--self-test`. Beklenen: hepsi yeşil, sayılar değişmemiş.
- [ ] **Step 2:** Bağımsız Opus incelemesi (yalnızca paketleme, kılavuz doğruluğu, Review Focus maddeleri); bulgular test-önce düzeltilir.
- [ ] **Step 3:** To-Do'da aşama 6 işaretlenir ("kuzene gönder" maddesi sizde kalır), `CLAUDE.md` komutlarına `check_dist.sh` eklenir, HANDOFF güncellenir, Drive'daki tasarım belgesine karar 9 (sürüm, simge, kapsam dışı olanlar) eklenir.
- [ ] **Step 4:** Commit `docs: stage 6 done`; push/PR sizde.

## Kuzenle tek deneme (sizin işiniz, plan dışı)
Zip'i gönderin; sorun çıkarsa kuzenin ekran görüntüsüyle ("Tarama bilgisi") düzeltip yeni zip hazırlanır. Doğrulanamayanlar: en yeni macOS'ta açılış/Gatekeeper, Tam Disk Erişimi akışı, gerçek Çöp Sepeti.
