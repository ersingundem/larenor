# Larenor — yararlı özellikler ve uygulama bütünlüğü planı

**5 Eylül 2026 · Kullanıcı onayıyla uygulama sürüyor.**

**Son ürün kararı (5 Eylül):** Music Assistant ve medya uygulamaları tek Larenor Server kurulumuna dahil olacak; servisler arası API bağlantıları otomatik kurulacak. Client yalnız Larenor hesabı ve kullanıcı ayarlarını sunacak. [Kapsam ve kabul ölçütleri](integrated-media-stack.md). Eski ayrı servis kurulum notları bu hedefin tamamlandığını göstermez.

**Güncel takip:** [Yapılanlar, aktif işler ve kalan kuyruk](PROGRESS.md). Bu plan ayrıntılı kapsamı ve önceki teslimlerin kanıtını saklar; en son çalışma durumu takip dosyasındadır.

**Yeni onaylı genişleme (5 Eylül):** Kullanıcı araştırmadaki **60 özelliğin
tamamını seçti**. [Bağımlılıklara göre 60 özellik planı](feature-expansion-plan-2026-09-05.md)
mevcut S06–S09 temellerini ve 10 yeni teslim grubunu birleştirir. Her özellik
planlandı durumundadır; yeni kabul 0/60. Önceki yaklaşık %65 tahmini
genişletilmiş toplamın yüzdesi değildir. Aşağıdaki mevcut açık işler korunur;
son ortak tablet tasarımı, README ve manuel cihaz kabulü en sonda kalır.

**Güncel platform ve mimari kararı:** Client tablet öncelikli bir **Android uygulaması** olarak geliştiriliyor; Samsung DeX aynı uygulamanın harici ekran/değişken pencere desteğidir. Apple Home esintili tasarım korunuyor, native iOS/HealthKit geliştirmesi kapsam dışı. **Larenor Server** veritabanı, hesap, şifreli yapılandırma, güncelleme ve eklenti API'lerini sağlar. Ayrı Server web arayüzü yoktur; tüm admin yönetimi Client içinde, Swagger/OpenAPI belgeli ve Server tarafında yetki kontrollüdür. Yeni S01–S09 sırası ve tamamlanma durumu [Server/Client mimarisinde](server-client-architecture-2026-09-05.md) izlenir. Kurulum en sonda manuel yapılır.

## Uygulama takibi

