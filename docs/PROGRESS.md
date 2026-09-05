# Larenor — güncel ilerleme ve iş kuyruğu

**Son güncelleme: 5 Eylül 2026, 21:55 (Türkiye saati).**

```text
Önceki kapsam       █████████████░░░░░░░  ≈ %65
S06 koordinatörü    ███████░░░░░░░░░░░░░  2/6 yazılım dilimi; test/yayın geçti
S06.3 kaynak temeli  ██████████░░░░░░░░░░  3/6 alt adım; Linux CI ile kabul
Yeni 63 özellik     ░░░░░░░░░░░░░░░░░░░░  0/63 kabul edildi
Genişletilmiş toplam                     Henüz hesaplanmadı
```

**İlk 60 özelliğin tamamı ve ardından VNC/RDP/SSH seçildi: toplam 63.**
[Bağımlılıklara göre uygulama sırası](feature-expansion-plan-2026-09-05.md)
11 teslim grubunu, mevcut S06–S09 temellerini ve her özelliğin kabul koşulunu
gösterir. 0/63, yeni özelliklerin henüz tamamlanma kabulü almadığını belirtir;
kullanıcı seçimi 63/63'tür. [Uzak erişim](remote-access-plan-2026-09-05.md)
Proxmox'tan bağımsız IP/alan adı eklemeyi kapsar; oturumlar Client'ta,
isteğe bağlı ortak profil/şifreli kayıt Core'da tutulur.
Mevcut kodla örtüşen işler yeniden yazılmayacak.

**Yaklaşık %65 yalnız önceki kapsamın tahminidir.** Önceki kapsamda S06 gerçek
kurulum, S07–S09, ileri kiosk/kamera, son tablet tasarımı ve fiziksel kabul
kalmıştı. Bu oran test kapsamı veya cihaz uyumluluk oranı değildir. Yeni 63
paketin eforu ayrıntılandıkça genişletilmiş toplam ayrıca hesaplanacak;
eski %35 kalan tahmini yeni toplam için kullanılmayacak.

Bu dosya yapılanları, devam eden işleri ve sıradaki paketleri tek yerde izlemek
içindir. Bütün kalan işler [yürütme kuyruğunda](EXECUTION_QUEUE.md), makinece
doğrulanabilen durum ve bağımlılıklar [JSON kaydında](execution-queue.json)
tutulur. Her doğrulanan dilimden sonra sıradaki uygun yazılım işine geçilir;
yeniden “devam et” talimatı beklenmez. Ayrıntılı kapsam için
[ürün planı](product-implementation-plan-2026-09-05.md),
[Server/Client planı](server-client-architecture-2026-09-05.md) ve
[test matrisi](testing-matrix-2026-09-05.md) kullanılır. Yeni onaylı özellikler
[63 özellik uygulama planında](feature-expansion-plan-2026-09-05.md) izlenir.

