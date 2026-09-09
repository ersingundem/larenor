# S06.4 dar medya kurulum yürütmesi

**Durum:** Kalıcı API, ayrı IPC ve doğrulanmış Jellyfin binding dilimleri yerelde
uygulandı. Binding'i tüketen ayrı sürüm-2 managed-container journal ve
journal-bound proof broker çekirdeği de yerelde tamamlandı. S06.4 tamamlanmadı;
tek-Engine production reader/bootstrap adaptörü, paketli mutasyon işçisi,
runtime ve iki mimarili native kabul açık. Ürün kurulum yeteneği
`installAvailable=false` kalır.

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
Okuyucu tek opaque Engine kimliği taşır. Bunun somut production Engine reader ve
volume-bootstrap adaptörü, son kurulum worker CLI'si ve runtime supervisor'ı
henüz yoktur. Kullanıcının Docker Engine'ine veya ev sistemlerine hiçbir
mutasyon yapılmadı.

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
- Güncel bağlayıcı/yürütme/IPC/eski worker regresyon paketi 89 test geçti;
  Python derleme ve `git diff --check` temiz.
- Broker'ın resource/volume/managed odak paketi 169 test geçti.
- Exact `086fa2a` kaynak commit'i [Server CI 34312388251](https://github.com/ersingundem/larenor/actions/runs/34312388251)
  ile geçti. Güncel broker kaynak commit'inin exact-source CI'ı henüz açık.

Sürüm kontrollü örnekler
[`contracts/media-installations.v1.json`](../contracts/media-installations.v1.json)
dosyasındadır. Son kabul için güncel kaynak commit'inin Server ve güvenlik CI'ı,
paketli worker runtime testi ve disposable Linux üzerinde amd64/arm64 gerçek
create/start makbuzları gerekir. Bunlar olmadan S06.4 `done` yapılamaz.

## Sonraki dilim

1. Production composite reader accepted image, managed appdata volume/bootstrap
   ve private control-network değerlerini tek Engine üzerinde taze doğrulayacak.
2. Aynı Server paketindeki mutasyon worker CLI ve supervisor yaşam döngüsü
   eklenecek.
3. İki mimarili disposable Linux acceptance gerçek Engine create/start,
   restart reconciliation ve owned-resource temizliğini kanıtlayacak.
