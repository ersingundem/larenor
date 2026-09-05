# Larenor — güncel ilerleme ve iş kuyruğu

**Son güncelleme: 5 Eylül 2026, 12:45 (Türkiye saati).**

**Genel ilerleme tahmini: %60–65.** Bu oran kalan paketlerin büyüklüğüne göre
mühendislik tahminidir; otomatik ölçülen test kapsamı veya cihaz uyumluluk oranı
değildir. Büyük kalan işler S05–S09, ileri kiosk/kamera ve fiziksel kabuldür.

Bu dosya yapılanları, devam eden işleri ve sıradaki paketleri tek yerde izlemek
içindir. Geliştirme sırasında tamamlanan dilim ve doğrulama sonuçları burada
güncellenir; sürekli çalışan bir izleme servisi değildir. Ayrıntılı kapsam için
[ürün planı](product-implementation-plan-2026-09-05.md),
[Server/Client planı](server-client-architecture-2026-09-05.md) ve
[test matrisi](testing-matrix-2026-09-05.md) kullanılır.

GitHub'a gönderilmiş işlerin **anlık CI durumu**
[Actions ekranından](https://github.com/ersingundem/larenor/actions) izlenir.
Bu yerel dosya geliştirme aşamalarında güncellenir; Actions ise çalışan
derlemelerin ve test işlerinin kendi canlı durumunu gösterir.

**Yayın durumu:** `5331f22` tabanından geliştirilen bu Server/Client paketi yerel
doğrulamadan geçti. Yeni paketin GitHub CI sonucu bekleniyor; [Actions](https://github.com/ersingundem/larenor/actions)
üzerinden ilgili commit'in sonucu kontrol edilmelidir. Yerel test başarısı,
GitHub CI veya fiziksel cihaz kabulü olarak sayılmaz.

Önceki `5331f22` commit'inin Android/analiz/güvenlik CI çalışmaları artifact
depolama kotasına takıldı; taramalar bulgu üretmedi. Bu pakette rapor yükleme
hatası açık uyarıyla ayrıldı, güvenlik taramalarının artifact bağımlılığı
kaldırıldı. Asıl test/tarama hataları ve imzalı APK teslim hataları hâlâ engelleyicidir.

## Şu anda çalışılanlar

| İş | Durum | Tamamlanma ölçütü |
| --- | --- | --- |
| Bütünleştirme ve teslim | Tam Flutter/native testleri, analiz ve sır taraması geçti; yeni paketin CI sonucu bekleniyor | GitHub testleri, E2E ve imzalı APK tesliminin gerçek sonucu |
| Gerçek Server imajı doğrulaması | Docker/CI kodu ve yerel politika testleri hazır; barındırılan CI çalışması bekliyor | amd64/arm64 gerçek derleme/başlatma/imza testi; iki mimari başarılı olmadan ortak imaj etiketi yayımlanmaması |

## Uygulananlar

“Uygulandı” kod ve belirtilen test kapsamını anlatır. Gerçek cihaz gerektiren
kabul işleri aşağıda ayrıca tutulur.

| Alan | Uygulanan kapsam |
| --- | --- |
| Ortak kullanım | Gezinme/arama, oda ve kart düzenleme, Bugün, enerji/bakım, bağlantı ve işlem sonucu ayrımı |
| Medya ve ağ | Ortak medya aşamaları, film gecesi rutinleri, Keenetic ölçüm kartları, Jellyfin/HA üzerinden yetenek kontrollü oynatma hedefleri |
| Tablet ve kiosk temeli | Değişken pencere/DeX düzeni, PIN ve özel sağlık görünümü, WebPanel kaynak/zoom ayarları, yönetilen görev kilidi, yerel fotoğraflı ortam ekranı ve haftalık program |
| Server hesapları | API ve veritabanı, ilk parola değişimi, dönen oturumlar, yönetici yetkileri, kullanıcı/oturum/denetim API'leri |
| Yapılandırma kalıcılığı | Şifreli yerel yedek; Server hesabıyla kasa önizleme, seçili bağlantı bilgilerini kaydetme ve yeniden kurulumdan sonra geri yükleme akışı |
| Client yönetici ekranları | Hesap, kullanıcı/rol, geçici parola, oturumlar ve denetim; son yöneticiyi koruma ve geçersiz kalan onayları kapatma |
| Güncelleme altyapısı | APK paket/imza/hash/sürüm doğrulaması, sürüm API'leri, indirme ve Android kurucusuna geçiş; ayrı yayın kimliğiyle koşullu CI teslimi |
| Otomatik güncelleme uyarısı | Ön planda açılış/dönüş ve 15 dakika aralıklı kontrol; oturumluk kapatma, PIN korumalı bağlantı, hesap/rota/arka plan sınırları. İlgili 92 test geçti |
| Server Docker/CI kodu | Sabitlenmiş bağımlılıklar ve imza aracı, root olmayan süreç, ayrı veri/anahtar depoları; iki mimari için test sonrası imaj yayını. Gerçek imaj çalışması CI'da bekliyor |
| Server ekran tasarımı | Altı gerçek-widget önizlemesi incelendi; admin seçili sekmesi belirginleştirildi; test matrisi ve README'ye görseller eklendi |
| Bağımsız kod incelemesi | Server başlatma/kaynak/lisans/sürüm sözleşmeleri, Client güncelleme uyarısı ve Docker/CI akışında uygulanabilir ek bulgu çıkmadı; gerçek imaj çalışması yerine geçmez |
| CI rapor kotası düzeltmesi | Test kanıtı yükleme hataları görünür uyarı üretir; Gitleaks/OSV taramaları artifact kotasına bağlı değildir. Gerçek tarama hatalarının engelleyici kaldığı test edildi |
| Lisans ve kaynak | AGPL-3.0-only, üçüncü taraf bildirimleri, uygulama içi lisans ekranı ve Server kaynak/lisans API'si |
| Geliştirme becerileri | İstenen frontend/CI seçkisinden 27 beceri kuruldu; 81 dosyanın kaynağı ve hash'i kaydedildi. Kurulum uygulama özelliği sayılmaz |

## Sıradaki geliştirme paketleri

1. **S05 — Hizmet yönetimi:** Client admin bölümüne hizmet bağlantıları ve
   kurulum/iş durumu yönetimini ekleme; Server tarafında yetki ve denetim kaydı.
2. **S06 — Eklenti sistemi:** Katalog, kurulum önizlemesi, sınırlandırılmış Linux
   kurulum işçisi ve başarısız işlemlerden toparlanma.
3. **S07 — CasaOS ve medya servisleri:** Mevcut servisleri bağlama; yeni servisleri
   kurma/yapılandırma. Music Assistant, Server'ın yönettiği ayrı servis olacak.
4. **S08 — Merkezi entegrasyonlar:** HA, medya ve ağ servislerini sırayla Server
   adaptörlerine taşıma; Client yetkileri, ortak hata/durum ve widget sözleşmeleri.
5. **Kalan ürün kapsamı:** İleri kiosk tarayıcı/video/PDF/sensör/uzaktan yönetim;
   Apple TV video ve müzik sağlayıcı akışları; isteğe bağlı yerel kamera/yüz
   özellikleri. Ayrıntılı sınırlar ürün planı ve ilgili yetenek matrislerinde.
6. **S09 — Kurulum ve son bütünlük:** Gerçek Server + yönetilen servislerin ortak
   kurulum/yedek/geri yükleme paketi; özellikler arası backend/frontend akışları,
   performans/stabilite/güvenlik kontrolleri ve yeni görsellerle README.

## Manuel kurulum ve fiziksel kabul

- CasaOS Docker veya Proxmox Linux VM kurulumu **en sonda kullanıcıyla manuel**
  yapılacak. Güncel geliştirme ev sunucusuna kurulmuş değildir.
- Spotify, Apple Music ve YouTube Music yetkilendirmesi; Music Assistant,
  HomePod, Chromecast ve Apple TV üzerinde gerçek arama/kuyruk/oynatma kabulü.
- Huawei MatePad 11.5 S 2026 ve diğer tabletler; Samsung DeX, dokunmatik monitör,
  ekran kapalı ses, kilit ekranı ve OEM güç davranışları.
- Sağlık sağlayıcısı/cihaz izinleri, yönetilen kiosk için fiziksel cihaz kabulü.
- Netelsan Algan 7'nin tam donanım revizyonu ve elektronik köprü; gerçek zil,
  kamera ve kapı davranışı. Yazılım temeli fiziksel bağlantı tamamlandı demek değildir.
- Gerçek Server üzerinden aynı imzalı Client yükseltmesi ve yeniden kurulumdan
  sonra hesap/kasa geri yükleme kabulü.

Üretim Home Assistant üzerindeki kontroller salt okunur kalır. Native iOS
geliştirmesi güncel kapsam dışındadır.

## Son test kanıtı

| Çalıştırma | Sonuç | Sınır |
| --- | --- | --- |
| Tam Server API/depolama/sürüm paketi | **154 geçti** | Sentetik servisler ve gerçek Java APK imza doğrulayıcısı; canlı ev sunucusu değil |
| Bütün Python araç/politika testleri | **97 geçti** | Yayın, container, imzalama, güvenlik ve tarama hata kodları dahil; gerçek sunucuya yayın yapılmadı |
| Client hesap/admin/kasa ilgili paketi | **80 geçti** | Birleşik ilgili kapsam; alt test sayıları buna tekrar eklenmez |
| Client güncelleme/gezinme ilgili paketi | **92 geçti** | 21 yeni uyarı testi dahil; yukarıdaki kapsamlarla örtüşebilir |
| Server ekran önizlemeleri | **6 geçti**; admin görünüm regresyonu **15 geçti** | Gerçek Flutter widgetları ve sentetik veriler; export ve CI modları ayrı doğrulandı |
| Tam Flutter paketi | **2.297 geçti** | Yeni Server ekranları ve otomatik uyarı dahil; sentetik unit/widget kapsamı |
| Tam Android native paketi | **98 geçti**, 18 test paketi | Yeni güncelleme/imza testleri dahil; fiziksel kurulum/oynatma kabulü değil |
| Android API 35 emülatör E2E | **4 uygulama + 4 platform senaryosu geçti** | Sentetik HA ve emülatör; fiziksel cihaz/sunucu uyumluluğu garantisi değil |

Test dosyaları, kapsam ve açıklar [test matrisinde](testing-matrix-2026-09-05.md).
Test adetleri farklı zaman ve kapsamları temsil eder; toplanarak başarı oranı
üretilmez. GitHub CI sonucu yeni commit sonrasında ayrıca kaydedilecektir.

## Güncelleme kaydı

- **12:45:** Artifact kotası CI düzeltmesi eklendi; dört yeni tarama hata
  yayılım testiyle araç paketi 97/97 geçti. Yayın paketi yerelde doğrulandı;
  GitHub CI ve gerçek Server imajı sonucu ayrı bekleniyor.
- **12:38:** Tam 2.297 Flutter ve 98 native test geçti; analiz temiz. Kullanıcının
  ilerleme sorusu için genel kapsam tahmini %60–65 olarak eklendi. CI rapor
  yükleme sorunu çözülmeden bulut CI başarılı olarak işaretlenmiyor.
- **12:33:** Güncelleme uyarısı, altı ekran önizlemesi ve Docker/CI kodu tamamlandı.
  93 Python araç testi ve tüm workflow'larda actionlint geçti. Birleşik son
  testler ve bağımsız kod incelemesi sürüyor; gerçek imaj doğrulaması bekliyor.
- **12:27:** Tek takip dosyası oluşturuldu; güncelleme uyarısı, Server imajı,
  ekran önizlemeleri ve son bütünleştirme aktif işlere alındı. Yerel çalışma ile
  yayımlanmış commit ve fiziksel kabul ayrıldı.