GitHub'a gönderilmiş işlerin **anlık CI durumu**
[Actions ekranından](https://github.com/ersingundem/larenor/actions) izlenir.
Bu yerel dosya geliştirme aşamalarında güncellenir; Actions ise çalışan
derlemelerin ve test işlerinin kendi canlı durumunu gösterir.

**Devam mekanizması etkin:** aynı Codex görevindeki “Larenor geliştirme ve
bakım” takibi 15 dakikada bir bu planı, kuyruğu, git durumunu ve yarım kalan
CI işlerini kontrol eder. Aynı iş için ikinci yürütücü başlatmaz; bir sonraki
bağımsız adıma geçer. Günlük depolama temizliği aynı görev içinde, Türkiye
saatinde 03.15 sonrasında günde en fazla bir kez korunur. Bilgisayarın ve Codex
uygulamasının açık, deponun erişilebilir olması gerekir; bu dosyanın kendisi
bir servis değildir. Görev Codex'in zamanlanmış görevler ekranından durdurulabilir.

**Kuyrukta kabul edilen işler: 4/125.** Saf kaynak planı, kalıcı journal ve
imaj/journal köprüsüyle **S06.3 içinde 3/6 alt adım** kapandı. **S08.1** de
Core/ev bağlamını tokenlarla güvenle bağlama kapsamında tam CI kabulü aldı.
Bu işler yeni 63 özelliğin kabul sayısı değildir; o sayaç **0/63**. Ana S06
sayacı **2/6** kalır; dizin/ağ, kurulum ve gerçek Engine kabulü açıktır.

**Son paket `54a677b` CI sonucunda bir test hatası verdi:**
[Server](https://github.com/ersingundem/larenor/actions/runs/33984554100)
2.295 geçti, bir bağlantı kapanışı testi başarısız; atlama yok.
[Android](https://github.com/ersingundem/larenor/actions/runs/33984554028)
2.701 Flutter, 98 JVM ve sekiz emülatör senaryosunu geçti; analiz temiz.
Emülatör 9:58,1; 42 aşama ve dört temizlik doğrulandı.
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33984553960)
202 araç testi ve sır taramasını geçti. Server kapısı nedeniyle yeni Core
imajı ve imzalı APK 90 yayımlanmadı; son tam yayın aşağıdaki `1408e80` kaldı.

**Dar CI düzeltmesi hazır:** test, Linux'un bağlantı kapanışını EOF yerine
`ConnectionResetError` olarak bildirebilmesini hesaba katmıyordu. Bu, kaynak
ve taşınabilir yeniden üretimle desteklenen açıklamadır; eski CI hatası ham
errno'yu kaydetmedi. `b2ca01f` RED → `bff9b98` GREEN yalnız test fixture'ını
değiştirir. Gerçek kapanış kanıtı, iptal sonucu ve bir saniyelik bekleme
korundu; süre veya başka hata kabul edilmiyor. İlgili **333 test geçti,
dört Linux testi Mac'te atlandı**; bağımsız inceleme temiz. Yeni Linux
socketpair testi ve tam uzak kapılar sonraki düzeltme paketinde doğrulanacak.
[Ağ adaptörü ve CI düzeltmesi](network-read-transport-implementation-2026-09-05.md) ·
[Client uyumluluğu](client-context-compatibility-2026-09-05.md) ·
[Tablet](tablet-navigation-implementation-2026-09-05.md).

**Yarım çalışmaları kaybetmeden devam:** aşağıdaki ayrı git çalışma
kopyaları yerel geliştirmeyi içerir; henüz `main` içine birleştirilmedi veya
yayımlanmadı. Yeniden başlayan yürütücü önce `git worktree list`, bu dalların
git durumu ve çalışan agent/CI durumunu kontrol eder; aynı işi baştan açmaz.
Yerel `/private/tmp` kopyalarının varlığı kalıcı arşiv garantisi değildir.

| İş | Dal | Yerel çalışma kopyası | Son inceleme noktası |
| --- | --- | --- | --- |
| B5.1 ayar satırları, uzun adres ve klavye/semantics | `codex/tablet-settings-accessibility` | `/private/tmp/larenor-tablet-settings-accessibility` | `3894abb`; 38 odaklı test geçti, geniş doğrulama sürüyor |
| S06.3e kontrollü ağ oluşturma taşıması | `codex/network-effect-bridge` | `/private/tmp/larenor-network-effect-bridge` | `ccc9137`; ilk 337 test geçti, üç Linux atlaması; sınır testleri sürüyor |

[Özel ağ create/journal planında](network-effect-bridge-plan-2026-09-05.md)
önce tek create taşıması, ardından ayrı incelemeyle journal bağlantısı var.
Dizin için supervisor/daemon/UID eşlemesi ve gerçek oluşturma/yayımlama açık.

S08.2 kendi CI kabulünü bekliyor. Ardından [ev runtime sınırı](client-home-scope-plan-2026-09-05.md)
uygulanacak: token yenilemesi gezinmeyi koruyacak, gerçek Core/ev/kullanıcı
değişimi eski ekran ve istekleri kapatacak. Yerel HA/cache yeni Core’a
kendiliğinden bağlanmayacak. Bu sınır şu anda plandır.

**Son tam uzak yayın `1408e80`:**
[Server CI](https://github.com/ersingundem/larenor/actions/runs/33982544738),
[Android CI](https://github.com/ersingundem/larenor/actions/runs/33982544696) ve
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33982544575)
**imzalı APK 89 dahil başarılı**. 2.092 Linux Server testi atlamasız;
2.678 Flutter, 98 JVM, sekiz emülatör senaryosu ve 202 araç testi geçti.
Üç gerçek Linux peer/mount vakası ayrıca doğrulandı. Emülatör akışı 9:59,2
ile 18 dakika sınırında; 42 aşama işareti ve dört tamamlanmış temizlik var.

AMD64/ARM64 Core imajları restart/medya hazırlığı/iptal kontrolünü geçti;
anonim commit/stable/index ve iki mimarinin sourceRevision değerleri doğrulandı:
`sha256:2c639e795687b28290de3f83bd3e85dad658812e79f03e094863aa86a0e27523`.
[İmzalı APK 89 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33982544696/artifacts/9974481883)
Java 17 + sabit apksig 9.1.0 ile ayrıca doğrulandı: doğru paket/sertifika,
`100000089`, minSdk 26, `debuggable=false`, kaynak commit ve metadata eşleşti.
APK SHA-256: `6829fd342d629931b2ef60ab7911af0d445340642d2b7cee1eb96023ca363243`.
Ev Server’ına koşullu Client yayını atlandı; cihaz/Server kurulumu yapılmadı.

<details>
<summary>Önceki doğrulanmış yayın: fc632b6 / APK 88</summary>

[Server](https://github.com/ersingundem/larenor/actions/runs/33981106713),
[Android](https://github.com/ersingundem/larenor/actions/runs/33981106645) ve
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33981106554)
imzalı APK 88 dahil başarılı. 1.890 Linux Server testi atlamasız; 2.659
Flutter, 98 JVM ve sekiz emülatör senaryosu geçti. Emülatör akışı 10:04,7;
42 aşama/temizlik işareti doğrulandı. Bu paket S06.3c ve S08.1 kabulüdür.
İki mimarili imaj anonim doğrulandı:
`sha256:00902e8b6142d546a9493e7db4a2b55a8fa166cbd44f9a4932894ae9fd5c4c22`.
[APK 88](https://github.com/ersingundem/larenor/actions/runs/33981106645/artifacts/9974067173)
Java 17 + sabit apksig ile ayrıca doğrulandı; `100000088`, doğru sertifika ve
`debuggable=false`. APK SHA-256:
`757b63032d51b3289f8ecb9d189f451bf777828e1867273d75e13eb485d75a47`.
Ev Server'ına yayın atlandı; ev kurulumu yok.

</details>

<details>
<summary>Önceki doğrulanmış yayın: 483ec13 / APK 87</summary>

[Server](https://github.com/ersingundem/larenor/actions/runs/33979199140),
[Android](https://github.com/ersingundem/larenor/actions/runs/33979199144) ve
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33979199030)
1.736 Linux Server, 2.625 Flutter, 98 JVM, sekiz E2E ve 202 araç testini geçti.
İki mimarili imaj anonim doğrulandı:
`sha256:7b368f5e5575746de203e88c96a3c64fb99527032b6806dce538f816c73ced61`.
[APK 87](https://github.com/ersingundem/larenor/actions/runs/33979199144/artifacts/9973530086)
Java 17 + sabit apksig 9.1.0 ile ayrıca doğrulandı: doğru paket/sertifika,
`100000087`, minSdk 26, `debuggable=false` ve kaynak commit eşleşti.
APK SHA-256: `1d642a628da571fbb5f4e0d453ac6c6bf94c2d69b6b5aa2109926df0730f3a76`.
Bu önceki kanıt daha yeni Client bağlamı veya imaj/journal köprüsünü kapsamaz.

</details>

<details>
<summary>Önceki temel kabul ve CI düzeltmeleri: 62b2054 ve öncesi</summary>

**S06 dilim 2 tamamlandı:** [birleşik medya gereksinim kontrolü](media-inspections-implementation-2026-09-05.md),
şifreli kalıcı sonuç/geçmiş/iptal, Android yönetim ekranı, toplam disk bütçesi ve
ayrı daemon bağlamı gözlemleri uygulandı. Bağımsız inceleme bulguları
regresyonlarla düzeltildi. İlk dilimdeki altı bileşenli hazırlık korunur;
`prepared` kurulum, `succeeded` ise bütün gereksinimler geçti demek değildir.

**Doğrulanan kod ve yayın: `62b2054`.**
[Security](https://github.com/ersingundem/larenor/actions/runs/33976443262),
[Server](https://github.com/ersingundem/larenor/actions/runs/33976443375) ve
[Android](https://github.com/ersingundem/larenor/actions/runs/33976443371)
CI'larının tamamı **imzalı APK teslimi dahil başarılı**.

- **1.516 Linux Server testi, sıfır atlama**; gerçek Linux socket/peer-context
  testi JUnit raporunda geçti. Yerelde 1.515 geçti, bir Linux testi Mac'te atlandı.
- **2.625 Flutter, 98 JVM/Robolectric ve 8 cihaz E2E senaryosu** geçti.
  Emulator 36.1.9.0/build 13823996; dört platform + dört uygulama senaryosu,
  42/42 aşama/temizlik işareti. Script yaklaşık 8:39 ile 18 dakika sınırında;
  bütün action yaklaşık 9:50. Analiz temiz; 178 araç testi geçti.
- **AMD64 ve ARM64 imajları** gerçek container restart/medya hazırlığı/iptal,
  APK doğrulayıcı ve kapalı inspection yeteneği kontrollerini geçti. Anonim
  erişimle commit ve `stable` için aynı imaj indeksi doğrulandı:
  `sha256:7ff0e5ef2322ad1711be7b9bcd6d79119695a2b9aa6718ce40e224b007875e70`.
- [**İmzalı APK 86 ve metadata**](https://github.com/ersingundem/larenor/actions/runs/33976443371/artifacts/9972729514)
  indirildi ve Java 17 + hash ile sabitlenmiş resmi apksig 9.1.0 ile ayrıca
  doğrulandı. Paket `com.ersingundem.larenor`, sürüm `100000086`, minSdk 26,
  doğru sertifika ve `debuggable=false`; kaynak commit ve APK SHA-256 eşleşti:
  `f5fa27b755331d8389985f4aa53ac8ef7b58f0e2f5de2615db06d849b91f70dc`.

Ev Server'ı henüz yapılandırılmadığından koşullu Client yayın adımı atlandı.
Ev cihazına veya sunucusuna kurulum yapılmadı. Medya motorlarını kurma,
otomatik eşleştirme ve gerçek HomePod oynatma kabulü hâlâ açık.

Bu sonuçları kaydeden son değişiklikler belgeler ve bir kaynak sürümü
alıntısının docstring düzeltmesidir; çalıştırılabilir Python AST'si aynı,
Client/test/workflow davranışı değişmedi. APK/imaj ve CI kanıtının kaynak
commit'i **`62b2054`** olarak kalır.

**Devam eden teslim:** [S06 dilim 3 — sahiplikli kaynak hazırlığı](media-resource-preparation-plan-2026-09-05.md).
Kaynak planı/journal → sabit digest ile imaj → sahiplikli appdata → özel kontrol
ağı → yarım işlem kurtarma/iki mimarili kabul sırası ayrıntılandırıldı.
Saf plan/journal ve imaj taşıması yerel testlerden geçti; bütün dilimin kabulü
henüz tamamlanmadı ve kurulum yetkisi açılmadı.

**CI hazırlığı düzeltmesi:** `ce1ce38` E2E'si uygulama senaryoları başlamadan
uyanık kalma ayarını doğrulayamadığı için durmuştu. `16dda6b` RED → `4e05b66`
GREEN ile yalnız seçilmiş QEMU emülatöründe toplam 10 saniye/en fazla beş
uygula-oku denemesi eklendi. Tam `7` veya `15` dışındaki kalıcı değer, ADB
hatası, taşan çıktı ve süre aşımı başarısız kalır; 21 regresyon geçti.
`19b14aa` gerçek koşusunda önkoşul ilk denemede doğrulandı ve bütün sekiz E2E
senaryosu geçti. Önceki hatanın kesin kök nedeni bu koşudan çıkarılmaz.

Önceki `5331f22` commit'inin Android/analiz/güvenlik CI çalışmaları artifact
depolama kotasına takıldı; taramalar bulgu üretmedi. Bu pakette rapor yükleme
hatası açık uyarıyla ayrıldı, güvenlik taramalarının artifact bağımlılığı
kaldırıldı. Asıl test/tarama hataları ve imzalı APK teslim hataları hâlâ engelleyicidir.

</details>

## Şu anda çalışılanlar

| İş | Durum | Tamamlanma ölçütü |
| --- | --- | --- |
| S05 hizmet yönetimi ve denetimi | Client admin ekranı, şifreli Server kayıtları ve 17 servis türünün kontrol yolu uygulandı | `19b14aa` Server/Güvenlik/Android ve imzalı APK teslimi geçti; gerçek servis kabulü ayrı |
| S06 birleşik medya hazırlığı/kontrolü | İlk iki dilim: hazırlık, toplam disk ve daemon bağlamı gözlemi, şifreli kontrol geçmişi/iptal ve Client akışı uygulandı | `62b2054` bütün CI ve imzalı APK geçti. Kaynak hazırlığı → kurulum adımları → özel bootstrap → kurtarma açık; port/alıcı ağı henüz `unknown` |
| B3 kalıcı Core/ev bağlamı | Korumalı kimlik API'si ve S08.1 atomik Client oturumu kabul edildi; S08.2 uyumluluk kod/testi hazır | S08.1 `fc632b6` tam CI; S08.2 kendi CI'ını bekliyor. Global provider/route/cache sınırı, merkezi adaptörler ve kaynak yetkileri açık |
| Gerçek Server imajı doğrulaması | `1408e80` AMD64/ARM64 Core restart/medya hazırlığı/iptal kontrolünü geçti ve yayımlandı | Anonim index ve kaynak kimliği doğrulandı; gerçek ev kurulumu ve medya motorlarının kurulması ayrı |
| Seçilen 63 özelliğin bağımlılık planı | İlk 60 seçim ve bağımsız VNC/RDP/SSH kaydedildi; 11 grup ve mevcut temel kapıları | Yeni özellik kabulü 0/63; SSH/tünel temeli → RDP → VNC, Proxmox veya medya kurulumu zorunlu değil |

**Son kapsam kararı:** Medya ve Music Assistant için ayrı uygulama kurulumu veya
elle API bağlantısı yapılmayacak. Bileşenler Larenor Server'a dahil olacak;
Client yalnız Larenor hesabı/API'si ve kullanıcı ayarlarını sunacak. Bu otomasyon
henüz tamamlanmadı. [Güncel bütünleşik medya planı](integrated-media-stack.md).

**Platform anlatımı:** Larenor Client tablet öncelikli Android uygulamasıdır.
DeX ayrı bir uygulama değil; aynı uygulamanın değişken pencere ve harici ekran
desteğidir. README, mimari belgeleri ve GitHub açıklaması buna göre güncellendi.

## Backend, Music Assistant ve HomePod: bugün nerede?

| Özellik | Çalıştığı yer / mevcut durum | Eksik adım |
| --- | --- | --- |
| Hesap, parola, oturum, rol, kullanıcı yönetimi | Larenor Server API ve veritabanında uygulandı | Gerçek sunucuya manuel kurulum |
| Kasa ve güncelleme sürümleri | Server'da şifreli kasa ve sürüm API'leri; Client geri yükleme/güncelleme akışları mevcut | Gerçek imzalı Client yükseltmesi ve yeniden kurulum kabulü |
| Entegrasyon bağlantı kayıtları | S05 şifreli Server kaydı, Client admin ekranı ve 17 türün kontrol yolu uygulandı | Yerel/uzak testler geçti; gerçek servis kabulü ve S08 adaptör taşıması |
| Gereksinim kontrolü ve iş geçmişi | Kalıcı şifreli işler, Linux işçisi ve açık politikayla Docker API/platform kontrolü uygulandı | Port ve alıcı ağı `unknown`; medya kurma/başlatma ve otomatik eşleştirme henüz yok |
| Birleşik medya hazırlığı/kontrolü | Altı bileşen planı, kalıcı kontrol, toplam disk ve ayrı daemon bağlamı sonuçları; Client geçmiş/iptal | Kaynak hazırlığı ve özel bootstrap; port/alıcı ağı `unknown`, kurulum kapalı |
| Core ve ev kimliği | Server'da kalıcı, anahtarla doğrulanan kimlikler; korumalı API ve Client sözleşme okuyucusu | Client oturum/cache ve kaynak kimliklerine bağlama; çoklu ev/federasyon henüz yok |
| HA, medya ve ağ komutları | Mevcut kontrollerin çoğu hâlâ Client adaptörlerinde | S08 ile gerçek veri ve komut akışlarını Server'a taşıma; yalnızca token saklamak bu taşıma sayılmaz |
| Music Assistant | Client müzik ekranı, eski MA-only paket ve Server token/sürüm kontrolü var; ev sunucusuna kurulmadı | Tek Larenor kurulumu içinde dahili motor; Client üzerinden sağlayıcı/oynatıcı yönetimi, ayrı MA URL/token girişi olmaması |
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
| Server Docker/CI kodu | Sabitlenmiş bağımlılıklar ve imza aracı, root olmayan süreç, ayrı veri/anahtar depoları; iki mimari ve gerçek APK imza kontrolü geçti. Yeniden başlatma testi de geçti ve ortak imaj yayımlandı; anonim manifest indirmesi doğrulandı |
| Server ekran tasarımı | Altı gerçek-widget önizlemesi incelendi; admin seçili sekmesi belirginleştirildi; test matrisi ve README'ye görseller eklendi |
| Bağımsız kod incelemesi | Server başlatma/kaynak/lisans/sürüm sözleşmeleri, Client güncelleme uyarısı ve Docker/CI akışında uygulanabilir ek bulgu çıkmadı; gerçek imaj çalışması yerine geçmez |
| Sunucu bileşenleri önizlemesi | Altı sabitlenmiş katalog kaydı, yönetici/oturum/katalog revizyonuna bağlı şifreli ve süreli önizlemeler; Client gereksinim ekranı. Kurulum düğmesi veya çalışan kurulum API'si yok |
| Kalıcı gereksinim işleri | Yönetici oluşturma/geçmiş/olay/iptal API'leri, şifreli plan/sonuç, belirsiz isteği aynı kimlikle kurtarma, restart ve güncel yetki denetimi. `succeeded` inceleme tamamlandı demektir; bütün kontrollerin geçtiği veya kurulum yapıldığı anlamına gelmez |
| Birleşik medya hazırlığı | Altı sabitlenmiş bileşen için tek kalıcı plan ve toplam istenen kaynak bütçesi; yönetici oluşturma/geçmiş/iptal, restart ve idempotence. Katalog değişse de geçmiş okunur; `installAvailable=false`. Jellyfin ortak kütüphaneyi yalnız salt okunur kullanır |
| Birleşik medya kontrolü | Toplam disk bütçesi, ayrı daemon mount/network/root gözlemleri, şifreli kalıcı kontrol işi ve tablet yönetimi; kaynak ayırma/servis kurma yok |
| Dahili salt okunur işçi | Aynı Server paketindeki `larenor-preflight-worker`, Linux UID doğrulamalı Unix IPC; toplam kapasite/platform, Docker GET `/version` ve açık v3 politikasıyla socket/process bağlamı. Varsayılan kapalı; kurulum yok ve `installAvailable=false` |
| Kalıcı Core/ev bağlamı | `/api/v1/context`, atomik şema 1→2→3 geçişi, HMAC doğrulaması; aynı 27 JSON örneğiyle Server ve Client okuyucu. Client oturum/cache bağlama henüz yok |
| Düzenli GitHub temizliği | Geliştirme/bakım takibi içinde günlük 03.15 sonrası kontrol ve testli araç; en yeni üç debug APK, bütün imzalı APK ve raporlar korunur. İlk koşumda beş eski debug APK (641.275.745 bayt) silindi; kalan 171 çıktı doğrulandı. GHCR izin ve manifest grafiği eksikliği nedeniyle silinmez |
| CI rapor kotası düzeltmesi | Test kanıtı yükleme hataları görünür uyarı üretir; Gitleaks/OSV taramaları artifact kotasına bağlı değildir. Gerçek tarama hatalarının engelleyici kaldığı test edildi |
| Lisans ve kaynak | AGPL-3.0-only, üçüncü taraf bildirimleri, uygulama içi lisans ekranı ve Server kaynak/lisans API'si |
| Geliştirme becerileri | İstenen frontend/CI seçkisinden 27 beceri kuruldu; 81 dosyanın kaynağı ve hash'i kaydedildi. Kurulum uygulama özelliği sayılmaz |

Son yerel doğrulamada **2.625 Flutter, 1.515 Server ve 178 araç testi** geçti.
Gerçek Linux peer-context testi macOS'ta atlandı; Linux CI'da 1.516 testin tamamı atlamasız geçti.
Server koşumunda gerçek Java/apksig kullanıldı. Workflow `actionlint` ve diff
kontrolü ve tam Flutter analizi temiz. Bağımsız incelemede bulunan
iş geçmişini belleğe topluca alma, hatalı worker ortam değerlerini güvenle
reddetme ve socket başlatma hatasında yalnız kendi inode'unu temizleme sorunları
regresyonlarla düzeltildi. Bu sonuçlar otomatik medya kurulumu veya fiziksel
cihaz kabulü yerine geçmez.

GitHub saklama politikası ve günlük görevin çalışma koşulları
[depolama temizliği belgesinde](github-storage-retention.md). Görevin çalışması için
Codex hostunun kullanılabilir olması gerekir; GitHub Actions cron işi değildir.
Container paketleri bu otomasyonun silme kapsamında değildir.

## Sıradaki geliştirme paketleri

Aşağıdaki mevcut işler korunur. Yeni G01–G11 grupları
[ayrıntılı plana](feature-expansion-plan-2026-09-05.md) göre bu işlerin arasına
yerleşir: S06/B1 ve S08/B3 temeli paralel; S07 otomatik medya bağlantıları ve
S09'un yazılım kurtarma bölümü erkenden tamamlanır. Yeni modüller yalnız kendi
bağımlılıklarını bekler. Son ortak tasarım, README ve fiziksel kabul tüm
seçili yazılım dilimlerinin ardından kalır.

Yarıda kalmaması için S06 kurulum koordinatörü ve B3 oturum/cache taşıması
[küçük teslimlere ayrıldı](remaining-core-integration-slices.md). Her dilimin
somut kabul koşulu vardır; yalnız model veya worker ilkeli eklemek uçtan uca
kurulum/yalıtımın tamamlandığı anlamına gelmez.

| Sıra | Paket / durum | Somut teslim ve bitti sayılma ölçütü |
| --- | --- | --- |
| 1 | **S05 — Hizmet yönetimi · kod ve uzak testler geçti** | Client admin ekranından bağlantı ekle/düzenle/unut/doğrula; şifreli Server kaydı, altı açık doğrulama durumu, yetki/oturum/çakışma testleri. Gerçek servis kabulü ayrı, servis kurulumu S06'da |
| 2 | **S06 — Eklenti sistemi · birleşik hazırlık uygulandı, kurulum eksik** | Altı bileşen için kalıcı hazırlık ve Client yönetimi; katalog/önizleme, kalıcı işler, Linux IPC ve açık politikayla Docker API/platform kontrolü mevcut. Birleşik kontrol ve daemon bağlamı da uygulandı. Sıradaki teslim: [sahiplikli imaj/dizin/ağ kaynakları](media-resource-preparation-plan-2026-09-05.md); ardından dar kurulum ve bootstrap |
| 3 | **S07 — CasaOS ve Music Assistant · sırada** | Tek Larenor Server kurulumu içinde medya ve Music Assistant; otomatik API anahtarı/adres/kütüphane eşleştirmesi, durum doğrulaması; Client'tan yalnız ayar yönetimi |
| 4 | **S08 — Merkezi entegrasyonlar · kimlik temeli eklendi** | Kalıcı Core/ev kimliği ve korumalı API hazır. Sırada Client cache sınırı, önce HA sonra medya/ağ adaptörleri, kaynak yetkileri, olay akışı ve widget sözleşmeleri; mevcut doğrudan yollar belgelenir |
| 5 | **Kalan ürün yetenekleri · sırada** | İleri kiosk ve kamera seçenekleri, Apple TV video, müzik sağlayıcıları ve HomePod kuyruk/grup/oynatma; yetenek matrisindeki desteklenmeyen durumları açık gösterme |
| 6 | **S09 — Ortak kurulum ve bütünlük · sırada** | Tek Larenor kurulumu ve dahili bileşenleri için kurulum/yedek/geri yükleme; özellikler arası akışlar, hata kurtarma, performans/güvenlik ve CI testleri |
| 7 | **G01–G11 — Seçilen 63 özellik · planlandı** | Güvenilir Core → kurtarma → tablet/bildirim → AI/otomasyon → eklentiler/çok ev → medya → aile → kamera → enerji → yeni cihazlar; bağımsız VNC/RDP/SSH dalı kendi ortak profil/güven kapıları hazır olunca paralel ilerler |
| 8 | **Son arayüz geçişi · işlevler tamamlanınca** | Apple tasarım ilkeleriyle ortak renk, tipografi, kart, gezinme, form ve diyalog sistemi; Dashboard, Media, Settings ve Server panelleri aynı düzende. Tek slogan korunacak |
| 9 | **Android tablet görsel kabul ve README · en son** | Huawei MatePad 11.5 S 2026 ve diğer tabletler, yatay/dikey yön, yeniden boyutlanan DeX penceresi, dokunma/klavye erişilebilirliği. Frontend bittikten sonra gerçek tablet görselleri; profesyonel README, ayrı Server/Client kurulumu, doğru GitHub konu etiketleri/açıklama ve insan/AI için açık belge gezinmesi. Telefon için ayrı tasarım hedefi yok |
| 10 | **Manuel kurulum ve fiziksel kabul · kullanıcıyla en son** | CasaOS/Proxmox kurulumu; sağlayıcı girişleri, gerçek HomePod/Chromecast/Apple TV, güç/kilit ekranı, güncelleme/geri yükleme senaryolarının cihazda doğrulanması |

Son tasarım aşamasında Flutter'a uygun Apple tasarım ve erişilebilirlik
becerileri uygulanacak; teknolojiye uymayan web becerileri uygulamaya zorlanmayacak.
README görselleri gerçek tablet düzenini temsil edecek; hazırlanmış taslaklar
çalışan uygulama ekranı gibi sunulmayacak.
Profesyonel README, keşfedilebilirlik ve gerçek kurulum yollarının son kontrolü
için [yayın hazırlık planı](readme-publication-plan.md) eklendi. GitHub açıklaması ve gerçek kapsamı anlatan 16 konu etiketi uygulandı; yıldız veya AI görünürlüğü artışı garanti edilmeyecek.

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
| Tam Server API/depolama/sürüm/iş paketi | **1.515 geçti; 1 Linux testi Mac’te atlandı** | Gerçek Java/apksig dahil bütün `server/tests`; sentetik servisler ve yerel IPC, canlı ev sunucusu değil |
| Tam Flutter paketi | **2.625 geçti** | Birleşik medya hazırlığı, bağlam ve sayfalama, hesap/yaşam döngüsü ve ortak JSON sözleşmeleri dahil unit/widget kapsamı |
| Bütün Python araç/politika testleri | **178 geçti** | Yeni container medya yolculuğu dahil; gerçek imaj çalışması GitHub CI'da ayrıca doğrulanır |
| Birleşik medya kontrol işleri | **116 odaklı test**, **%99 satır/dal** | Model/API/şema %100; gerçek HTTP→Unix→restart ortak JSON, şifreli sonuç, idempotence, iptal ve yetki yarışları |
| Client birleşik kontrol | **160 ilgili test**, **%93,8 satır** | Yeni alan 680/725 satır; aynı Server JSON örneği, beklenen Core/ev sınırı, EN/TR ve büyük yazı |
| Daemon bağlamı | **179 geçti; 1 Linux testi Mac’te atlandı**, **%94 satır/dal** | Socket pidfd, thread/proc/root/mount kimlikleri; gerçek ev Docker'ı kullanılmadı |
| Host/IPC son bağımsız inceleme | **120 geçti**, **%95 satır/dal** | Host %98, IPC %91; ortak bütçe, path değişimi, tek süre sınırı, bozuk nested sonucun reddi |
| Birleşik medya planner'ı | **83 geçti**, **%97 birleşik kapsam** | Altı bileşen, güvenli katalog, değişmez hash/kimlikler; host I/O veya kurulum yok |
| Medya API/depolama/ortak sözleşme | **75 geçti**, **%92 birleşik kapsam** | Şema/API/model %100; şifreleme/AAD, paralel tekrar/iptal, restart, katalog/yetki ve 8/256 sınırları |
| Client medya hazırlığı | **52 geçti**, 18 widget; **%95,3 satır** | İlgili katalog/iş/bağlamlarla birlikte 237 test; farklı Core, 256 kayıt erişimi, belirsiz POST, 2× yazı ve erişilebilir alanlar |
| Container medya smoke protokolü | **29 ilgili test**, helper **%100 kapsam** | `19b14aa` CI'ında gerçek amd64/arm64 imajlarında oluştur/restart/iptal geçti; medya servisleri kurulmadı |
| Emülatör hazırlığı | **21 araç regresyonu geçti** | Sınırlı tekrar, QEMU kanıtı, kesin ayar değeri ve hata halinde derleme başlamaması; `19b14aa` gerçek E2E önkoşulu ilk denemede geçti |
| Client gereksinim işleri | **53 geçti**, 19 widget; **%94,8 satır** | Tam Flutter toplamının içindeki odaklı kapsam; fiziksel tablet kabulü değil |
| Docker ve politika bütünleştirmesi | **236 geçti**, üç modülde **%99 birleşik satır/dal** | Docker probe %96; host/runtime %100. Sonradan eklenen dördüncü yavaş-daemon journey de geçti; fiziksel daemon kabulü değil |
| Kalıcı Core/ev kimliği ve ortak sözleşme | **59 Server / 63 Client testi geçti** | Yeni Server modülü ve Client model/metot %100 kapsam; çoklu ev ve Client oturum/cache henüz yok |
| Dahili işçi CLI | **47 geçti**, **%100 kapsam** | Politika/izin, statik hata ve durdurma testleri; gerçek kurulum yok |
| İşçi IPC bağımsız incelemesi | **83 testlik ilgili koşum**; 201/216 statement, 59/68 dal | 16 temel IPC testi ve başlatma hataları dahil; kapsamdaki diğer dosyalarla toplanmaz |
| Kalıcı iş bağımsız incelemesi | **55 geçti**, **%89 birleşik kapsam** | Yetki, kalıcılık, iptal, idempotence, bozulma ve restart; Server toplamının içindedir |
| Önceki yerel Android native koşumu | **98 geçti**, 18 test paketi | Güncel S06 için yeni fiziksel kurulum/oynatma kanıtı değildir |
| Uzak API 35 x86_64 E2E (`62b2054`) | **4 uygulama + 4 platform senaryosu geçti** | Gerçek emülatör 36.1.9.0; 42/42 işaret ve yaklaşık 8:39 script süresi. Fiziksel tablet kabulü değil |

Test dosyaları, kapsam ve açıklar [test matrisinde](testing-matrix-2026-09-05.md).
Test adetleri farklı zaman ve kapsamları temsil eder; toplanarak başarı oranı
üretilmez. CI kanıtı yukarıda adı verilen commit içindir; yalnız belge değişiklikleri uygulama veya workflow kodunu değiştirmez.

## Güncelleme kaydı

- **19:42:** Kullanıcının sürekli devam talimatıyla kalan adımların kalıcı
  yürütme kuyruğu hazırlanıyor; mevcut takip 15 dakikalık geliştirme devamına
  genişletildi, günlük debug APK temizliği aynı sınırlarla korundu.
  S06.3a saf kaynak sözleşmesi `8ab8006` RED → `0de91a2` GREEN: 67 yeni,
  katalog/stack ile 249 test geçti. Kaynak journal'ı ve imaj akışı paralel;
  kurulum yetkisi açılmadı, fiziksel ev işlemi yapılmadı.

- **19:22:** S06 dilim 2 tamamlandı, koordinatör **2/6**. `62b2054` bütün
  CI ve imzalı APK 86 teslimi geçti; APK yerelde ayrıca doğrulandı.
  1.516 Linux Server, 2.625 Flutter, 98 JVM/Robolectric, 8 E2E, 178 araç testi;
  iki mimarili imaj ve anonim index doğrulaması başarılı. `072aa8a` son tam
  regresyonunda bulunan üç eski test taklidi `62b2054` ile güncellendi;
  eski koşular concurrency ile iptal edildi. Sonraki kaynak hazırlığı altı
  adıma ayrıldı; yeni özellik kabulü hâlâ 0/63, gerçek ev kurulumu yok.

- **18:24:** `19b14aa` Güvenlik, Server ve Android CI'ı imzalı APK 84 teslimi
  dahil başarılı. 1.273 Server, 2.572 Flutter ve yerelde 176 araç testi;
  gerçek emülatörde 4 native + 4 uygulama senaryosu, 42 aşama işareti geçti.
  İki mimarili medya restart/iptal imajı yayımlandı, anonim manifest doğrulandı.
  Dilim 2 için daemon bağlamı, ortak süre sınırı, değişen yol, toplam dosya
  sistemi bütçesi ve ağ bilinmezliği beş somut kabul senaryosuna ayrıldı.
  Uzak erişim F61–F63 planlandı; protokol motorları henüz uygulanmadı.
- **18:00:** `ce1ce38` Server/Güvenlik ve gerçek iki mimarili medya restart
  akışı geçti; anonim imaj manifesti doğrulandı. Android analiz ve debug/native
  başarılı; E2E hazırlıkta durdu, imzalı APK üretilmedi. Ayarı doğrulamayı
  gevşetmeden 21 regresyonlu, süre/çıktı sınırları olan hazırlık düzeltmesi
  eklendi; bütün araç paketi 176 testle geçti. Uzak erişimde kişisel bağlantının
  Core gerektirmediği ve açık
  oturumların çıkış/hesap/ekran değişimindeki kapanış politikası netleştirildi.
- **17:40:** S06 ilk dilimi 2.572 Flutter, 1.273 Server ve 169 araç testiyle
  yerelde doğrulandı. Bağımsız incelemenin boş/bozuk şema, farklı Core
  tarihçesi, eski kayıt erişimi ve son erişilebilirlik/sınır bulguları düzeltildi.
  Gerçek iki mimarili imaj smoke'una hazırlık → restart → aynı kayıt → iptal
  eklendi. VNC/RDP/SSH F61–F63 olarak onaylı plana eklendi; toplam 63,
  yeni kabul 0/63. Protokoller Client'ta, ortak profil/kasa isteğe bağlı Core'da.

- **17:27:** `21bbf58` üç CI kapısından geçti; imzalı APK-82 teslim edildi.
  S06 dilim 1 için altı bileşenli plan, şifreli hazırlık, HTTP/Client sözleşmesi
  ve yönetici ekranı uygulandı. Jellyfin ortak kütüphanesindeki salt okunur
  amaç uyuşmazlığı düzeltildi. Bağımsız inceleme ve yeni tam testler sürüyor;
  kurulum/otomatik eşleştirme ve B3 oturum/cache sınırları açık kalıyor.

- **16:57:** `e73533e` Android/Güvenlik/Server CI tamamen başarılı;
  `app-signed-release-apk-81` imzası doğrulanarak teslim edildi. Gerçek ev
  Server'ına yayın yapılandırılmadığından atlandı. Son ortak sözleşme dilimi
  1.103 Server, 2.520 Flutter, 159 araç testi, analiz/format/sır taraması
  kanıtlarıyla yeni push için hazır; önceki koşum onun CI'ı yerine sayılmaz.

- **16:50:** `e73533e` uzak Android E2E **8/8 geçti**. Emülatör pininin
  gerçekten yüklendiği ve bütün uygulama aşamalarının tamamlandığı doğrulandı;
  timeout/assertion sınırları gevşetilmedi. İmzalı APK işi sürüyor.

- **16:44:** `e73533e` Server/Güvenlik CI başarılı; iki mimaride kimlik restart
  kontrolü geçti, Android sürüyor. Ortak 27 JSON örneği Server ve Client'a
  bağlandı; bool/float şema kabulü düzeltildi. Tam Server 1.103 test geçti;
  Client 63 ilgili test ve tam 2.520 Flutter testi geçti; analiz temiz.
  [Sonraki küçük teslimler](remaining-core-integration-slices.md)
  açıklandı; cache izolasyonu ve otomatik medya kurulumu hâlâ açık.

- **16:32:** Kesilen işlerden S06 Docker kontrolü ve B3 kalıcı Core/ev kimliği
  tamamlandı; tam 1.075 Server, 2.479 Flutter ve 159 araç testi geçti.
  `5deb1e6` Server/Güvenlik CI başarılı; Android native 4/4 sonrası emülatör
  kaybı nedeniyle E2E başarısız. Yeni pin ve aşama tanılaması hazır; yeni
  commit'in CI sonucu bekleniyor. [Docker kanıtı](docker-preflight-implementation-2026-09-05.md)
  ve [kimlik kanıtı](core-context-implementation-2026-09-05.md) eklendi.

- **15:55:** Kullanıcı 60/60 yeni özelliği seçti. Seçim JSON'a kaydedildi;
  her özellik 10 teslim grubunda tekil ID, bağımlılık ve kabul ölçütüyle
  mevcut kuyruğa bağlandı. Eski yaklaşık %65 yalnız önceki kapsam olarak
  ayrıldı; yeni kabul 0/60, genişletilmiş toplam henüz hesaplanmadı.
  Tam Flutter analizi de temiz sonuçlandı. Yeni kurulum veya cihaz işlemi yok.

- **15:40:** S06 kalıcı salt okunur gereksinim işleri, Linux IPC ve Client
  geçmiş/iptal/istek kurtarma akışı `5c6b83b` üzerinde yerelde doğrulandı:
  2.477 Flutter, 921 Server ve 157 araç testi. Henüz gönderilmedi; yeni CI ve
  tam analiz sonucu bekleniyor. `09729be` güvenlik ve iki mimarili Server yayını
  başarılı; Android E2E Quickstep ANR/odak hatası açık. Yaklaşık %65 tahmini
  korundu; yeni 60 fikir seçim bekliyor ve kapsama eklenmedi.

- **14:14:** Katalog/önizleme dahil **653 Server testi** geçti; işçi testleri
  bu koşuma henüz dahil değil. Ortak Python/Dart katalog-plan sözleşmesi için
  ayrıca bir API testi geçti. Wheel içindeki paketlenmiş katalog bağımsız
  açılarak doğrulandı. Android E2E odak/grafik düzeltmesi `8346c01` ile gönderildi;
  yeni CI sürüyor. Birleşik medya kurulum otomasyonu sıradaki ana iştir.

- **14:11:** Kullanıcının yeni kararı işlendi: Music Assistant ve tüm medya
  bileşenleri tek Larenor Server kurulumu içinde, API bağlantıları otomatik;
  Client'ta yalnız ayar yönetimi. Eski MA-only kurulum belgesi geçiş referansı
  olarak işaretlendi. Katalog ekranı dahili bileşen gereksinimleri ekranına
  uyarlandı; kurulum ve bağlantı otomasyonu henüz tamamlandı sayılmıyor.

- **14:01:** S05 `88c26fc` ile yayımlandı. Güvenlik ve iki mimarili Server CI
  başarılı; Android CI sürüyor. GitHub About açıklaması ve 16 konu etiketi
  uygulandı ve geri okunarak doğrulandı. S06 katalog/önizleme/işçi geliştirmesi
  sürüyor. Genel kapsam tahmini **%65** olarak korundu; henüz bitmemiş S06 veya
  fiziksel kabul tamamlanmış sayılmadı. Final README ve görseller frontend sonrası.

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