- [x] 0. Şifreli yapılandırma kasası — Şifreli kasa ve kalıcı imza CI altyapısı eklendi. Birleşik 865 Flutter / 23 Python testi geçti; Build Tools 37 sertifika çıktısı düzeltildi; d2166cd için kalıcı imzalı release APK, sertifika/paket/sürüm doğrulaması CI’da geçti. Gerçek cihaz kabulü bekliyor.
- [x] 1. Ortak gezinme ve arama — 50 yönlendirme/arama/sistem/rutin testi geçti; oda/kaydırma ve pencere boyutu geçişi doğrulandı.
- [x] 2. Bağlantı ve işlem durumları — HA kontrol makbuzları, geçerli veri/erişim ayrımı ve medya kısmi hata kanıtı; diğer servislerin ayrıntılı okuma kanıtı ilgili entegrasyon aşamasında genişletilecek.
- [x] 2a. Netelsan Algan 7 diafon temeli — yerel eşleştirme ekranı, zil/kamera/kapı kontağı ve süreli onayla açma; diafon + yedekleme 106 test geçti. Elektronik mimari belgelendi; tam revizyon, donanım köprüsü ve fiziksel kabul bekliyor.
- [x] 3. Bugün: listeler, takvim, bildirimler — 55 veri/UI testi; HA saat dilimi, UID, kısmi hata, hesap/arka plan sınırları. Cihaz kabulü bekliyor.
- [x] 4. Medyada istekten oynatmaya ortak aşamalar — bağımsız istek/aktarım/import/sezon kanıtı, salt okunur ayrıntı çözümleme ve qBittorrent 4/5 istemci/UI akışı uygulandı. Gerçek medya sunucusu/oynatma kabulü ayrıca bekliyor.
- [x] 5. Film gecesi rutinleri — sahne önizlemesi + doğrulanmış oynatıcı + ayrıca onaylı bitiş sahnesi; 14 akış testi dahil birleşik paket geçti. Sahne kabulü fiziksel cihaz sonucu sayılmıyor; üretim HA'da komut çalıştırılmadı.
- [x] 6. Kontrollü oda eşitleme ve kart düzenleme — alan önizlemesi/eşitleme, elle eklenenleri koruma, kart boyutları/sırası ve görünür kartları oluşturan grid uygulandı; birleşik testler geçti.
- [x] 7. Enerji ve bakım özeti — HA saat diliminde kayıtlı sayaç/istatistikler, pil/çevrimdışı/bakım listesi ve Proxmox kapasitesi; telefon/tablet testleri ve birleşik paket geçti. Fiziksel cihaz kabulü bekliyor.
- [x] 8. Keenetic internet/IP/hız/uptime ve diğer cihazlar için seçilebilir canlı kartlar — beş Keenetic ölçümü, ortak widget seçici ve geçmiş/hava durumu/WebView yaşam döngüsü tamamlandı. Bilinmeyen değerler sıfır sayılmıyor; firmware ve gerçek ağ kabulü bekliyor.
- [ ] 9. Medya hedefleri: Chromecast/Apple TV — aynı kullanıcıya ait Jellyfin TV oturumuna gönderme ve HA medya kaynağı → yetenek doğrulanan Cast/Apple ses hedefi yolu uygulandı. HA kaynağında 60 veri/akış/UI testi geçti. Apple TV video ve fiziksel alıcı kabulü ayrıca bekliyor.
- [ ] 10. Spotify/Apple Music ve HomePod — HA üzerinden Music Assistant kütüphane/arama/kuyruk/oynatma istemcisi uygulandı. Sunucu **Larenor Server** adıyla en sonda manuel kurulacak: CasaOS Docker veya Proxmox üzerinde ayrı Linux VM. Sağlayıcı yetkilendirme ve gerçek HomePod kabulü bekliyor; otomatik canlı kurulum yapılmıyor. Üyelik doğrudan SDK bağlantısı sayılmıyor.
- [ ] 11. Uygulama içinde müzik merkezi — yerel dört sekmeli ekran, sayfalı katalog, açık arama, kuyruk özeti, kaynak/hedef onayı ve çıktı kontrolleri uygulandı. Tam Music Assistant sunucu motoru Android APK içinde çalışmıyor; harici motor gereksinimi açık gösteriliyor.
- [ ] 12. Kilit ekranı/arka plan/güç — Android Media3/MediaSessionService, yerel ses bilgisi/kontrolleri, tek oynatıcı ve Jellyfin video geçişi, güç ayarları uygulandı; 37 Dart ve 14 native test geçti. Seçili yerel kapak görseli eklendi; Media3 listener/timeline üzerinden ham metadata sızması giderildi. Gerçek cihazda ekran kapalı oynatma, OEM güç yönetimi ve kilit ekranı kabulü bekliyor.
- [ ] 13. Samsung DeX — kısa/değişken pencere, kaydırılabilir kenar çubuğu, Ctrl+K/Ctrl+1–4 oda koruması ve native insets/profil gözlemi uygulandı. Widget/native testleri geçti; dock, harici dokunmatik monitör ve gerçek OEM kabulü bekliyor. [Uygulama](window-panel-implementation-2026-09-05.md).
- [ ] 14. Kişisel sağlık/tartı — PIN/özel pencere koruması, ayrı Ölçümler/Kaynaklar ekranı, bounded read-only Health Connect ve açık HA kişi/sensör eşlemesi uygulandı. Özel varlıklar ortak ekranlardan gizlenir; v2 yedeklerde gizleme politikası korunur. Huawei geliştirici onayı ve gerçek cihaz izin kabulü bekliyor; native iOS/HealthKit güncel kapsamdan çıkarıldı. Android minimum API 26 oldu. [Uygulama](wellbeing-implementation-2026-09-05.md).
- [ ] 15. Fully Kiosk Browser — K00–K02 pencere/profil/idle temeli, K03 kaynak izinleri/zoom/paylaşılan web verisi temizleme, K04 açık onaylı yönetilen görev kilidi, K05 yerel fotoğraflı ortam ekranı ve K06 haftalık ekran programı uygulandı. DPC fiziksel kabulü, ileri tarayıcı işlemleri, video/PDF, sensörler ve uzaktan yönetim kalan ayrı dilimlerdir. [WebPanel](web-panel-implementation-2026-09-05.md), [tam matris](kiosk-capabilities-research-2026-09-05.md).
- [x] 16. Superapp araştırması: 12 projenin resmi kaynakları/lisansları karşılaştırıldı; 9 ortak ürün paketi mevcut aşamalara ve kabul testlerine bağlandı. Bkz. [araştırma](superapp-patterns-research-2026-09-05.md). Özelliklerin uygulaması ilgili aşamalarda izlenir.
- [ ] 17. İsteğe bağlı kamera/yüz özellikleri: anonim yaklaşma algılama ile ekran uyandırma, açık kayıt/izin ile kişisel görünüm; cihazda işleme ve silme, donanım/model lisansı/performans değerlendirmesi. Yüz tanıma tek başına yönetici veya kişisel sağlık erişim kilidi olmayacak.
- [ ] Son GitHub frontend skill incelemesi, uçtan uca özellikler arası backend/frontend akış kontrolü, ortak tasarım, test/CI, ekran görüntülü README ve GitHub doğrulaması.

