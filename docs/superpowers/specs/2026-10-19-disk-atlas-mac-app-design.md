# Disk Atlas — macOS uygulaması tasarım belgesi

Tarih: 2026-10-19 · Durum: **6 karar işlendi; 1–3. aşamalar uygulandı** (kod yazıldı)

## 1. Anlayış (düzeltmeniz için)

**Amaç.** Mevcut Python + HTML "Disk Atlas" aracını, kuzeninin M4 MacBook Air'inde `.app` dosyasına çift tıklayarak çalışan, diskini tarayıp gösteren ve (ikinci aşamada) seçilen öğeleri Çöp Sepeti'ne taşıyabilen bir **hobi projesine** dönüştürmek.

**Sizin söyledikleriniz**
- Para kazanma amacı yok; hobi projesi.
- Ücretli Apple Developer hesabı yok, App Store yok.
- Kodu Claude yazacak; öğrenme süresi engel değil.
- Kuzen `.app` dosyasını alıp tıklayınca çalışmalı.
- Tek tıkla silme istiyorsunuz.

**Benim varsayımlarım (yanlışsa söyleyin)**
- Hedef makine Apple Silicon (M4) ve büyük olasılıkla en son macOS sürümü. Uygulama macOS 14+ için derlenir. Sizin geliştirme Mac'iniz macOS 15.7'de olduğundan en son sürümde ayrıca test edilemez.
- Kuzen teknik bilgisi yüksek biri; güvenlik uyarısını kendisi aşabilir.
- Arayüz Türkçe kalır (İngilizce sonraya).
- Kuzen geliştirici olmayabilir. Bu yüzden uygulama geliştirici araçlarına özel değil, genel kullanıcı için de anlamlı olmalı.
- Silme "tek tıkla" olacak ama **yalnızca Çöp Sepeti'ne taşıma** ve onay penceresiyle. Kalıcı silme yok.

**Başarı ölçütü.** Kuzen zip'i açar, uygulamayı bir kez izin vererek açar, "Tara"ya basar, birkaç dakikada diskinin haritasını görür, iki tarama arasında neyin büyüdüğünü görür, güvenli önbellekleri onaylayıp Çöp Sepeti'ne taşır. Hiçbir terminal komutu gerekmez.

## 2. Kapsam

### Dahil (v1)
1. Uygulama içinde disk taraması (ilerleme, iptal).
2. Alan haritası (treemap), tür görünümü, büyük dosyalar, tarama bilgisi: mevcut ekranlar korunur.
3. **Tarama geçmişi ve karşılaştırma**: iki tarama arası klasör bazlı büyüme.
4. **Uygulama/araç bazlı görünüm**: ilişkili klasörleri birlikte gösterir (örn. Android: SDK + emülatör + önbellek).
5. Açıklayıcı bulgular + **Tanınmayan büyük alanlar** listesi.
6. **Temizlik (Aşama 2)**: Çöp Sepeti'ne taşıma, izin listesi, onay, günlük.
7. İlk açılış rehberi: Tam Disk Erişimi izni.
8. Mevcut Python JSON raporlarını içe aktarma.

### Dahil değil (şimdilik)
- Kalıcı silme, Çöp Sepeti'ni otomatik boşaltma.
- App Store, notarization, otomatik güncelleme, imzalı dağıtım.
- Arka plan/zamanlanmış tarama, menü çubuğu simgesi, bulut senkronu.
- Çok iş parçacıklı tarama (önce tek iş parçacığı; ölçüp gerekirse sonra).
- İngilizce arayüz, Intel Mac'ler.

## 3. Mimari

```
DiskAtlas.app
├─ Swift uygulama kabuğu (pencere, menü, izinler)
│   └─ WKWebView ── yerel web arayüzü (HTML/CSS/JS, paketin içinde)
│          ▲  JSON mesajları (köprü)
│          ▼
└─ DiskAtlasCore (Swift kütüphanesi)
    ├─ Scanner        dosya sistemi metaverisini okur
    ├─ Classifier     kural dosyasıyla yol → kategori/araç
    ├─ ReportStore    taramaları diske yazar/okur
    ├─ Differ         iki taramayı karşılaştırır
    └─ TrashService   güvenli taşıma (Aşama 2)
```

