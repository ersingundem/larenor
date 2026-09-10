# Larenor — güncel ilerleme ve iş kuyruğu

**Son güncelleme: 10 Eylül 2026 — PR66 `4925a50` ile ana dala alındı. Dördüncü toplu kilometre taşı Music Assistant ilk kurulumunu, Core-backed Proxmox/Keenetic tablet yüzeylerini ve doğrulanmış bounded indirmeyi birleştiriyor.**

```text
Kuyruk kabulü       ██░░░░░░░░░░░░░░░░░░  14/125 iş (%11; eşit ağırlıklı sayaç)
S06 koordinatörü    █████████████░░░░░░░  4/6 yazılım dilimi
S06.3 kaynak temeli  ████████████████████  6/6 alt adım
S08.7 HA kapsamı     ████████████████████  5/5 yazılım kapısı; fiziksel kabul ayrı
Yeni 63 özellik     ░░░░░░░░░░░░░░░░░░░░  0/63 kabul edildi
```

Bu sayaçlar test kapsamı, cihaz uyumluluğu veya harcanacak toplam sürenin
oranı değildir. Önceki kapsam için belirtilen yaklaşık %65 tahmini,
sonradan seçilen 63 özelliği içermez; genişletilmiş ürünün tamamlanma oranı
olarak kullanılmaz. İlk 60 adayın tamamı ve VNC/RDP/SSH seçildi.
[Bağımlılıklara göre özellik sırası](feature-expansion-plan-2026-09-05.md)
ve [uzak erişim kapsamı](remote-access-plan-2026-09-05.md) korunuyor.

