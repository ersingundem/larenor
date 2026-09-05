# Larenor Client — panel ve medya geliştirmeleri

5 Eylül 2026. Bu belge uygulanan kodu ve otomatik regresyon kapsamını açıklar.
Canlı HA değişikliği, kişisel fotoğraf okuması, cihaz sahipliği değişimi veya
hoparlör/kapı işlemi bu geliştirmeler sırasında çalıştırılmadı.

## Ortam ekranı

Görünüm → Ortam ekranı, saat/hava ve açıkça seçilmiş fotoğrafları yönetir.
Sistem dosya seçicisinin dönüşü Ayarlar kapısında yeniden doğrulanır. İptal,
arka plan, başka sayfa, idle veya yetki süresi dolunca geç dönen içerik kaydolmaz.
Kullanıcı fotoğraf göstermeyi ayrıca etkinleştirir; boş/okunamayan koleksiyon
saate döner. Hava yalnız ortak ekranda açıklanmasına izin verilen güncel HA
varlıklarından okunur.

Yerel kopya sınırları: en fazla 24 fotoğraf ve toplam 96 MiB; kaynak JPEG/PNG
12 MiB ve 24 megapiksel; normalize edilmiş çıktı en fazla 1920 piksel kenar ve
8 MiB PNG. Animasyon yerine ilk kare alınır. Yeniden kodlama kaynak dosya adı,
konum/EXIF ve diğer gömülü metadata'yı taşımaz. Sistem dosya okuması 15 saniye,
iptal temizliği en fazla bir saniyedir. Kaynak ve sıralama tamponları kuyruk
başlamadan kopyalanır; kaydetme yetkisi atomik manifest değişiminden hemen önce
yeniden kontrol edilir. Sembolik bağlantılar reddedilir, hash ve manifest üyeliği
okumada doğrulanır. Silme yalnız uygulamanın kendi yönettiği kopyayı kaldırır.

Görünen ekranda tek fotoğraf yüklenir. Koleksiyon değişince eski sonuç uygulanmaz;
tüm kopyalar bozuksa sonsuz okuma döngüsü oluşmaz. Kullanılmayan decoded görseller
önbellekten bırakılır. 15/30/60/120/300 saniye aralık, sığdır/doldur ve küçük saat
kaydırması bulunur. Hareketi azalt tercihi kaydırmayı kapatır. Kaydırma ekran
hasarını önleme garantisi değildir. Video/PDF/web içerik listeleri sonraki kapsamdır.

`PreventAmbientDisplay`, görünen ve aktif Jellyfin videosu için sahipli bir
idle erteleme kaydı tutar. Arka plana alınma, görünmez route, durma ve dispose
bu kaydı bırakır; OS kilit/pil politikasını değiştirmez. Yerel ses ekran
kapalıyken devam edebilir ve kendi başına ekranı açık tutmaz.

## Haftalık program ve yedek

Görünüm → Ekran programı en fazla 16 adlandırılmış kural saklar. Günler kuralın
başlangıç günüdür; gece yarısını aşan aralık ertesi gün tamamlanır. En alttaki
eşleşme önceliklidir; yukarı/aşağı kontrolleri bunu açıkça değiştirir. Tüm gün
seçimi ayrı ve açık; eşit başlangıç/bitiş boş aralık kabul edilir. Uygulama kendi
karartma ve keep-awake isteğini yalnız odaktaki ön plan penceresine uygular.

`screen_program_v1` ve `ambient_settings_v1` katı şema/sürüm/boyut kontrolüyle
şifreli kasa kapsamındadır. Fotoğraf bytes, site çerezleri ve cache kasada yoktur;
yeniden kurulumda fotoğraflar yeniden seçilir. Eski gece ayarlı yedeği “seçileni
değiştir” ile yüklemek yeni haftalık override'ı aynı geri alma günlüğünde kaldırır.
“Mevcudu koru” ve yalnız görünüm içeren eski yedek bunu yapmaz. Ara yazma hatası
ve uygulama kapanması eski haftalık/gece durumunun beraber geri alınmasını sağlar.