**Neden yerel sunucu yok.** Arayüz, `WKWebView` içinde paketten yüklenir ve Swift ile `WKScriptMessageHandler` üzerinden konuşur. Port, oturum anahtarı ve "başka bir web sitesi silme isteği gönderebilir" riski yoktur.

**Web arayüzünün bölünmesi.** Şu an tek 2 MB'lık HTML dosyası. `Resources/web/` altında `index.html`, `app.css`, `app.js` olarak ayrılır. JS iki arka uç arasında seçim yapar:
- `NativeBackend`: uygulama içi (Swift köprüsü).
- `FileBackend`: tarayıcıda JSON açma (geliştirme ve testler için, mevcut davranış).

**Proje yapısı** (SwiftPM + derleme betiği; Xcode proje dosyası olmadan komut satırından derlenir):
```
mac-disk/
├─ Package.swift
├─ Sources/DiskAtlasCore/        ← tarayıcı, sınıflandırıcı, fark, çöp servisi
├─ Sources/DiskAtlasApp/         ← pencere, köprü, izinler
├─ Resources/web/                ← arayüz
├─ Resources/rules.json          ← sınıflandırma ve araç kuralları (tek yerde)
├─ Tests/
├─ scripts/build_app.sh          ← .app paketini kurar, ad-hoc imzalar, zip'ler
├─ scanner.py, build_ui.py,      ← mevcut Python aracı yerinde kalır (referans);
│  verify_ui.cjs,                   şablon Resources/web'e bölünürken kopyalanır
│  Disk-Atlas.template.html
├─ reports/                      ← mevcut raporlar (git dışında)
└─ docs/superpowers/specs/
```
Mac'inizde Xcode 16.3 / Swift 6.1 / macOS 15.7 kurulu; `swift build` ve `swift test` çalışır durumda.

### 3.1 Köprü sözleşmesi
Her mesaj `{id, type, payload}`. Swift her gelen mesajı doğrular; JS'e güvenilmez. Yollar JS'ten değil, Swift'in bildiği tarama sonuçlarından çözülür.

| Yön | Mesaj | Anlam |
|---|---|---|
| JS→Swift | `startScan{root}` / `cancelScan` | Taramayı başlat/iptal |
| JS→Swift | `listScans` / `loadScan{id}` / `deleteScan{id}` | Geçmiş |
| JS→Swift | `compare{a,b}` | İki tarama farkı |
| JS→Swift | `permissionStatus` / `openFullDiskAccess` | İzin kontrolü, ayar penceresine gitme |
| JS→Swift | `revealInFinder{id}` | Finder'da göster |
| JS→Swift | `planTrash{itemIds}` → `confirmTrash{planId}` | Aşama 2: önce plan, sonra onay |
| Swift→JS | `scanProgress{records, folder, elapsed}` / `scanDone{id}` / `scanFailed` | Olaylar |

### 3.2 Veri depolama
`~/Library/Application Support/DiskAtlas/`
- `scans/<zaman>.json`: her tarama. Mevcut Python şemasının (`schema 1`) üst kümesi (`schema 2`).
- `actions.log`: yapılan her Çöp Sepeti işlemi.

**Karşılaştırma için ek veri.** Python raporu küçük öğeleri "Diğer N öğe" olarak gruplayıp bilgi kaybediyor. Yeni şemada ağaçtan ayrı olarak **düz klasör dizini** saklanır: `yol → bayt` (1 MiB ve üstü klasörler; yaklaşık 20–30 bin kayıt, sıkıştırılmış birkaç MB) ve **kapsam bilgisi**: tamamlandı mı, hangi yollar okunamadı (tam liste, 100 ile sınırlı değil), boş alan ve kullanılan alan.

