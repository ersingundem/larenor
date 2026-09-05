# Larenor Client / Server mimarisi

5 Eylül 2026, 15:55 TRT · Kullanıcının onayladığı kapsam; uygulama devam ediyor.

**Güncel takip:** [Yapılanlar, aktif işler ve kalan kuyruk](PROGRESS.md).

## Ürün sınırı

- **Larenor Client:** Tablet öncelikli Android uygulaması. Samsung DeX, aynı uygulamanın değişken pencere ve harici ekran desteğidir; ayrı bir uygulama değildir. Huawei MatePad 11.5 S 2026, dokunmatik monitör ve klavye/fare kabul hedefleri. Apple Home esintili ortak tasarım korunur. Native iOS ve Apple HealthKit geliştirmesi şimdilik kapsam dışıdır; mevcut iOS dosyaları silinmez.
- **Larenor Server:** Linux/CasaOS üzerinde Docker ile çalışan, veritabanı ve eklenti hizmetlerini sağlayan API uygulaması. Kurulum en sonda kullanıcıyla manuel yapılır. Ayrı bir Server web yönetim arayüzü geliştirilmez.
- **Yönetim:** Client içindeki yönetici bölümünden kullanıcı, oturum, bağlantı, eklenti, kurulum işi, yedekleme ve güncelleme yönetimi. Yetki denetimi her API çağrısında Server'dadır; yerel Ayarlar PIN'i server admin yetkisi sağlamaz. Swagger/OpenAPI aynı API sözleşmesini belgeler.
- **Bütünleşik medya/müzik:** Music Assistant ve medya sistemi, tek Larenor Server kurulumunun dahili bileşenleridir. Yeni kurulumda ayrı servis/MA hesabı veya elle API anahtarı/adres eşleştirmesi istenmez. Larenor kurar, bağlar ve denetler; kullanıcı Client'tan ayarları yönetir. [Güncel kapsam ve kabul ölçütleri](integrated-media-stack.md). Bu otomasyon henüz tamamlanmadı.

## Uygulama sırası ve durum

| Paket | Sonuç | Durum |
| --- | --- | --- |
| S01 | FastAPI, SQLite WAL, varsayılan yönetici, ilk parola değişimi, dönen oturumlar, şifreli kasa | Uygulandı; sentetik API/depolama testleri geçti |
| S02 | Android Client sunucu girişi, hesap/rol, oturum yenileme, kasa önizleme/geri yükleme | Uygulandı; birim/widget akışları geçti |
| S03 | İmzalı Android APK doğrulama, güncelleme bildirimi, indirme ve sistem kurulum akışı | Uygulandı; ilgili 92 Client testi geçti. Gerçek sunucu/cihaz yükseltme kabulü bekliyor |
| S04 | Release yayın API'si, CI teslimi, saklama ve aynı imzayla güncelleme testi | API ve koşullu CI teslimi hazır; ev sunucusuna teslim/fiziksel güncelleme bekliyor |
| S05 | Client yönetici paneli; kullanıcı/oturum, hizmet bağlantıları ve denetim kayıtları | Şifreli hizmet CRUD, 17 tür kontrol adaptörü ve Client ekranları uygulandı; uzak güvenlik/Server CI geçti. Android E2E ve gerçek servis kabulü açık |
| S06 | Katalog, gereksinim önizlemesi, kalıcı işler ve sınırlandırılmış Linux işçisi | Katalog/şifreli önizleme, salt okunur gereksinim işi/geçmişi, Linux IPC ve Client akışı uygulandı. Gerçek kurulum ve otomasyon henüz kapalı |
| S07 | Tek Larenor kurulumunda dahili medya/müzik bileşenleri ve otomatik API eşleştirmesi; mevcut CasaOS bağlantıları isteğe bağlı | S06 sonrasında |
| S08 | HA/medya/ağ bağlantılarını Server'a taşıyan yetkili servis adaptörleri | S05 sonrasında, servis servis |
| S09 | Otomatik kurulum paketi, yedek/geri yükleme, API/Client bütünlük ve fiziksel kabul | Son aşama |