**Yeni test ve adlandırma isteği:** Android uygulaması **Larenor Client**, manuel Docker paketi **Larenor Server**. Mevcut birim/widget/native testlere gerçek Android emülatöründe uçtan uca bağlantı, gezinme, PIN ve şifreli yedek akışları ekleniyor. Özellik bazında kanıt ve fiziksel test boşlukları [test matrisinde](testing-matrix-2026-09-05.md) izlenir. Kurulum işlemi en sona bırakıldı.

**13–15 önceki teslim ve bütünlük kontrolü:** 1.913 Flutter testi, 23 Python testi ve 44 Android native testi geçti. Tam analiz ve 652 Dart dosyasının biçim kontrolü temiz; aşamaya alınmış yaklaşık 775 KB metin değişikliğinin sır taraması temiz. DeX/pencere, özel sağlık, v2 yedek gizlilik ilkesi, ortak WebPanel ve eski dashboard/Arr/Jellyseerr/Jellyfin onayları aynı pakette doğrulandı. Dört yeni gerçek-widget önizlemesi README’ye eklendi. [Tasarım ve akış kontrolü](design-and-flow-review-2026-09-05.md). Bu kanıt fiziksel cihaz veya canlı servis kabulü değildir.

**9–12 müzik/oynatma dilimi yerel kontrolü:** 1.674 Flutter testi, 23 Python testi ve 14 Android native testi geçti. Tam analiz ve 609 Dart dosyasının biçim kontrolü temiz. HA cihaz/işlem ekranlarında eski hesap veya gizlenmiş onayla komut gönderme regresyonları kapatıldı; müzik kütüphane/kuyruk ve telefon/tablet görselleri sentetik verili gerçek widgetlardan üretildi. Fiziksel cihaz veya üretim sunucusunda komut çalıştırılmadı.

**6–8 ve 9’un Jellyfin dilimi yerel kontrolü:** 1.484 Flutter testi ve 23 Python testi geçti. 173 test dosyası aynı pakette çalıştırıldı; 152 ilgili Dart dosyasının biçim/analiz kontrolü ve aşamaya alınmış 1,16 MB değişikliğin sır taraması temiz. Enerji, kart düzenleme ve Keenetic seçici görselleri gerçek Flutter widgetlarından sentetik veriyle üretildi. Canlı HA veya cihazlarda işlem yapılmadı.

**Önceki 4–5. aşama yerel kontrolü:** 1.048 Flutter testi ve 23 Python testi geçti;
tam analiz, 477 dosya biçim kontrolü ve aşamaya alınmış değişikliklerin sır
taraması temiz. Bugün ekranının telefon/tablet açık/koyu görselleri gerçek
Flutter widgetlarından sentetik veriyle üretildi. Bunlar fiziksel cihaz veya
canlı servis kabulü yerine geçmez.

Aşağıdaki araştırma önerileri bu teslimlerin gerekçesidir. Hesap/Assist ve yeni
Frigate entegrasyonu ayrıca değerlendirilmek üzere sonraki
plan olarak kalır; Music Assistant kullanıcıya göre yayın/müzik yolu için araştırılır; mevcut yedi özelliğin tamamlandığı iddiası değildir.

Bu plan mevcut `140eaae` kodunu, Home Assistant 2026.8.3 ile yapılan önceki salt
okunur doğrulamayı ve resmi ürün/API kaynaklarını temel alır. Değer/efor sıralaması
ürün değerlendirmesidir; kullanıcı araştırması veya cihaz benchmark sonucu değildir.
Üretim Home Assistant üzerinde hiçbir kurulum veya değişiklik yapılmadı.

## Yeni öncelik: ayarları yeniden kurulumda koruma

Kullanıcının tekrar token girme sorunu nedeniyle bu iş ilk aşamada uygulandı.
Aşağıdaki tasarımın kod ve testleri `2170ce6` değişikliğinde bulunur; cihazda
kaldır–kur doğrulaması bekler. İki tamamlayıcı teslim:

1. **Kaldırmadan güncelleme:** aynı uygulama kimliği ve kalıcı imza anahtarıyla
   APK üretmek; artan sürüm kodu. CI için kalıcı imza anahtarı sağlandı ve debug/release işleri ayrıldı. Release APK derlendi; Build Tools 37 sertifika çıktı biçimi değişikliğine göre doğrulayıcı
   düzeltildi ve aynı APK üzerinde eski/yeni araçla test edildi. `d2166cd` için Android
   debug ve imzalı release işleri CI’da geçti. Mevcut kurulu
   sürümün imzası ölçülmeden kullanıcıdaki kaldırma gereğinin nedeni kesin
   söylenemez. İmza değişimine geçişten önce mevcut uygulamadan yedek alınmalı.