### 3.3 Karşılaştırma kuralları
- Her klasör için durum: `büyüdü`, `küçüldü`, `yeni`, `kalktı`, `belirsiz`.
- Bir klasör iki taramanın birinde okunamadıysa veya tarama yarıda kaldıysa `belirsiz`; asla "silindi" denmez.
- "Diğer N öğe" grupları karşılaştırmaya girmez.
- **Açıklanamayan fark satırı**: disk doluluğu farkı ile ölçülen klasör farkı arasındaki bölüm (APFS anlık görüntüleri, korumalı alanlar, taramalar arası değişen boş alan vb.). Arayüz bunu açıkça gösterir.
- Dosya düzeyinde "eklendi/silindi" listesi **yok** (yalnızca klasör düzeyi). Neden: saklanan veri bunu kesin vermez.

## 4. Özellikler ve ekranlar

### 4.1 Ekran akışı
1. **Karşılama / izin**: Tam Disk Erişimi açıklaması ve "Ayarları Aç" düğmesi. İzin verilmeden de tarama başlatılabilir, ama sonuç "kısmi" işaretlenir.
2. **Tarama**: kayıt sayısı, o an taranan klasör, geçen süre, İptal düğmesi.
3. **Pano**: mevcut özet kartları (boş alan, ölçülen alan, önbellek, kullanıcı klasörü) + sekmeler.

### 4.2 Sekmeler
| Sekme | İçerik |
|---|---|
| **Keşfet** | Treemap, klasör/tür modu, yol çubuğu, sağda "Yakından bakılacaklar". Mevcut. |
| **Uygulamalar** | Kurallarla gruplanmış araçlar: örn. *Android → SDK 14,6 GiB + emülatör 8,3 GiB + önbellek*. Satırı açınca bileşenler. Her satırda: nedir, neden bu kategoride, silinirse ne olur. |
| **Tanınmayan** | Hiçbir kurala uymayan en büyük klasörler. Kuralları geliştirmek için de veri sağlar. |
| **Büyük dosyalar** | En büyük 150 dosya. Mevcut. |
| **Geçmiş** | Tarama listesi, iki tarama seç → karşılaştırma tablosu (sıralanabilir: en çok büyüyen) + açıklanamayan fark satırı. |
| **Tarama bilgisi** | Kapsam, hatalar, sınırlar, macOS ve uygulama sürümü. |

### 4.3 Aşama 2: Temizlik
- Satırlarda onay kutusu (şimdiki "inceleme listesi" gibi), altta **"Çöp Sepeti'ne taşı"** düğmesi.
- Düğme önce **plan** gösterir: tam yollar, boyutlar, toplam; "Çöp Sepeti'ne taşınır, boşaltana kadar yer açılmaz".
- Her kural bir **güvenlik düzeyi** taşır (`rules.json`):
  - `güvenli`: yeniden oluşturulabilir (önbellekler, DerivedData, `node_modules`, npm/Gradle önbelleği). Tek onay yeter.
  - `incele`: uygulama verisi, SDK, VM imajı. Ek onay kutusu ("Ne olduğunu anladım").
  - `asla`: sistem yolları, kullanıcı klasörünün kendisi, Belgeler/Masaüstü/Fotoğraflar kökleri. Düğme devre dışı.
- Taşıma sonucu satır satır raporlanır (başarılı/başarısız ve neden). Tamamı `actions.log`'a yazılır.

## 5. Güvenlik tasarımı (silme)
1. Yalnızca `FileManager.trashItem` kullanılır. `rm`, `removeItem` yok. Kodda arama ile doğrulanabilir.
2. Yollar tarama sonucundan **Swift tarafında** çözülür; JS'ten gelen ham yola güvenilmez.
3. Taşımadan hemen önce yeniden `lstat`: sembolik bağlantı mı, aynı volume mü, `asla` listesinde mi, hâlâ aynı tür mü.
4. Tarama sürerken temizlik yapılamaz.
5. WebView yalnızca paketteki içeriği yükler. Harici gezinme engellenir. CSP: `default-src 'self'`, uzak istek yok.
6. Uygulama ağ erişimi kullanmaz, veri göndermez, izleme yok.
7. Yeni "Salt okunur" etiketi yerine, Aşama 2'den sonra üst çubukta **"Silme: yalnızca Çöp Sepeti"** yazar.