Bir satırın geliştirme sırasında olması, tamamlandığı veya gerçek ev cihazlarında doğrulandığı anlamına gelmez. Mevcut yerel HA bağlantısı ve şifreli dosya yedeği, Server akışı tamamlanırken kullanılabilir kalır. [Genel kuyruk](product-implementation-plan-2026-09-05.md), [test matrisi](testing-matrix-2026-09-05.md).

[60 özellik fikrinin](feature-candidates-2026-09-05.md) tamamı kullanıcı
tarafından seçildi. [Genişleme planı](feature-expansion-plan-2026-09-05.md)
S06 bileşen yaşam döngüsü, S08 ortak kimlik/yetki/olay ve S09 yazılım kurtarma
temellerini 10 teslim grubuna bağlar. Çoklu ev kimliği, içerik gizliliği ve
dosya/medya aktarımı erken ortak sözleşmelerdir; tam federasyon sonra gelir.
Yeni özellik kabulü 0/60; eski yaklaşık %65 yalnız önceki kapsamın tahminidir.

[Server Docker paketi](server-container.md) `09729be` için
[iki mimarili yayın CI'ını](https://github.com/ersingundem/larenor/actions/runs/33964170947)
geçti; amd64/arm64 imajları yayımlandı. Yeni salt okunur iş/IPC/Client paketi
`5c6b83b` yerel doğrulamanın kod tabanıdır. Yerelde 2.477 Flutter, gerçek Java/apksig dahil
921 Server ve 157 araç testi geçti; tam Flutter analizi temiz. Yeni paket
için CI/imaj başarısı veya bütünleşik medya kurulumu iddiası yoktur. Güncel
uzak Android E2E başarısızlığı ve ayrıntılı sınırlar [ilerleme kaydındadır](PROGRESS.md).

## Hesap, oturum ve yapılandırma

**B3 kimlik temeli:** `GET /api/v1/context` hazır kullanıcıya kalıcı Core/ev
kimliğini verir. Ana DB şeması 3; eski 1→2→3 geçişi ve kimliğin kasa anahtarıyla
HMAC bağı aynı başlangıç işlemi içinde doğrulanır. Yeni modülde 28, eski
migration ile 31 test geçti; bozuk mevcut kimlik otomatik üretilmez.
[Sözleşme ve kanıt](core-context-implementation-2026-09-05.md).
Bu dilim merkezi HA/medya adaptörlerini, Client önbelleğini veya çoklu ev
yetkisini henüz taşımaz.

İlk kurulum tek `admin` hesabı oluşturur. Rastgele ilk parola yalnızca özel izinli yerel bootstrap dosyasına yazılır; sabit parola, kaynak kodda parola ve logda token bulunmaz. İlk girişte parola değişmeden kasa, eklenti veya yönetim API'si kullanılamaz. Parolalar Argon2id ile hash edilir.

Access token kısa ömürlüdür; refresh token tek kullanımla döner, veritabanında yalnız hash'i tutulur. Tekrar kullanılan refresh token ilgili cihazın oturum ailesini iptal eder. Parola değişimi önceki oturumları iptal eder. Client session bilgisini Android güvenli deposunda saklar; giriş parolasını saklamaz. Giriş/çıkış veya Server adresi değişimi eski istek ve indirme sonuçlarını geçersiz kılar.

İlk veritabanı SQLite WAL'dır. Ev sunucusu için tek servis ve atomik işlemlerle başlar; veri erişimi modüllerin dışına taşmaz. Kasa AES-GCM ile şifrelenir; anahtar veritabanından ayrı, özel izinli dosyadadır. Var olan DB'nin anahtarı kayıpsa yeni anahtarla sessizce devam edilmez. Anahtar, DB ve medya servis verilerinin tutarlı yedeği kurulum paketinin parçasıdır.

Kasa aktarımı mevcut `BackupSnapshot` v2 doğrulamasını kullanır: gizlilik, ayarlar, dashboard ve seçilen bağlantılar. İlk aşama açık önizleme ve revizyon kontrollü kayıt/geri yüklemedir; eşzamanlı değişiklik sessizce ezilmez. Kasa kaydı çalışır servis bağlantısı sayılmaz. Android kaldırıldıktan sonra Server'a tekrar girişle yapılandırma geri alınabilir; yerel fotoğraflar, platform izinleri ve cihaz PIN'i otomatik geri taşınmaz.

## API sözleşmesi

Sürüm öneki `/api/v1`. Reverse proxy altında bir yol önekiyle kurulabilir. Token URL/query içinde taşınmaz. JSON hatası `{error:{code,message}}`; hata mesajlarında sır veya ham exception bulunmaz. İstek/yanıt boyutu, timeout ve eşzamanlılık sınırları vardır.

| API | Yetki / davranış |
| --- | --- |
| `GET /health` | Servis/API sürümü; sır veya cihaz envanteri yok |
| `GET /source` | Kaynak/lisans, paket sürümü ve varsa dağıtım commit'i; herkese açık |
| `POST /auth/login` | Kullanıcı/parola/cihaz adı; access/refresh ve kullanıcı rolü |
| `POST /auth/refresh` | Tek kullanımlık refresh; yeni token çifti |
| `GET /auth/me` | Geçerli oturum ve güncel kullanıcı |
| `POST /auth/password` | Mevcut/yeni parola; eski oturumlar iptal edilir |
| `POST /auth/logout` | Geçerli oturumu kapatır |
| `GET /vault` | Kendi kasası ve revizyonu; ilk parola değişimi gerekir |
| `PUT /vault` | `expectedRevision` ile yazma; çakışmada 409 |
| `GET /client/releases/latest` | Platform/channel filtresi; yoksa 204 |
| `GET /client/releases/{versionCode}/apk` | Yetkili, doğrulanmış Client paketi |
| `/admin/*` | Server'da doğrulanan admin rolü; yetkisiz kullanıcı 403 |

Bağlantı durumları, API ve saklama davranışı:
[Merkezi hizmet bağlantıları](server-service-connections.md).

Kullanıcı/oturum/denetim ve üç aşamalı Client yayın API'leri uygulandı.
`/admin/services` bağlantı listeleme/ekleme, `/{id}` revizyon kontrollü
düzenleme/unutma ve `/{id}/check` doğrulama route'ları yerelde eklendi;
Client/servis adaptörleriyle bütünleştirildi. Katalog, önizleme ve aşağıdaki
salt okunur iş API'leri de uygulandı; kurulum işleri ve sunucu yedekleme API'si
henüz yoktur. OpenAPI şeması gerçek route modellerinden üretilir;
plan maddesi henüz çalışan endpoint anlamına gelmez.

## Güncelleme dağıtımı

CI, aynı commit'in analiz/birim/native/Android E2E kontrollerinden sonra mevcut kalıcı imzayla Client APK üretir. Yayın kaydı paket adı, artan sürüm kodu, minimum Android sürümü, imza sertifikası, APK SHA-256, boyut ve commit içerir. Yayın kimliği normal kullanıcı oturumundan ayrıdır ve sadece release yüklemeye yetkilidir.

Client Server'dan yeni sürümü öğrenir; açık işlemle indirir ve kurar. İndirilen APK'nın kriptografik imzası, kurulu uygulamanın gerçek imzası, paket kimliği, sürümü, boyutu ve hash'i doğrulanır. Manifestte yazılı hash/imza tek başına yeterli değildir. Android sistem kurulum onayı ve gerekiyorsa bu uygulama için kaynak izni kullanılır. Normal Android uygulaması için sessiz kurulum varsayılmaz.

CI'ın özel ev ağına erişimi kurulum aşamasında seçilir: erişilebilir HTTPS yayın adresi veya sınırlandırılmış yerel aktarım işçisi. GitHub bulut runner'ının özel LAN'a kendiliğinden ulaşabildiği varsayılmaz. CI kimlik bilgileri henüz sağlanmadı ve ev sunucusunda kurulum yapılmadı.

Normal Server komutu bütün hesap/yönetim/kasa/yayın route'larını kaydeder. Yayın kimliği veritabanının dışında `publisher.token` dosyasında oluşturulur. Android CI'da `LARENOR_RELEASE_SERVER_URL` değişkeni ayarlıysa, `LARENOR_RELEASE_PUBLISH_TOKEN` sırrıyla yalnız testleri geçen, imzalanmış, güncel main APK'sı yüklenir; adres boşsa adım çalışmaz. Java/apksig doğrulayıcı çalışmıyorsa yayın reddedilir. Sürüm ve gerçek imza regresyonları son **921 testlik Server koşumuna** dahildir; Client ve yayın aracı kanıtları [test matrisinde](testing-matrix-2026-09-05.md) ayrı kapsamlarla kaydedilir.

## Eklenti ve CasaOS yönetimi

Eklenti bildirimi kimlik/sürüm, yetenekler, yapılandırma şeması, port/disk gereksinimleri, sağlık kontrolü, sabitlenmiş imaj ve desteklenen mimarileri taşır. Başlangıç kataloğu Jellyfin, Seerr, Sonarr, Radarr, qBittorrent ve Music Assistant hedefler. Dış servisin lisansını veya yetki kurallarını değiştirmez.

Yeni ürün akışı tek Larenor Server kurulumunda dahili bileşenlerin otomatik
hazırlanmasıdır; kullanıcı ayrı uygulama kurmaz veya API anahtarlarını birbirine
girmez. Mevcut dış servise isteğe bağlı bağlanmak ayrı bir akıştır. Bugünkü
katalog ve gereksinim önizlemesi bu hedefin incelenebilir temelidir; kurulum
başlatmaz. Mevcut CasaOS container/veri dizinine otomatik sahiplik alınmaz.

### Uygulanan salt okunur gereksinim işleri

Client yöneticisi katalogdan ayarları inceler, süreli önizleme oluşturur ve
işçi yapılandırılmışsa gereksinim kontrolü ister. İş geçmişi, olaylar, sonuçlar
ve iptal aynı Client içindedir. PIN/arka plan/hesap değişimi eski etkileşimleri
geçersiz kılar. Belirsiz gönderim sonucunda kullanıcı aynı değişmez istek
kimliğiyle kurtarmayı seçer; otomatik yeni iş oluşturulmaz.

Aşağıdaki yollar `/api/v1/admin/plugins` altındadır ve güncel, ilk parolasını
değiştirmiş yönetici gerektirir:

| Yol | Uygulanan davranış |
| --- | --- |
| `GET /catalog`, `POST /previews` | Sabitlenmiş katalog ve şifreli, süreli gereksinim önizlemesi |
| `GET /jobs/capabilities` | `preflightConfigured` yapılandırmanın varlığını bildirir; erişilebilirlik garantisi değildir. `installAvailable=false` |
| `POST /jobs` | Yalnız `operation: preflight`; önizleme revizyonu, plan hash'i ve kullanıcıya bağlı `requestId` ile 202 kabulü |
| `GET /jobs`, `GET /jobs/{id}` | Yöneticiler için kalıcı iş geçmişi ve ayrıntı; liste en yeniden `before` cursor'ıyla |
| `GET /jobs/{id}/events` | Statik olay kodları; artan `after` sırasıyla sayfalama |
| `POST /jobs/{id}/cancel` | Revizyon kontrollü iptal; çalışan salt okunur kontrolün sonucu geldiğinde iptal tamamlanır |

`queued` ve `running` sonrasında `succeeded`, `failed`, `cancelled` veya
`needs_attention` durumlarından biri kaydedilir. **`succeeded` inceleme
tamamlandı demektir:** sonuçtaki kontroller ayrıca `passed`, `failed` veya
`unknown` olabilir. Kurulum başarı durumu değildir. Platform, izinli veri kökü
ve kapasite okunur; açık v2 işletmeci politikasıyla Docker API/platform
uyumluluğu da okunabilir. Port ve alıcı ağı kontrolleri `unknown` kalır.
İş planı/sonucu şifrelidir; API host yollarını veya ham işçi hatalarını
göstermez. Bir önizleme tek işe bağlanır; kabul edilen iş önizlemenin süresi
dolsa da geçmişte korunur. Bir etkin iş ve 16 kuyruk sınırı vardır.

İşin asıl yöneticisinin revizyonu ve oturum ailesi, kontrol öncesinde ve sonuç
kaydedilmeden önce yeniden doğrulanır. Normal access/refresh yenilemesi işi
bozmaz; rol veya oturum kaybında sonuç yayımlanmaz. İşler oturum temizliğiyle
silinmez. Server yeniden başladığında kalan salt okunur iş bu denetimlerden
sonra devam edebilir; backend çağrısı boyunca DB işlemi açık tutulmaz.

### Dahili işçi ve kalan kurulum sınırı

`larenor-preflight-worker` aynı Server paketinin isteğe bağlı dahili komutudur.
Varsayılan API kurulumunda worker yapılandırılmaz. `LARENOR_PLUGIN_WORKER_SOCKET`
ve `LARENOR_PLUGIN_WORKER_UID` yalnız işletmeci tarafından ayarlanır; Client
serbest host yolu veya Docker seçeneği göndermez. Gerçek peer UID denetimi
Linux Unix socket üzerinde yapılır. Politika dosyası worker'a ait, tek linkli,
`0600` izinli olmalıdır; dizin sahipliği ve yazma izinleri doğrulanır. Geçersiz
ortam/başlatma hataları değerleri yansıtmayan sabit kodlarla reddedilir.

Kapanış yeni işi durdurur, bağlantıları kapatır ve sınırlı süre bekler. Takılı
bir dosya sistemi okuması sürüyorsa başarılı kapanış bildirmez veya ikinci
worker'ın aynı kimliği almasına izin vermez. Var olan socket otomatik silinmez
veya sahiplenilmez; başarısız başlangıç
yalnız o süreçte oluşturulan inode'u temizler. Yeniden başlatmayı engelleyen
eski runtime için işletmeci önce sahibi ve sürecin durmuş olduğunu doğrular.
Ayrıntılı komut/politika ve durdurma sözleşmesi
[işçi belgesindedir](../server/larenor_server/plugins/README.md);
[container sınırları](server-container.md) gerçek dağıtım kabulünden ayrıdır.

Mevcut worker Docker'da değişiklik yapmaz; API süreci ham Docker socket erişimi
almaz. V1 politikası Docker'a bağlanmaz; v2'de açık `docker` nesnesi yalnız
worker'ın sabit `GET /version` kontrolüne izin verir. `docker: null` kontrolü
kapalı tutar. API 1.47/platform uyumu, kurulum veya alıcı kabulü değildir.
Sonraki kurulum dilimi yalnız doğrulanmış katalog, özel kontrol ağı, yönetilen
veri ve kayıtlı onay üzerinden çalışacak; yarım kurulum, sağlık sonucu ve
otomatik API eşleştirmesi ayrıca uygulanıp test edilecek. Client'tan serbest
shell, Compose veya keyfi Python çalıştırma yolu yoktur. Mevcut medya arşivi
ve uygulama verisi kaldırma varsayılanı değildir.

## Gerektiğinde upstream projeleri fork etme

Kullanıcı gerektiğinde CasaOS, medya servisleri ve ileride Home Assistant forklarına izin verdi. İlk adım somut eksikliği API/adaptör veya resmi eklenti yoluyla karşılamaktır; kaynak değişikliği gereken noktada ayrı fork ve küçük patch seti kullanılır. Şu anda bu kapsamda yeni fork oluşturulmadı.

Katalog, servis kimliğini dağıtımdan ayırır: `serviceId`, `distributionId`, `upstreamRepository`, `sourceRepository`, `sourceRevision`, `imageDigest`, `license`, `apiCompatibility`, `configSchemaVersion`, `dataSchemaVersion`. Özgün imaj ve gelecekteki Larenor fork imajı aynı yetenek sözleşmesini uygulayabilir. Client bu ayrımı bilmek zorunda kalmaz; yönetici dağıtım ve kaynak bilgisini görebilir. İmaj değişikliği yönetici onaylı, sürüm sabitlenmiş ve veri geçişi doğrulanmış kurulum işidir.

CasaOS uygulama yaşam döngüsü ayrı [AppManagement projesinde](https://github.com/IceWhaleTech/CasaOS-AppManagement) bulunur. Önce bu servisin ilgili API'si/adaptörü değerlendirilir; yalnız uygulama yönetimi için bütün işletim sistemi arayüzünü çatallamak gerekmeyebilir. Bu, mevcut proje ayrımından çıkan mimari tercihtir. Home Assistant için Core, frontend ve diğer bileşenler [ayrı mimari bileşenlerdir](https://developers.home-assistant.io/docs/architecture_index/); ileride Core fork etmek bütün dağıtımı fork etmekle eş tutulmaz. Larenor HA REST/WebSocket sözleşmesi ve yetenek sorgulamasıyla çalışır; çekirdek kaynak koduna doğrudan bağımlı olmaz.

İncelenen ana lisans dosyalarında [CasaOS](https://github.com/IceWhaleTech/CasaOS/blob/main/LICENSE), [Home Assistant Core](https://github.com/home-assistant/core/blob/dev/LICENSE.md) ve [Music Assistant Server](https://github.com/music-assistant/server/blob/stable/LICENSE) Apache-2.0; [Jellyfin](https://github.com/jellyfin/jellyfin/blob/master/LICENSE) GPLv2 metni kullanır. Bir fork hazırlanırken seçilen commit'in bütün ilgili dosyaları/bağımlılıkları ayrıca incelenir; kaynak, lisans/NOTICE, değişiklik kaydı ve gerekiyorsa karşılık gelen kaynak dağıtımı korunur. Larenor'un kendi kodunun lisans başlığı üçüncü taraf koduna otomatik uygulanmaz. Marka kullanımı ayrı değerlendirilir.

Her fork için upstream tabanı, yerel değişiklik gerekçesi, uyumluluk testleri, güvenlik güncellemelerini birleştirme yolu ve veri geri dönüş planı tutulur. Otomatik upstream merge/deploy varsayılmaz. Mevcut kullanıcı verisi üzerinde denenmeden önce sentetik veri ve izole test kurulumuyla geçiş doğrulanır.

## Kabul ölçütleri

- Son arayüz geçişi tablet ve DeX'i esas alır; telefon için ayrı bir tasarım hedefi yoktur. Dashboard/Media/Settings/Server aynı renk, tipografi, kart, gezinme, form ve diyalog düzenini kullanır. Tek Latin slogan korunur. README görselleri gerçek tablet düzenlerinden üretilir; sentetik widget önizlemeleri ile fiziksel cihaz ekran görüntüleri açıkça ayrılır.
- Varsayılan parolayla yönetim engellenir; member kullanıcı Client ekranını atlasa bile admin yazamaz. Son yönetici kaybı önlenir; parola/rol değişikliği eski yetkiyi düşürür.
- Tokenlar DB/log/Swagger örneklerinde açık bulunmaz; refresh yarışı/replay, logout, hesap değişimi, çevrimdışı ve storage hataları test edilir.
- Kasa yeniden kurulumdan alınır; yanlış sürüm/gizlilik içeriği, büyük/bozuk veri ve eski revizyon hiçbir yerel ayarı değiştirmez.
- Yanlış imza/paket/hash, downgrade, yönlendirme, yarım indirme, hesap değişimi ve disk sınırında APK kurulmaz. Doğru imzalı güncellemede uygulama verisi korunur.
- Salt okunur işlerde plan kimliği, yetki kaybı, iptal, bozuk kalıcılık ve restart test edildi. Gerçek kurulum diliminde eski onayın reddi, port/disk çakışması, yarım kurulum ve servis health kabulü ayrıca tamamlanacak. CasaOS/Linux kurulumu en son yapılır.
- Tablet/DeX admin panelinde aynı gezinme, hata, işlem onayı ve erişilebilirlik düzeni kullanılır. API başarısı fiziksel cihaz sonucuyla karıştırılmaz.

Temel resmi kaynaklar: [FastAPI güvenlik](https://fastapi.tiangolo.com/tutorial/security/), [SQLite Python işlemleri](https://docs.python.org/3/library/sqlite3.html), [Android PackageInstaller](https://developer.android.com/reference/android/content/pm/PackageInstaller), [Music Assistant kurulumu](https://www.music-assistant.io/installation/).
