# S06.4 dar medya kurulum yürütmesi

**Durum:** Kalıcı API, ayrı IPC ve doğrulanmış Jellyfin binding dilimleri yerelde
uygulandı. S06.4 tamamlanmadı; binding'i tüketen ayrı journal/runtime, paketli
mutasyon işçisi ve iki mimarili native kabul açık. Ürün kurulum yeteneği
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

Bu dilim son kurulum worker CLI'sini, ayrı managed-container journal'ını veya
runtime supervisor'ını sağlamaz. Kullanıcının Docker Engine'ine veya ev
sistemlerine hiçbir mutasyon yapılmadı.

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
- Güncel bağlayıcı/yürütme/IPC/eski worker regresyon paketi 78 test geçti;
  Python derleme ve `git diff --check` temiz.

Sürüm kontrollü örnekler
[`contracts/media-installations.v1.json`](../contracts/media-installations.v1.json)
dosyasındadır. Son kabul için güncel kaynak commit'inin Server ve güvenlik CI'ı,
paketli worker runtime testi ve disposable Linux üzerinde amd64/arm64 gerçek
create/start makbuzları gerekir. Bunlar olmadan S06.4 `done` yapılamaz.

## Sonraki dilim

1. Worker-only policy modeli accepted image, managed appdata volume ve private
   control-network receipt kimliklerini tam eşleşmeyle açacak.
2. Builder doğrulanmış receipt'lerden mount/port/security binding üretecek;
   API veya Client ham yolları seçemeyecek.
3. Aynı Server paketindeki mutasyon worker CLI ve supervisor yaşam döngüsü
   eklenecek.
4. İki mimarili disposable Linux acceptance gerçek Engine create/start,
   restart reconciliation ve owned-resource temizliğini kanıtlayacak.