## 6. Görsel tasarım
- Mevcut arayüzün dili korunur: krem tonlu, klasik **Macintosh** esintili tema (duvar kâğıdı dokusu, sakin renkler), özet kartları, kenarda kategorili renk noktaları. Yeni ekranlar aynı bileşenlerle (`panel`, `stat`, `segmented`, `count-pill`) yapılır.
- Pencere: tek ana pencere, en az 960×640. Üstte marka + sekmeler + "Tara" düğmesi, altta durum çubuğu.
- Açık/koyu tema: v1'de yalnızca açık (mevcut). Koyu tema sonraya.
- Erişilebilirlik: klavye gezinmesi, odak halkaları, `aria` etiketleri mevcut düzeyde korunur.
- Wireframe (Keşfet):
```
┌ Disk Atlas  [Keşfet|Uygulamalar|Tanınmayan|Büyük dosyalar|Geçmiş|Bilgi]  [Tara] ┐
│ [Boş alan 5,4 GiB] [Ölçülen 184 GiB] [Önbellek 16 GiB] [Kullanıcı 131 GiB]       │
│ ┌ Alan gezgini ───────────────────────────┐ ┌ Yakından bakılacaklar ──────────┐ │
│ │ ↑ ⌂  Users › mehmet › Library           │ │ 🔍 ara…                          │ │
│ │ ┌────────────┬─────┬────┐               │ │ ☐ Android SDK        14,6 GiB   │ │
│ │ │ Application│Cache│... │  treemap      │ │ ☐ npm önbelleği       3,4 GiB   │ │
│ │ └────────────┴─────┴────┘               │ │ Seçili: 0 B  [Çöp Sepeti'ne taşı]│ │
│ └─────────────────────────────────────────┘ └─────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────────┘
```