2. **Yedekle ve geri yükle:** odalar/kartlar/favoriler, tercihler, etkin servisler
   ve kullanıcı seçerse bağlantı token/parolalarını içeren, ayrı güçlü yedek
   parolasıyla şifrelenmiş taşınabilir dosya. Kullanıcı dosyayı sistem Dosyalar
   seçicisiyle uygulama alanı dışında saklar. Yeni kurulumda dosya + yedek parolası
   ile açılır ve sırlar yeni cihazın güvenli deposuna yeniden yazılır. Eski Android
   Keystore anahtarı geri yükleme için gerekmez. Yedek parolası yalnız uygulamanın
   içinde tutulmamalı; unutulursa başka kurtarma anahtarı yokken yedek açılamaz.

İlk sürüm yerel dosya olmalı. Sonraki sürüm aynı şifreli dosyayı NAS/WebDAV veya
kullanıcının seçtiği bulut dosya sağlayıcısına taşıyabilir. Otomatik senkronizasyon
ilk dosya yedeğinin yerine geçmez; kurulum sonrası erişim ve kurtarma ayrıca
çözülmeli. Bu araştırmada token dışa aktarılmadı veya herhangi bir servise yüklenmedi.

**Kapsam:** bilinen yapılandırma alanlarından allowlist; adresler ve tokenlar
aynı servis kaydı içinde bağlı kalır. PIN/deneme sayaçları, WebView çerezleri,
Proxmox geçici ticket/CSRF, loglar ve medya önbelleği yedeğe alınmaz. Yeni cihazda
PIN yeniden belirlenir; Jellyfin cihaz kimliği için aynı kurulum geri yükleme ile
yeni cihaz aktarımı ayrılır. İptal edilmiş veya süresi dolmuş token yedekle
geçerli hale gelmez; o serviste yeniden giriş gösterilir.

**Geri yükleme:** içerik önizlemesi, servis seçimi, mevcut ayarla çakışma kararı,
sürüm/şema doğrulaması; bütün dosya doğrulanmadan hiçbir ayar değiştirilmez.
Uygulama yazmaları durdurulur; yarıda kalan kayıt için kurtarma planı ve sırları
loglamayan hata çıktısı gerekir. Eski bir yedek bekleme süresini kaldırarak mevcut
PIN doğrulamasını aşamamalı; dışa aktarma/geri yükleme ayar kilidinin arkasındadır.

**Kabul testleri:** şifrele–çöz–geri yükle eşitliği; yanlış parola, oynanmış/
kesilmiş dosya ve desteklenmeyen sürümde sıfır değişiklik; boyut/iş maliyeti
sınırları; bozuk/yarım güvenli depo yazmasından toparlanma; yeniden başlatmada
odalar/favoriler/servislerin korunması; farklı cihazda yeni Keystore ile geri
alma; eski token için doğru hata; güncellemede veri korunması. CI'da gerçek
üretim tokenları kullanılmaz. Android emulator ile kaldır–kur–dosyadan geri al
senaryosu, gerçek cihaz testiyle tamamlanmalı.

