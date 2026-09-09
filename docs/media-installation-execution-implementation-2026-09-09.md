# S06.4 dar medya kurulum yürütmesi

**Durum:** Kalıcı API, ayrı IPC ve doğrulanmış Jellyfin binding dilimleri yerelde
uygulandı. Binding'i tüketen ayrı sürüm-2 managed-container journal,
journal-bound proof broker çekirdeği, tek-endpoint production reader bileşimi,
paketli volume bootstrap verifier, `larenor-installation-worker` CLI yaşam
döngüsü ve worker yaşamına bağlı ilk native supervisor tamamlandı. Managed-v2
workflow'un amd64/arm64 native kabulü de exact PR kaynağında geçti. S06.4
tamamlanmadı; supervisor diliminin Linux CI'ı, rootful/remap-disabled üretim
yetkisi ve bağımsız inceleme açık.
Ürün kurulum yeteneği `installAvailable=false` kalır.

## Uygulanan sınır

`POST /api/v1/admin/media/installations` yalnız bir idempotency kimliği ile
önceden kabul edilmiş preparation ve başarılı inspection kimliklerini,
revision'larını ve plan hash'ini alır. Hizmet, imaj, komut, host yolu, Docker
endpoint'i veya Docker JSON'u almaz. Core paketli plandan sadece Jellyfin için
`create_container` ve `start_container` child adımlarını yeniden üretir.

Kabul ve her yan etki öncesinde yönetici/user revision, session family,
Core/ev, preparation, inspection, katalog ve iptal durumu yeniden kontrol
edilir. Belirsiz create sonucu aynı job/step kimliğiyle uzlaştırılmadan start'a
geçilmez. Worker makbuzundaki job veya step değişirse sonuç reddedilir. Aynı
request tekrarında önceki kayıt döner; aynı preparation için farklı request
`409 media_installation_conflict` üretir.

Tam plan AES-GCM ile şifrelenir ve kimlik, sıra, revision, aktör, family, kaynak
kimlikleri, state ve timestamp AAD'ye bağlanır. Geçmiş katalog değişse bile
okunur; eski planla yeni etki çalıştırılmaz. En fazla 256 kayıt saklanır ve
SQLite işlemi worker çağrısı boyunca açık tutulmaz.

## Ayrı mutasyon kanalı

`LARENOR_PLUGIN_WORKER_SOCKET` salt okunur host kontrolü içindir.
`LARENOR_INSTALLATION_WORKER_SOCKET` ise yalnız `status`, `apply` ve
`reconcile` kabul eden ayrı Unix IPC'dir. İki yol aynı olamaz. Bağlantının
socket türü/sahipliği ve peer UID'si doğrulanır; paket ve toplam süre sınırlıdır.
Worker gelen `WorkerStep` ile tam paketli `MediaStackPlan` ilişkisini ve güncel
kataloğu yeniden doğrular, Jellyfin child'ını içeride seçer. Böylece kaynak
makbuzlarını Core/ev/preparation kimliğiyle yeniden türetmek için gereken bağlam
korunur. Docker binding yalnız worker içindeki güvenilir builder'dan gelebilir.

Worker-only `JellyfinBindingBuilder`, tam stack ve güncel katalog/politikadan
resource ile volume planlarını yeniden türetir. Güvenilir broker'dan aynı planlara
bağlı image kimliği/konfigürasyonu, bootstrap doğrulanmış tam iki volume ve özel
ağ makbuzu ister. Çıktı LAN portu yayınlamaz, ağı sabit private network'e bağlar,
yalnız `/config` ve `/cache` için `NoCopy=true` named volume üretir. Image'ın
bildirdiği bütün `Config.Volumes` hedefleri bu iki mount ile tam örtüşmezse veya
taze inspect image/security/mount/network kimliğinden saparsa eşleşme reddedilir.

Ayrı sürüm-2 managed-container journal tam binding'i yan etkiden önce kalıcı
yazar. Sürüm-1 legacy satırlarını okuyamaz; create/start sırasını, journal ve
installation etiketlerini ve idempotency digest'ini yeniden doğrular. Belirsiz
create sonucunda ikinci create yapmadan tam Engine gözlemiyle uzlaştırır. Güncel
kaynaklardan yeniden üretilen binding saklanan binding ile aynı değilse Engine'e
ulaşmadan reddeder. Image referansı, etiket şeması, ortam, kaynak sınırları,
read-only rootfs, tmpfs, iki NoCopy mount ve private network gövdesi sabit Docker
create yolundan önce tekrar doğrulanır.