## 7. Dağıtım (kuzene)
- `scripts/build_app.sh` → `DiskAtlas.app` kurar, **ad-hoc imzalar** (`codesign -s -`; Apple Silicon'da çalışmak için yeterli), `DiskAtlas.zip` üretir.
- İmzasız/notarize edilmemiş olduğu için kuzende **ilk açılışta uyarı** çıkar. macOS 15'te: *Sistem Ayarları → Gizlilik ve Güvenlik → "Yine de Aç"*. Yedek: Terminal'de `xattr -cr DiskAtlas.app`. Kısa bir `OKU-BENI.md` yeterli (kuzen teknik biri, resimli rehber gerekmez).
- **Tam Disk Erişimi** macOS tarafından programatik olarak istenemez. Uygulama izni algılar, yoksa rehber ekran gösterir ve doğrudan ilgili ayar sayfasını açar. Kuzen elle uygulamayı listeye ekleyip açar, uygulamayı yeniden başlatır.
- Güncelleme: yeni zip gönderilir (otomatik güncelleme yok).
- Dürüst sınır: "tıkla ve çalışsın" ifadesi ilk kurulumdaki bu iki adım (uyarı + izin) hariç doğrudur.

## 8. Test stratejisi
- **Birim testleri (`swift test`)**: Scanner (geçici dizin: sembolik bağlantı, sabit bağlantı, `chmod 000` okunamayan klasör, boş klasör, derin ağaç), Classifier (kural eşleşmeleri), Differ (aggregate, eksik tarama, okunamayan, yeni/kalkan klasör, açıklanamayan fark), TrashService (yasaklı yollar, sembolik bağlantı değişimi, başka volume), köprü mesaj doğrulama.
- **Python ile eşdeğerlik**: aynı test dizininde Swift ve Python (`scanner.py`) tarayıcılarının toplam ve kategori sonuçları karşılaştırılır.
- **Şema uyumu**: `reports/` altındaki gerçek Python JSON'ları içe aktarılabilmeli.
- **Arayüz**: mevcut `verify_ui.cjs` yeni dosya yapısına uyarlanır (sahte DOM).
- **Gerçek pencere**: Derleyip çalıştırıp ekran görüntüsüyle bakmayı deneyeceğim; bunu güvenilir yapamazsam sizden gözle kontrol isteyeceğim. Kuzenin Mac'inde son kabul testi (uyarı + izin + tarama) sizin elinizde.
- Silme testleri yalnızca geçici dizinde çalışır; testler gerçek kullanıcı dosyalarına dokunmaz.

## 9. Riskler
| Risk | Önlem |
|---|---|
| Tam Disk Erişimi olmadan eksik tarama | İzin rehberi, "kısmi tarama" işareti, okunamayan yolların tam listesi |
| Yanlış silme | Yalnızca Çöp Sepeti, izin listesi, yeniden kontrol, onay, günlük |
| Hardlink sayımı sıraya bağlı | v1'de tek iş parçacığı (deterministik); paralelleşirse yeniden ele alınır |
| Gatekeeper uyarısı ilk açılışta çıkar (kuzen teknik biri, kendisi aşabilir) | Kısa OKU-BENI, `xattr` yedeği |
| Dosya sistemi API'leri ve izin davranışı macOS sürümüne göre değişir; kuzen sizden daha yeni bir macOS kullanıyor olabilir | Testler, Tarama bilgisi sayfasında macOS ve uygulama sürümü, kuzenin Mac'inde tek deneme |
| Çöp Sepeti'ne taşıma yer açmaz | Arayüzde açık uyarı |

## 10. Aşamalar (her biri ayrı plan/onay döngüsü)
1. **Çekirdek**: Swift paketi, Scanner + Classifier + şema + Python eşdeğerlik testleri; JSON içe aktarma.
2. **Uygulama kabuğu**: WebView, köprü, tarama ekranı, izin rehberi, `build_app.sh`. *Kendi Mac'inizde ilk kurulum simülasyonu (karantina bayrağı, izinsiz tarama).*
3. **Geçmiş ve karşılaştırma**.
4. **Uygulamalar ve Tanınmayan görünümleri** (`rules.json`).
5. **Temizlik** (Çöp Sepeti).
6. **Cila ve dağıtım**: OKU-BENI, kuzen testi, hata düzeltme.

## 11. Alınan kararlar (2026-10-19)
1. Uygulama adı **Disk Atlas** olarak kalır (paket kimliği `local.diskatlas.app` yer tutucu). **Evet.**
2. Minimum macOS **14**. **Uygun.** (Kuzende 15+ olmalı.)
3. Mevcut Python dosyaları **taşınmaz**, proje kökünde yerinde kalır. **Taşınmasın.**
4. `git init` + `.gitignore` yapılır. `reports/`, üretilmiş `Disk-Atlas.html` (kişisel yollar içerir), `Disk-Atlas.onceki.html`, `*.app`, `.build/` git dışında kalır. **Evet.**
5. Temizlik 5. aşamaya ertelenir; 1–4. aşamalar kendi Mac'inizde sağlam çalışana kadar eklenmez (kuzen testi yalnızca en sonda, nihai ürünle). **Evet.**
6. Boyutlar macOS ile aynı **ondalık birimle (GB, 1 GB = 1.000.000.000 bayt)** gösterilir; GB ve üstü iki, KB/MB bir ondalıkla. "Ölçülen" kartı, kullanılan alandan ölçülemeyen kısmı (macOS sistem birimi, anlık görüntüler, korumalı alanlar) ayrıca yazar. (2026-10-19, kullanıcı isteği.)
7. **Uygulamalar** ve **Tanınmayan** görünümleri `rules.json` içindeki araç kataloğuyla çalışır (26 araç, 66 bileşen; gerçek bir taramada ölçülen alanın %78'i tanındı). Güvenlik düzeyleri (güvenli/incele/asla) bu sürümde yalnızca bilgi rozetidir. (2026-10-19, kullanıcı onayı: katalog, tanınmayan sezgisi, rozetler, yüklü uygulamalar, salt okunur gerçek veri doğrulaması.)