[Android güncelleme koşulları](https://developer.android.com/google/play/app-updates),
[Android kalıcı kullanıcı belgeleri](https://developer.android.com/training/data-storage/shared/documents-files),
[flutter_secure_storage yedekleme açıklaması](https://pub.dev/packages/flutter_secure_storage)

## Ana karar

Yedekleme ve güncelleme sürekliliğinden sonra en yüksek getiri **ortak gezinme + tek arama + güvenilir veri
ve işlem durumu**. Bunların üzerine günlük ev işlerini eklemek, mevcut on bir dış
servisi daha kullanılabilir kılar. Yeni entegrasyonlar aynı yapıya sonradan katılır.

Mevcut güçlü temeller: ortak Apple Home esintili tema, tek Latin slogan ve logo,
yerel odalar, HA dinamik servis kataloğu, medya kimlik indeksi, seri polling,
yoğun olay birleştirme, PIN, genişletilmiş test/CI paketi. Bunlar yeniden yazılmaz.

Kodda kalan bütünlük boşlukları:

- Ana router üç kök hedef tanıyor: ev, medya, ayarlar. Günlük servis ekranlarının
  önemli kısmına Ayarlar üzerinden gidiliyor; oda/filtre/ayrıntı durumları ortak
  route modeliyle temsil edilmiyor.
- Entegrasyon yönetimindeki `connected` değeri kayıtlı bağlantının varlığına
  dayanıyor; güncel bir sunucu erişim testi değil. Medya servislerinin bazı
  başarısızlıkları boş listeye dönüşebiliyor.
- Oda/cihaz seçicileri, medya araması ve HA eylem araması ayrı. Ortak arama yok.
- Odalar yerel tutuluyor; HA alanıyla isteğe bağlı kalıcı eşleştirme yok.
- Medya kimlik ve kullanılabilirlik temeli var; istekten oynatılabilir dosyaya
  kadar ortak aşama modeli ve kısmi sezon durumu eksik.
- PIN, yerel Ayarlar erişimini koruyor; kişi/servis yetkilendirmesi değil.

## Önerilen ekran düzeni

```mermaid
flowchart TD
    L[Larenor] --> E[Ev]
    L --> M[Medya]
    L --> R[Rutinler]
    L --> S[Sistem]
    E --> B[Bugün · odalar · favoriler]
    M --> K[Kütüphane · istekler · indirilenler · müzik]
    R --> F[Sahneler · ev rutinleri · otomasyonlar]
    S --> H[Bağlantı sağlığı · ağ · sunucular]
    L --- A[Ortak arama · bildirimler · hesap ve ayarlar]
```

Tablet kenar çubuğu ve daraltılmış DeX penceresindeki gezinme aynı dört hedefi
kullanmalı. Telefon için ayrı arayüz geliştirme hedefi yoktur. Son tasarım
geçişi ve README görselleri tabletin yatay/dikey düzenini esas alır.
Ayarlar hesap, entegrasyon yapılandırması ve uygulama tercihlerini içermeli.
Medya oynatma veya VM durumuna bakmak için Ayarlar'a girmek gerekmemeli.
Bağlı olmayan özelliklerde ekranın yeri kaybolmamalı; o ekranda anlaşılır bir
bağlantı başlangıcı bulunmalı. Apple'ın tutarlı tab bar önerisi bu kararı destekler.
[Apple tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)

## Öncelikli iş paketleri

Efor: **K** küçük, **O** orta, **B** büyük; kesin teslim süresi değildir.

| Sıra | İş paketi | Somut kullanım | Efor | Önkoşul |
| --- | --- | --- | --- | --- |
| 1 | Ortak gezinme ve arama | “Salon” ile oda, ışık, TV ve sahneye; film adıyla medya başlığına erişim | O | Route ve arama sonuç sözleşmesi |
| 2 | Ev sağlığı ve işlem durumu | “Jellyfin erişilemiyor”, “son başarılı veri 3 dakika önce”, “komut kabul edildi, cihaz yanıtı bekleniyor” | O | Ortak bağlantı ve action modelleri |
| 3 | Bugün, listeler ve bildirimler | Alışverişe ekle, ev işini tamamla, yaklaşan etkinlikleri ve dikkat gerektirenleri gör | O | İlgili HA to-do/calendar/notification yetenekleri |
| 4 | Medyada baştan sona durum | İstendi → sırada → indiriliyor → içe aktarılıyor → kısmen hazır/oynatılabilir | O | Mevcut medya kimlikleri, sezon kapsamı |
| 5 | Medya–ev rutinleri | Film ayrıntısından seçili sahneyi çalıştır ve oynat; bitiş sahnesi sun | O | Kullanıcının mevcut scene/script seçimi |
| 6 | Kontrollü oda eşitleme ve düzenleme | HA alan değişikliklerini önizle; yerel sıra, gizlenenler ve favoriler korunsun | O–B | Oda şema geçişi ve kaynak alan kimliği |
| 7 | Enerji ve bakım özeti | Günlük tüketim/maliyet, düşük pil, çevrimdışı cihaz, disk/VM kapasitesi | O–B | Doğru sayaç ve istatistik yapılandırması |
| 8 | Hesap, aile ve misafir deneyimi | Kişiye uygun görünüm ve her servis için açık hesap/yetki bilgisi | B | Servis bazında gerçek yetki sınırı |
| 9 | Yazılı Assist; sonra bas-konuş | Komutun sonucu, hatası ve ilgili cihaz aynı ekranda | O / B | Conversation; ses için pipeline/STT/TTS |
| 10 | Music Assistant; sonra Frigate | Müzik ve kamera olaylarını aynı arayüze eklemek | B | Ayrı servisler ve hesaplar |

### 1. Gezinme ve tek arama

Sabit route kimlikleri oda, varlık, medya başlığı ve sunucu nesnesini temsil etmeli.
Evden medyaya gidip dönünce oda seçimi ve kaydırma konumu korunmalı. Uygulama içi
bildirim, arama sonucu ve Android kısayolu aynı hedefi açmalı.

İlk arama yerel kayıtları kullanmalı. İnternet/katalog araması seçildiğinde uzak
sağlayıcılar devreye girmeli; her tuş vuruşunda bütün servislere istek gönderilmemeli.
Cihazı açmakla komutu çalıştırmak ayrı sonuç türleri olmalı. HA Quick Search ve
Homarr Spotlight bu ayrım için yararlı referanslar.
[HA Quick Search](https://www.home-assistant.io/docs/tools/quick-search),
[HA Android kısayolları](https://companion.home-assistant.io/docs/integrations/android-shortcuts/),
[Homarr arama](https://homarr.dev/docs/management/search-engines/)

**Kabul:** Türkçe karakterler, klavye/TalkBack, telefon/tablet, doğrudan bağlantı,
PIN/yetki kontrolü, 5.000 varlıkta arama; eski sorgu yeni sonucu ezmez. Aynı ad
farklı servisteyse sonuçlar kimlikleriyle ayrılır.

### 2. Sağlık ve işlem makbuzu

Bağlantı kaydı, erişim, oturum ve veri güncelliği farklı durumlar olmalı. Ortak
modelde son başarılı okuma, son transport teması, hata türü ve ilgili servis/hesap
bulunmalı. Işığın değeri değişmedi diye eski `last_updated` değeri bağlantı hatası
sayılmamalı. Dashy servis durumu ve gecikmeyi birlikte sunuyor.
[Dashy status indicators](https://dashy.to/docs/status-indicators/)

Komut için “gönderiliyor / sunucu kabul etti / durum doğrulandı / başarısız /
sonuç belirsiz” ayrılmalı. Proxmox'ta UPID görev sonucu, HA'da mümkün olduğunda
context ve durum güncellemesi kullanılmalı. Bir HTTP başarısı fiziksel sonucun
kanıtı değildir. Evrensel geri alma veya belirsiz yazmayı tekrar gönderme yok.
[HA WebSocket API](https://developers.home-assistant.io/docs/api/websocket/)

**Kabul:** 401, 403, ağ kesilmesi, geç yanıt, arka plan/ön plan ve yeniden bağlantı;
çift dokunuş tek istek; çevrimdışı komutlar sonradan kendiliğinden çalışmaz.
Sunucu hatası “kütüphane boş” biçiminde gösterilmez.

### 3. Günlük ev işleri

**Listeler:** `todo.*` üzerinden liste seçme, hızlı ekleme, UID ile tamamlama ve
son tarih. Aynı başlıktaki iki öğe karıştırılmamalı. HA 2026.8.3 item list yolu kullanılır; to-do listeleri ön planda 60 saniyelik
okuma, yeniden bağlantı ve açık işlem sonrası okuma ile yenilenir. Uygun to-do
entegrasyonu gerekli; yerel bildirim okundu durumu bellekte kalır.
[8.3 to-do kaynak](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/todo/__init__.py),
[Local to-do](https://www.home-assistant.io/integrations/local_todo/)

**Bugün:** Takvim, yaklaşan ev işleri ve aktif sayaçlardan seçilebilir kartlar.
Önceki canlı kontrolde Calendar bulunmamıştı; kullanıcı isterse ayrı kurulum
adımı gerekir. Uygulama kapalıyken hatırlatma HA tarafında çalışmalı. Timer süresi
HA kapalıyken dolarsa `timer.finished` açılışta yeniden oynatılmaz; telafi modeli
ayrıca tasarlanmalı.
[Calendar](https://www.home-assistant.io/integrations/calendar/),
[Local Calendar](https://www.home-assistant.io/integrations/local_calendar/),
[Timer](https://www.home-assistant.io/integrations/timer/)

**Bildirim kutusu:** Önce HA persistent notifications, sonra servis uyarıları.
Yerel “okundu” sunucudaki “dismiss” işleminden ayrı olmalı; dismiss bildirimi
HA'dan kaldırır. Bu ekran telefon push altyapısı sağlamaz.
[8.3 bildirim kaynak](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/persistent_notification/__init__.py),
[Kalıcı bildirimler](https://www.home-assistant.io/integrations/persistent_notification/)

**Kabul:** Eşzamanlı liste düzenleme, abonelik yeniden kurma, aynı adlı öğeler,
tüm gün etkinliği, saat dilimi/yaz saati, yinelenen bildirim, hesap değişimi;
salt okunur profilde sunucuya yazan düğmeler yok. Hassas bildirim içeriği ortak
tablette gizlenebilmeli.

### 4–5. Medyanın ev deneyimine bağlanması

Başlık ayrıntısı, arama sonucu, dashboard ve indirme ekranı aynı durum modelini
kullanmalı. Kısmi sezon ayrı bir durum olmalı; Jellyfin'de doğrulanmadan bir
başlık oynatılabilir sayılmamalı. Homarr'ın kısmi/istenmiş/işleniyor ayrımı iyi bir
referans. [Homarr media request search](https://homarr.dev/docs/management/search-engines/#media-request-search)

“Film gecesi” ilk sürümde mevcut scene/script seçimi ve açık kullanıcı başlatması
olmalı. Eylem öncesi hangi cihazların etkileneceği gösterilmeli. Sahne başarısızsa
oynatmanın devam edip etmeyeceği açık olmalı. Bitiş için kullanıcı seçili sahne,
genel otomatik geri almadan daha öngörülebilir. HA sahnelerinin `turn_off` işlemi
yok; geçici snapshot sahneleri kalıcı garanti sağlamaz.
[HA Scenes](https://www.home-assistant.io/integrations/scene/)

**Kabul:** Mevcut sezon tekrar istenmez; kısmi import/hata/retry durumları tutarlı;
aynı rutin iki kez çalışmaz; başka kişinin sonradan değiştirdiği ışık eski bir
snapshot ile habersizce ezilmez. Bu iş Netflix hesabı/DRM oynatması eklemez.

### 6. Oda ve görsel düzenin tutarlılığı

Mevcut yerel odaları koruyarak isteğe bağlı HA `area_id` bağlantısı eklenmeli.
Eşitleme önerisi yeni/çıkan cihazları önizlemeli; alan adı değişince ikinci oda
oluşmamalı, HA alanı silinince yerel oda otomatik silinmemeli. İlk eşitleme yalnız
HA'dan okumalı. Kat ve etiketler filtre/aramanın sonraki genişlemesi olabilir.
[HA Floors](https://www.home-assistant.io/docs/organizing/floors/),
[HA Labels](https://www.home-assistant.io/docs/organizing/labels/)

Kart düzenleyicisi ortak grid, boyut ve görünürlük kuralları kullanmalı.
HA Sections sürükleme/koşullu görünürlük; Homey ise telefon/tablet widget
kişiselleştirmesi için yararlı karşılaştırmalar.
[HA Sections](https://www.home-assistant.io/dashboards/sections/),
[Homey Dashboards](https://support.homey.app/hc/en-us/articles/16732145289116-Create-and-manage-Homey-Dashboards)

Görsel kurallar: tek slogan **Unus Lar, omnem domum servat.**; ortak açık/koyu
palet; aynı sayfa başlığı, boş/hata/yükleniyor düzeni; önem taşıyan aktif durum
renkleri; seçili, işlemde ve erişilemez durumlarını yalnız renkle anlatmama.
Animasyonlar hareket azaltma tercihine uymalı. Ağır blur ve sürekli hareket
performans kabulü olmadan eklenmemeli.

### 7. Enerji ve bakım

Enerji bileşeninin var olması yeterli değil: enerji tercihleri, sayaç istatistikleri
ve maliyet verileri doğru yapılandırılmış olmalı. Önce okuma ekranı: gün/hafta
karşılaştırması, cihaz tüketimi; veri uygunsa güneş/batarya akışı.
[HA 8.3 enerji API](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/energy/websocket_api.py)

**Kabul:** Wh/kWh dönüşümü, sayaç sıfırlanması, eksik zaman aralığı, gün sınırları,
çift sayım. Eksik veri “0 tüketim” veya kesin fatura tahmini olarak sunulmaz.
Disk, VM, düşük pil ve offline uyarıları aynı sağlık kartı dilini kullanır.

### 8–9. Hesaplar, misafir ve Assist

Yerel profil görünümü belirler; gerçek yetki her servisin hesabından gelmeli.
HA yönetici hesabı, Proxmox veya Jellyfin yöneticiliği anlamına gelmez. HA'nın
2026.8.3 normal kullanıcı politikası bütün entity erişimine izin verir: non-admin
hesap tek başına oda/cihaz izolasyonu değildir. PIN ve kart gizleme de bu sınırı
sağlamaz. Güçlü misafir izolasyonu için kısıtlı servis hesabı/politikası veya ayrı
yetki uygulayan gateway gerekir.
[HA permissions](https://developers.home-assistant.io/docs/auth_permissions/),
[8.3 sistem politikaları](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/auth/permissions/system_policies.py)

HA tarayıcıyla giriş, refresh ve revoke akışları incelenmeli; callback/state
koruması tasarlanmalı. Bu sunucu sürümünde PKCE desteği doğrulanmadığı için önceki
roadmap'teki “OAuth/PKCE” tek hazır çözüm gibi ele alınmamalı.
[HA Authentication API](https://developers.home-assistant.io/docs/auth_api/),
[8.3 auth uygulaması](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/auth/__init__.py)

Assist önce yazı, sonra bas-konuş olabilir. Conversation'ın bulunması ses
pipeline'ının hazır olduğunu kanıtlamaz. Genel sohbet komutu cihazları
değiştirebileceği için salt okunur profilde serbest `conversation.process`
çalıştırılmamalı. Kullanılan agent bulutsa veri aktarımı açık gösterilmeli.
[Conversation](https://www.home-assistant.io/integrations/conversation/),
[Assist pipeline](https://developers.home-assistant.io/docs/voice/pipelines/)

## Teslim sırası ve testler

1. **Bütünlük sürümü:** ortak route/gezinme, arama, sağlık ve işlem durumları.
   Test: telefon/tablet geçişi, geri tuşu, deep link/PIN, 401/403, eski veri,
   arama yarışları, çift komut engeli. Mevcut 5.000 varlık stres testleri korunur.
2. **Günlük kullanım sürümü:** Bugün + listeler + bildirim kutusu; medya aşamaları.
   Test: HA 8.3 yetenek keşfi, eşzamanlı değişiklik, saat dilimi, reconnect,
   hesap değişimi ve salt okunur kullanım.
3. **Evle bütünleşme sürümü:** film rutinleri, kontrollü oda eşitleme, enerji.
   Test: kısmi işlem başarısızlığı, izinsiz otomatik geri alma olmaması,
   kayıt geçişleri ve enerji matematiği.
4. **Genişleme:** Music Assistant → Frigate. Hesap/izin altyapısı ve gerçek
   donanım kabulü tamamlanmadan genel yetkili misafir/Assist iddiası yok.

Her dilim aynı CI birim/widget/sözleşme testlerine girer. Sonraki altyapı işi,
mock servislerle Android emulator E2E ve seçilecek gerçek tablette profile-mode
frame/bellek ölçümüdür. Başlangıç, 24 saat kullanım, ağ değişimi, arka plan/dönüş,
büyük yazı ve TalkBack kabulü cihaz belirtilmeden tamamlanmış sayılmaz.

Güncel HA belgeleri 2026.9 özellikleri de içeriyor. Uygulama yetenekleri gerçek
sunucu sürümü ve servis/entity özelliklerinden açmalı; 2026.8.3 için destek
varsayılmamalı. Araştırmada yeni servis kurulmadı ve hesap bağlanmadı.


## Son kullanıcı açıklamaları

- Music Assistant sunucusu **kurulu değil**. Spotify, Apple Music ve YouTube Music
  üyelikleri mevcut. “Hepsi evet” yanıtı sunucu kurulumu olarak yorumlanmamalı.
- Kullanıcı müzik merkezi ve mümkünse sunucu işlevlerinin uygulama içinde
  çalışmasını istiyor. Yalnız harici sunucuya istemci eklenmesi bu talebin tümünü
  karşılamaz; Android/platform/DRM desteği doğrulanıp sınırlar açıkça raporlanmalı.
- Home Assistant üretim kurulumu salt okunur sınırında; uygulama kodu için verilen
  yetki, sunucuya Music Assistant kurma veya gerçek cihazları değiştirme izni değildir.

- Birincil tablet: **Huawei MatePad 11.5 S (2026)**. Global resmi model
  HarmonyOS 4.3 kullanır; kullanıcı cihazındaki build ayrıca doğrulanmalıdır.
  GMS varsayımı yapılmayacak; ağdan hedef kontrolü ve müzik davranışı Huawei,
  genel Android tablet ve Samsung DeX pencerelerinde sınanacak.
  Kaynak: https://consumer.huawei.com/en/tablets/matepad-11-5-s-2026/specs/
- 5 Eylül oturumundaki `adb devices -l` sonucu boş; fiziksel cihaz testi yapılmadı.

## Ek bütünlük denetimi

Kullanıcı, listede düşünülmemiş eksiklerin de giderilmesini istedi. Son kontrolde
yalnız ekran varlığı değil, hesap değişimi, eski veri, belirsiz komut sonucu,
çift tıklama/slider istek yağmuru, arka plan ve geri dönüş, erişilebilirlik,
platform yetenekleri, kişisel veri sınırları ve hata sonrası toparlanma denetlenir.
Sağlayıcının sunmadığı API veya bağlı olmayan fiziksel cihaz için yüzde yüz
uyumluluk iddiası üretilmez; doğrulama sınırı açık tutulur.

Kişisel sağlık kaynaklarının resmi erişim yolları ve kabul kontrolleri:
[Sağlık sağlayıcıları araştırması](wellbeing-provider-research-2026-09-05.md).