Bu dilim gerçek kaynak journal'larını okuyup aynı Engine'e karşı yeniden
bağlayan broker çekirdeğini de içerir. Broker iki journal kilidini sabit sırada
tutar, exact source/revision/nonce bağını alır, image/volume/bootstrap/network
okumalarından sonra bağları tekrar kurar ve eski bootstrap revision'ını reddeder.
`JellyfinEngineReaders` image, volume ve network Unix taşıyıcılarını tek
operator-owned `DockerEndpoint` üzerinden kurar ve bootstrap verifier'ın da aynı
endpoint nesnesine bağlı olmasını ister. Paketli verifier exact sha256 image
kimliğiyle yalnız `verify_root` çalıştırır; ağsız, read-only rootfs'li, bütün
capability'leri düşürülmüş geçici helper'a hedef volume'u read-only NoCopy olarak
bağlar ve kesin çıkış sonucundan sonra bilinen container ID'sini siler. Komut,
image, mount, ağ ve silme seçenekleri IPC'den gelemez.

`larenor-installation-worker`, private 0600 politikasından tek Docker endpoint'i,
opaque worker policy bağını, helper image ID'sini ve birbirinden ayrılmış üç
journal yolunu yükler. `--check-config` bu kaynakları açmadan salt şemayı kontrol
eder. Runtime her stack isteğinde proof broker'ı tekrar kurar, socket'i Engine
endpoint'i veya journal ağaçları içine koymayı reddeder ve kapanışta socket'ten
sonra bütün journal'ları kapatır.

Yeni `SupervisedInstallationBackend`, IPC servis thread'i içinde tek doğrulanmış
Docker Unix bağlantısı açar ve o peer'e ait socket-bound pidfd, executable,
proc, user/mount/network namespace ve process-root tanıtıcılarını worker
yaşamı boyunca tutar. Socket inode zinciri, daemon incarnation ve kimlikler her
`apply`/`reconcile` öncesi ve sonrasında aynı native thread'de yenilenir. Startup
kanıtı hazır olmadan IPC `start` başarılı sayılmaz; daemon restart, endpoint
replacement, thread değişimi, deadline veya post-effect kanıt kaybı statik
`worker_unavailable` sınırında kapanır. Backend etkiden sonra belirsiz kalırsa
journal üzerinden mevcut reconcile kuralı korunur. Eşit user namespace/map
gözlemi initial host namespace veya remap-disabled daemon başlangıcı değildir;
bu yüzden bu dilim kendi başına kurulum yetkisi üretmez. Kullanıcının Docker
Engine'ine veya ev sistemlerine hiçbir mutasyon yapılmadı.

## TDD ve doğrulama

- RED `d25ca83`: kapalı create/start yürütme ve her adımda gate sözleşmesi.
- GREEN `b95158b`: Jellyfin yürütme koordinatörü ve worker köprüsü.
- RED `6b9be95`, `c772f71`, `c76983e`: kalıcı API, sahte makbuz, katalog
  değişimi, iptal ve şifreli saklama regresyonları.
- GREEN `25e6a9b`: kalıcı API, migration, Core/router ve dispatcher bağlantısı.
- RED `b170075`: preflight'tan ayrı mutasyon IPC sözleşmesi.
- RED `241e6fb`: resource binding için tam stack bağlamının IPC'de korunması.
- GREEN `3300dd0`: worker tam stack'i yeniden doğrulayıp Jellyfin child'ını seçer.
- RED/GREEN `44e4bfd` / `874aca1`: typed resource proof'tan kapalı Jellyfin binding.
- RED/GREEN `28e7e4e` / `52bae6c`: reconcile sırasında taze proof ve binding zorunluluğu.
- RED/GREEN `9d2f171` / `d2c5a5f`: tam image/mount/network inspect matcher.
- RED/GREEN `d97f63b` / `c7955ab`: legacy'den ayrılmış v2 journal, kalıcı
  create/start niyeti, kayıp cevap uzlaştırması ve sabit managed Docker yolu.
