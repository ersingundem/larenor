# S06.3d sonrası: çalışan Jellyfin'e giden en küçük volume kurulumu

6 Eylül 2026. İncelenen taban `9a19c95a4d375bf2fff39d5edd7f22c28ced9486`;
dal `codex/volume-bootstrap-plan`. **Bu commit yalnız plandır.** Yeni yazılım,
test koşusu, Engine erişimi, CI veya ev kurulumu yapılmadı. API/runtime ve
`installAvailable=false` değişmedi.

## Bitiş ölçütü ve ilk seçim

Tek dikey teslim **katalogdaki Jellyfin 10.11.11** olsun: yönetici açıkça bu
child'ı seçer; Core iki dedicated volume'u hazırlar, doğrulanmış kullanıcıyla
başlatır, ilk hesabı özel kanalda kurar, bağlantısını şifreli kaydeder ve
yeniden açılışta aynı kurulumun kimliğini/sağlığını tekrar doğrular. Client'ta
kurulum işi ve çalışan yönetilen Jellyfin bağlantısı görünür. Sadece container
201, çalışan PID, `/health` 200 veya yeni bir `bootstrap_required` kaydı
başarı değildir. Oynatma/HA eşleme gibi S08.8 işlevleri bu kurulum sonucu diye
gösterilmez; boş kütüphaneli, kimliği doğrulanmış servis kurulumu gerçek ilk
ürün çıktısıdır.