**Son tam doğrulanmış CI Client paketi: `4021391` / APK140.** Aynı kaynakta
5.438 Flutter ve 4.065 Server testi geçti; Android emülatöründe 17/17 E2E
başarılı oldu. Arşiv yolculuğu yeniden açılan ekranda kalıcı okumayı doğrulayan
`core_archive.reopened_readback` fazına ulaştı. CI APK'nın imzasını,
sertifikasını, paketini, sürümünü ve release bayrağını doğruladı;
`app-signed-release-apk-140` artefakt arşivi 57.127.889 bayt ve süresi dolmamış
durumda. Aynı commitin bağımsız Security ve Server Container iş akışları da
geçti; Server 4.065 testi ile amd64/arm64 imaj ve manifest yayını tamamlandı.
[Android CI140](https://github.com/ersingundem/larenor/actions/runs/34304624138) ·
[Server Container CI](https://github.com/ersingundem/larenor/actions/runs/34304624214) ·
[Security CI](https://github.com/ersingundem/larenor/actions/runs/34304624024).
Gerçek ev kurulumu ve fiziksel tablet kabulü henüz yapılmadı.

## Şimdi yapılan işler

### F62 RDP — bounded Client yazılım dilimi

Core ve Proxmox'tan bağımsız kişisel RDP profilleri; hedef/gateway ayrımı,
Windows domain, şifreli kimlik bilgisi ve sertifika pini, açık bağlantı/yeniden
bağlantı, tablet/DeX pointer-klavye-resize yüzeyi olarak hazırlandı. Üretim
varsayılanı native motor yokken bağlantı denemez. Gerçek Windows/RD Gateway,
FreeRDP/JNI ve fiziksel Huawei tablet/DeX kabulü açık olduğundan F62 kabulü ve
**14/125 · 0/63** sayaçları değişmedi. Ayrıntı:
[bounded RDP Client dilimi](rdp-client-flow-2026-09-11.md).

### Tamamlanan toplu kilometre taşı — PR64

Ara commitlerde yalnız ilgili testler çalıştırılıyor; aynı teslim grubunun tam
Android, Server, E2E, güvenlik ve iki mimarili native kapıları tek exact head
üzerinde bir kez çalışıyor. [PR64](https://github.com/ersingundem/larenor/pull/64)
şu yazılım dilimlerini birlikte taşıyor:

- Seerr ve Music Assistant için kalıcı, plan-türetilmiş Core kurulum işleri;
  kullanıcı Docker girdisi yok ve `installAvailable=false` korunuyor.
- HA komutlarında actor/source/reason/correlation geçmişi ile şifreli append
  zinciri ve dış HMAC checkpoint doğrulaması.
- IP, alan adı ve IPv6 hedefli SSH/RDP/VNC profil yönetimi ile PIN korumalı,
  host-key pinli ve şifreli kimlik bilgili ilk SSH terminali.
- Home Assistant service-check için varsayılan ret, exact origin/IP izinleri,
  DNS/peer doğrulaması ve şifreli denetim kaydı.

Yerel toplu doğrulamada seçili Server paketleri; 226 birleşik
Keenetic/uzak-erisim/Ayarlar tablet testi; 49 SSH testi; 543 bileşen internet
izni testi; güvenlik politikası ve kuyruk doğrulaması geçti. İlk tam CI denemesi
Music Assistant'ın yeni worker capability değerini beklemeyen dört tarihsel
fixture buldu; fixture'lar güncellendi ve ilgili 44 test geçti. Yeni exact head
için 15/15 zorunlu CI kontrolü geçti ve PR64 ana dala alındı. Bu dilimler
F13/F20/F63 veya S06.5'in bütün
kabul ölçütlerini tek başına kapatmadığı için kanıt sayaçları henüz artırılmadı.

### Tamamlanan ikinci toplu kilometre taşı — PR65

Her commit `tool/commit_with_progress.py` ile kuyruktaki kanıtlı durumu okur ve
`Larenor-Queue-Progress` ile `Larenor-Feature-Progress` trailerlarını ekler.
Kısmi geliştirme yüzdeleri yükseltmez. Şu anki kanıtlı değerler **14/125
(%11,2)** ve **0/63 (%0,0)**.

[PR65](https://github.com/ersingundem/larenor/pull/65) şu parçaları tek kabul
noktasında birleştirdi:

- Music Assistant'ın doğrulanmış kurulumundan şifreli authenticated readback,
  tekil HA/Jellyfin keşfi ve revision bağlama.
- Spotify, Apple Music ve YouTube Music için şifreli ve idempotent provider
  kurulum niyetleri; beklenmeyen URL/alan/akış durumunda kapalı davranış.
- Paylaşılan SSH kimliği ve host pinini kullanan, 200 öğe ve 64 MiB sınırına
  sahip tablet SFTP tarayıcısı ile açık indirme/yükleme.
- Actor/source/reason/result ve bütünlük/checkpoint durumunu gösteren salt
  okunur tablet HA etkinlik ekranı.

Yerel birleşim kapısında seçili Music Assistant/provider Server testleri ve
**298 birleşik SFTP/SSH/Core HA Flutter testi** geçti. Exact PR head üzerinde
Android analiz/test, debug APK, API 35 emülatör E2E, Server, Security ve iki
mimarili Jellyfin/Arr/qBittorrent karakterizasyonu dahil **15/15 zorunlu
kontrol** geçti. Gerçek sağlayıcı hesabı, gerçek SFTP hostu ve fiziksel tablet
kabulü ayrı kaldı.

### Hazırlanan üçüncü toplu kilometre taşı

- Music Assistant provider form/OAuth worker'ı yalnız şifreli Unix IPC ile
  çalışıyor; exact instance/domain/loaded readback olmadan hazır saymıyor.
- HomePod/AirPlay dahil doğrulanmış player keşfi; açık play/pause/stop/skip,
  ses/mute ve queue add/replace/clear niyetleri revision, idempotency,
  deadline ve authenticated readback ile kapalı davranıyor.
- Kişisel SSH tarafında loopback tünel, dört PTY terminal sekmesi, Türkçe UTF-8,
  SFTP, keyboard-interactive MFA ve tek açık jump host; kopuşta otomatik komut,
  retry veya replay yok.
- F20 Client checkpoint'i Android güvenli depoda Core/ev kapsamıyla açıkça
  pin/rotate/export ediliyor; gerçek loopback Core restore/rollback/tamper ve
  geç yanıt/401/yetki kaybı E2E'si var.
- Her PR commitindeki iki yüzde trailerı artık CI'da doğrulanıyor. Günlük
  artifact işi eski tamamlanmış debug APK'lardan en yeni üçünü koruyor; ilk
  canlı tur **5 artifact / 651.810.797 bayt** sildi, belirsiz sonuç üretmedi.

Bu birleşimde ilgili Server **39**, Flutter **374** ve araç/güvenlik **257**
testi geçti. Commit ilerleme kapısı bu kayıt dahil mevcut **23/23** commit
mesajını doğruluyor.
Gerçek HomePod/sağlayıcı, iki hostlu SSH fixture, fiziksel Huawei/DeX ve GitHub
PR/CI kabulü açık olduğundan sayaçlar **14/125 (%11,2)** ve **0/63 (%0,0)**
olarak korunuyor. S08.9 Keenetic/Proxmox ve S08.10 bounded transfer pilotları
bir sonraki toplu paket için paralel yürütülüyor.

### Hazırlanan dördüncü toplu kilometre taşı

- Her PR commitinin kuyruk ve seçili özellik yüzdesi GitHub Actions özetinde
  commit hash'iyle ayrı satırda gösteriliyor. Bu kayıt öncesindeki **30/30 commit**
  `14/125 (%11,2)` ve `0/63 (%0,0)` trailerlarıyla doğrulandı.
- Music Assistant 2.10.2 ilk kurulumunda Core iç yöneticiyi oluşturuyor, kısa
  kurulum anahtarını uzun ömürlü entegrasyon anahtarıyla değiştiriyor,
  onboarding'i tamamlıyor ve aynı sunucu kimliğini tekrar okuyor. Sırlar yalnız
  UID-korumalı Unix IPC ve retained worker içinde kalıyor.
- Proxmox pilotunda yönetici preview/confirm ve üye salt okunur Core ekranı;
  kaynak seçen Core-backed dashboard widget'ı, node/QEMU-LXC/storage özeti ve
  stale/denied/offline ayrımı var. Core yolunda Direct fallback yok.
- Keenetic pilotu authenticated Core kaynağından internet durumu, public IP,
  uptime, indirme/yükleme, CPU/RAM ve çevrimiçi cihaz özetini tablet/DeX paneli
  ve kaynak/revision bağlı dashboard kartında gösteriyor. Yönlendirici ayarı
  değiştirmiyor ve Direct kimlik bilgisi/cache yoluna dönmüyor.
- S08.10 bounded indirme pilotu trace, sıra, final frame, uzunluk, SHA-256,
  içerik türü ve servis revision doğrulanmadan Android SAF'e veri yayımlamıyor.
  İptal, timeout, oturum/lifecycle ve ACL değişiminde akış kapanıyor; otomatik
  retry, range veya resume yok.

Birleşim sonrası ilgili **228 Server** ve **100 Flutter** testi geçti; security
policy, Python compileall, kuyruk ve commit ilerleme kapıları temiz. Flutter
generated kaynakları birleşik testten önce yeniden üretildi. Uzak CI,
gerçek Proxmox/Keenetic/Music Assistant, Android SAF, Huawei MatePad ve Samsung
DeX fiziksel kabulü açık. S08.9, S08.10, S06.5 ve seçili özelliklerin bütün
kriterleri kapanmadığı için sayaçlar **14/125 (%11,2)** ve **0/63 (%0,0)**
olarak korunuyor.

| Adım | Durum | Sonraki somut çıktı |
| --- | --- | --- |
| S08.5 — restore, logout ve journal hedef sınırı | **Kabul edildi**, exact `960691c` / APK108 | [Kabul ve korunan geçmiş](restore-people-acceptance-108-2026-09-08.md) |
| S08.6 — kişi, oda, kaynak ve izin yönetimi | **Kabul edildi**, aynı yayın | Merkezi HA akışının yetki temeli hazır |
| S08.7 — merkezi Home Assistant adaptörü | **Kabul edildi**; typed switch, kalıcı komut/makbuz, Direct→Core ve kapalı salt okunur standart/özel domain projeksiyonu PR17 tam CI ile ana dala alındı | Registry/servis keşfi ve domain'e özel typed komutlar sonraki HA dilimi |
| B5.1 — ortak tablet tasarımı | Services/hesap IME paketi APK116 ile kabul edildi; S08.7 komut ve aktarım yüzeyleri yerel tablet matrisinden geçti | Exact-source Android CI ve kalan ortak tablet yüzeyleri |
| S06.3d — kalıcı depolama | **Kabul edildi**; Native18 exact `6a054ea`, amd64+arm64 makbuzları doğrulandı | S06.3f ile birleşik kaynak kapısı kapandı |
| S06.3f — kaynak kabulü | **Kabul edildi**; exact `4021391`, iki mimarili native makbuz, 4.065 Server ve tam Android/Server CI yeşil | S06.4 dar kurulum yürütme kapısı |
| S06.4 — dar kurulum yürütme kapısı | **Kabul edildi**; PR16 `bf6f860`, PR18 `75af015`, PR19 `9ce3c5a` ve PR20 `2b9166b` tam CI kapıları yeşil | S06.5 özel bootstrap ve otomatik servis eşleştirme |
| S06.5 — özel bootstrap ve otomatik eşleştirme | **Devam ediyor**; Jellyfin ve qBittorrent native kabulü geçti. Sonarr/Radarr download-client bağlantısı PR56, Seerr private temel PR57 ve executor/worker IPC PR58 ile ana dalda. Seerr journal-bound konteyner kurulum işi yerelde yeşil | Şifreli kalıcı Seerr bootstrap işi, Sonarr/Radarr/kütüphane/initialize eşleştirmesi ve iki mimarili native kabul; ardından Music Assistant |

S06.5'in ilk iki TDD parçası, yalnız tamamlanmış Jellyfin kurulumundan
yöneticiye bağlı bootstrap niyeti üretir ve public API'de sır, hedef adres veya
Docker yetkisi kabul etmez. Ayrı adaptör resmi startup sırasını tek, önceden
doğrulanmış bağlantıda; bounded başlık/gövde ve ortak total deadline ile
yürütür. Redirect/retry yoktur; kısmi veya belirsiz yazma sonucu sabit ve
secret-free hata durumuyla üst koordinatöre bırakılır. Odaklı 30 test ve ilgili
81 test geçti. Exact `9882c7c` kaynak, sabit apksig 9.1.0 ve gerçek JDK 17 ile
tam yerel Server paketinde **4.381 PASS / 13 macOS skip** verdi; security policy
ve derleme kontrolü de temiz. GitHub CI henüz kabul edilmedi; gerçek
container/LAN işlemi yapılmadı.
[Uygulama ve açık sınırlar](media-service-bootstrap-implementation-2026-09-09.md).

Sonraki `e04a06a` → `832b44a` TDD dilimi, exact journal container ID ve
yeniden doğrulanmış stack/binding ile çalışan container'ın tek internal control
network IPv4/prefix/gateway gözlemini birleştiriyor. Yalnız RFC1918 subnet ve
sabit Jellyfin TCP/8096 listener'ı numeric bağlantı üretebilir; DNS, proxy,
alternatif adres ve retry yoktur. **27 yeni / 86 ilgili test** geçti. Bu bağlantı
henüz gerçek ağa açılmadı. `42128c2` → `5a1b1b0`, ardından `89687d1` ile
tamamlanan üçüncü dilim bu kanıtı başarılı `start_container` journal receipt'i,
dört retained-authority kapısı, startup öncesi/sonrası taze container gözlemi
ve tek ortak deadline içinde birleştiriyor. Bağlantı erişilemezliği endpoint
değişiminden ayrı raporlanıyor; beş resmi adım doğrulanmadan başarı üretilmiyor.
**14 yeni / 100 ilgili test** ile security policy, compileall ve diff kontrolü
geçti. IPC/supervisor dispatch ve kalıcı bootstrap durum geçişi henüz bağlı
değil; bu kaynak gerçek Docker/Jellyfin ağına dokunmadı.

`b931fdd` → `2e75cd3` TDD dilimi public duruma secret-free `errorCode` ekledi
ve koordinatörün `queued → running → credentials_configured` geçişini kalıcı
hale getirdi. Kesilmiş `running` kayıt restart sonrasında yeniden denenmiyor;
`bootstrap_interrupted` ile insan incelemesine ayrılıyor. Yetki kaybı backend
çağrısından önce duruyor; kısmi/belirsiz etki `needs_attention`, kesin bağlantı
erişilemezliği `failed` oluyor. **18 odaklı / 90 ilgili test** geçti. Production
Core backend'i bu ara committe kapalıydı; gerçek servis işlemi yapılmadı.

`e9a71a3` → `ae96651` ve `26aca71` → `d8d8276` TDD dilimleri aynı
UID-korumalı installation Unix socket'e private bootstrap operasyonunu ekledi.
Core yalnız bu socket yapılandırılmışsa koordinatörü backend'e bağlar. Exact
job/plan/private sözleşme dışındaki giriş worker'a ulaşmaz; kısmi sonuç yalnız
sabit adım, hata kodu ve belirsizlik taşır. Runtime kurulum ve bootstrap için
aynı journal/binding'i kullanır; supervisor iç gate'leri ve Docker bağlantılarını
aynı retained daemon lease'i/native thread içinde doğrular. Sentetik gerçek
Unix-soket Core→IPC→worker yolculuğu dahil **11 yeni / 149 ilgili test** geçti;
bir Linux-only test macOS'ta skip edildi. Gerçek Docker/Jellyfin etkisi yapılmadı.

`dcf6b17` yaşam döngüsü düzeltmesi, kalıcı bootstrap kuyruğunu Server açılışında
otomatik dispatcher'a bağladı. Kapanış devam eden UID-korumalı IPC çağrısının
şifreli makbuz yazımını bekliyor; beklenmeyen yürütücü ayrıntıları yerine yalnız
sabit hata kodu loglanıyor. Gerçek Unix-soket yolculuğu ve diğer dispatcher
regresyonları dahil **57 ilgili test** geçti. Exact GitHub CI açık olduğundan
S06.5 ve genel sayaç değişmedi.

`7668017` → `0745d70`, `c790748` → `61be275`, `1f36ed5` / `22bae10` →
`a681d74` ve `e95e436` → `d198a72` TDD zinciri, tamamlanan startup'tan sonra
ikinci kez doğrulanmış private endpoint üzerinde Jellyfin sistem kullanıcısını
authenticate eder. Tek doğrulanmış `Larenor Core` API anahtarını yeniden kullanır;
yoksa bir kez oluşturup geri okumadan kabul etmez. `System/Info` kimliği ve
`Library/VirtualFolders` sonucu kapalı modele alınır, geçici auth oturumu
`Sessions/Logout` ile kapatılır. API key, session token, parola ve medya yolları
UID-korumalı IPC dışında görünmez; Core sonucu AES-GCM ciphertext olarak saklar
ve public durumu yalnız `wiring_partial` yapar. İlk dilimde ilgili altı paket **110 PASS**,
değişen ve doğrudan bağlı beş modül branch coverage toplamı **%80** verdi.
[TDD kanıtı ve açık sınırlar](jellyfin-authenticated-readback-implementation-2026-09-09.md).

Native genişletmenin son `2c3f591` kaynağı, Jellyfin 10.11.11'in gerçek ilk
kullanıcı adı, iki zorunlu remote-access alanı, internal Docker ağındaki boş
gateway gözlemi, null alanları atılan `ApiKey` wire biçimi ve wizard sonrası
sağlık durumuyla eşleştirildi. **655 ilgili test** geçti. Exact
[CI 34389549143](https://github.com/ersingundem/larenor/actions/runs/34389549143)
arm64 ve amd64 üzerinde bootstrap/readback/logout, ilk sağlık, restart sağlık,
kimlik ve kalıcı veri kontrollerini tamamladı; public makbuzda sır bulunmuyor.

Sonraki `1f998d3` → `a62b904`, `33e6bf5` → `a0d1420` TDD dilimi sabit
`Larenor Movies` ve `Larenor Shows` kütüphanelerini üçüncü doğrulanmış private
endpoint üzerinde idempotent oluşturup yeniden okur. İlgisiz kayıtlar korunur;
ad/yol/tür çakışması ve kısmi yazma silme veya otomatik retry üretmez. Runtime,
IPC, public hata modeli ve secret-free native aşama tanıları bağlandı;
İlk sözleşmede **306 ilgili test** geçti. Native CI `34394429050`, eksik
`/media/movies` yolunu beklendiği gibi `bootstrap_wiring_create_failed` ile
kapattı. `7ac61db` bunun üzerine sekizinci journal-bound medya hacmini, sabit
dizin hazırlığını ve Jellyfin'in salt okunur `/media` bağını ekledi; genişleyen
hacim/Jellyfin paketi **513 PASS** verdi. `33bb2d2` ayrıca Jellyfin'in geçerli
kütüphane sıralarını bağımsız kabul edip yanlış/ekstra kayıtları reddeden
matcher ve kapalı sonuç tanıları ekledi; paket **514 PASS** oldu. Exact
[CI 34398527312](https://github.com/ersingundem/larenor/actions/runs/34398527312)
AMD64 ve ARM64 üzerinde geçti. İndirilen iki makbuz merge kaynağı `73fbd0a`
için repo doğrulayıcısıyla yeniden geçti. Tam Server koleksiyonunda test
assertion hatası olmadı; yerel ortamda sabit `LARENOR_TEST_APKSIG_JAR` olmadığı
için dört release-verifier crypto fixture'ı kurulamadı. İki mimarili native kabul
tamamlandı; diğer medya servisleri açık olduğu için S06.5 sayacı değişmedi.
[TDD kanıtı ve açık kabul sınırı](jellyfin-managed-libraries-implementation-2026-09-09.md).

qBittorrent dilimi, LinuxServer qBittorrent 5.2.3 için yalnız Larenor'un
yönettiği yolları ve güvenlik ayarlarını üreten deterministik config sözleşmesi
ekledi. Core'un özel Bearer akışı önce exact `v5.2.3` kimliğini, ardından API
anahtarını, portları, indirme yollarını, WebUI güvenlik bayraklarını ve sabit
`movies`/`tv` kategorilerini doğruluyor. Eksik yönetilen kategoriler eklenebiliyor;
yabancı veya çakışan durum değiştirilmiyor ve yazma sonrası bağlantı kaybı
belirsiz etki olarak raporlanıyor. **104 qBittorrent testi**, ortak HTTP
çerçeveleme/Jellyfin paketleriyle **149 test** ve yerel gitleaks taraması geçti.
Container hacim bağları ile amd64/arm64 gerçek qBittorrent kanıtı açık olduğu
için kurulum yeteneği kapalı ve kuyruk kabul sayacı değişmedi.
[Uygulama ve açık sınırlar](qbittorrent-owned-bootstrap-implementation-2026-09-10.md).

Takip eden TDD dilimi config bytes üretimini yalnız güncel `VolumeCreateJournal`
kaydından yeniden bağlanan qBittorrent `/config` appdata kaynağına bağladı.
Revision, resource/operation, journal/nonce, volume adı, child plan, portlar,
servis ve hedef eşleşmeden config üretilemiyor; işlem journal'ı değiştirmiyor.
**15 yeni / 294 ilgili test**, compileall, diff ve gitleaks kontrolü geçti.
Bu yalnız private bellek içi sözleşmedir; atomik volume yazma ve native
container kanıtı hâlâ açıktır.
[Uygulama ve açık sınırlar](qbittorrent-config-volume-binding-implementation-2026-09-10.md).

Aynı dalın ikinci parçası tek yönetilen library volume'ünü qBittorrent,
Sonarr ve Radarr için `/data` yazılabilir; Jellyfin için `/media` salt okunur
olarak tüketilecek sabit bir plana bağladı. Seerr ve Music Assistant bu medya
hacmini almıyor. **19 yeni / 315 ilgili test** geçti; bu öneri de henüz mount
veya kurulum yetkisi vermiyor.

Sonraki helper dilimi, config'i yalnız stdin'den kabul edip tek sabit
`/volume/qBittorrent/qBittorrent.conf` hedefine kuruyor. Exact allowlist,
`O_NOFOLLOW`, özel sahiplik/izinler, üzerine yazmayan atomik hard-link yayını,
dosya/dizin kimliği geri okuması ve yarım etkiyi koruyan kapalı hata politikası
uygulandı. **16 yeni / 136 ilgili test** geçti. Worker/Docker stdin etkisi ve
iki mimarili gerçek qBittorrent kabulü açık olduğundan sayaç değişmedi.
[Uygulama ve açık sınırlar](qbittorrent-config-helper-implementation-2026-09-10.md).

Bir sonraki private worker dilimi Docker API 1.47 sürümünü, Unix socket
kimliğini ve peer UID'yi aynı attach bağlantısında doğrulayıp config'i container
metadata'sına koymadan bounded stdin ile iletiyor. Yetki private byte öncesinde
yeniden sınanıyor; non-TTY stdout/stderr frame'leri ayrı ve sınırlı okunuyor.
Journal-bound effect sabit networksüz/RW-volume helper gövdesini
create/start/stream/wait/remove sırasıyla çalıştırıyor, exact digest/state
sonucunu ve kaynağı etkiden sonra tekrar doğruluyor. **37 yeni / 274 ilgili
test** geçti. Supervisor/IPC state bağı ve iki mimarili native kabul açık.
[Uygulama ve açık sınırlar](qbittorrent-config-effect-implementation-2026-09-10.md).

Takip eden runtime dilimi stack ve volume planını worker içinde yeniden türetip yalnız güncel qBittorrent `/config` intent'ini seçiyor. Pinned helper ve platform ile kurulan effect, installation supervisor'ın aynı native thread/retained-daemon kapısında etki öncesi, iç gate'lerde ve etki sonrası doğrulanıyor. Bilinmeyen adapter hataları ayrıntı sızdırmadan belirsiz etki oluyor. **12 yeni; runtime ve supervisor paketinde 70 PASS / 1 mevcut macOS skip; geniş pakette 343 PASS / 2 mevcut macOS skip; tam Server koleksiyonunda 4.736 test / exit 0**. Kalıcı şifreli job, IPC operasyonu, create/start önkoşulu ve native kabul açık.
[Uygulama ve açık sınırlar](qbittorrent-runtime-binding-implementation-2026-09-10.md).

`0983c28` TDD dilimi qBittorrent private config isteğini ayrı mutating worker
socket'ine bağladı. Core ve worker packaged stack'i ayrı ayrı doğruluyor; iş
kimliği runtime sınırına kadar taşınıyor; credential, API key, salt ve config
bytes public modele veya makbuza girmiyor. Etki sonrası Core yetkisi kaybolursa
sonuç belirsiz etki oluyor. **14 yeni test; 418 ilgili testte 417 PASS / 1 mevcut
macOS skip**, compileall, queue, diff ve gitleaks kontrolü geçti. Kalıcı şifreli
qBittorrent job, create/start sırası ve iki mimarili native kabul açık olduğu
için sayaç değişmedi.
[Uygulama ve açık sınırlar](qbittorrent-installation-ipc-implementation-2026-09-10.md).

`9bf5f40` TDD dilimi Core'un ürettiği qBittorrent credential, API key ve salt'ı
satır kimliği/durum/kaynak bağlamlı AES-GCM kayıt içinde tutan kalıcı işi ekledi.
Admin API oluşturma, sınırlı listeleme, okuma ve revision-bound iptal sunuyor;
dispatcher gerçek UID-korumalı IPC'yi otomatik çağırıyor ve kapanışta devam eden
makbuzu bekliyor. Restart sırasında `running` kalan iş tekrar edilmiyor; etki
sonrası iptal, yetki kaybı veya bilinmeyen worker kopması açıkça
`needs_attention` oluyor. **23 yeni ve 263 ilgili test PASS**; sabit apksig/JDK
ile dört gerçek APK doğrulama testi de geçti. Create/start sırası, iki mimarili
native qBittorrent ve otomatik servis eşleştirmesi açık olduğu için sayaç
değişmedi ve `installAvailable=false` kaldı.
Exact `420ba57` kaynağının Server, Android analyze/debug/E2E, güvenlik ve iki
mimarili karakterizasyon kapıları geçerek PR37 üzerinden ana dala birleşti.
[Uygulama ve açık sınırlar](qbittorrent-configuration-jobs-implementation-2026-09-10.md).

`da879f3` TDD dilimi qBittorrent işini tek kapalı worker operasyonunda önce
owned config'i kurup doğrulamaya, ardından aynı retained-daemon/native-thread
otoritesiyle sabit container binding'ini üretip create/start etmeye bağladı.
Binding yalnız owned `/config` ve ortak yazılabilir `/data` volume'lerini kabul
ediyor; published port yok. Birleşik şifreli makbuz public durumda yalnız
`container_started` gösteriyor; önceki config-only kayıtlar okunabilir kalıp
container başarısı iddia etmiyor. **229 ilgili testte 228 PASS / 1 mevcut macOS
skip**, compileall, diff ve queue doğrulaması temiz. Exact CI ile gerçek
amd64/arm64 servis/readback/restart kanıtı açık olduğundan sayaç ve
`installAvailable=false` değişmedi.
Exact `729eb1e` kaynağının Server, Android analyze/debug/E2E, güvenlik ve iki
mimarili karakterizasyon kapıları geçerek PR38 üzerinden ana dala birleşti.
[Uygulama ve açık sınırlar](qbittorrent-configured-container-implementation-2026-09-10.md).

`2934815` qBittorrent private endpoint dilimi yalnız exact running container,
journal binding'i ve tek Larenor control-network gözleminden RFC1918 numeric
TCP/8080 bağlantısı üretiyor; DNS, proxy, alternatif hedef veya public port yok.
Worker-private bootstrap executor önce sabit `movies`/`tv` kategorilerini
idempotent doğruluyor, sonra taze kanalda pinned sürüm, API key ve owned ayarları
geri okuyor. Altı retained-authority kapısı ve her etkiden önce/sonra endpoint
drift kontrolü var; olası yazma sonrası hata belirsiz etki. **354 ilgili testte
353 PASS / 1 mevcut macOS skip**, compileall, security policy ve gitleaks temiz.
Exact PR39 head `98a7a1c` Server, Android analyze/debug/API35 E2E, güvenlik ve
iki mimarili karakterizasyon kapılarından geçip `ec977b2` ile ana dala
birleşti. Core IPC/runtime dispatch sonraki dilimde bağlandı; native servis
kanıtı açık olduğundan sayaç değişmedi.
[Uygulama ve açık sınırlar](qbittorrent-private-bootstrap-implementation-2026-09-10.md).

`a1e3bb6` doğrulanmış-servis dilimi yalnız ilk read-only TCP hazır olma
bağlantısını ortak deadline içinde yeniden deniyor; her denemede yetkiyi,
journal-bound container'ı ve aynı private numeric endpoint'i yeniden kanıtlıyor.
Runtime kategori ve authenticated readback'i config/create/start sonrasına
bağladı. UID IPC yalnız `qbittorrent_service_verified` makbuzunu başarı kabul
ediyor; Core bunu şifreli saklayıp public durumda `serviceState=verified`
gösteriyor. Eski config-only veya container-started kayıtlar okunuyor fakat
doğrulandı sayılmıyor. **130 odaklı test PASS / 1 mevcut macOS skip**; sabit
apksig 9.1.0 jar ve JDK 17 ile tam Server paketi **4.831 PASS / 13 platform
skip**. Security policy, compileall, queue, diff ve gitleaks temiz.
PR41'in gerçek servis koşuları Docker'ın çalışan container endpoint projeksiyonu,
qBittorrent'in exact `qbt_` API-key biçimi ve WebUI UPnP'den bağımsız peer-port
yönlendirme ayarını ortaya çıkardı. Kapalı sözleşmeler bu gerçek davranışlara
göre düzeltildi; **289 ilgili yerel test PASS**. Exact PR head `f00a869` için
[CI 34437420807](https://github.com/ersingundem/larenor/actions/runs/34437420807)
amd64 ve arm64 üzerinde config, start, Bearer auth, iki kalıcı kategori, restart
ve ikinci readback adımlarının tamamını geçti. İndirilen iki makbuz exact merge
kaynağı `8cf7257` ile repo doğrulayıcısında yeniden PASS oldu. Diğer medya
servislerinin otomatik eşleştirmesi açık olduğu için sayaç ve
`installAvailable=false` değişmedi.
[Uygulama ve açık sınırlar](qbittorrent-service-verification-implementation-2026-09-10.md).

`9df82dd` ile başlayan Arr dilimi, sabitlenmiş Sonarr `4.0.19.2979` ve Radarr
`6.3.0.10514` kaynaklarındaki 32 karakterlik API-key ve `config.xml` başlangıç
davranışını kapalı bir üreticiye bağladı. Yalnız `sonarr`/`radarr`, sabit port,
örnek adı ve güvenlik ilkesi kabul ediliyor; secret ve dosya baytları `repr`
çıktısına girmiyor. Exact karşılaştırma ek veya değiştirilmiş XML'i ve servisler
arası yeniden kullanımı reddediyor. **36 yeni / 218 ilgili test**, compileall,
security policy ve diff kontrolü PASS. Henüz dosya sistemi/Docker etkisi olmadığı
için sayaç ve `installAvailable=false` değişmedi.
[Uygulama ve açık sınırlar](arr-owned-config-implementation-2026-09-10.md).

`0643801` helper dilimi, Sonarr ve Radarr exact XML'ini yalnız ayrı kapalı
komutlarla `/volume/config.xml` hedefine yazıyor. Byte'lar sadece bounded
stdin'den alınır; servis/yol/izin seçimi yoktur. UID/GID `1000:1000`, hacim
`0750`, dosya `0600`, `O_NOFOLLOW`/`O_EXCL`, tek-link denetimi, atomik
no-overwrite yayın, `fsync` ve exact geri okuma birlikte uygulanır. Aynı içerik
idempotent kabul edilir; symlink, hardlink, yanlış mod, yabancı dosya veya kalan
geçici dosya korunup çakışma olur. Helper paketinde **58 PASS**, owned config ile
**94 ilgili PASS**; compileall, security policy, queue ve diff temiz. Bu kaynak
henüz Docker effect veya gerçek servis başlangıcı yapmadığı için sayaç ve
`installAvailable=false` değişmedi.
[Uygulama ve açık sınırlar](arr-config-helper-implementation-2026-09-10.md).

`25b7850` saf binding dilimi, Sonarr/Radarr config üretimini yalnız güncel
`VolumeCreateJournal` intent'inden yeniden türetilen ilgili `/config` appdata
kaynağına bağladı. Resource/operation/journal/nonce/revision, plan digest'leri,
installation, volume, servis, kullanıcı, mount ve sabit stack ayarlarının tamamı
eşleşmeden config üretilemiyor. Bütün binding alanları ve API key yeniden
doğrulanıyor; public API servis/yol/port/stack/policy seçimi almıyor ve hiçbir
host/ağ etkisi oluşturmuyor. **44 yeni / 138 ilgili test**, compileall, security
policy, queue, diff ve Gitleaks PASS. Docker effect ve native kabul açık olduğu
için sayaç ve `installAvailable=false` değişmedi.
[Uygulama ve açık sınırlar](arr-config-binding-implementation-2026-09-10.md).

`87449f1` worker effect dilimi, journal-bound config'i sabit digest'li, ağsız,
salt okunur-root, capability'siz ve `1000:1000` helper'a bounded Engine stdin
ile iletiyor. Caller Docker gövdesi, komut, volume, yol, ağ veya container adı
seçemiyor; secret create metadata'sına ve makbuza girmiyor. Kaynak işlem
öncesi/sonrası yeniden bağlanıyor, exact digest ile servise ait durum zorunlu.
Geçersiz container kimliği cleanup yoluna girmiyor; start sonrası sapmalar
belirsiz etki oluyor. **22 yeni / 160 ilgili test**, compileall, security policy,
queue, diff ve Gitleaks PASS. Runtime/container ve native API kabulü açık olduğu
için sayaç ve `installAvailable=false` değişmedi.
[Uygulama ve açık sınırlar](arr-config-effect-implementation-2026-09-10.md).

`228687d` runtime dilimi, Arr config effect'i packaged catalog/policy ile yeniden
türetilen güncel appdata intent'ine ve installation supervisor'ın aynı retained
daemon/native thread kapısına bağladı. Sonarr/Radarr seçimi kapalı; API key exact
32 hex, internal iş kimliği 32 hex. Stale journal helper'a ulaşmıyor; Docker
transport ve private stdin aynı peer verifier'ı kullanıyor. `daff353`, değişen
backend yapıcısını qBittorrent native kabul giriş noktasında da iki config
runtime'ıyla eşledi ve çapraz sözleşme testi ekledi. **20 yeni test**; ilk tam
ilgili koşuda **251 PASS / 1 mevcut macOS skip**, düzeltme sonrası seçili yedi
pakette **148 PASS / 1 mevcut macOS skip**. Compileall, security
policy, queue, diff ve Gitleaks PASS. Kalıcı Core işi, IPC, container create/start
ve native API kabulü açık olduğu için sayaç ve `installAvailable=false`
değişmedi.
[Uygulama ve açık sınırlar](arr-config-runtime-implementation-2026-09-10.md).

`ebf98c0` IPC dilimi, strict private Arr modelini UID-korumalı installation Unix
socket'ine ekledi. Client ve server plan/model/iş/deadline/peer sınırlarını
yeniden doğruluyor; runtime sadece `configure_arr` operasyonundan çağrılıyor.
Yetki dispatch öncesi ve sonuç sonrası tekrar sınanıyor; Sonarr/Radarr makbuz
eşleşmesi üç katmanda doğrulanıyor. Status iki servisi bildiriyor fakat
`installAvailable=false`. **18 yeni test**; ilgili altı pakette **140 PASS / 1
mevcut macOS skip**. Compileall, security policy, queue, diff ve Gitleaks PASS.
Kalıcı Core işi, container zinciri ve native API kabulü açık olduğundan sayaç
değişmedi.
[Uygulama ve açık sınırlar](arr-configuration-ipc-implementation-2026-09-10.md).

`c3eacee` kalıcı iş dilimi, Sonarr ve Radarr yapılandırmalarını servis başına
tekil, yöneticiye bağlı ve AES-GCM şifreli no-retry işlere dönüştürdü. API
anahtarı yalnız Server tarafından üretiliyor; public modeller, hata ve repr
yüzeyleri sırrı taşımıyor. Yaşam döngüsü dispatcher'ı UID-korumalı worker IPC
üzerinden exact servis makbuzunu kaydediyor; kesinti ve belirsiz etkiler otomatik
tekrarlanmıyor. **5 yeni uçtan uca sözleşme testi** dahil ilgili Arr paketlerinde
**267 PASS / 1 mevcut macOS skip**. Security policy, queue, compileall, diff ve Gitleaks PASS. Container
create/start ve gerçek native API readback açık olduğundan sayaç değişmedi.
[Uygulama ve açık sınırlar](arr-configuration-jobs-implementation-2026-09-10.md).

`f113835` readback dilimi, Sonarr/Radarr pinned servis adı ve sürümünü
`X-Api-Key` ile sabit system/status endpoint'inden doğruluyor. Hedef, proxy,
resolver veya serbest header girdisi yok; auth, protokol, servis/sürüm sapması ve
timeout secret-free statik sonuçlara kapanıyor. **14 yeni test**, compileall,
security policy, queue ve Gitleaks PASS. Container zinciri ve iki mimarili native
kabul açık olduğundan sayaç değişmedi.
[Uygulama ve açık sınırlar](arr-authenticated-readback-implementation-2026-09-10.md).

`b02bdb6` endpoint dilimi ortak managed-container builder'ı Sonarr/Radarr'a
genişletti ve exact journal/container/ağ proof'undan sabit private 8989/7878
stream'i üretti. DNS, proxy, alternatif hedef ve retry yok. Arr endpoint/readback
ile mevcut Jellyfin/qBittorrent regresyonlarında **97 PASS**; security, queue ve
Gitleaks PASS. Create/start orkestrasyonu açık olduğundan sayaç değişmedi.
[Uygulama ve açık sınırlar](arr-private-endpoint-implementation-2026-09-10.md).

`cdeb54c`–`06242ba` zinciri, config sonrası create/start, fresh private endpoint,
authenticated readback, UID-korumalı IPC ve kalıcı Core sonucunu birleştirdi.
Public iş durumu config, container ve doğrulanmış servis sonucunu ayırıyor; çapraz
servis veya belirsiz sonuç retry edilmeden kapanıyor. `6a1270a` okunabilirlik
düzenlemesiyle deadline readback başlamadan tükenirse açılmış özel stream'in de
kapatılmasını güvenceye aldı. `8f3bfc9`, yanlışlıkla qBittorrent'a yönlenen Arr
reconcile metodunu seçili servise geri bağladı ve qBittorrent reconcile metodunu
doğru sınıfa taşıdı. `382c8a9`, eksik Arr supervisor metodunu tamamladı ve
config/create/start/readback zincirini aynı retained daemon/native thread
kanıtına bağladı; yürütme ile bootstrap yetki, timeout, kaynak ve geçersiz sonuç
hatalarını kapalı, secret-free belirsiz sonuçlara ayırdı. İlgili 13 pakette
**313 PASS / 1 mevcut macOS skip**; Ruff,
compileall, security, queue ve Gitleaks PASS. İki mimarili native
kabul açık olduğundan sayaç değişmedi.
[Uygulama ve açık sınırlar](arr-configured-container-implementation-2026-09-10.md).

`c16c107`–`e9ac68c` zinciri, Sonarr için `/data/shows` ve Radarr için
`/data/movies` kökünü private API üzerinden idempotent biçimde oluşturup ikinci
okumada doğruluyor. Exact mevcut kayıt değişmeden geçiyor; yabancı, ek veya
bozuk kayıt silinmeden `arr_root_folder_conflict` durumuna kapanıyor. Sonuç
bootstrap makbuzuna bağlandı; **23 odaklı / 151 ilgili PASS**, compileall,
security policy, queue ve Gitleaks yeşil. Native dizin hazırlığı, qBittorrent
download-client kaydı ve iki mimarili kabul açık olduğundan sayaç değişmedi.
[Uygulama ve açık sınırlar](arr-root-folder-wiring-implementation-2026-09-10.md).

`7f03b85` native kabul dilimi, Sonarr ve Radarr'ı gerçek AMD64/ARM64
runner'larında ayrı dört iş olarak config/create/start/authenticated readback,
restart ve ikinci readback zincirinden geçirecek kapalı CI makbuzunu ekledi.
Ephemeral daemon/cgroup/namespace sahipliği, exact source hash'leri ve secret-free
makbuz sözleşmesi **25 odaklı / 239 ilgili PASS** ile yerelde doğrulandı; Ruff,
compileall, security policy, queue ve Gitleaks PASS. Gerçek dört native makbuz
henüz gözlenmediğinden `installAvailable=false` ve sayaç değişmedi.
[Uygulama ve açık sınırlar](arr-native-characterization-implementation-2026-09-10.md).
Native kapı PR #51 ile güncel `main` tabanında çalıştırılıyor.

`77448d0` dilimi, ortak yönetilen medya hacmindeki sabit `movies` ve `shows`
dizinlerini production Core binding kanıtına taşıdı. Journal'dan yeniden
türetilmiş tek hacim ağsız, sınırlandırılmış helper'a geçici olarak yazılabilir
bağlanıyor; yol, komut, kullanıcı ve Docker seçenekleri caller girdisi değil.
Hazırlık sonucu aynı resource/operation/journal/nonce/revision ile doğrulanıp
kök yeniden salt okunur kanıtlanmadan container binding'i üretilemiyor. **27
odaklı / 180 ilgili PASS**; Ruff, compileall, security policy, queue, diff ve
Gitleaks yeşil. Exact CI ve iki mimarili native kabul açık olduğu için sayaç ve
`installAvailable=false` değişmedi.
[Uygulama ve açık sınırlar](managed-media-directory-preparation-implementation-2026-09-10.md).

PR54 exact `7fa8350`, qBittorrent'ın config/create/start/private servis doğrulama
makbuzunu aynı preparation kimliğindeki Sonarr/Radarr işleri için zorunlu ve
fail-closed bağımlılığa dönüştürdü. PR56 exact `15fe18b`, bu şifreli private API
anahtarını Arr runtime'a taşıdı; sabit `qbittorrent:8080` download-client
test/create/readback zincirini kök klasör bootstrap'ına ekledi. Endpoint ve
yetki her sır yazımından hemen önce yeniden kanıtlanıyor. PR56'nın **15/15
zorunlu kontrolü**, Android analiz/debug/API35 E2E, tam Server, Security ve
amd64/arm64 Jellyfin/Arr/qBittorrent işleri geçti; squash merge `26978d1` ile
ana dala alındı. S06.5, Seerr ve Music Assistant açık olduğu için kapanmadı.

Seerr'ın ilk `0ffef42` → `f45ad03` ve `1cca084` → `5dc00db` TDD dilimleri,
pinned 3.4.1 API'sinde yalnız yeni `initialized:false` örneğin Jellyfin sistem
hesabıyla ilk admin oluşturmasına izin veren kapalı oturum adaptörünü ekledi.
Admin kimliği ve izin biti doğrulanıyor; yalnız dar `connect.sid` cookie kabul
ediliyor; üretilen API anahtarı geri okunup oturum kapatılıyor. Parola, cookie
ve anahtar hata veya repr yüzeyine çıkmıyor. Managed container yalnız sahipli
`/app/config` hacmi ve internal ağ alıyor; çalışan exact journal container'ından
DNS/retry olmadan RFC1918 TCP/5055 endpoint üretiliyor. **24 ilk-yönetici**, ilgili
probe/kataloglarla **236**, endpoint/binding/resource regresyonlarında **99 PASS**;
security policy ve Gitleaks temiz. PR57 exact `73ccf235` bütün zorunlu Android,
Server, Security ve iki mimarili medya kontrollerinden geçti; squash merge
`e62f407` ile ana dala alındı. Sonarr/Radarr/kütüphane/initialize eşleştirmesi
ve native Seerr kabulü henüz açık.
[TDD kanıtı ve açık sınırlar](seerr-private-bootstrap-implementation-2026-09-10.md).

Sonraki `d53c42e` → `387ed9d` ve `a560c62` → `9ab1d7e` TDD zinciri,
Seerr'ın tamamlanmış start makbuzunu aynı yönetilen ağdaki taze Jellyfin
kanıtıyla birleştiren executor'ı ve UID-korumalı worker IPC operasyonunu ekledi.
Parola gönderilmeden önce ve etkiden sonra iki konteyner ile retained daemon
yetkisi yeniden doğrulanıyor; sonuç yalnız private socket'te API anahtarı
taşıyor. **12 executor**, **7 IPC** ve mevcut kurulum/runtime/supervisor
regresyonlarıyla **160 PASS / 1 mevcut macOS skip** geçti. `341a983` →
`8dd35a7` güvenlik daraltması, worker isteğinden Jellyfin API anahtarı ve
kütüphane verisini çıkarıp yalnız parola ile kaynak bootstrap kimliği/revizyonunu
bıraktı; 6 model ve ilgili 40 test geçti. Exact `8dd35a7` üzerinde tam
Server paketi **5.243 testte geçti**. Core'un şifreli kalıcı Seerr işi henüz bağlı değil; sayaç ve `installAvailable=false` değişmedi.
[Executor ve IPC kanıtı](seerr-bootstrap-executor-implementation-2026-09-10.md).

PR58'in exact `db75479` kaynağı **15/15 zorunlu kontrolden** geçti ve squash
merge `aee92b4` ile ana dala alındı. Sonraki `fb3ecf3` → `47e3d04` TDD dilimi,
aynı doğrulanmış preparation üzerinde Jellyfin ve Seerr için ayrı kalıcı
create/start işleri üretiyor. Worker servis kimliğini plan içindeki tek
`installationId` eşleşmesinden türetiyor; request Docker/image/ağ ayrıntısı
taşımıyor. V1 kurulum ve bağlı Jellyfin bootstrap satırları v2 şemasına ciphertext
değiştirilmeden kayıpsız taşınıyor; foreign key hedefi yeniden kanıtlanıyor. **106 ilgili test**, migration/public contract ve Jellyfin bootstrap kimlik
regresyonları geçti; güncel **5.249 testlik** tam Server paketi yeniden çalışıyor.
`b8fad69a` → `8ce745cf` TDD dilimi, tamamlanmış Seerr konteynerini aynı
preparation içindeki doğrulanmış Jellyfin bootstrap kaynağına exact revizyonla
bağlayan AES-GCM şifreli kalıcı işi ekledi. Yeniden başlatma, idempotency,
kaynak/kurulum drift'i, gizli alan reddi ve sınırlı okuma kapıları yeşil.
`a8751777` → `b85a53ba` dilimi işi UID-denetimli private worker'a bağlıyor,
etki sırasında retained admin ve kaynak revizyonlarını yeniden doğruluyor,
API anahtarını yalnız şifreli kayıtta saklıyor ve belirsiz/yarım etkileri tekrar
çalıştırmadan `needs_attention` durumuna alıyor. Sonarr/Radarr/kütüphane/initialize
eşleştirmesi ve native iki mimari kabul açık; `installAvailable=false` değişmedi.
[Seerr konteyner işi kanıtı](seerr-container-installation-implementation-2026-09-10.md).

S06.4 native kabul koşusu [34326112926](https://github.com/ersingundem/larenor/actions/runs/34326112926)
iki gerçek GitHub runner'ında geçti. İndirilen ARM64 ve X64 makbuzları merge
commit'i `b6e7034` için repo verifier ile tekrar doğrulandı; bu commit'in ikinci
ebeveyni PR head'i `19485ab`. Her iki makbuz da `journaled_managed_v2`, journal
sürümü 2, iki volume, bir restart, hazır imaj, kapalı bootstrap hesabı ve
`installAvailable=false` sınırını kanıtlıyor. Kaynak sınırları istek gövdesinin
yanında çalışan cgroup'da da okundu. Bu kanıt disposable CI daemon'ına aittir;
gerçek ev Docker Engine'ine yazılmadı ve ürün kurulumu açılmadı.

PR16'nın güncel `bf6f860` kaynağı için [Android Build 34332778297](https://github.com/ersingundem/larenor/actions/runs/34332778297)
5.438 Flutter, 4.225 Server, 98 Android native testi ve 17 gerçek API 35
emülatör yolculuğuyla geçti. [Security 34332777924](https://github.com/ersingundem/larenor/actions/runs/34332777924)
yeşil; [managed native 34332777927](https://github.com/ersingundem/larenor/actions/runs/34332777927)
amd64 ve arm64 üzerinde geçti. İndirilen makbuzlar merge commit'i `670614a`
ve ebeveynleri `ffdb48c` / `bf6f860` için tekrar doğrulandı.

Stacked PR18 exact `75af015`, üç mevcut journal'ı tek kapalı runtime'da açan paketli
`larenor-installation-worker` komutunu ve yalnız exact image ID, `verify_root`,
read-only NoCopy volume, networksüz geçici container kabul eden bootstrap
verifier'ı ekledi. `--check-config` journal, socket veya Engine açmaz; IPC socket'i
Docker endpoint'iyle çakışamaz ve journal içine yerleşemez. Bu yeni dilim 43
odaklı testle başladı; güncel exact kaynak yerelde **4.262 PASS / 12 platform
skip**, Linux Server CI'da **4.274 PASS** verdi. [Android Build 34341554668](https://github.com/ersingundem/larenor/actions/runs/34341554668),
[Security 34341554393](https://github.com/ersingundem/larenor/actions/runs/34341554393)
ve [managed native 34341554476](https://github.com/ersingundem/larenor/actions/runs/34341554476)
yeşil; amd64/arm64 makbuzları exact merge `adbb8476` üzerinde tekrar doğrulandı.

`cac0625` → `b6196a1` TDD dilimi, `InstallationWorkerServer` servis thread'i
hazır olmadan IPC açılışını başarılı saymıyor. Supervisor aynı thread'de tek
Docker bağlantısını, socket inode zincirini, socket-bound pidfd'yi ve daemon ile
worker proc/user/mount/network/root kimliklerini tutuyor. Her `apply` ve
`reconcile` çağrısı bu kanıtlarla çevreleniyor; daemon restart/socket değişimi,
yanlış native thread veya işlem sonrası kanıt kaybı başarı döndürmeden bütün
tutulan kaynakları kapatıyor. `5d43299` → `1e94267` düzeltmesi ayrıca image,
volume, network, bootstrap helper ve managed create/start taşıyıcılarının açtığı
her Engine bağlantısının peer PID'sini aynı tutulan canlı pidfd'ye bağlıyor.
Socket activation veya listener FD devrinde aynı inode ve UID arkasındaki farklı
daemon process'i artık kabul edilmiyor. İlgili yerel paket **272 PASS / 4 Linux
skip**;
İlk Linux Server koşusu 4.301 testin 4.300'ünü geçirip test düzeneğinin zaten
bağlı `socketpair` üzerinde ikinci kez `connect()` çağırması nedeniyle durdu;
üretim kodu etkiden önce fail-closed kapandı. `9ce3c5a` gerçek peer pidfd'sini
koruyan preconnected test sarmalayıcısını ekledi. Exact
[Android Build 34349256229](https://github.com/ersingundem/larenor/actions/runs/34349256229)
5.438 Flutter, 4.302 Linux Server, 98 Android native ve 17 gerçek API 35 E2E
testini geçti; gerçek Linux supervisor testi atlanmadı.
[Security 34349256017](https://github.com/ersingundem/larenor/actions/runs/34349256017)
üç işiyle yeşil. Eşit user map'leri tek başına initial host namespace veya
remap-disabled başlangıç kanıtı sayılmaz; `installAvailable=false` korunur.

`422eb80` → `5580f66` ve `ffba1a7` → `5c81207` TDD dilimleri, supervisor'ın
socket-bound proc/root tanıtıcılarından daemon `cmdline` ve daemon köküne göre
çözülen exact `daemon.json` kanıtını no-follow dosya tanıtıcılarıyla tutuyor.
`/version` ile `/v1.47/info` aynı doğrulanmış bağlantıda ve ortak deadline içinde
okunuyor. Peer ve worker için root credentials, tam initial kimlik haritası ve
aynı user namespace zorunlu; başlangıç argümanında veya config'te
`userns-remap`, Engine güvenlik seçeneklerinde `rootless`/`userns`, yanlış
platform, duplicate/bozuk JSON, config değiştirme/yerine koyma ya da deadline
kaybı bütün worker kanıtını etkiden önce kapatıyor. Runtime güvenlik seçenekleri
her effect öncesi/sonrası yeniden okunuyor. Yeni iki modülün **60 testi**
ve kurulum/kimlik/Engine yollarını içeren geniş ilgili paket yerelde geçti.
Exact `b6c8ede` kaynağında tam Server paketi **4.351 PASS / 13 macOS platform
skip** verdi; Security policy, compileall, diff ve kuyruk doğrulaması temiz. Bu yerel kanıt
henüz exact Linux CI veya bağımsız review değildir.

S08.7 üç sonlu teslimden oluşur: **kaynak bağlama ve typed durum → komut ve
kalıcı sonuç → açık Direct aktarımı**. Üç yerel dilim de squash yapılmadan
main'e alındı. Server gerçek HTTP/SQLite/loopback ile kaynak bağlama, yetkili
switch durumu, sınırlı cache ve AES-GCM ile saklanan idempotent komut makbuzu
sağlıyor. Client Core kaynak satırında Aç/Kapat, açık sonuç durumu ve kaybolan
POST yanıtı için yalnız GET kullanan kurtarma akışı sunuyor. DNS/bağlantı/TLS
sonrasında ve ilk HTTP baytından hemen önce yetki/revision yeniden denetleniyor;
eski snapshot yarışları cache nesliyle engelleniyor. Provider yalnız `200`
sonucunda accepted; `400/401/403/404/405/422` rejected ve diğer sonuçlar
unknown. Otomatik retry ve Direct fallback yok.

Açık Direct aktarımı yalnız PIN ile açılan Ayarlar akışında kayıtlı tek HA
URL/token çiftini ve seçilmiş mevcut, boş bir Core switch kaynağını önizler.
Server 60 saniyelik, tek kullanımlık önizlemeden sonra şifreli service, binding
ve sonuç makbuzunu tek SQLite transaction'ında yazar; Client Direct kayıtları
değiştirmez. Oda, sahne, betik, diafon, web-origin izni veya diğer servisler bu
dar aktarımda taşınmaz. Kayıp onay yanıtı yalnız sonuç GET'iyle kurtarılır;
confirm tekrarlanmaz. Güncel admin, kaynak WRITE/revision, PIN, hesap, ev,
pencere ve rota bağlamı ağ öncesinde ve sonrasında yeniden denetlenir.
Gerçek Server HTTP sözleşmesinin 15 kaydı Client'ta 14 HTTP isteği ve değişmiş
confirm'in ağ öncesi reddiyle eşleşti; sözleşme SHA-256 değeri sabit kaldı.

Yeni [salt okunur domain dilimi](core-ha-readonly-domains-implementation-2026-09-09.md)
`domain.object_id` biçimindeki standart ve özel HA varlıklarını kapalı
`kind/state/commandAvailable` projeksiyonuna aldı. Attributes ve upstream
kimlik/sır alanları aktarılmıyor; 255 karakteri aşan veya kontrol karakteri
içeren state reddediliyor. Switch dışındaki domain'ler admin WRITE izninde
bile komut yayınlamıyor, HA'ya POST göndermiyor ve komut journal'ına kayıt
yazmıyor. Android salt okunur ham durumu gösteriyor; `unknown` ile
`unavailable` ayrımını koruyor. Direct aktarımı switch-only kaldı. Yerel ilgili
**200 Server + 219 Android PASS**, tablet matrisi ve analiz temiz; exact-source
CI ve fiziksel cihaz kabulü açık.

Yerel birleşik Server koşusu ortam değişkeni eksikken **3.851 PASS, 12 macOS
platform skip ve 4 setup error** verdi; sabit `apksig 9.1.0` JAR hash'i ve
Homebrew Java 17 yolu doğrulandıktan sonra bu dört kripto testi ayrıca **4/4
PASS** oldu. Bu iki koşu tek temiz tam suite diye toplanmaz. Direct Server
odaklı **87 PASS**, Client odaklı **92 PASS**, Client ilgili **599 PASS**;
yeni Server modülleri %95,93 ve yeni Client modülleri %95,88 satır kapsamı
verdi. Birleşmiş main üzerinde Direct Client **92 PASS**, analiz0 ve 19 dosyada
format farkı0 tekrarlandı. Server ile Client bağımsız kaynak incelemeleri ve
TR/EN 2× 600/1280 gerçek-font tablet görselleri temiz. Exact-source uzak CI ve
APK122 geçti; geniş HA varlık/servis kapsamı ve fiziksel kabul bekliyor.
[Server kanıtı](core-ha-switch-server-implementation-2026-09-08.md) ·
[Client kanıtı](core-ha-switch-client-implementation-2026-09-08.md) ·
[Komut ve makbuz kanıtı](core-ha-switch-command-implementation-2026-09-08.md) ·
[Direct Server aktarımı](direct-ha-migration-server-implementation-2026-09-08.md) ·
[Direct Client aktarımı](direct-ha-migration-client-implementation-2026-09-08.md) ·
[Uygulama planı](core-home-assistant-adapter-plan-2026-09-06.md).

İlk exact-source uzak paket `32d43fd` üzerinde Security ve ayrı Server
Container koşuları geçti; Server **3.867 PASS** ve amd64/arm64 container
manifestini tamamladı. Android işinde tam Flutter **5.436 PASS**, debug APK ve
emülatör **17/17** yolculuk geçti. Aynı workflow'un bağımsız Server kopyası
**3.866 PASS** sonrasında yalnız sentetik volume test sunucusunun isteğe bağlı
ikinci isteği beklerken `socket.timeout` kaydetmesiyle bir fixture hatası verdi;
bu nedenle imzalı APK işi çalışmadı. Tek tam Android logunun SHA-256 değeri
`494e06e10e58a79dcbf2e7ab24846cac64afb54763c45d8640ef71371993eb10`.
Üretim etkisi olmayan yedi satırlık fixture düzeltmesi gerçek 3 RED→4 GREEN,
son 612 ilgili PASS/3 mevcut macOS skip ve paralel 8×4 PASS ile main'e alındı;
ilk GET, başlık/gövde sınırları, callback hataları ve çağrı sayısı korunuyor.
[Fixture yaşam döngüsü](volume-create-fixture-lifecycle-repair-2026-09-08.md).
İkinci exact-source paket `bd1a604` üzerinde bu yarış kapandı. Security, ayrı
Server Container **3.867 PASS**, amd64/arm64 imaj ve manifest yayını; Android
workflow'unda **5.436 Flutter PASS**, **3.867 Server PASS**, debug/native
sözleşmeleri ve API 35'te **17/17 E2E** geçti. İmzalı **APK122** üretildi ve
yerel resmi `apksig 9.1.0` doğrulamasında `com.ersingundem.larenor`,
`versionCode=100000122`, `minSdk=26`, `debuggable=false`, beklenen sertifika ve
geçerli imza olarak doğrulandı. APK 122.207.785 bayt; SHA-256
`21cc73b9c471ad08c21e010c8cf382410ce57d539ca1b9c395c42fd3064ca94b`.
Bu CI/artefact kabulü Direct→Core ve ortak tablet paketini doğrular; fiziksel
Huawei/DeX/TalkBack ve geniş Home Assistant varlık/servis kapsamı açık kalır.

Arşiv E2E yardımcısındaki rota-sahipliği yarışı exact `e97189f` üzerinde
kapandı. Güncel ve dokunulabilir izinli rota içinden tek dikey kaydırma sahibi
seçiliyor; küçük 420×400/2× HomeSource görünümü ve gerçek Archive geçişi
regresyon testleriyle korunuyor. İlgili 200 yerel test ve analiz temizdi;
uzak Android CI **5.438 Flutter PASS**, **3.934 Server PASS** ve API 35'te
**17/17 E2E** verdi. İmzalı **APK125**, bağımsız Security ve Server Container
işleri de aynı exact source üzerinde geçti. Bu kanıt test yarışını kapatır;
fiziksel cihaz kabulünün yerine geçmez.

[Services tablet paketi](core-services-tablet-accessibility-2026-09-06.md):
46 yeni ve 186 ilgili test geçti; tam bağlantı adları, 48px hedefler, görünür
klavye odağı ve tek adımlı IME geçişi düzeltildi.
[Core hesap formları](core-account-ime-navigation-2026-09-08.md):
12 gerçek hata yeniden üretildi; son 24 IME ve 163 ilgili test geçti.
Üretimde yalnız yinelenen iki odak geçişi kaldırıldı. Bu iki paket exact
`5cbff21` / APK116 ile temiz CI ve bağımsız imza kapısından geçti. Önceki birleşik
Client koşusu `cd961ac` üzerinde tamamlandı; Mac'in uzun
bakım uykularıyla çakışan iki 90 saniyelik test zaman aşımı kaydedildi. Bu koşu
başarılı sayılmıyor. Kaynak ve test süreleri değiştirilmeden iki testin odaklı
tekrarı **2 PASS**, tam analiz **0 sorun** ve biçim kontrolü **973 dosya / 0 fark**
verdi. [Birleşim ve korunan başarısız koşu](core-services-ime-integration-2026-09-08.md).
Bu önceki başarısız yerel koşu tarihsel kanıt olarak korunur; CI116 aynı
kaynağın devamında 5.220 Flutter testinin tek koşuda geçtiğini doğrular.

[Jellyfin yönetilen kurulum planı](jellyfin-managed-volume-installation-plan-2026-09-06.md)
dört adımdır: gerçek image/UID karakterizasyonu, onu tüketen mount/kurulum akışı,
güncel yönetici/worker yetkisi ve özel ilk hesap ile doğrulanmış Core bağlantısı.
[Helper fixture](jellyfin-storage-fixture-implementation-2026-09-08.md)
main ile birleşti: **87 odaklı ve 261 ilgili test geçti**. Bağımsız incelemede
bulunan build context ve kaynak değişimi sorunları gerçek RED/GREEN ile
kapatıldı; son kaynak incelemesi temiz. Manuel native amd64/arm64 CI hazırlığı ve kaynak incelemesi tamamlandı:
122 fixture/launcher ve 215 politika testi geçti.
[Birleşik yayın hazırlığı](services-ime-native-ci-preparation-2026-09-08.md).
İlk manuel native amd64/arm64 koşusu iki mimaride de genel karakterizasyon
hatasıyla kapandı ve makbuz üretmedi. Kapalı phase/hata kodu tanılaması
8 RED→8 GREEN, toplam 139 odaklı test, 215 politika testi ve %96,09 dal dahil
kapsamla main'e alındı. [Tanılama kanıtı](jellyfin-native-storage-diagnostics-2026-09-08.md).
Bu aşamada kesin neden tahmin edilmiyor.
İkinci koşu her iki mimaride de `helper_build / fixture_command_failed` verdi;
bu, kaynak/daemon/imaj/volume/staging kapılarının geçtiğini daralttı. Helper build
altında exit, çıktı sınırı, zaman aşımı, spawn ve I/O hatalarını ham stderr
taşımadan ayıran ek tanılama 5 RED→5 GREEN, toplam 152 test, 215 politika testi
ve %96,49 dal dahil kapsamla main'e alındı.
[Helper build tanılama kanıtı](jellyfin-helper-build-diagnostics-2026-09-08.md).
Üçüncü koşu iki mimaride de `helper_build / fixture_command_exit_failed`
verdi: child gerçekten nonzero çıktı; timeout, stdout sınırı, spawn ve I/O
sınıfları elendi. Yalnız helper build stderr'ini 64 KiB özel RAM sınırında
drain edip bilinen Docker hata ailelerini sabit kodlara dönüştüren son tanılama
12 RED→12 GREEN, toplam 172 ilgili test, 215 politika testi, %96,48 dal dahil
kapsam ve bağımsız CLEAR ile main'e alındı. Ham stderr, path, URL, env veya sır
log/artifact'a çıkmaz; belirsiz/taşan veri genel kapalı kod olarak kalır.
[Özel build tanılama kanıtı](jellyfin-private-build-errors-2026-09-08.md).
Bu sınıflandırıcıyı içeren dördüncü native koşu `34240514836`, exact
`42bbcf6` üzerinde iki mimaride de yine
`helper_build / fixture_command_exit_failed` verdi; bounded stderr bilinen bir
hata ailesine uymadı. Kök neden çıkarılmadı. Sonraki koşunun helper build'den
önce exact, digest-pinned Python base imajını pull/inspect/create/start/result
sınırlarında ayrı sınaması main'e alındı: 38 yeni, toplam 210 ilgili test ve
215 politika testi geçti; dal dahil kapsam %97,02 ve bağımsız inceleme temiz.
[Exact base runtime probe](jellyfin-helper-base-runtime-probe-2026-09-08.md).
Beşinci native koşu `34250089907`, exact `25d438a` üzerinde pull, image inspect,
create ve created-state kapılarını iki mimaride geçti; exact base
`start --attach` aşaması `fixture_command_failed` verdi. Tek indirilen logun
SHA-256 değeri
`c7444904c1bbeecb7f49d14725aeeb4d068800022938cc409b6fb24771cc9cd0`.
Bu start çağrısında stderr toplamadan mevcut nonzero/timeout/output-limit/
spawn/I-O sınıflarını açan dar tanı main'e alındı: 15 yeni, toplam 225 ilgili
test ve 215 politika testi geçti; dal dahil kapsam %97,18, bağımsız inceleme
temiz. [Attached start tanısı](jellyfin-base-start-process-diagnostics-2026-09-08.md).
Altıncı native koşu `34257672707`, exact `32d43fd` üzerinde iki mimaride de
`helper_base_start / fixture_command_exit_failed` verdi. Tek indirilen log
70.211 bayt, SHA-256
`f5357a2f73df32572efcf306599d621609fe215e8d5347237c082b34e44acbb1`.
Bu, CLI sürecinin nonzero çıktığını kanıtlar; attach, start, wait veya container
çıkışı arasında kök neden seçmez. Yalnız exact attached base start çağrısında
64 KiB + 1 bayt özel stderr drain eden kapalı tanı main'e alındı: 10 gerçek
RED→10 GREEN, 32 yeni, toplam 257 ilgili ve 215 politika testi geçti; runner ve
launcher dal dahil kapsamı %97,28, bağımsız inceleme temiz. Ham stderr hiçbir
çıktıya yazılmaz; tek leaf wrapper'a üstün, birden çok leaf ambiguous, boş veya
eşleşmeyen mesaj eski genel hata olarak kalır. 20 saniye/128 bayt stdout, tek
deneme ve process-group cleanup değişmedi.
[Private start tanısı](jellyfin-base-start-private-stderr-2026-09-08.md).
Birleşmiş main üzerinde Jellyfin, Engine HTTP ve volume ailesinin **847 PASS /
3 mevcut macOS skip** koşusu da geçti. Yedinci native koşu `34260536889`, exact
`bd1a604` üzerinde iki mimaride yine
`helper_base_start / fixture_command_exit_failed` verdi; bounded stderr bilinen
bir aileyle eşleşmedi. Tek indirilen log 70.222 bayt, SHA-256
`8ac144f5069622b8bcb5fd63d55bbdcfd9d481fd92637f599005df91ec8a70c4`.
Başarısız tek start denemesinden sonra yalnız aynı sahipli containerın `.State`
alanını 10 saniye/64 KiB sınırında okuyan tanı yerelde hazır: 15 RED→15 GREEN,
249 son Jellyfin ve 215 politika testi geçti; runner+launcher dal dahil kapsamı
%98'e yuvarlandı. OOM/dead/running/exited-nonzero sonuçları kapalı ve neden
iddiası taşımayan kodlara dönüşür; bozuk/okunamayan durum eski kapalı kodu
korur. İki inceleme P2'si kapatıldı ve final bağımsız inceleme CLEAR.
[State tanısı](jellyfin-base-start-state-diagnostics-2026-09-08.md).
Bu state tanısı tek başına Engine/install kabulü sayılmadı.
Sekizinci koşu `34263828110`, exact `18b4623` üzerinde arm64'te
`helper_base_wait_failed`, amd64'te `fixture_command_exit_failed` verdi; başarı
makbuzu yok. Tek indirilen 70.190 bayt logun SHA-256 değeri
`27dbd3a1724475af715faa1e2c4cd5e4d3c5350a2b0cca92aeb91a28611b4a82`.
Bu mimariye göre farklı sonuç tek ortak neden iddiasını desteklemiyor. Mevcut
bounded state gözleminde kalan iki olgusal sonuç yerelde ayrıldı: boş hata ile
`exited/0` ve `created/0`. İki gerçek RED kapandı; 15 state, toplam 251
Jellyfin ve 215 politika testi geçti. Tek start/inspect, redaksiyon ve cleanup
değişmedi; bağımsız final inceleme CLEAR.
[Zero-state tanısı](jellyfin-base-zero-state-diagnostics-2026-09-08.md).
Dokuzuncu koşu `34267014037`, exact `63b25f8` üzerinde iki mimaride de
`helper_base_start / fixture_command_exit_failed` verdi; başarı makbuzu yok.
Tek indirilen 70.203 bayt logun SHA-256 değeri
`85f0cd8e7c8308e42062b00eeaf9870f4d99c328d822a1169b7fd64fe8384076`.
Zero-state kodlarından hiçbiri gözlenmedi. Genel start sonucu için state
okunamadı/geçersiz/sınıflandırılmadı ayrımı yerelde eklendi; daha güçlü wait,
timeout, permission ve runtime gözlemleri korunuyor. İlk altı RED ile incelemede
bulunan Unicode/Recursion P2'sinin iki gerçek RED'i kapandı; 21 state, toplam
257 Jellyfin ve 218 politika testi geçti. Tek bounded inspect, redaksiyon,
cleanup ve no-retry sınırları değişmedi; bağımsız final inceleme CLEAR.
[State-read tanısı](jellyfin-base-state-read-diagnostics-2026-09-08.md).
Onuncu koşu `34270629266`, exact `e97189f` üzerinde iki mimaride de
`helper_base_start / helper_base_state_unclassified` verdi; başarı makbuzu yok.
Tek indirilen 70.215 bayt logun SHA-256 değeri
`27e931c6eaa35470d68a329cfc010e34a0b99f143fc38e57a152da8fbd683f58`.
Bu, tek bounded state okumasının typed ve geçerli olduğunu doğruladı. Kalan
şekil, ham hata metni taşınmadan unknown error, created/nonzero, unknown status
ve diğer bilinen status olarak ayrıldı. Dört gerçek RED kapandı; 28 state,
toplam 264 Jellyfin ve 218 politika testi geçti. İncelemede geçerli Docker
`removing` durumuna “tutarsız” denemeyeceği nötr kategoriyle güvence eklendi;
final bağımsız inceleme CLEAR.
[State-shape tanısı](jellyfin-base-state-shape-diagnostics-2026-09-08.md).
On birinci koşu `34273975969`, exact `bd03125` üzerinde iki mimaride de
`helper_base_start / helper_base_state_error_unclassified` verdi; başarı
makbuzu yok. Tek indirilen 70.209 bayt logun SHA-256 değeri
`37654a4e183b644beaeffc175234e1d0350e195ef6039d5bb58326e5bdd0baad`.
Bu sonuç typed state içindeki boş olmayan hatayı doğruladı ancak metni veya
nedeni açığa çıkarmadı. Kalan hata cgroup/security-profile/namespace/mount,
host kaynağı, yol, kimlik ve yapılandırma ailelerine yerelde ayrıldı; çoklu
eşleşme ayrı kapalı ambiguous sonucuna gider. Beş gerçek RED kapandı; 34 state,
66 state+stderr, toplam 270 Jellyfin ve 218 politika testi geçti. Tek bounded
inspect, redaksiyon, cleanup ve no-retry sınırları değişmedi; exact commit için
bağımsız inceleme CLEAR.
[State-error aileleri](jellyfin-base-state-error-families-2026-09-08.md).
On ikinci koşu `34276890501`, exact `282bcc1` üzerinde iki mimaride de
`helper_base_start / helper_base_path_failed` verdi; başarı makbuzu yok. Tek
indirilen 70.199 bayt logun SHA-256 değeri
`555a81b36a5713364ffdef8a658be8d76a763f832e1ec678329c08ff199e0cba`.
Bu sonuç image/proc/sys/runtime/Engine/host yol konumu ailelerine yerelde
ayrıldı; çoklu eşleşme ambiguous, bilinmeyen konum generic kalıyor. İlk yedi
RED ile incelemede bulunan “missing” ENOTDIR yanlış iddiası ve çıplak runtime
adı P2'leri gerçek regresyonlarla kapandı. 43 state, 75 state+stderr, toplam 279
Jellyfin ve 218 politika testi geçti. Tek bounded inspect, redaksiyon, cleanup
ve no-retry sınırları değişmedi.
Exact commit için bağımsız final inceleme CLEAR.
[Yol-konumu tanısı](jellyfin-base-path-location-diagnostics-2026-09-08.md).
On üçüncü koşu `34279647850`, exact `8f07560` üzerinde iki mimaride de
`helper_base_start / helper_base_path_location_ambiguous` verdi; başarı
makbuzu veya artefakt yok. Tek indirilen 70.214 bayt logun SHA-256 değeri
`a8e7ac3ee4053ffc9673c91fa7de1a7f08d732f5be3926a34588efe7eb9634fb`.
Engine kökü ile image/proc/sys/runtime/host hedefini aynı path belirtecinde
kanıtlayan beş ilişki ayrıldı. İki ayrı yolun tek ilişki sayılması P2'si gerçek
RED ile kapandı; üç aile veya bağımsız iki yol ambiguous kalıyor. 50 state, 82
state+stderr, toplam 286 Jellyfin ve 218 politika testi geçti. Exact commit için
bağımsız final inceleme CLEAR. Tek bounded inspect, redaksiyon, cleanup ve
no-retry sınırları değişmedi.
[Yol-ilişkisi tanısı](jellyfin-base-path-relation-diagnostics-2026-09-09.md).
Exact `8f07560` Server Container ve Security CI geçti. Android debug, analiz,
5.438 Flutter testi ve 17/17 E2E geçti; yeniden kullanılan Server işi eski 15
dakikalık sınırda iptal edildiği için imzalı paket atlandı. `3dbdde2` test
kapsamını değiştirmeden bu bounded sınırı 20 dakikaya çıkardı. Exact `1e73ea3`
yeniden koşusunda tam Server kapısı, 17/17 E2E ve imzalı APK129 başarıyla geçti.
On dördüncü koşu `34281674390`, exact `1e73ea3` üzerinde iki mimaride de
`helper_base_start / helper_base_path_location_ambiguous` verdi; başarı
makbuzu veya artefakt yok. Tek indirilen 70.207 bayt logun SHA-256 değeri
`81409d865a87f785bda58094a978344e4ed37d6817f1562184744a8da5309bed`.
Engine kökü ile image/proc/sys/runtime/host ailelerinin exact ikili birlikte
görülmesi beş nötr `*_paths_observed` koduna ayrıldı; aynı token ilişkisi daha
özel kalıyor, üçlü ve diğer kümeler ambiguous. Beş gerçek RED kapandı; 54
state, 86 state+stderr, toplam 290 Jellyfin ve 218 politika testi geçti.
Bağımsız final inceleme CLEAR; tek inspect/no-retry/redaksiyon/cleanup sınırları
değişmedi.
[Path birlikteliği tanısı](jellyfin-base-path-cooccurrence-diagnostics-2026-09-09.md).
On beşinci koşu `34284431981`, exact `d5d5889` üzerinde iki mimaride de
`helper_base_start / helper_base_engine_proc_paths_observed` verdi; başarı
makbuzu veya artefakt yok. Tek indirilen 70.226 bayt logun SHA-256 değeri
`6a22d9e663d17e2856a7ac445d0f5a754e82725bd7b53147bc769c4f1e9a9d20`.
Procfs gözlemi sys/net, self fd, exact mountinfo, self namespace ve sayısal
process namespace/fd alt ailelerine ayrıldı. `/proc/sys` artık sysfs sayılmıyor;
başka köklerdeki benzer metin ve `mountinfo-private` iki gerçek review RED ile
kapandı. Son exact kod Python 3.12.14 altında 64 state, 96 state+stderr, toplam
300 Jellyfin ve 218 politika testini geçti. Bağımsız final inceleme CLEAR.
Aynı kodu taşıyan exact `5407011` izole Server
CI koşusunda 3.977 test geçti.
[Procfs alt yol tanısı](jellyfin-base-proc-subpath-diagnostics-2026-09-09.md).
On altıncı koşu `34287061380`, exact `b4e8620` üzerinde iki mimaride de
`helper_base_start / helper_base_proc_process_namespace_observed` verdi;
başarı makbuzu veya artefakt yok. Tek indirilen 70.230 bayt logun SHA-256
değeri `c9ba3dd9cbd9891036426bc927aa79538a5c49eb8dac48f1e3ffb10c876cb83a`.
Sayısal süreç namespace yolu net/mnt/ipc/uts/pid/pid-child/user/cgroup/time/
time-child yapraklarına ayrıldı; PID kapalı kodlara girmez. Path metni genel
hata imzalarından ayrılarak `cgroup` yaprağının izolasyon hatası sanılması
önlendi. On bir gerçek RED kapandı; son exact kod 75 state, 107 state+stderr,
toplam 311 Jellyfin ve 218 politika testini geçti. Bağımsız final inceleme
CLEAR. Exact `ce5479a` izole Server CI koşusunda 3.988 test geçti.
[Process namespace tanısı](jellyfin-base-process-namespace-diagnostics-2026-09-09.md).
On yedinci koşu `34289499126`, exact `d7b2027` üzerinde iki mimaride de
`helper_base_start / helper_base_proc_process_net_namespace_observed` verdi;
başarı makbuzu veya artefakt yok. Tek indirilen 70.235 bayt logun SHA-256
değeri `0db35348fe1aff1f7177b174b5e961fe206e41d4d95c93693ca6dae290b65c09`.
PID namespace içinde host procfs görünümünü bırakma adayı yerel testlerde
311 Jellyfin ve 218 politika testini geçti; ancak bağımsız inceleme iç thread
kimlikleri ile procfs sayı uzayını ayırdığını gösterdi. Aday Native'e
gönderilmeden geri alındı. `30a2b3b` onarımı mount-only daemonı transient
systemd servisine, helper ve Jellyfin süreçlerini aynı servisin ayrı
`containers` cgroup alt ağacına alır. Systemd kimliği, invocation, ana PID ve
cgroup inode'u iki aşamada doğrulanır; temizlik yalnız önceden açılmış
`cgroup.kill` ve aynı `cgroup.events` descriptorlarıyla yapılır. Launch yanıtı
belirsizse aynı adlı servis sonradan sahiplenilmez. 351 Jellyfin ve 219 politika
testi geçti; bağımsız final inceleme CLEAR. Exact-source izole Server CI
[34293524785](https://github.com/ersingundem/larenor/actions/runs/34293524785)
4.027 testi iki uyarıyla geçti. Paket `6a054ea` olarak main'e alındı. Native18
[34294788670](https://github.com/ersingundem/larenor/actions/runs/34294788670)
aynı exact kaynak üzerinde amd64 ve arm64 karakterizasyonunu, platform/source
makbuz doğrulamasını ve iki public artifact yüklemesini geçti. İndirilen iki
1.753 bayt makbuz yerelde aynı verifier ile yeniden doğrulandı; iki volume,
bir restart, hazır imaj ve iki `observed_requires_bootstrap` sonucu taşırken
`bootstrapAccountConfigured=false` ve `installAvailable=false` kaldı. S06.3d
iki mimarili native kabulü kapandı. Main Server Container
[34294585502](https://github.com/ersingundem/larenor/actions/runs/34294585502)
4.027 testten sonra iki mimari image build/smoke ve manifest yayınını da geçti;
Security `34294584966` başarılı. S06.3f tam kaynak makbuzu sıradaki kapıdır.
Android
[34294585430](https://github.com/ersingundem/larenor/actions/runs/34294585430)
aynı exact kaynakta 5.438 Flutter, 17 API 35 E2E ve 4.027 Server testini,
native platform kontrollerini ve imzalı APK135'in paket/imza/sürüm
doğrulamasıyla Larenor Server yayımını geçti.
[Sahiplikli cgroup yaşam döngüsü](jellyfin-owned-cgroup-lifecycle-2026-09-09.md).
Gerçek ev kurulumu ve kullanıcı kurulum yetkisi hâlâ açık;
`installAvailable=false`.

S06.3f için ayrı native kaynak fixture’ı yalnız katalogda sabit Jellyfin
image’ını pull/inspect eder ve tek iç control network’ü create/list/full-ID
inspect ile doğrular. Aynı journal kapatılıp yeniden açıldığında hazır
makbuzların hiçbir Engine I/O’su veya yeni yetki istemeden okunabildiği kapalı
bağımlılıklarla sınanır. Public makbuz ham network ID veya preparation ID
taşımaz; yalnız ağ kimliğinin SHA-256 değerini, kaynak dosyalarının özetlerini,
`containerOperations=0` ve `installAvailable=false` değerlerini içerir.
İlk incelemede ortak daemon açılışındaki tek `docker info` CLI çağrısı kabul
sınırını aştığı için ilk uzak CI iptal edildi. Kaynak fixture daemon’ı artık
canlı systemd MainPID ve `/proc/<pid>/cmdline` değerini baştan sona sabit argv
ile doğruluyor; bütün Docker CLI çağrılarını kapalı hata ile reddediyor. Odaklı
44 test, ilgili 674 test ve güvenlik politikası yerelde geçti. Tam 4.284
testlik yerel koleksiyonda yalnız zorunlu apksig ortamı verilmediği için dört
setup hatası oluştu; sabit apksig 9.1.0 SHA-256 doğrulandıktan ve Homebrew Java
17 yolu verildikten sonra bu dört kriptografik test 4/4 geçti. Exact-source
Exact `191baf3` Server CI 4.0k+ test paketiyle geçti. Managed v2 create/start için
ayrı kaynak-bağlı amd64/arm64 workflow ve kapalı receipt verifier `3be1dc6`
üzerinde yerelde hazırlandı; bu yeni workflow'un iki native artifact'i henüz
bekleniyor.
[Yerel kaynak kabul kaydı](media-resource-native-acceptance-2026-09-09.md).

İlk main bütünlük tekrarında bağımsız Server CI 4.064 PASS ve native iki mimari
PASS olmasına karşın Android ile Server Container’ın eşzamanlı reusable Server
işleri aynı sentetik volume `False-arm64` varyantında `uncertain` verdi. Hedef
test 20 seri ve 64 paralel tekrar geçti. Fixture’ın HTTP header okuyucusunda
byte başına socket syscall üreten yol bloklu, 16 KiB ile sınırlı ve header ile
aynı pakette gelen body’yi koruyan okuyucuya çevrildi; ürün Engine timeout veya
retry davranışı değiştirilmedi. İlgili 307 test ve yük altında ikinci 64 tekrar
geçti. Güncel exact-source main CI bu fixture commit’i için yeniden koşmalıdır.

## Canlı takip ve sıradaki işler

- [Yürütme kuyruğu](EXECUTION_QUEUE.md): durumlar, bağımlılıklar ve kabul kapıları.
- [Makinece doğrulanan kuyruk](execution-queue.json): tamamlanan ve kalan 125 iş.
- [GitHub Actions](https://github.com/ersingundem/larenor/actions): gönderilmiş kaynağın canlı CI durumu.
- [Ürün planı](product-implementation-plan-2026-09-05.md), [Core/Client mimarisi](server-client-architecture-2026-09-05.md) ve [test matrisi](testing-matrix-2026-09-05.md).

Her doğrulanan dilimden sonra bağımlılıkları hazır sıradaki yazılım işine
geçilir. Aynı Codex görevindeki “Larenor geliştirme ve bakım” takibi 15 dakikada
bir planı ve yarım kalan işleri kontrol eder; ikinci çakışan yürütücü açmaz.
Mac/Codex açık ve erişilebilir olmalı, kullanım hakkı bulunmalıdır. Yerel
uyku veya kullanım sınırı sırasında çalışma kesilebilir; bu dosya tek başına
arka plan servisi değildir. Takip Codex'in zamanlanmış görevlerinden durdurulabilir.

Günlük GitHub depolama bakımı Türkiye saatinde 03.15 sonrasında en fazla bir
kez çalışır. **8 Eylül: 7 eski debug APK, 909.621.176 bayt temizlendi**;
en yeni üç debug APK ve bütün imzalı APK/test raporları korundu. Silinen ID'lerin
artık bulunmadığı ve korunanların durduğu taze envanterle doğrulandı.
GHCR paketleri silinmedi. [Saklama politikası](github-storage-retention.md).

Önceki başarısız [CI105](client-delivery-105-2026-09-06.md) ve
[CI106](client-delivery-106-2026-09-06.md) kanıtları değişmedi;
[CI108 öncesi kuyruk kayıtları](restore-people-evidence-before-ci108-acceptance-2026-09-08.json)
ayrı korundu. Yeni 63 özellik sayacı **0/63**; yazılan planlar kabul edilmiş
özellik olarak gösterilmiyor.

## Önceki teslim kayıtları

Aşağıdaki kayıtlar kendi tarih ve kaynaklarına aittir; güncel durum yukarıdadır.

**CI102 sonuçlandı: Core ve güvenlik geçti; Android teslimi durdu.**
Exact `38bc2bc` kaynakta Linux3.203, Flutter4.417, güvenlik207, JVM98 test geçti.
E2E13 PASS/1 FAIL: onuncu logout yolculuğu test verisindeki `ref.id` yerine
`id` okuduğu için mount öncesinde düştü; imzalı APK102 üretilmedi.
[Sonuç ve hata kaydı](client-delivery-102-2026-09-06.md).
Dar fixture onarımı `2cced39` GitHub'a gönderildi: yeni regresyon RED→GREEN,
88 ilgili test ve tam analiz geçti; bağımsız kaynak incelemesi temiz.
[Android103](https://github.com/ersingundem/larenor/actions/runs/34012091515),
[Core](https://github.com/ersingundem/larenor/actions/runs/34012091577) ve
[güvenlik](https://github.com/ersingundem/larenor/actions/runs/34012091354)
CI103 sonuçlandı: Core3.203 ve güvenlik207 geçti; Android13 PASS/1 FAIL,97/99 faz.
Çıkış sonrası yeniden kurulan ekran geçici olarak yokken test erken okuma yaptı.
[Başarısız koşu ve sınırları](client-delivery-103-2026-09-06.md) korunur.
Dar bekleme onarımı `64bdf58`: RED1 PASS/2 FAIL→GREEN3 PASS;91 destek testi,
tam analiz0 ve899dosya biçim kontrolü geçti; bağımsız inceleme temiz.
[Android104](https://github.com/ersingundem/larenor/actions/runs/34013071464),
[Core31](https://github.com/ersingundem/larenor/actions/runs/34013071566) ve
[güvenlik104](https://github.com/ersingundem/larenor/actions/runs/34013071378)
sonuçlandı: Core Linux3.203, güvenlik207, Flutter4.421 ve JVM98 geçti.
Android14 E2E/99faz ve bağımsız imzalı APK104 teslimi de doğrulandı.
[Sonuç](client-delivery-104-2026-09-06.md).

**S08.5 başladı:** logout'ta başarısız kalıcı silme sonrası eski oturumun geri
kullanılması ve gecikmiş hatanın Core ana ekranında görünmemesi gideriliyor.
Paralelde geri yükleme önizlemesi/onayı, hedef okuma kümesi ve özel journal
aynı işleme bağlanıyor; provider kapanışında açık devir uygulanacak.
[Somut uygulama sırası ve açık sınırlar](client-restore-logout-implementation-plan-2026-09-06.md).
Logout `2911ac9`, **25 odaklı / 1.547 ilgili PASS** ve bağımsız son inceleme
ile yerelde tamamlandı. Volume Unix okuyucusu `0d86fa1` ile ayrı sonraki
`091b2bb` birleşiminde **4.415 tam Client PASS / 5:05**, **3.192 tam Core
PASS / 11 Linux skip / 5:13**, analiz0 ve896dosya biçim farkı0 elde edildi.
[Sonraki birleşim](volume-reader-integration-2026-09-06.md).
Onuncu Android çıkış yolculuğu `0bf1258` ile birleşti: **87 fixture testi**, tam analiz0 ve897dosya biçim kontrolü geçti. Eski9yolculuk/89faz aynen korundu; yeni hedef **14 E2E / 99 faz**. İki yeni host testi önceki tam koşuya dahil değil.
Restore çalışması ve yeni paketin kendi CI kabulü açık. CI101 kaynağına
bu değişiklikler eklenmedi. Ayrı restore dallarında gerçek dosya ve Server
kasası ekranları prepared journal yoluna geçiriliyor; başarısız kurtarma
sonrasında eski ekranların açılması, değişen hedefe yazma ve başka journal'a
müdahale etme sınırları RED→GREEN ile kapatılıyor. Hazırlanan restore ve Vault dalları `552e67f` yerel birleşiminde bir araya geldi.
Dosya restore376, Vault387 ilgili test kanıtı kendi dallarına aittir ve toplanmaz;
Vault erişilebilirlik ek düzeltmesi1ab3483 ile birleşti:73 ilgili test geçti.
`c0d8145` uygulama/test kaynağında **4.544 tam Client PASS / 6:09**,
analiz0 ve912dosya biçim farkı0 elde edildi. Politika testleri kontrollü
tam tekrarda207 PASS verdi. [Birleşim ve bütün sonuçlar](prepared-vault-household-integration-2026-09-06.md). Core oda arşivinin model/şifreleme/tek kullanımlık restore katmanları yerelde
birleşti: codec55 yeni/168 ilgili, controller35 yeni/159 ilgili test geçti.
Aynı Core/ev/kullanıcı ve güncel hedef sınırı bağımsız incelendi. Gerçek dosya
seçimi/önizleme/onay tablet ekranı523a07f ile birleşti: **61 yeni/410 ilgili
PASS**, yeni satır kapsamı%97,60, analiz/format12dosyada0; kaynak ve EN/TR
büyük yazı görselleri ayrıca incelendi. [Arşiv ekranı](core-layout-archive-ui-implementation-2026-09-06.md).
Arşiv Android yolculuğu56607c6 da birleşti:101 host destek testi geçti;
bunlar native kabul sayılmaz. Eski10gövde/99faz +üye8 +arşiv12 =119 faz,
hedef4platform+12uygulama yolculuğudur. Kişi admin akışı eklenirken son
birleşik test/CI hazırlanıyor; bütün S08.5 kabulü açık.

**S08.6 kişi sözleşmesi yerelde hazır:** ayrı `person` modeli46 yeni/92 ilgili
Server testi ve bağımsız kaynak incelemesiyle geçti. Eski oda/kaynak modeli
aynı kaldı. Kişi oluşturma yalnız ad/sıra kabul eder; hesap, rol, izin veya
HA kişisi bağı yaratmaz. Ayrı kişi HTTP API/şifreli SQLite kaydı104 ilgili test ve dal dahil%89 kapsamla
yerelde tamamlandı; bağlı SQLite nesnesi inceleme bulgusu kapatıldı.
İlk tam Server koşusunda eski şema test verilerinden gelen5hata bulundu.
Yalnız test verisi hazırlığı düzeltildi;137 ilgili test geçti. Son tam Server
koşusu **3.298 PASS / 11 Linux skip / 321,74sn** verdi; üretim korumaları değişmedi.
Android kişi modeli/API adaptörü yerelde birleşti:77 yeni/278 ilgili test,
analiz0 ve bağımsız inceleme geçti. Gerçek HTTP sözleşmesi birleşimde2 testle
yeniden doğrulandı. Kişi provider/controller4184289 yerelde birleşti:58 yeni/135 kişi/418 ilgili
PASS; analiz0 ve bağımsız inceleme temiz. Üye listesi, PIN korumalı admin
profilleri/izin ekranları eed3916 ile gerçek arayüze bağlandı: **55 yeni/608 ilgili
PASS**, satır kapsamı%96,29, analiz0 ve12dosya biçim farkı0. EN/TR,2×,
320/600/1280 ve klavye kontrolleri ile bağımsız inceleme geçti.
[Kişi ekranı kanıtı](home-people-ui-implementation-2026-09-06.md).
Read-only Android fixture113 destek testiyle birleşti. Üye yolculuğu754d87e
hazır: eski10gövde/99faz aynı,8yeni faz; henüz Android'de çalıştırılmadı.
Admin/ACL yolculuğu ayrıca hazırlanıyor. Önceki634bc10 kaynağında
**4.870 tam Client PASS / 5:14**, analiz0 ve931dosya biçim farkı0 vardı;
bu sayı yeni ekranları/fixture testlerini içermez. Yeni HTTP sözleşmesi dahil
son tam Server koşusu **3.300 PASS /11 Linux skip /439,183sn** verdi;
Server/contract ağacı sonraki UI birleşimlerinde aynı kaldı. Birleşimin yeni tam Client testi
ve kendi CI/APK kabulü açık; bu kişi paketi APK104'e dahil değildir.
[Model kanıtı](home-people-contract-implementation-2026-09-06.md).

**S08.4 kabul edildi:** üç madde ve 22 kayıt sınıfı exact `1c2db57` kaynağında
bağımsız son inceleme + CI/APK100 ile doğrulandı.
[İnceleme](client-boundary-acceptance-review-2026-09-06.md).
Önceki 31 alt dilim ve kapanış öncesi 14 kanıt, başarısız Android97 dahil
[özgün arşivde](client-boundary-evidence-archive-2026-09-06.json) ve
[kapanış arşivinde](client-boundary-completion-archive-2026-09-06.json) korunur.

## Önceki checkpoint notları

Aşağıdaki sonuç ve “açık/bekliyor” ifadeleri ilgili eski kaynağın tarihsel
snapshot'ıdır. Güncel kabul, sıradaki paket ve aktif işler yukarıda gösterilir.

**Önceki tam doğrulanmış yayın `a27abea` / APK 101.** Üç CI ilk denemede başarılı:
Core **3.104 PASS / 0 skip**, güvenlik **207 PASS**, Flutter **4.390 PASS**,
JVM **98 PASS**, **4 platform + 9 uygulama = 13 E2E PASS / 89 sıralı faz**.
Tam analiz0; CI formatter895 dosya,0 fark. İmzalı APK tek tam indirmeyle
ayrıca doğrulandı: sürüm `100000101`, kalıcı sertifika, minSdk26,
`debuggable=false`, paket/kaynak/SHA eşleşiyor.
[Android101](https://github.com/ersingundem/larenor/actions/runs/34005590269) ·
[Core](https://github.com/ersingundem/larenor/actions/runs/34005590288) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/34005590189) ·
[APK101 ve teslim kanıtı](client-delivery-101-2026-09-06.md).
Anonim iki mimarili Core yayını da doğrulandı; evde kurulum yapılmadı.

**Bu paketin içeriği:** ACL yönetim ekranı `ab678df`, volume journal
`f9a3faa` ve dokuzuncu Android yolculuğu `1d909b8`.
[Birleşim kanıtı](core-grants-volume-integration-2026-09-06.md).
[Önceki APK100](client-delivery-100-2026-09-06.md) ve S08.4 kabulü korunur.
Sonraki logout ve Unix okuyucusu birleşimi daha sonra APK104 ile doğrulandı. Hazırlanan restore ve kişi sözleşmesi bu pakete eklenmez.

**Önceki tam doğrulanmış yayın `4bc79dc` / APK 99.** Üç CI başarılı:
Core **2.951 PASS**, güvenlik **207 PASS**, Flutter **3.941 PASS**, JVM
**98 PASS**, **4 native + 7 uygulama = 11 E2E PASS**. Analiz sıfır bulgu,
860 dosyada sıfır biçim farkı. 65 E2E fazı sıralı tamamlandı.
[Android](https://github.com/ersingundem/larenor/actions/runs/34002121963) ·
[Core](https://github.com/ersingundem/larenor/actions/runs/34002121806) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/34002121729).
[İmzalı APK 99](https://github.com/ersingundem/larenor/actions/runs/34002121963/artifacts/9980085515)
tek tam indirme sonrası Java 17 + sabit apksig ile ayrıca doğrulandı:
kalıcı sertifika, kaynak commit, paket `com.ersingundem.larenor`, sürüm kodu
`100000099`, minSdk 26 ve `debuggable=false` eşleşti. APK SHA-256:
`099476a93aa3492c8c4aae283be8868d3c536f448ddcfecdab9c9b980a93b396`.
İki mimarili Core yayını anonim doğrulandı. Ev Core'una yayın ve cihaz
kurulumu yapılmadı. [Teslim kanıtı](client-delivery-99-2026-09-06.md).
Sonraki yerel paketler için yeni birleşik test ve CI ayrıca gerekir.

**Önceki tam doğrulanmış yayın `a2658ec` / APK 98.** Linux Server **2.919 PASS**,
güvenlik **207 PASS**, Flutter **3.422 PASS**, JVM **98 PASS**, temiz analiz,
845 dosyada sıfır biçim farkı ve **dört native + yedi uygulama = 11 E2E PASS**.
Eski scoped-layout fixture düzeltmesi gerçek Android akışını geçti. Üç workflow
ilk denemede başarılı; başarısız Android 97 kaydı aşağıda korunuyor.
[Android 98](https://github.com/ersingundem/larenor/actions/runs/34000029533) ·
[Server](https://github.com/ersingundem/larenor/actions/runs/34000029460) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/34000029415).

[İmzalı APK 98 ve metadata](https://github.com/ersingundem/larenor/actions/runs/34000029533/artifacts/9979498174)
tek tam indirmeyle Java 17 ve sabit apksig 9.1.0 üzerinden ayrıca doğrulandı:
`com.ersingundem.larenor`, `1.0.0` / `100000098`, minSdk 26,
`debuggable=false`, kalıcı sertifika ve kaynak commit eşleşiyor. APK SHA-256:
`eac472cec2a0e9de02a2df6f1f78876ae5e4dc9c56ef7e9440fe1691690586ae`.

İki mimarili Core **hazırlık** smoke'u ve anonim kaynak/AGPL etiketli yayın
geçti: `sha256:ed365020ea6bf38200beaa8a73627111a27a87c54124f6cd30bbd234bc846410`.
Ev Server'ına yayın atlandı, cihaz kurulumu yapılmadı. Aşağıdaki yeni yerel
paketler bu APK'da bulunmaz; kendi birleşik testleri ve CI ayrıca gerekir.

**`4bc79dc` ile gönderilen birleşim:** kişisel sağlık/fotoğraf ayarları,
Jellyseerr/Bazarr/Prowlarr ve qBittorrent paketleri bağımsız incelemelerden
geçti. İlk birleşik koşu **3.665 PASS / 5 FAIL** verdi; beş hata idle testinin
eski yerel depolama hazırlığındaydı. `1b2d7d3`, gerçek gizlilik sağlayıcılarını
bekleyen test düzeltmesiyle **23/23 PASS** verdi. Ardından gerçek native
pencere odağı açığı `729d96d` ile düzeltildi: **26 odaklı / 252 ilgili PASS**,
arka plan müziği korunuyor. Son birleşik koşu `1b260ce`: **3.923 PASS / bir eski test taklidinde derleme hatası**, 4:15. `ad5f866` yalnız bu taklidin yeni Proxmox imzasını düzeltti; aynı sistem ekranının **18 testi geçti**, bağımsız inceleme temiz. Tam analiz sıfır bulgu; 860 dosyada biçim farkı yok. Bu, tek koşuda tam yeşil yerel sonuç diye sayılmıyor; yeni CI tam paketi sınayacak.
[Odak kanıtı](application-window-focus-implementation-2026-09-06.md).

**Birleşime alınan bağlantılar:** Jellyfin 98 yeni/297 ilgili, Proxmox 213 odaklı/665 ilgili test ve bağımsız inceleme ile tamamlandı. Keenetic sonraki ayrı pilotta. Jellyfin'de
başarısız credential yazısının eski doğrulanmış bağlantıyı bırakması düzeltildi;
aynı durum yedi API-key bağlantısında 370 ilgili test ve bağımsız incelemeyle düzeltildi. Dashboard WebviewTile için kaynak sahipliği düzeltmesi `0a742a9` ayrı yerel diliminde **79 ilgili test** ve bağımsız inceleme ile geçti; yeni yayın paketine henüz dahil değil. Bu incelemeler tüm
entegrasyon API'lerinin veya fiziksel cihazların kabulü değildir.

**Yeni yerel birleşim hazırlanıyor:** Keenetic kayıt/PIN/kurtarma pilotu
`dc87062` **1008 ilgili PASS**, Wi-Fi/cihaz/port ekranı koruması `74e3f44`
**1047 ilgili PASS** ve bağımsız inceleme ile tamamlandı. Dashboard WebView,
Core yönetim ekranı ve volume gözlemi aynı sonraki pakete alındı.
[Birleşim kanıtı](core-client-integration-2026-09-06.md) tam test/CI aşamasını izler.
`8d9e4d2` birleşik üretim/test kaynağı **4.271 Client testi / 4:48** ile geçti;
207 güvenlik/CI araç testi ve backup/CI politika kontrolü de temiz. Tam Server
**3.040 PASS / 10 Linux'a özgü skip / 8:17,88** verdi. Tam analiz 0 bulgu,
878 dosyada biçim farkı yok. Sonraki `bb6ed4e` birleşimi sekizinci Android
metadata yolculuğunu ekledi: tüm fixture klasörü **48 PASS**, tam analiz
0 bulgu ve **881 dosyada sıfır biçim farkı**. Yeni CI hedefi 4 native +
8 uygulama = **12 E2E**; Linux'a özel testler ve yeni Android yolculuğu
gerçek CI sonucu gelmeden kabul edilmiş sayılmaz.
[Sekizinci yolculuk](core-resource-admin-android-journey-2026-09-06.md).
Core metadata mutasyon API'si `8e00548` yerel dalında **87 odaklı / 656 ilgili
Client ve 40 Server testi**, temiz analiz ve bağımsız inceleme ile doğrulandı.
Bu API'nin PIN korumalı oluşturma, ad/sıra değiştirme ve kayıt silme UI'si
`68e77b8` yerel diliminde **431 ilgili test**, temiz analiz, 12 tablet/DeX
boyut-tema-dil kontrolü ve bağımsız inceleme ile geçti. Yeni Android E2E
yolculuğu birleştirildi; bu UI henüz APK 99'da değildir. ACL editörü ve gerçek cihaz komutları
ayrı açık işlerdir. Kuyrukta kabul sayısı bu alt dilimler için artırılmadı.

**Kaynak erişimi API'si yerel olarak doğrulandı:** `a65691d`, gerçek Core
grant/no-op/revoke yanıtlarını Client'a bağlar; **53 odaklı / 709 ilgili Client,
131 ilgili Server PASS**, yeni 108 satırın tamamı testte, bağımsız inceleme
temiz. Kullanıcı seçimi ve ACL yönetim ekranı ayrı dalda geliştiriliyor.
[Sözleşme kanıtı](core-home-resource-grants-contract-2026-09-06.md).

**S06.3d depolama alternatifi:** Core'a ait yönetilen volume önerisi saf plan
olarak eklendi: **32 yeni / 182 ilgili PASS**, modülde dal dahil %100 kapsam,
bağımsız kaynak incelemesi temiz. Henüz Engine'e veya HTTP kurulum yoluna
bağlanmadı; `installAvailable=false` sürer. Sahiplik gözlemi, kalıcı journal,
UID/bootstrap ve gerçek kurulum etkileri açıktır.
[Değerlendirme](managed-volume-storage-assessment-2026-09-06.md) ·
[Uygulama kanıtı](managed-volume-proposal-implementation-2026-09-06.md).

**Volume gözlemi sonraki yerel birleşime alındı:** `4baa55a`, yedi managed
hedefi tam plan/kimlik/etiketlerle eşleştiren katı Engine yanıt denetimini
ekler. **95 odaklı / 282 ilgili test**, 124 satır ve 24 dalda %100 kapsam;
bağımsız inceleme temiz. Host dizini açılmaz ve gözlem kurulum yetkisi sayılmaz.
Kalıcı volume journal'ı, gerçek bootstrap ve Engine işlem bağlantısı açık.
[Gözlem kanıtı](managed-volume-observation-implementation-2026-09-06.md).

**Sonraki bağımsız volume journal paketi hazır:** `codex/managed-volume-journal`
dalı `f9a3faa` checkpoint'inde **54 odaklı / 273 ilgili PASS** ve bağımsız
inceleme ile donduruldu; yeni modül 139 satır ve 8 dalda %100 kapsamda.
Bu dal yukarıdaki tam Server koşusuna veya mevcut yayına dahil değil.
Yalnız gözlem geçmişini saklar; Engine/bootstrap ve kurulum yetkisi açık.

**S08.4 kabul incelemesi tamamlandı:** üç kabul maddesi ve 22 kayıt sınıfı
kaynak/test kanıtlarıyla eşleştirildi; yeni somut P1/P2 bulunmadı. Yeni paketin
kendi CI kapısı geçince bu adım kapanabilir. Restore S08.5 ve typed
adaptör/cache S08.7–9 ayrı kalır.
[İnceleme](client-boundary-acceptance-review-2026-09-06.md).

S08.4'ün önceki 31 ayrıntılı kanıt kaydı
[özgün kayıt arşivinde](client-boundary-evidence-archive-2026-09-06.json)
aynen korunur. Yürütme kuyruğu yerel test/inceleme özetlerini buraya bağlar;
başarılı ve başarısız CI kayıtları kuyrukta da kalır. Bu düzenleme kabul
sayılarını veya tarihsel test sonuçlarını değiştirmez.

**6 Eylül günlük depolama bakımı tamamlandı:** bir eski debug APK çıktısı,
**129.424.470 bayt** temizlendi. En yeni üç debug APK korundu; imzalı çıktılar
ve test raporları silinmedi. Sonraki envanter silinen kaydın yokluğunu ve
korunan üç kaydı doğruladı. GHCR paket izni olmadığından imaj temizliği yapılmadı.

**Önceki tam doğrulanmış yayın `8c3b60d` / APK 96: üç CI ve bağımsız APK kontrolü başarılı.**
Linux Server **2.916 testi atlamasız**, Flutter **2.989**, JVM **98** ve
**dört native + altı uygulama = 10 E2E** geçti. Güvenlik CI 207 testi ve
secret taramasını geçti. Yeni Core login/PIN/oda kopyası/remount/başka Core
akışı gerçek Android CI'da doğrulandı. 57 faz, altı temizlik; E2E komutu
322,195 saniye, 18 dakika sınırında 757,805 saniye pay var.
[Android 96](https://github.com/ersingundem/larenor/actions/runs/33995289219) ·
[Server](https://github.com/ersingundem/larenor/actions/runs/33995289140) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33995288940).

AMD64/ARM64 Core medya **hazırlığı**/restart/iptal smoke'u ve anonim yayın
başarılı: `sha256:d3a2b48c07634be20c59b14e2a84b2b6f3e89e69c1094205f4e7f7be3355c027`.
Bu kontroller gerçek medya bileşeni veya ev kurulumu değildir.

[İmzalı APK 96 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33995289219/artifacts/9978185451)
tek tam indirmeyle Java 17 + sabit apksig 9.1.0 kullanılarak ayrıca doğrulandı:
`com.ersingundem.larenor`, sürüm kodu `100000096`, minSdk 26,
`debuggable=false`, kalıcı sertifika ve kaynak commit eşleşti. APK SHA-256:
`1017d1405d4127dbed241a4957826ab6660b4fc2185c33d57bb334e5dba2a5c8`.
Ev Server'ına koşullu Client yayını atlandı; ev/tablet kurulumu yapılmadı.

**Yeni birleşik teslim `27def3d`:** Arr/backup ve eski Core fixture düzeltmesi ana dalda.
`7f9a74f` üzerinde tam Client **3.421 PASS / 4:00**, tam analiz temiz,
845 dosyada biçim kontrolü sıfır değişiklik. Ardından eklenen tek fixture testi
ve genişletilen senaryo `27def3d` üzerinde **18 son destek testi**, dört dosyada
temiz analiz/biçim ile doğrulandı. Kaynak incelemesi temiz. Yeni Android/Core
CI üstteki Android 98 kaydında geçti; bağımsız imzalı APK 98 kontrolü de geçti.
[Fixture düzeltmesi](core-resource-fixture-compat-2026-09-06.md).

**Kaynak ekranı paketi `808938e`:** diafon/film gecesi kaynak sınırı, Core'un
salt okunur oda/kaynak ekranı ve yeni yedinci Android yolculuğu birleştirildi.
Birleşik yerel Client **3.115 testi 3:40 içinde geçti**; tam analiz sıfır
bulgu, 838 dosyada biçim kontrolü sıfır değişiklik. Gerçek Server ortak
kaynak sözleşmesi üç testi, kuyruk doğrulaması 24 testi geçti. Bu yeni
ekran/yolculuk APK 96'da yoktur; yeni CI ve imzalı APK kabulü ayrıca izlenecek.

**`20d92d7`: Core ve güvenlik geçti; Android 97 başarısız, APK üretilmedi.** [Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33997176904)
207 testi ve secret taramasını geçti. [Android 97](https://github.com/ersingundem/larenor/actions/runs/33997176965)
içindeki Server işi 2.919, Flutter 3.115, JVM 98 testi geçti.
E2E: dört native ve altı uygulama senaryosu geçti; eski scoped-layout senaryosu
son temizlikte dört reddedilen istek nedeniyle durdu. Yeni kaynak ekranının
yedinci uygulama senaryosu geçti. Eski admin test sunucusunda görünür ekranın
oda/kaynak GET desteği eksikti; `1f7c6b4` bu eski kullanıcı/rolü değiştirmeden
aynı kapsama ait boş liste yanıtını ekler. İstek/yetki/temizlik kontrolleri korunur.
Bu düzeltmenin Android 98 E2E kabulü geçti; imzalı APK 98 kontrolü de geçti.
[Core imajı](https://github.com/ersingundem/larenor/actions/runs/33997176958)
ilk denemesinde 2.918 PASS ve bir Unix test düzeneği kapanış zaman aşımı var.
İlk hata kaydı korunarak yalnız başarısız iş bir kez yeniden çalıştırıldı;
ikinci deneme **2.919 test ve imaj işlerinde başarılı**. İlgili dokuz intent-değişimi senaryosu
yerelde 20 ayrı koşuda, toplam 180 çalıştırmada geçti. Bu tekrarlar ilk Linux
hatasının sebebini kesinleştirmez veya onun yerine geçmez.

**Sıradaki birleşik paket `e4f0f15` ana dala alındı:** dört Arr bağlantısı
ve yedek sınırı **3.418 tam Client testi**, temiz analiz ve 845 dosyada sıfır
biçim değişikliğiyle doğrulandı. Bağımsız incelemeler temiz. Önceki yayının
eksik Android kapısı düzeltilirken Jellyseerr/Bazarr/Prowlarr, qBittorrent ve kişisel sağlık/fotoğraf
kayıtlarının sınırları ayrı dallarda ilerliyor. Bu paketler henüz CI kabulü almadı. Kişisel kayıt paketi `4eac0f6` 253 ilgili
test ve bağımsız incelemeyle sonraki birleşim için hazır; diğer iki pilotun
son UI/inceleme işleri devam ediyor.

<details>
<summary>Önceki tam doğrulanmış yayın: 394de0f / APK 95</summary>

**Önceki tam doğrulanmış yayın `394de0f` / APK 95: üç CI ve bağımsız APK kontrolü başarılı.** 2.792 Linux Server testi
atlamasız, 2.837 Flutter, 98 JVM, dört native + beş uygulama = dokuz E2E ve
207 araç testi geçti. Yeni gerçek Linux tam kök/proc/mount/descriptor fixture'ı
0,204 saniyede geçti. Android akışı 260,80 saniye; Gradle ağır derlemesi cihaz
başlatılmadan önce tamamlandı. İmzalı APK 95, Java 17 ve sabit apksig 9.1.0
ile ayrıca doğrulandı.
[Android](https://github.com/ersingundem/larenor/actions/runs/33991460336) ·
[Server](https://github.com/ersingundem/larenor/actions/runs/33991460310) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33991460186).

AMD64/ARM64 Core medya hazırlığı/restart/iptal smoke'u ve anonim yayın
başarılı: `sha256:1dcc66fcc964d6f5d1ab6a1d0df653f43d21c7562bb5f19bd098815f89461642`.
Bu kontroller gerçek medya bileşeni veya ev kurulumu değildir.

[İmzalı APK 95 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33991460336/artifacts/9977060537):
`com.ersingundem.larenor`, sürüm kodu `100000095`, minSdk 26,
`debuggable=false`, kalıcı imza ve kaynak commit eşleşti. APK SHA-256:
`e12a90c81ff1b22ab1bf5dc1ca272dc6675de65dac2587cd311f594f6ce67be1`.
Ev Server'ına koşullu Client yayını atlandı; ev veya cihaz kurulumu yapılmadı.
İlk bağımsız indirme hazırlığı geçici dizin adı hatasıyla 0 bayt yazmadan durdu;
yol düzeltildikten sonra tek tam indirme ve kontrol başarılı oldu.

</details>

<details>
<summary>Önceki tam doğrulanmış yayın: 4b98680 / APK 94</summary>

**Son tam doğrulanmış yayın `4b98680` / APK 94:** üç CI ve bağımsız APK
kontrolü başarılı. **2.704 Linux Server testi atlamasız**, 2.815 Flutter,
98 JVM, **dört native + beş uygulama = dokuz E2E** ve 207 araç testi geçti.
[Android](https://github.com/ersingundem/larenor/actions/runs/33989941216) ·
[Server](https://github.com/ersingundem/larenor/actions/runs/33989941147) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33989940928).

Yeni Direct → Core → Direct yolculuğu eski HA bağlantısının kapanmasını ve
açık seçimden sonra yeni abonelik kurulmasını doğruladı. 48 faz, beş temizlik;
E2E komutu 242,584 saniye, 18 dakika sınırında 837,416 saniye pay var.
Emülatörden önce Gradle 331 saniye; cihaz açıkken 20,6/31,2 saniye.
Native odak geçti; önceki Quickstep hatası bu koşuda görülmedi.

AMD64/ARM64 Core restart, medya **hazırlığı** ve iptal smoke'u; anonim
commit/stable/index ve iki mimarinin kaynak/lisans kayıtları doğrulandı:
`sha256:8df10dcadb6f97db17eabbf41fc566c394b45a9b0161227f5107673a348bb19b`.
Gerçek medya bileşeni kurulumu bu smoke kapsamında değildir.

[İmzalı APK 94 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33989941216/artifacts/9976632723)
Java 17 + sabit apksig 9.1.0 ile ayrıca doğrulandı: doğru paket/sertifika,
`100000094`, minSdk 26, `debuggable=false`, kaynak commit ve metadata eşleşti.
APK SHA-256: `44d505607e282ff23bb24ffeb349dd12f5e71ea6533d5be6db65812f3a3f6bbf`.
Ev Server'ına koşullu Client yayını atlandı; ev/cihaz kurulumu yapılmadı.

</details>

- **S08.3 ev kaynak sınırı kabul edildi:** `10d3eb1` → `4ba7024`; açık, kalıcı doğrudan
  HA/Core seçimi ve bağımsız ev runtime'ı. Eski evin route/WS/callback'leri
  kapanır; hesap, PIN, tema ve güç ayarları ortak sahiplikte kalır. Core
  adaptörleri hazır olmadan eski yerel HA/medya verisi Core ekranına sızmaz.
  50 odaklı ve 1.093 ilgili test, %99,2 yeni modül satır kapsamı ve bağımsız
  inceleme geçti. Yeni beşinci uygulama akışıyla **dokuz E2E ve imzalı APK 94**
  `4b98680` kaynağında doğrulandı. [Uygulama kanıtı](client-home-session-scope-implementation-2026-09-05.md).
- **B5.1 dashboard:** `5cf7f30` → `8cc4665`; kartlarda Tab/Enter/Space,
  menü tuşu, tekil ekran okuyucu duyurusu ve görünür odak. Servis kartları
  gizli/eski oturumdan sayfa açamaz; termostat ok tuşlarıyla ayarlanır.
  343 dashboard ve 49 son delta testi, kapsam %88,1, scoped analiz ve
  bağımsız inceleme ve `4b98680` Android/yayın CI geçti. Genel B5.1 ve ayrı
  fiziksel TalkBack kabulü açık.
  [Uygulama kanıtı](tablet-dashboard-accessibility-implementation-2026-09-05.md).

Yeni birleşimde ilk yerel test başlangıcı eski üretilmiş çeviri dosyaları
nedeniyle durduruldu; kaynak üretimi ve çeviriler yenilendikten sonra tam
Client suite **2.815 testi 3:46 içinde geçti**. Bu hazırlık hatası başarı olarak sayılmaz.
Bu hazırlık düzeltmesinden sonra aynı kaynak uzak CI ve APK 94 kabulünü de geçti.

**Yeni CI ile doğrulanan paket (`14b7b62` → `394de0f`):** appdata tam kök gözlemi ve medya posterleri
birleşti. Medya kartları native klavye odağına sahip; 2× başlık satırı gerçek
ızgara genişliğine göre hesaplanıyor. 733 ilgili/22 son test, %92,5 ilgili
satır kapsamı, bağımsız kod ve açık/koyu gerçek-font görsel incelemesi geçti.
Tam Client **2.837 testi 4:04 içinde geçti**; analiz sıfır bulgu, 803 dosyada
biçim kontrolü sıfır değişiklik. Aynı üretim kaynakları yeni `394de0f`
Android CI içinde 2.837 Flutter, 98 JVM ve dokuz E2E ile doğrulandı. [Medya kanıtı](tablet-media-accessibility-implementation-2026-09-05.md).

**Sıradaki bağımlı çalışma:** S06.3d'de salt okunur native kimlik gözlemi
`3dde2f8` Linux CI ile doğrulandı. Onaylı tam appdata kökünün bütün parent/name/descriptor bağlarını tutan
resolver `32254ad` → `0d9e250` main içinde. 87 odaklı/573 ilgili test ve
bağımsız inceleme geçti. Tam Server **2.782 geçti, 10 Linux testi Mac'te
atlandı** (3:20,8). Ardından `394de0f` Linux CI **2.792 testi atlamasız**
geçti; yeni gerçek kök fixture'ı doğrulandı. Supervisor,
remap-disabled başlangıç kanıtı, issuer ve create/publish hâlâ açık.
[Native kimlik](native-identity-observation-implementation-2026-09-05.md) ·
[Kalan sıra](appdata-native-lease-plan-2026-09-05.md).
S08.3 kabulüyle başlangıç bağımlılığı açılan [kapsamlı düzen deposu ve açık taşıma](client-scoped-storage-plan-2026-09-05.md)
ilk dilimi `3018c57` → main `fd23a3f` içinde. Core/ev/kullanıcıya ayrı kayıt,
PIN korumalı önizleme ve seçili pasif oda adlarının kopyası eklendi.
93 son test, %96,9 ilgili satır kapsamı, bağımsız inceleme ve dört gerçek-font
görsel kontrolü geçti. `115dfa1` altıncı Android yolculuğu da birleşti;
`fd23a3f` üzerinde tam Client **2.914 test**, temiz analiz ve 814 dosyada
biçim kontrolü geçti. Bu altıncı Android yolculuğu `8c3b60d` ve APK 96 ile CI kabulü aldı.
[Diğer kayıtların envanteri](client-record-ownership-2026-09-06.md) çıkarıldı.

**S08.4 HA ve yedek sınırı ana dalda:** `d8edab5` ve `9b11195` → `7ed736b`.
Gerçek HA provider/store ve EnabledServices seed erişimi Direct kaynak
sahipliğine bağlı; Core veya eski callback sır okuma, kayıt veya HA transport
oluşturamaz. Yarım HA adres/token kaydı kalıcı bir işaretle durur; yalnız açık,
tam yeniden bağlantı veya silme bu belirsizliği kapatır. Böyle bir çift yeni
yedeğe/restore hazırlığına giremez; mevcut journal kurtarması çalışır ve işareti
silmez. Direct paketinde 53 son/482 ilgili test ve %99,5 satır kapsamı;
yedekte 40 son/143 ilgili test, repository %98,2 ve ekran %94,4; bağımsız
incelemeler ve analizler temiz. Toplamlar birbirine eklenmez. `7ed736b`
birleşik Client **2.989 testi 3:58 içinde geçti**; analiz sıfır bulgu,
820 dosyada biçim kontrolü sıfır değişiklik. Aynı dilimler `8c3b60d`
2.916 Linux, 10 E2E ve APK 96 ile de geçti. Bütün S08.4 kabulü açık.
[Direct kanıtı](direct-home-boundary-implementation-2026-09-06.md) ·
[Yedek kanıtı](ha-backup-boundary-implementation-2026-09-06.md).
**Diafon/film gecesi sınırı da `cc3db2` → main `cc0d89d` içinde:**
eski kaynak callback'leri kayıt yapamaz, kapı komutu veya film akışı
başlatamaz. 542 ilişkili test, %86,2 ilgili satır kapsamı, temiz analiz
ve bağımsız inceleme geçti. `808938e` birleşik Client 3.115 testi ve analizi
geçti; yeni CI kabulü açık.
[Kanıt](direct-home-routines-implementation-2026-09-06.md).
Sıradaki pilot ortak credential kayıt sınırıyla Sonarr/Radarr/Lidarr/Readarr
bağlantılarıdır; çok alanlı kayıt belirsizliği ve yedek kontrolleri birlikte
tamamlanmadan bu pilot birleştirilmeyecek.

**Paralel S08.6 ana dalda:** Kalıcı, şifreli oda/kaynak/hesap izin kayıtları ve
gerçek authenticated HTTP API `133786e` / belge `1b6b866` ile birleşti.
Üye yalnız izinli kayıtları görür; opak sayfa özeti gizli kayıt hareketlerini
açıklamaz. 124 odaklı test, dal dahil %95 kapsam, bağımsız inceleme ve tam
Server **2.906 PASS / Mac üzerinde 10 Linux skip** geçti. `8c3b60d` Linux CI **2.916 testi atlamasız** ve iki mimarili
imaj kapısını da geçti. Client salt okunur liste ekranı `codex/core-home-resource-list` üzerinde
`73dba35` → main `808938e` içinde. 82 odaklı/940 ilgili test,
%99,2 yeni feature satır kapsamı, 8 gerçek-font tablet kontrolü ve bağımsız
inceleme geçti; `808938e` birleşik Client 3.115 testi ve analizi geçti.
Yeni yedinci Android yolculuğu ve CI kabulü açık.
[Client kanıtı](core-home-resource-list-implementation-2026-09-06.md) ve
[yedinci Android yolculuğu](core-home-resources-android-journey-2026-09-06.md)
yeni teslim kapsamını ayırır. Yönetim ekranı, hane kişi profilleri, değişmez sağlayıcı bağları
ve gerçek cihaz komutları henüz tamamlanmış sayılmıyor.
[Uygulama ve kanıt](home-resource-registry-implementation-2026-09-06.md).

**S08 kabul sırası netleştirildi:** Mevcut kayıt kapsamı S08.4, restore/journal
S08.5, kimlik/yetki S08.6; gerçek HA eşlemesi ve typed cache S08.7, medya
S08.8, altyapı S08.9. Böylece bir adım kendi sonraki adaptörünü bitiş önkoşulu
olarak beklemiyor. Kapsam ve 125 işlik kuyruk korunuyor; kabul sayısı 7/125.

**S08.9 Proxmox salt okunur pilotu ayrı dalda:** `codex/core-proxmox-adapter`
node/QEMU-LXC guest/storage özetini yönetici preview/onay binding'i ve Home
Resources read ACL'si üzerinden Core'a taşır. Beş saniyelik typed cache exact
Core/ev/kaynak/binding/servis/kullanıcı/oturum tuple'ına bağlıdır; endpoint,
credential, revizyon, ACL veya oturum değişince geç yanıt yayınlanmaz. Bu paket
güç/yapılandırma komutu eklemez ve gerçek Proxmox'a bağlanmadı. Mevcut Android
Direct Proxmox yolu, Core-backed Client geçişi ve fiziksel tablet kabulüne kadar
geçici olarak açıktır. Bu yalnız pilot kanıtıdır; S08.9 ve seçilen özellik kabul
sayaçları değişmedi. [Sınır ve API](core-proxmox-resource-pilot-2026-09-10.md).

**Yarım çalışmaları kaybetmeden devam:** önce çalışma kopyaları, dallar,
agent ve CI durumları incelenir; aynı iş yeniden başlatılmaz. Tamamlanan
RED/GREEN checkpoint'leri git geçmişinde tutulur; ana dala birleşme uzak CI
kabulü değildir. Geçici çalışma kopyaları kalıcı arşiv yerine geçmez.

| İş | Dal / çalışma kopyası | Durum |
| --- | --- | --- |
| B5.1 tablet ayarları | `codex/tablet-settings-accessibility` | `ba884f6` main içinde; yeni `3dde2f8` sekiz E2E ve Android CI geçti. |
| B5.1 medya posterleri | `codex/tablet-media-accessibility` · `/private/tmp/larenor-tablet-media-accessibility` | `cb792c0` → `14b7b62` main içinde; 733 ilgili/22 son test ve bağımsız görsel inceleme geçti. Tam Client 2.837 test/analiz ve `394de0f` dokuz E2E geçti; bağımsız imzalı APK 95 doğrulandı. |
| B5.1 dashboard | `codex/tablet-dashboard-accessibility` · `/private/tmp/larenor-tablet-dashboard-accessibility` | `5cf7f30` birleşti; `4b98680` tam Android CI ve APK 94 kabulü geçti. |
| S06.3e ağ journal köprüsü | `codex/network-effect-bridge` | `6a00168` main içinde; `9138e61` Server/güvenlik CI ile yazılım kabulü tamamlandı. |
| S08.4 kaynaklı düzen | `codex/client-scoped-layout` ve `codex/scoped-layout-e2e` | `3018c57` ve `115dfa1` ana dalda; 93 son ve 2.914 tam Client testi/analiz geçti. Altıncı Android yolculuğu ve APK 96 `8c3b60d` ile doğrulandı. |
| S08.4 HA ve yedek sınırı | `codex/direct-home-boundary` ve `codex/ha-backup-boundary` | `d8edab5` ve `9b11195` → main `7ed736b`; 53/40 son test ve bağımsız incelemeler temiz. `8c3b60d` 2.989 Flutter/10 E2E ve bağımsız APK 96 kontrolü geçti. |
| S08.4 diafon/film gecesi | `codex/direct-home-routines` | `cc3db2` → main `cc0d89d`; 542 test ve inceleme geçti. `808938e` birleşik Client 3.115 test/analiz geçti; yeni CI açık. |
| S08.4 Arr bağlantıları ve yedek sınırı | `codex/direct-arr-credentials` ve `codex/direct-credential-backup` | 0298c5a ve 6426d55 birleştirildi; 192 odaklı/547 ilgili Arr ve 245 ilgili backup testi, bağımsız incelemeler temiz. e4f0f15 birleşik 3.418 test/analiz geçti; yeni Android düzeltmesiyle CI açık. |
| S08.6 Core kaynak listesi | `codex/core-home-resource-list` ve `codex/core-home-resources-e2e` | `73dba35` ve `c0b765c` → main `808938e`; 82 odaklı/940 ilgili test, tablet QA ve bağımsız inceleme geçti. Birleşik Client 3.115 test/analiz temiz; yedinci Android yolculuğu ve yeni CI açık. |
| S08.6 Core kaynak/yetki kaydı | `codex/home-resource-registry` | `133786e` / `1b6b866` ana dalda; tam Server 2.906 PASS/10 Mac skip, 124 odaklı test, %95 dal kapsamı ve inceleme temiz. `8c3b60d` Linux 2.916/iki mimari geçti. Yeni Client liste/bütün yönetim kabulü açık. |
| S08.7 seçili HA switch durumu ve komutu | `codex/core-ha-switch-adapter`, `codex/core-ha-switch-client`, `codex/core-ha-command` | İlk durum dilimi main `e11eb57`; kalıcı idempotent komut/makbuz davranışı `409ffc8`, kanıt `0949e3b` → main `914e1e7`. Tam Server 3.748 PASS/12 Mac skip; ilgili 222 Server ve 124 Client PASS, Core HA Client kapsamı %95,52; bağımsız son inceleme temiz. Exact-source CI, Direct aktarımı, geniş HA kapsamı ve fiziksel kabul açık. |
| S08.3 Client ev runtime'ı | `codex/client-home-session-scope` · `/private/tmp/larenor-client-home-session-scope` | `10d3eb1` birleşti; `4b98680` dokuz E2E ve imzalı APK 94 ile S08.3 kabul edildi. |
| S06.3d appdata tam kök gözlemi | `codex/native-appdata-root-observation` · `/private/tmp/larenor-native-appdata-root-observation` | `32254ad` → `0d9e250` main içinde; `394de0f` gerçek Linux 2.792 test/0 skip ve iki mimarili hazırlık smoke geçti. Salt okunur gözlem yazma yetkisi değildir. |

Ağ yazılımının gerçek Engine/iki mimarili kaynak kabulü **S06.3f** içindedir.
Production dispatcher/host grant, appdata oluşturma ve medya kurulumu açık;
`installAvailable=false` değişmedi.

<details>
<summary>Önceki doğrulanmış yayın: 3dde2f8 / APK 93</summary>

**Önceki tam doğrulanmış yayın `3dde2f8` / APK 93:** Server, Android ve güvenlik başarılı.
Linux **2.704 test atlamasız**, 2.739 Flutter, 98 JVM, dört native + dört
uygulama E2E senaryosu ve 207 araç testi geçti. İndirilen APK 93, Java 17 +
sabit apksig 9.1.0 ile ayrıca doğrulandı: doğru paket/sertifika, `100000093`,
minSdk 26, `debuggable=false`, kaynak commit ve metadata eşleşti.
[İmzalı APK 93 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33988283337/artifacts/9976135162).
APK SHA-256: `b9582694525493255641ab172aa90630d114ed88218a821accff5556f3695065`.
[Server](https://github.com/ersingundem/larenor/actions/runs/33988283387) ·
[Android](https://github.com/ersingundem/larenor/actions/runs/33988283337) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33988283178).

AMD64/ARM64 Core restart, medya **hazırlığı** ve iptal smoke'u geçti; anonim
commit/stable/index ve iki mimarinin kaynak/lisans kayıtları doğrulandı:
`sha256:e77b7a11907ac009d8000ec374fcb94745614602331c9da307d41ca97fb895d6`.
Gerçek medya bileşeni kurulumu bu smoke kapsamında değildir; ev Server'ına
koşullu Client yayını atlandı, ev/cihaz kurulumu yapılmadı.

**Emülatör hazırlığı gerçek CI'da doğrulandı:** ağır derleme emülatörden önce
403 saniyede tamamlandı. Emülatör açıkken ilk Gradle derlemesi önceki koşudaki
363,9 saniyeden 23,9 saniyeye indi; ikinci derleme 36,0 saniye. Test komutu
231,793 saniye sürdü; 42 aşama ve dört temizlik tamamlandı. Native odak testi
geçti. Bu tek koşu, önceki Quickstep ANR'nin kesin kök nedenini veya kalıcı
çözümünü kanıtlamaz; toplam CI aynı oranda hızlanmış değildir.
[Ölçüm ve sınırlar](android-e2e-precompile-2026-09-05.md).

</details>

<details>
<summary>Önceki koşu: 9138e61 Core kabulü, Android 92 hatası</summary>

Linux 2.566 test atlamasız, iki mimarili Core hazırlık/restart/iptal ve
güvenlik kontrolleri geçti; bu backend kanıtıyla **S06.3e** kabul edildi.
[Server](https://github.com/ersingundem/larenor/actions/runs/33986835291) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33986835178).
İmaj `sha256:7902dc0fcf299c0b2b7e598943a6293c8af6e5e60efd0e13f1f27ac28216d805`.

[Android 92](https://github.com/ersingundem/larenor/actions/runs/33986835301)
2.739 Flutter, 98 JVM ve dört uygulama akışını geçti. Quickstep ANR nedeniyle
native odak testi başarısız oldu: E2E 7/8, imzalı APK 92 üretilmedi.
QEMU/adb canlı, ekran uyanık ve kilitsizdi; OOM veya emülatör çökmesi
kanıtlanmadı. 673,224 saniye, 42 aşama ve dört temizlik kaydedildi.

</details>

<details>
<summary>Önceki doğrulanmış yayın: 19dbcbe / APK 91</summary>

**Önceki tam uzak yayın `19dbcbe`:**
[Server](https://github.com/ersingundem/larenor/actions/runs/33985459924),
[Android](https://github.com/ersingundem/larenor/actions/runs/33985459959) ve
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33985459857)
**imzalı APK 91 dahil başarılı**. **2.298 Linux Server testi atlamasız**;
2.701 Flutter, 98 JVM, sekiz emülatör senaryosu ve 202 araç testi geçti.
Linux'un unread Unix stream reset davranışı ve iki iptal/kapanış varyantı
ayrıca geçti; önceki `54a677b` hatası kapandı. Emülatör 9:34,4 ile 18 dakika
sınırında; 42 aşama ve dört tamamlanmış temizlik var.

AMD64/ARM64 Core restart/medya hazırlığı/iptal smoke'u ve anonim
commit/stable/index/child/sourceRevision doğrulaması geçti:
`sha256:9867d551fb10cf141bc513569eab523162485eb04caaa181abd06249a840b8cd`.
[İmzalı APK 91 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33985459959/artifacts/9975280844)
Java 17 + sabit apksig 9.1.0 ile ayrıca doğrulandı: doğru paket/sertifika,
`100000091`, minSdk 26, `debuggable=false`, kaynak commit ve metadata eşleşti.
APK SHA-256: `caf77a39de2586b1250c3dcf1ebe3cbd2a3b66f4a73f3b1342b28e7319ccc498`.
Ev Server'ına koşullu Client yayını atlandı; ev/cihaz kurulumu yapılmadı.
Bu kanıt sonraki kaynak değişikliklerini kapsamaz.


</details>

<details>
<summary>Önceki doğrulanmış yayın: 1408e80 / APK 89</summary>

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

</details>

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
| Dar kurulum yürütme kapısı | Yöneticiye açık şifreli kalıcı istek/geçmiş/iptal API'si; güncel actor/session/Core/ev/preparation/inspection/catalog kapıları; yalnız Jellyfin create/start ve kayıp cevap uzlaştırması için ayrı UID denetimli Unix IPC. Tek-endpoint production image/volume/network reader ve ayrı managed-v2 native kabul workflow'u hazır; paketli bootstrap/mutasyon worker runtime'ı ve gerçek kurulum henüz yok; `installAvailable=false` |
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
platform dosyaları kaldırılmıştır; Client Android tablet ve DeX ürünüdür.

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