- RED/GREEN `dc2d15d` / `6b81c49`: ready resource receipt'ini yalnız exact
  güncel source ve revision'a yeniden bağlayan worker-private journal kapısı.
- RED/GREEN `2344f11` / `797709f`: iki journal'a ve tek Engine kimliğine bağlı
  taze Jellyfin image/volume/bootstrap/network proof broker çekirdeği.
- GREEN `ba54f9a`: sabit Unix image/volume/network okuyucularını tek exact
  Docker endpoint'i ve endpoint-bound bootstrap verifier altında birleştirir.
- RED/GREEN `3be1dc6`: mevcut storage kanıtını koruyan ayrı managed-v2 native
  CI adapter'ı, exact receipt verifier ve amd64/arm64 workflow'u.
- GREEN `9b01bcf`–`06f7c3e`: Docker'ın swap, empty-tmpfs, moved-mount ve
  created-state network normalizasyonlarını dar kabul eden matcher; gerçek
  cgroup memory/cpu/pids doğrulaması.
- RED/GREEN `19485ab`: image digest ile çıplak 64-hex container ID biçimini
  ayıran create receipt doğrulaması.
- RED/GREEN `af113e0`: exact helper ile read-only volume kökü doğrulaması,
  private policy, üç journal'lı dinamik binding builder ve paketli installation
  worker CLI yaşam döngüsü; **43 odaklı PASS**. Pinli apksig ve gerçek Homebrew
  JDK 17 ile bütün Server paketi **4.256 PASS, 12 platform skip**.
- RED/GREEN `cac0625` / `b6196a1`: IPC thread'ine bağlı daemon supervisor,
  startup hazır olma kapısı, her etki öncesi/sonrası socket/pidfd/proc/namespace
  yenilemesi ve kapanış; ilgili yerel paket **268 PASS / 3 Linux skip**.
- Güncel storage/managed/resource/binding paketi **216 PASS**; managed workflow
  politika paketi ayrıca **7 PASS**. Python derleme ve `git diff --check` temiz.
- Exact `191baf3` kaynak commit'i [Server CI 34313975186](https://github.com/ersingundem/larenor/actions/runs/34313975186)
  ile geçti.
- PR head'i `19485ab` ve onun merge kaynağı `b6e7034` için
  [managed native CI 34326112926](https://github.com/ersingundem/larenor/actions/runs/34326112926)
  amd64 ile arm64 üzerinde geçti. İki indirilen makbuz exact merge checkout'unda
  repo verifier ile yeniden PASS verdi. Makbuzlar iki volume, bir restart,
  `journaled_managed_v2`, journal 2, hazır image, kapalı bootstrap hesabı ve
  `installAvailable=false` değerlerini doğruladı. Security CI aynı PR head'inde
  geçti; tam Android/Server CI halen ayrı yayın kapısıdır.

PR18 exact `75af015` için yerel tam Server **4.262 PASS / 12 skip**; Linux
[Android Build 34341554668](https://github.com/ersingundem/larenor/actions/runs/34341554668)
paketinde Server **4.274 PASS**, Flutter **5.438 PASS**, Android native **98 PASS**
ve gerçek API 35 **17 PASS** verdi. Security 34341554393 ve amd64/arm64 managed
native 34341554476 da yeşil; iki makbuz exact merge `adbb8476` üzerinde yeniden
doğrulandı.

Sürüm kontrollü örnekler
[`contracts/media-installations.v1.json`](../contracts/media-installations.v1.json)
dosyasındadır. Son kabul için paketli worker runtime testi, güncel kaynağın tam
Android/Server CI'ı ve inceleme gerekir. Bunlar olmadan S06.4 `done` yapılamaz.

## Sonraki dilim

1. Supervisor'ın gerçek Linux peer-pidfd/proc/user-namespace testi stacked
   Server CI'da atlamadan geçecek.
2. Native başlangıç/config kanıtı rootless ve userns-remap'i fail-closed
   ayıracak; eşit map veya UID 0 tek başına yetki olmayacak.
3. Stacked kaynak bağımsız inceleme ile kapatılacak.
