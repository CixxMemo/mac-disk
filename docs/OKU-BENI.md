# Disk Atlas — Beni Oku

Sürüm: {{VERSION}} · Apple Silicon Mac, macOS 14 veya üstü

Disk Atlas, Mac'inde diskin neyle dolduğunu gösterir: klasör haritası, araç/uygulama grupları (Android, Xcode, npm, Docker…) ve iki tarama arasındaki büyüme.

## Ne yapar, ne yapmaz
- Tararken yalnızca dosya **adını, yolunu ve boyutunu** okur. Dosya içeriklerini açmaz.
- Ağa hiçbir şey göndermez. Taramalar yalnızca bu Mac'te durur.
- Hiçbir şeyi kalıcı silmez. Yalnızca senin seçip onayladığın öğeleri **Çöp Sepeti'ne taşır**; Çöp Sepeti'ni boşaltmaz. Boşaltana kadar disk alanı açılmaz. İstersen Çöp Sepeti'nde öğeye sağ tıklayıp "Geri Koy" diyebilirsin.
- Belgeler, Masaüstü, Resimler (Fotoğraflar arşivi dahil), Filmler, Müzik gibi kişisel klasörleri, Mail/Mesajlar verilerini ve sistem dosyalarını taşımaz.

## İlk açılış
Uygulama Apple'a notarize edilmedi (Developer hesabı yok), bu yüzden macOS ilk açılışta uyarı verir.
1. Zip'i aç, `DiskAtlas.app`'i **Uygulamalar** klasörüne sürükle.
2. Çift tıkla. "Doğrulanamadı / açılamıyor" uyarısı çıkar: **Bitti**'ye bas (**Çöp Sepeti'ne Taşı'ya basma**).
3. **Sistem Ayarları → Gizlilik ve Güvenlik**'i aç, aşağı kaydır, Disk Atlas için **Yine de Aç**'a bas. Açılan ikinci pencerede yine **Yine de Aç**'a bas ve parolanı (veya Touch ID) gir.
   Düğme görünmüyorsa önce uygulamayı bir kez açmayı dene; düğme yalnızca engellenen bir açılıştan sonra, bir süre görünür. Menü adları macOS sürümüne göre küçük farklar gösterebilir.
4. Bu yol çalışmazsa Terminal'de şunu çalıştırıp uygulamayı yeniden aç:
   ```
   xattr -dr com.apple.quarantine /Applications/DiskAtlas.app
   ```

## Tam Disk Erişimi (önerilir)
Mail, Mesajlar, Safari gibi korumalı klasörler izin olmadan okunamaz; tarama "kısmi" olur.
1. **Sistem Ayarları → Gizlilik ve Güvenlik → Tam Disk Erişimi**'ni aç (uygulamadaki "Ayarları aç" düğmesi de buraya götürür).
2. Disk Atlas listede yoksa **+** ile Uygulamalar klasöründen ekle; varsa anahtarı aç.
3. **Uygulamayı kapatıp yeniden aç.** İzin yeniden açılana kadar geçerli olmaz.
4. **Yeni sürüm kurduğunda** (uygulamayı değiştirdiğinde) izin açık görünse de çalışmayabilir: listede Disk Atlas'ı kapatıp yeniden aç (veya **−** ile çıkarıp yeniden ekle).

İzin vermeden de taranabilir; macOS Masaüstü, Belgeler, İndirilenler, başka uygulamaların verileri veya harici/ağ diskleri için ayrıca izin sorabilir. Tam Disk Erişimi verirsen bu pencereler çıkmaz.

## Kullanım
- **Tara**: tüm diski ölçer (birkaç dakika sürebilir). Sonuç otomatik kaydedilir, uygulama açılınca en son tarama görünür.
- **Keşfet**: klasör haritası. **Uygulamalar**: araçlara göre gruplar, her satırda "nedir / neden bu türde / silinirse ne olur" ve güvenlik rozeti. **Tanınmayan**: hiçbir araca bağlanamayan büyük klasörler. **Geçmiş**: iki taramayı karşılaştır.
- **Çöp Sepeti'ne taşıma**: bir öğenin kutusunu işaretle, alttaki "Çöp Sepeti'ne taşı…" düğmesine bas, planı oku, onayla. "İncele" rozetli öğeler için ek onay kutusu çıkar. Taşıdıktan sonra tarama güncel sayılmaz; yeniden tara.
- Boyutlar macOS gibi ondalık GB'dır (1 GB = 1.000.000.000 bayt).

## Dosyalar
- Taramalar: `~/Library/Application Support/DiskAtlas/scans`
- Yapılanların kaydı: `~/Library/Application Support/DiskAtlas/actions.log` (satır başına bir JSON; ilk taşımadan sonra oluşur)
- Uygulama ayrıca pencere konumu gibi küçük ayarları macOS'un standart Tercihler klasörüne (`~/Library/Preferences`) yazar.
Taramaları ve günlüğü silmek serbesttir. Uygulamayı kaldırmak için `DiskAtlas.app`'i Çöp Sepeti'ne at.

## Sorun olursa
**Tarama bilgisi** sekmesinin ekran görüntüsünü ve macOS sürümünü gönder.