## Web panelleri

Kart düzenleyicisinde başlangıç URL'si, başlık, en fazla 15 tam ek web kökeni,
yakınlaştırma ve Android metin ölçeği (%75–200) değiştirilebilir. Wildcard,
URL yetki bölümünde kodlanmış biçimler, aynı köken tekrarları ve web olmayan
kartlarda web izni reddedilir. Bir köken eklemek o sitedeki bütün sayfalara
geçiş izni verir; bu sonuç onayda açıklanır. Form kendisi web sayfası başlatmaz.

Görünüm → Web sitesi verileri güncel Ayarlar PIN'i ister. Temizleme önce bütün
panelleri emekliye ayırır ve native boşaltma işlemlerinin tamamlanmasını bekler.
Hata/süre aşımında eski renderer tekrar kullanılmaz; elle yeniden deneme gerekir.
Platform eklentisinin çerez, local storage ve cache silmesi uygulanır; IndexedDB
gibi diğer site depolarının veya sunucu oturumunun tamamen silindiği söylenmez.
Genel web sayfasına HA tokenı, native yönetim yetkisi veya TLS istisnası verilmez.

## Albüm kapağı ve medya oturumu

Yerel ses için kullanıcı JPEG/PNG seçer: en fazla 1 MiB, 4096 piksel kenar ve
16 megapiksel. Native kod EXIF yönünü uygular, en fazla 512 piksel / 128 KiB JPEG
üretir; kaynak metadata'sı atılır. Dosya okumasının toplam süresi 10 saniye,
iptal temizliği bir saniyedir. Servis yalnız seçilen kaynağın kimliği ve kapağını
yayımlar; byte dizisi sık durum güncellemelerine taşınmaz. URI'den otomatik kapak
indirme yoktur. Seçili kaynak/stop değişiminde eski kapak uygulanamaz.

Media3'te yalnız getter filtrelemek yeterli olmadığı gerçek MediaSession
regresyonuyla bulundu. `SelectedAudioPlayer`, listener, toplu olay, timeline ve
playlist yayınlarını da aynı seçili metadata üzerinden üretir; stream etiketi,
seçilmemiş embedded art veya özel URI controller'a kaçamaz. Play/pause/seek/stop
kontrolleri bu katmandan geçerek korunur.

## Kontrol kanıtı

- `test/features/ambient/`: gerçek PNG normalizasyonu, byte/piksel/süre sınırları,
  sembolik bağlantı/manifest/hash, geç yazma ve değişen tamponlar, görünürlük/idle,
  bozuk albüm, fotoğraf onayı, %200 yazı ve ekran okuyucu adları.
- `test/features/settings/screen_program*` ve `screen_policy*`: hafta/gece/DST
  kuralları, tercihler, geri yükleme, lifecycle, eski onay ve dar DeX saat popup'ı.
- `test/features/backup/panel_backup_test.dart`: model→şifreli kasa içeriği→geri
  yükleme sınırı, eski yedek override, tüm durable ara durumlarda rollback,
  bozuk kaynak ve fazla web izinlerinin erken reddi. Şifreleme ayrıca mevcut
  `backup_codec_test.dart` tarafından doğrulanır.
- `test/features/web_panel/`: ek kaynaklar, platform kararları, renderer temizleme
  bariyeri, PIN doğrulama, geç native callback ve tekrar deneme.
- `test/features/media/local_audio/` ve Android `audio` testleri: kapak, kaynak
  değişimi, metadata/listener/timeline yayını ve oynatma kontrolleri.
- `test/shared/panel_design_preview_test.dart`: gerçek widgetlardan dört görsel;
  manzara sentetik yerel fixture'dır, kişisel fotoğraf veya canlı cihaz kaydı değildir.

Yönetilen cihaz ayrıntıları [kiosk belgesinde](kiosk-managed-implementation-2026-09-05.md),
sunucu hedefi [Larenor Server kurulumunda](music-assistant-deployment.md), kapsam
ve kalan donanım kabulü [test matrisinde](testing-matrix-2026-09-05.md) izlenir.