Jellyfin'in `/config` ve `/cache` hedefleri, `1000:1000` kullanıcı isteği ve
isteğe bağlı `mediaRootId` alanı mevcut katalogdadır. İlk profil bu alanı
**null** ister: host bind/library aktarımı, GPU, DLNA, host ağı, diğer beş
servis veya tüm medya stack'inin kurulumu aynı anda açılmaz. İki platformun
repository/manifest/config digest değerleri doğrudan paket kataloğundan
alınır; bu belge yeni digest veya bootstrap image kimliği uydurmaz.
[Katalog](../server/larenor_server/plugins/packagedcatalog.json),
[plan türetme](../server/larenor_server/plugins/catalog.py#L124).

Eski altı-child `MediaStackPlan` ve yedi-volume planı değişmeden kaynak
olarak kalır. Yeni kurulum niyeti yalnız mevcut Jellyfin child/step ID'lerini
referanslar. Diğer child'lar kurulmuş sayılmaz; eski v1 planın
`installAvailable` alanı true'ya kopyalanmaz. Yeni **ayrı execution preview**,
managed-volume tercihini, portsuz özel kontrol ağını ve yalnız Jellyfin
kapsamını açık gösterir; eski planın host-path/`0.0.0.0` isteği sessizce başka
anlamda yürütülmez.

## Hazır temeller ve bugün doğrudan bağlanamayan noktalar

| Kaynak | Kullanılacak mevcut davranış | Eksik kanıt |
| --- | --- | --- |
| [volume_plan.py:101–113](../server/larenor_server/plugins/volume_plan.py#L101) | Sabit ad/target/user ve `NoCopy=true` | Yazılabilir UID veya başlangıç dosyaları değil |
| [volume_create_journal.py:160–212](../server/larenor_server/plugins/volume_create_journal.py#L160) | Güncel kaynak/revision/nonce bağı, durable begin ve tarihsel gözlem | `observed_requires_bootstrap` içinde UID, içerik veya container kimliği yok |
| [volume_transport.py:77–103](../server/larenor_server/plugins/volume_transport.py#L77) | Taze, kapalı volume GET; Mountpoint atılır | Volume host yolunu açma veya kapasite kanıtı değil |
| [image_resources.py:70–114](../server/larenor_server/plugins/image_resources.py#L70) | Pinli image kimliği ve özel `ImageObservation.configuration` | Dosya ağacı/entrypoint'in UID altında çalışması test edilmemiş |
| [worker.py:50–57,194,437–461](../server/larenor_server/plugins/worker.py#L50) | Mevcut mountsuz container doğrulaması ve durable create/start | `Mounts/Binds` kapalı, image `Config.Volumes` reddediliyor; bu guard kaldırılarak bağlanamaz |
| [network_preparation.py:1–12](../server/larenor_server/plugins/network_preparation.py#L1) | Journaled network create/fresh inspect | Attach, ilk-kullanıcı izolasyonu veya actor/daemon grant'i yok |
| [native root gözlemi](../server/larenor_server/plugins/native_appdata_root_observation.py#L10), [native lease planı](appdata-native-lease-plan-2026-09-05.md) | Gerçek FD/proc/root/namespace gözlemleri | Trusted supervisor, remap-disabled başlangıç üreticisi ve production issuer hâlâ yok |
| [job_api.py:15](../server/larenor_server/plugins/job_api.py#L15), [jobs.py:163](../server/larenor_server/plugins/jobs.py#L163) | Gerçek admin gereksinim işleri, iptal ve geçmiş | Bunlar salt okunur; eski jobs endpoint'i kurulum endpoint'ine çevrilemez |

Yeni mount doğrulayıcısı gerekirse **aşağıdaki aynı dikey paketin container
builder'ı tarafından doğrudan tüketilen fonksiyon** olacaktır. Ayrı journal,
ayrı readiness API'si veya tek başına teslim edilen yeni makbuz katmanı yok.
Mevcut create receipt'i niçin yeterli değil: yalnız label/driver/options
gözlemi taşır; `Config.Volumes`, tam mount seti, UID ve seed davranışını içermez.

## Sabit storage/başlangıç kararı

İlk aday profil `jellyfin-empty-nocopy-v1`: iki boş local volume, options boş,
iki mount'ta `NoCopy=true`, runtime user `1000:1000`. Başlangıç dosyalarını
Jellyfin'in kendi pinli entrypoint'i üretir; rastgele image içeriğini kopyalayan
genel bir seed motoru yok. Bu aday **gerçek iki mimarili test geçmeden destekli
profil değildir**. Pinli image boş volume ile ilk verisini üretemiyorsa sonuç
desteklenmiyor olarak kalır; `NoCopy=false`, root runtime, yeni cap veya image
değişimi otomatik fallback değildir, yeni açık profil incelemesi gerektirir.

Moby local driver veri kökünü daemon root eşlemesiyle 0755 açar; bu durum
1000 kullanıcısına yazma hakkı vermez. `NoCopy` yalnız copy-up'ı kapatır.
[Local driver](https://github.com/moby/moby/blob/v27.5.1/volume/local/local.go#L148-L155),
[mount parser](https://github.com/moby/moby/blob/v27.5.1/volume/mounts/linux_parser.go#L309-L322).

Gerekli dar filesystem bootstrap, kaynak kodu incelenip kendi build'inde
manifest/config digest'i sabitlenen **tek amaçlı helper image** ile yapılır.
Bugün böyle bir pin mevcut değildir; bir başkasının `latest` shell image'ı
yerine konmaz. Helper yalnız tek generated volume'u sabit container-içi
`/volume` hedefinde `NoCopy=true` ile görür; ağ/host-path/socket/device,
serbest komut veya recursive chown almaz. İlk aday işlem, gerçekten boş
kökün yalnız kendisini `1000:1000` ve profilin sabit moduna hazırlamaktır.
Mod ve helper'ın en küçük UID/capability seti gerçek testle dondurulur;
uygulama container'ını root/privileged çalıştırmak çözüm sayılmaz. Gerekirse
helper'a verilen ayrı, kısa ömürlü izin uygulamaya veya genel shell'e taşınmaz.
Helper çıktısı bounded kimlik ve
durumdur; dosya adları/içerikleri/loglar public sonuca taşınmaz.

Helper'ın `check`, `initialize_empty_root`, `verify_root` kipleri kapalıdır.
Mutasyon yalnız yeni durable intent'te, boşluk ve exact volume binding tekrar
denetiminden sonra olur. Dolu/foreign/şüpheli volume veya crash sonrası
yarım işlem otomatik düzeltilemez. Uygulamanın sonradan yazdığı ağaç
yeniden boş kabul edilmez; sahipliğini değiştirme, copy/delete veya kullanıcı
arşivini taşıma yoktur. Sentetik doğru-UID cevabı kernel kanıtı sayılmaz.

## Sonlu checkpoint'ler

### 1. Gerçek image/UID karakterizasyonu ve dar helper

İlk runtime RED, izole native amd64/arm64 ephemeral Engine'de iki yeni volume
ile katalog kullanıcı profiline yazma/ilk-start beklentisidir. Aynı test,
mevcut `JournaledImageOperations`, `JournaledVolumeCreates`, fresh image/volume
reader'ları tüketir. Kapsam yalnız bu koşunun oluşturduğu Engine socket'i ve
UUID ad alanıdır; varsayılan Docker socket/`DOCKER_HOST` keşfi yoktur.

Beklenen kaynak: yeni `tool/jellyfin_storage_smoke.py` ve protokol testleri;
helper'ın kendi kaynak/Dockerfile'ı ve `test_volume_bootstrap.py`. Helper
çıktısı/pin manifesti üretilmeden production bootstrap profili yok. Test
oracle'ı: gerçek container UID/GID, iki writable appdata kökü, tam beklenen
image/entrypoint, ilk configuration/database oluşumu, yabancı sentinel
korunması ve restart sonrası aynı veri. NoCopy kontrolü yalnız boş volume'a
bakmakla yetinmez: izole fixture image'ındaki bilinen sentinel mount öncesi
mevcuttur, `NoCopy=true` sonrası volume'a kopyalanmamıştır. Pinli Jellyfin
ayrıca kendi gerçek ilk verisini üretip sağlıklı başlamalıdır.

Bu test bir kere helper olmadan izin engelini gerçekten göstermeli, sonra
dar helper ile geçmelidir; beklenmedik şekilde ilk durum geçerse sahte RED
üretilmez, gerçek permission koşulu kaydedilir. Engine yokluğu yerel testte
açık ayrı marker olabilir; gerçek CI job'ında skip başarı sayılmaz.

### 2. Bootstrap'ı tüketen mounted-container köprüsü

Yeni `plugins/managed_container.py` içinde kapalı Jellyfin builder + inspect
matcher ve aynı akışı çağıran dar coordinator; yeni
`plugins/volume_bootstrap.py` helper protokolü. Mevcut image/network/volume
primitive'leri yeniden yazılmaz. Gerektiği kadar ortak Unix taşımasına exact
container create/start/inspect ve helper-result yolları eklenir; her allowlist
delta'sı ayrı bağımsız inceleme alır. Genel Docker JSON/exec API açılmaz.

Mevcut `WorkerJournal` v1 mountsuz kayıtlarını yeni anlamda okumamak için
kurulum phase kayıtları açık yeni domain/tag taşır. FD/flock/SQLite/digest
kabuğu mevcut `ResourceJournal`dan kullanılır; ayrı bir generic workflow
framework kurulmaz. Tek `ManagedInstallJournal` prepare_storage/create/start/
bootstrap/verify fazlarını ve child step ID'lerini tutar. İki volume create
journal'ı ikinci kez kopyalanmaz; revision/nonce/spec referansları saklanır.

Planlanan dosya sınırı: `managed_install_journal.py` yalnız bu beş faz;
`managed_installation.py` onları gerçekten tüketen coordinator;
`managed_container.py` ve `volume_bootstrap.py` bu coordinator'ın çağırdığı
kapalı uygulayıcılar. `tool/volume_bootstrap_helper.py` ve
`server/Dockerfile.volume-bootstrap` kendi pinli helper build'ini tanımlar.
Salt model olarak bırakılacak paralel bir installation framework yoktur.

Builder bütün `Config.Volumes` hedeflerinin tam explicit mount ile
karşılandığını doğrular; ek/anonim, çakışan, nested veya path-normalization
gerektiren hedef reddedilir. İlk Jellyfin profilinde mount listesi tam olarak
`/config` ve `/cache` olur; image başka hedef istiyorsa önce profil incelemesi.
`HostConfig.Mounts` içindeki Type/Source/Target/ReadOnly/VolumeOptions.NoCopy
ve final inspect'teki Name/Driver/Destination/RW/propagation tam eşleşir.
`HostConfig.Binds`, `VolumesFrom`, driver options ve image'dan sızan anonim
volume kabul edilmez. Eski `ContainerBinding` ve eski journal testleri aynı
şekilde mount reddetmeye devam eder.

Moby, image `Config.Volumes` içindeki örtülmemiş hedef için anonim volume
açabilir; copy-up container **create** sırasında yapılır. Dolayısıyla “start
etmedik, henüz veri etkisi yok” varsayımı geçersizdir.
[Moby create akışı](https://github.com/moby/moby/blob/v27.5.1/daemon/create_unix.go#L40-L82).

### 3. Gerçek yetki ve dar üretim dispatch

Mevcut `preflight_ipc` readonly kalır. Native operator worker/supervisor için
tek Jellyfin install komutunu taşıyan ayrı kapalı IPC/dispatcher eklenir;
API container'a Docker socket veya host FD verilmez. İlk destek profili
kanıtlı rootful/remap-disabled daemon ile sınırlıdır. Mevcut daemon/context
gözlemleri, operator'ın sabit başlangıç/konfigürasyon bağını üreten gerçek
supervisor ve `/info` doğrulamasıyla tamamlanır. UID 0, executable adı,
policy hash veya `/info`da userns bayrağı olmaması tek başına grant değildir.
Eksik üretici `mapping_unavailable/worker_unavailable` bırakır; test callback'i
production issuer'a dönüşmez. Native host bind-mount resolver'ı bu managed
volume profili için gevşetilmez veya tamamlanmış sayılmaz.

API'de mevcut `auth.assert_current` ve admin/first-password denetimi yeniden
kullanılır. DB transaction içinde actor/user revision, session family,
Core/home, preparation revision/hash, cancel ve execution profile sürümü
eşleşir. Her effect'in hemen öncesinde worker aynı yetkiyi tekrar alır;
callback yalnız gerçek broker uygulamasını temsil eder. İşlem sonrası geç
revocation başarı yayınını durdurur. Network/SQLite/Engine arasında atomic
transaction veya dispatch edilmiş isteği geri alma iddiası yoktur.

Production bağlantısı `install_ipc.py`/`install_runtime.py` ve
`install_api.py`/`install_models.py` dosyalarına ayrılır; mevcut readonly IPC
ve jobs router'ına yeni mutation anlamı yüklenmez. Native runtime'ın gerçek
Core container full ID/başlangıç bağı operator tarafından doğrulanır; label,
container adı veya Client'ın gönderdiği ID üzerinden Core keşfedilmez.

### 4. Özel Jellyfin bootstrap, health ve kullanıcıya tamamlanan kurulum

İlk container hiçbir LAN portu publish etmeden, yalnız doğrulanmış özel
kontrol ağı ve worker/bootstrap ulaşımıyla başlar. Internal network etiketi
tek başına izolasyon kanıtı değildir: Engine endpoint üyeleri ve gerçek
untrusted sibling/LAN erişim negatifleri test edilir. Bu profil için güvenli
kontrol ulaşımı kurulamazsa wizard başlamaz; MA host ağı istisnası taşınmaz.
Mevcut `PrepareControlNetworkResource` zaten `internal=true` üretir. Yeni
bağlama adımı yalnız operator'ın doğruladığı Core full ID ile yeni Jellyfin
full ID'yi kabul eder; gerekiyorsa exact network-connect isteği ayrıca
journaled effect olur. Taze network inspect bu izinli endpoint setini
doğrular; mevcut boş-network reader'ını gevşetmez. Kaybolan network-connect
ACK yalnız taze üyelik okumaya gider, otomatik connect tekrarı yoktur.
Sonraki health isteğinin sayısal hedefi de bu fresh container/network
gözleminden gelir; DNS/adres değişimini başka servise sessizce takip etmez.

Core rastgele Jellyfin yönetici sırrını **ilk upstream mutasyondan önce**
şifreli ve installation/source bağlı kaydeder. Pinli upstream Startup API
şemasıyla ilk hesabı kurar, wizard'ı tamamlar, yeni kimlikle authenticated
okuma yapar. Sonra `ServiceManagement` şifreleme/secret redaksiyonunu yeniden
kullanarak yönetilen bağlantıyı saklar; kişisel vault kullanılmaz. Bağlantı
record'unun installation/source bağı ayrı, değiştirilemez ilişki olarak
kalır; sonradan endpoint revision değişirse otomatik yeni adrese yetki
taşınmaz. API anahtarı kullanıcıdan kopyalanmaz; sır plan/log/Client DTO'ya
girmez. Upstream yazıda kayıp ACK, ikinci kullanıcı veya yeniden wizard POST
doğurmaz; exact kayıt üzerinden gözlem/yeniden kimlik doğrulama gerekir.
[Pinli StartupController](https://github.com/jellyfin/jellyfin/blob/1fbd8739292cce610231be93daf43368733edf63/Jellyfin.Api/Controllers/StartupController.cs).

Son başarı: `/health`, beklenen Jellyfin sürüm/Server ID, tamamlanmış wizard,
gerçek authenticated `/System/Info`, iki mount'un taze inspect'i ve şifreli
Core service record revision'ı birlikte eşleşir. Mevcut
[probe.py:323–333](../server/larenor_server/services/probe.py#L323) wizard bitmeden
authenticated dememeyi zaten sağlar. Container aynı portsuz özel kontrol
profilinde kalır; var olan container'a sonradan PortBindings eklenebileceği
varsayılmaz. Core bu kapalı ağdaki şifreli yönetilen bağlantıyla gerçek servisi
izler. Kullanıcının doğrudan LAN yayını/reverse proxy ve oynatma akışı sonraki
açık profil/S08.8 işidir; ilk kurulumun tamamlandığına kanıt diye gösterilmez.
Client mevcut plugin ekranında ayrı **Jellyfin kurulumu** onayı/iş geçmişi ve
çalışan Core bağlantısını gösterir; salt okunur “gereksinim denetimi” eylemi
mutasyona dönüştürülmez. Core yönetilen servis kullanımı Direct credential
store'larına yazılarak taklit edilmez.

## Kesin giriş/çıkış ve restart sözleşmesi

Önerilen private giriş:
`install_jellyfin(stack, catalog, policy, volume_plan, execution_profile,
install_intent, *, broker, cancelled)`.
Girdi JSON yetkisi değildir; immutable exact-type kaynaklar çağrı ve her
effect öncesi yeniden türetilir. `install_intent`: Core/home/preparation,
Jellyfin installation/operation/5 step ID, request ID, expected preparation
revision, stack/volume/catalog/manifest/config/profile digest'leri ve actor/
session/user revision bağı. Caller volume/container adı, UID, mount, image,
port override, secret veya serbest Docker alanı sağlayamaz.

Public öneri: `POST /admin/media/preparations/{id}/installations`, kapalı
`serviceId='jellyfin'`, `requestId`, `expectedRevision`, `stackPlanHash`,
`executionProfileDigest`; 202 ile yeni installation-job. GET durum/geçmiş,
expected job revision ile iptal. Eski media/preflight API biçimleri ve
altı-child v1 hash aynen kalır. Ayrı capability yalnız bu supported service'i
ve gerçek worker/profile durumunu bildirir; katalog genel olarak enabled
yapılmaz. Bu API ancak checkpoint 1–4'ün birlikte kabulünden sonra açılır.

Çıkış: `installed` yalnız tüm son oracle'lar doğruysa; aksi halde kapalı
`cancelled`, `authority_lost`, `unsupported_profile`, `resource_conflict`,
`uncertain`, `needs_attention`, `health_failed` kodları. Private receipt
container full ID, image config ID, iki volume journal/revision/nonce,
mount-spec digest ve service-record revision taşır; raw Config, Mountpoint,
bootstrap stdout veya sır taşımaz.

| Kesilme noktası | Yeniden açılışta zorunlu davranış |
| --- | --- |
| Durable begin başarısız/ACK kayıp | Engine effect yok; DB gerçek phase yeniden okunur |
| Volume create belirsiz | Mevcut GET-only reconcile; ikinci create/delete yok |
| Helper create/start veya UID değişimi belirsiz | Helper/container ID + volume binding + current metadata gözlemi; tekrar chown/seed yok, yarım durum korunur |
| Service container create/start ACK kayıp | Exact full-ID/mount/config inspect; yeni anonymous container veya ikinci start yok |
| Bootstrap upstream yazısı ACK kayıp | Saklı secret/installation ile durum doğrulama; yeniden hesap/sır üretimi veya kör POST yok |
| Başarıdan sonra worker/daemon restart | Tarihsel receipt izin değildir; source/broker/volume/container/service bağı taze ölçülmeden yeni effect yok |
| İptal/rol kaybı/foreign volume/üçüncü değer | Sonraki effect yok; veri otomatik silinmez, helper kalıntısı genel prune ile temizlenmez |

Kurulumdaki yetki, kapasite ve bütün kaynaklar tek magic “ready” alanında
birleştirilmez. Docker veri alanının kapasitesi native appdataRoot ölçümünden
türetilmez; gerçek operator storage profile ve son recheck zorunludur.

## RED/GREEN kapısı ve kaynak sahipliği

İlk iş **gerçek karakterizasyon testini ve aynı testin tükettiği dar
bootstrap/mount köprüsünü** birlikte açmaktır. Sırf yeni model/validator
checkpoint'i tamamlanmış feature sayılmaz. Önerilen dosyalar yukarıdaki iki
production modülü, tek managed-install journal/coordinator, dar install
API/IPC+Jellyfin bootstrap adapter ve karşılık gelen odak testleridir. Mevcut
auth/crypto/worker/HTTP kabuğu değişecekse her değişiklik için dar gerçek RED,
eski mountsuz/image/network/readonly jobs uyumluluğu ve bağımsız diff review
gerekir; tümünü yeniden yazmak gerekmez.

Yerel oracle'lar: actual SQLite crash/reopen/locking, exact request sayıları,
body/header sınırları, durable-before-effect, reentrant revision, source/
nonce/platform kayması, auth disable/demotion/logout ve gecikmiş ACK; gerçek
HTTP Client confirmation→job→cancel/readback ile secret/log taraması.
Gelecek API için body 8 KiB sınırı; mevcut volume inspect 64 KiB, image inspect
1 MiB sınırı korunur. Yeni container/body/result sınırları fixture'da ölçülüp
closed codec'e konur; sınırsız log veya filesystem taraması yok. HTTP süreleri
exchange başınadır; ayrı wall-clock job bütçesi ve kill/reap testi olmadan
bütün syscall zincirine kesin süre vaadi verilmez.

Gerçek native amd64 ve arm64 CI oracle'ları: doğru UID yazısı/ilk DB, sentinel
copy-up negatif/NoCopy, tam iki named mount ve sıfır anonymous volume, init
API'nin dışa kapalı oluşu, authenticated sonuç, Core+worker+container restart
sonrası veri ve Server ID korunumu; aynı isimde foreign volume ve yetki
kaybında yeni effect sıfır. Ephemeral fixture yalnız kendi kaynaklarını
temizler; production iptal veya recovery hiçbir kullanıcı verisini silmez.
QEMU/synthetic Unix sonucu bu gerçek Engine kapısının yerine geçmez.

Son kabul sırası: local RED/GREEN ve coverage ≥%80 → bağımsız review → exact
iki mimarili ephemeral Engine CI → gerçek Client akışı/Android teslimi → en
son, ayrı kullanıcı adımıyla ev kurulumu/donanım. Bu belge, önceki
3435 PASS/12 Linux skip kaynak doğrulamasına yeni kernel/UID veya kurulum
kabulü eklemez; S06.3d/3f/4/5/6 topluca tamamlanmış sayılmaz.
