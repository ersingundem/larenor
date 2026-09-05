# Larenor — güncel ilerleme ve iş kuyruğu

**Son güncelleme: 5 Eylül 2026, 13:49 (Türkiye saati).**

```text
Genel kapsam  █████████████░░░░░░░  ≈ %65
```

**Yaklaşık %35 kapsam kaldı.** Bu oran kalan paketlerin büyüklüğüne göre
mühendislik tahminidir; otomatik ölçülen test kapsamı veya cihaz uyumluluk oranı
değildir. Tamamlanan görevleri sayarak hesaplanmaz; büyük paketler ayrıntılandıkça
değişebilir. Büyük kalan işler S05–S09, ileri kiosk/kamera, son tablet tasarım
geçişi ve fiziksel kabuldür.

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

**Yayın durumu:** Son gönderilen commit `773a02e`; ana özellik paketi `473132e`.
[Güvenlik CI](https://github.com/ersingundem/larenor/actions/runs/33960748048)
son commit'te başarılı. Önceki [Android Build](https://github.com/ersingundem/larenor/actions/runs/33960748149)
E2E adımında emülatör sürecini kaybetti; gerçek neden kesinleşmedi. CI bellek
sınırları ve hata tanı çıktısı bu pakette eklendi.
[Server Container Build](https://github.com/ersingundem/larenor/actions/runs/33960748157)
iki mimariyi derledi ve gerçek APK imza kontrolünü geçti, ancak yeniden başlatma
sağlık kontrolü başarısız. Testte eski geçici portun kullanılması hatası sentetik
olarak doğrulandı ve düzeltildi; CI hatasının kesin nedeni yeni koşum ve ek
tanı çıktısıyla doğrulanacak. Yayın engelli. S05 ve bu durum güncellemesi henüz
commit edilmedi. Yerel dosya ile GitHub görüntüsünün zaman damgası farklı olabilir.
CI tamamlanması fiziksel cihaz kabulü anlamına gelmez.

Önceki `5331f22` commit'inin Android/analiz/güvenlik CI çalışmaları artifact
depolama kotasına takıldı; taramalar bulgu üretmedi. Bu pakette rapor yükleme
hatası açık uyarıyla ayrıldı, güvenlik taramalarının artifact bağımlılığı
kaldırıldı. Asıl test/tarama hataları ve imzalı APK teslim hataları hâlâ engelleyicidir.

## Şu anda çalışılanlar

| İş | Durum | Tamamlanma ölçütü |
| --- | --- | --- |
| S05 hizmet yönetimi ve denetimi | Client admin ekranı, şifreli Server kayıtları ve 17 servis türünün kontrol yolu uygulandı; 2.333 Flutter, 529 Server ve 114 araç testi geçti. Yayın kontrolü sürüyor | Son sır taraması, GitHub CI ve yayımlanan paketin doğrulanması |
| S06 eklenti kataloğu | Katalog ve kurulum planı modelleri yazılıyor; işçi/API kurulumu henüz yok | Sabitlenmiş imajlar, doğrulanmış mimariler, açık kaynak/lisans bilgisi ve deterministik kurulum önizlemesi |
| Gerçek Server imajı doğrulaması | Derleme/ilk başlatma/gerçek APK imzası geçti. Yeniden başlatma testinin geçici port varsayımı düzeltildi; yeni CI koşumu bekliyor | İki mimaride kalıcılık ve yeniden başlatma dahil bütün smoke testi başarılı olmadan ortak imaj etiketi yayımlanmaması |

## Backend, Music Assistant ve HomePod: bugün nerede?

| Özellik | Çalıştığı yer / mevcut durum | Eksik adım |
| --- | --- | --- |
| Hesap, parola, oturum, rol, kullanıcı yönetimi | Larenor Server API ve veritabanında uygulandı | Gerçek sunucuya manuel kurulum |
| Kasa ve güncelleme sürümleri | Server'da şifreli kasa ve sürüm API'leri; Client geri yükleme/güncelleme akışları mevcut | Gerçek imzalı Client yükseltmesi ve yeniden kurulum kabulü |
| Entegrasyon bağlantı kayıtları | S05 şifreli Server kaydı, Client admin ekranı ve 17 türün kontrol yolu uygulandı | Son birleşik test, CI ve yayın; gerçek servis kabulü |
| HA, medya ve ağ komutları | Mevcut kontrollerin çoğu hâlâ Client adaptörlerinde | S08 ile gerçek veri ve komut akışlarını Server'a taşıma; yalnızca token saklamak bu taşıma sayılmaz |
| Music Assistant | Client müzik ekranı, ayrı Docker paketi ve yeni Server token/sürüm kontrolü var; ev sunucusuna kurulmadı | Gerçek Larenor Server paketine ayrı yönetilen servis olarak bağlama; sağlayıcı ve oynatıcı yönetimi |
| HomePod / AirPlay | Music Assistant üzerinden hedef kapsamda; keşif, eşleştirme, kuyruk, ses ve oynatma akışları tamamlanıp doğrulanacak | Sağlayıcı oturumları, aynı ağda keşif/eşleştirme, gerçek ses/grup/yeniden bağlanma testleri |

**Backend taşıması henüz tamamlanmadı; Music Assistant şu anda Larenor Server
tarafından kurulmuş/yönetilen bir servis değil.** Eski
`deploy/larenor-server/compose.yaml` yalnızca Music Assistant bileşenini çalıştırır;
Python Larenor Server API'sinin yerini tutmaz. Ortak pakette bu isim ayrımı
düzeltilecek. Ayrıntı: [Music Assistant kurulum planı](music-assistant-deployment.md).
HomePod için upstream [AirPlay desteği](https://www.music-assistant.io/player-support/airplay/)
mevcuttur; Larenor üzerinden gerçek cihaz uyumluluğu henüz doğrulanmadı.

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
| Merkezi hizmet bağlantıları | 17 tür için şifreli kayıt, ekle/düzenle/unut/kontrol; hizmete uygun giriş alanları. HA, medya ve ağ komutlarının tamamının Server'a taşındığı anlamına gelmez |
| Güncelleme altyapısı | APK paket/imza/hash/sürüm doğrulaması, sürüm API'leri, indirme ve Android kurucusuna geçiş; ayrı yayın kimliğiyle koşullu CI teslimi |
| Otomatik güncelleme uyarısı | Ön planda açılış/dönüş ve 15 dakika aralıklı kontrol; oturumluk kapatma, PIN korumalı bağlantı, hesap/rota/arka plan sınırları. İlgili 92 test geçti |
| Server Docker/CI kodu | Sabitlenmiş bağımlılıklar ve imza aracı, root olmayan süreç, ayrı veri/anahtar depoları; iki mimari ve gerçek APK imza kontrolü geçti. Yeniden başlatma testi düzeltilene kadar imaj yayını engelli |
| Server ekran tasarımı | Altı gerçek-widget önizlemesi incelendi; admin seçili sekmesi belirginleştirildi; test matrisi ve README'ye görseller eklendi |
| Bağımsız kod incelemesi | Server başlatma/kaynak/lisans/sürüm sözleşmeleri, Client güncelleme uyarısı ve Docker/CI akışında uygulanabilir ek bulgu çıkmadı; gerçek imaj çalışması yerine geçmez |
| CI rapor kotası düzeltmesi | Test kanıtı yükleme hataları görünür uyarı üretir; Gitleaks/OSV taramaları artifact kotasına bağlı değildir. Gerçek tarama hatalarının engelleyici kaldığı test edildi |
| Lisans ve kaynak | AGPL-3.0-only, üçüncü taraf bildirimleri, uygulama içi lisans ekranı ve Server kaynak/lisans API'si |
| Geliştirme becerileri | İstenen frontend/CI seçkisinden 27 beceri kuruldu; 81 dosyanın kaynağı ve hash'i kaydedildi. Kurulum uygulama özelliği sayılmaz |

## Sıradaki geliştirme paketleri

| Sıra | Paket / durum | Somut teslim ve bitti sayılma ölçütü |
| --- | --- | --- |
| 1 | **S05 — Hizmet yönetimi · yerelde uygulandı, yayın kontrolünde** | Client admin ekranından bağlantı ekle/düzenle/unut/doğrula; şifreli Server kaydı, altı açık doğrulama durumu, yetki/oturum/çakışma testleri. Servis kurulumu S06'da |
| 2 | **S06 — Eklenti sistemi · katalog aşaması başladı** | Sürümlü katalog, kurulum önizlemesi, kalıcı iş durumu, sınırlı Linux işçisi; başarısız kurulumdan toparlanma ve yetki testleri |
| 3 | **S07 — CasaOS ve Music Assistant · sırada** | Mevcut servisleri bağlama veya yeni servis kurma; Music Assistant'ı ayrı servis olarak ortak pakete alma; durum/sürüm/yedek ve sağlayıcı yapılandırma akışları |
| 4 | **S08 — Merkezi entegrasyonlar · sırada** | Önce HA, ardından medya ve ağ adaptörleri; Client isteklerinin Server'dan geçmesi, yetkiler, olay akışı, hata ve widget sözleşmeleri. Client'ta kalan doğrudan yolları açıkça belgeleme |
| 5 | **Kalan ürün yetenekleri · sırada** | İleri kiosk ve kamera seçenekleri, Apple TV video, müzik sağlayıcıları ve HomePod kuyruk/grup/oynatma; yetenek matrisindeki desteklenmeyen durumları açık gösterme |
| 6 | **S09 — Ortak kurulum ve bütünlük · sırada** | Gerçek Server + ayrı yönetilen servisler için kurulum/yedek/geri yükleme; özellikler arası akışlar, hata kurtarma, performans/güvenlik ve CI testleri |
| 7 | **Son arayüz geçişi · işlevler tamamlanınca** | Apple tasarım ilkeleriyle ortak renk, tipografi, kart, gezinme, form ve diyalog sistemi; Dashboard, Media, Settings ve Server panelleri aynı düzende. Tek slogan korunacak |
| 8 | **Tablet / DeX görsel kabul ve README · en son** | Huawei MatePad 11.5 S 2026 ve diğer tabletler, yatay/dikey yön, yeniden boyutlanan DeX penceresi, dokunma/klavye erişilebilirliği. Frontend bittikten sonra gerçek tablet görselleri; profesyonel README, ayrı Server/Client kurulumu, doğru GitHub konu etiketleri/açıklama ve insan/AI için açık belge gezinmesi. Telefon için ayrı tasarım hedefi yok |
| 9 | **Manuel kurulum ve fiziksel kabul · kullanıcıyla en son** | CasaOS/Proxmox kurulumu; sağlayıcı girişleri, gerçek HomePod/Chromecast/Apple TV, güç/kilit ekranı, güncelleme/geri yükleme senaryolarının cihazda doğrulanması |

Son tasarım aşamasında Flutter'a uygun Apple tasarım ve erişilebilirlik
becerileri uygulanacak; teknolojiye uymayan web becerileri uygulamaya zorlanmayacak.
README görselleri gerçek tablet düzenini temsil edecek; hazırlanmış taslaklar
çalışan uygulama ekranı gibi sunulmayacak.
Profesyonel README, keşfedilebilirlik ve gerçek kurulum yollarının son kontrolü
için [yayın hazırlık planı](readme-publication-plan.md) eklendi. Etiketler yalnız
gerçek kapsamı anlatacak; yıldız veya AI görünürlüğü artışı garanti edilmeyecek.

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
| S05 dahil tam Server API/depolama/sürüm paketi | **529 geçti** | 13:49 kontrolü; geliştirilmekte olan S06 kataloğu bu yayın kapsamı dışında. Sentetik servisler ve gerçek Java APK imza doğrulayıcısı; canlı ev sunucusu değil |
| Bütün Python araç/politika testleri | **114 geçti** | Yayın, container, imzalama, güvenlik ve CI hata kapıları dahil; yeni hosted CI sonucu ayrı bekliyor |
| Client hesap/admin/kasa ilgili paketi | **80 geçti** | Birleşik ilgili kapsam; alt test sayıları buna tekrar eklenmez |
| Client güncelleme/gezinme ilgili paketi | **92 geçti** | 21 yeni uyarı testi dahil; yukarıdaki kapsamlarla örtüşebilir |
| Server ekran önizlemeleri | **6 geçti**; admin görünüm regresyonu **15 geçti** | Gerçek Flutter widgetları ve sentetik veriler; export ve CI modları ayrı doğrulandı |
| Tam Flutter paketi | **2.333 geçti** | Hizmet kayıtları, giriş yöntemi alanları ve ortak Server/Client JSON sözleşmesi dahil; sentetik unit/widget kapsamı |
| Tam Android native paketi | **98 geçti**, 18 test paketi | Yeni güncelleme/imza testleri dahil; fiziksel kurulum/oynatma kabulü değil |
| Android API 35 emülatör E2E | **4 uygulama + 4 platform senaryosu geçti** | Sentetik HA ve emülatör; fiziksel cihaz/sunucu uyumluluğu garantisi değil |

Test dosyaları, kapsam ve açıklar [test matrisinde](testing-matrix-2026-09-05.md).
Test adetleri farklı zaman ve kapsamları temsil eder; toplanarak başarı oranı
üretilmez. GitHub CI sonucu yeni commit sonrasında ayrıca kaydedilecektir.

## Güncelleme kaydı

- **13:49:** S05 tamamlanmış kod dilimi: 17 servis türü, Client admin akışı,
  türüne uygun kimlik bilgisi alanları ve ortak JSON sözleşmesi. Son 2.333 Flutter,
  529 Server, 114 araç testi geçti; analiz ve 747 Dart dosyasının biçimi temiz.
  CI için yeniden başlatma portu ve emülatör kaynak/tanı düzeltmeleri hazır.
  Son sır taraması ve GitHub gönderimi yapılıyor; S06 katalog çalışması ayrı sürüyor.
- **13:39:** Tam 2.327 Flutter testi, 106 araç testi ve analiz geçti. Ortak JSON
  sözleşmesi hem FastAPI hem Dart Client tarafından doğrulandı. Kaynak üretimi
  ve imaj dosya izni düzeltmeleri `773a02e` ile gönderildi. Server gerçek imza
  testini geçti; yeniden başlatma testinin port varsayımı düzeltiliyor. Yeni
  görseller frontend sonrasına bırakıldı; README/etiket/kurulum yayın planı eklendi.
- **13:16:** Yaklaşık %65 ilerleme çubuğu ve dokuz açık teslim adımı eklendi.
  Server'a taşınan hesap/kasa/yayın ile hâlâ Client'ta çalışan entegrasyonlar
  ayrıldı. Music Assistant'ın henüz yönetilen servis olmadığı ve HomePod fiziksel
  kabulünün beklediği açıklandı. Son tasarım ve README için tablet/DeX önceliği
  kaydedildi. S05 CRUD 63 test geçti; son Server CI başlatma hatası inceleniyor.
- **12:47:** `473132e` GitHub'a gönderildi ve uzak dosya doğrulandı. Güvenlik
  CI başarılı; Android ve Server imajı işleri çalışıyor. Yerel takip dosyası bu
  sonucu yansıtır; devam eden yayın kontrollerini geçersiz kılmamak için yalnız
  durum kaydıyla yeni bir `main` commit'i oluşturulmadı.
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
