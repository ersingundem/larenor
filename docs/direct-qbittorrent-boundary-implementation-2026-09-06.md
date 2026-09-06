# S08.4 — Direct qBittorrent kaydı ve açık kurtarma

6 Eylül 2026. İzole dal `codex/direct-qbittorrent-boundary`, başlangıç
`e4f0f155d55bc0a2a37bc2e0e5e32ce3905b70dc` (Arr + backup birleşimi).
Üretim dondurması `66d3965245f14f0d6f46f81da774c7690d29b59d`.
Bu paket qBittorrent tüketicisini kapsar; bütün S08.4 veya diğer medya
servislerinin tamamı için kabul değildir.

## Kayıt ve kaynak sınırı

`QbittorrentCredentialsStore`, mevcut `DirectCredentialRecord` sözleşmesini
qBittorrent'in kapalı URL, kullanıcı adı ve parola alanlarıyla tüketir.
`qbittorrent_connection_pending_v1` marker'ı ilk alan etkisinden önce yazılır;
bütün alanlar ve güncellik kontrolleri tamamlanınca kaldırılır. Marker bulunan
okuma, tuple alanlarını okumadan statik `pending_mutation` hatası verir.
Boş veya beklenmedik marker metni de izin vermez. Platform yanıtı başarısızsa
etkinin gerçekleşmediği varsayılmaz; arada kalmış yeni URL/eski kullanıcı veya
parola birleşimi yeni store örneğinde de kullanılmaz.

Üretim store'u ilk `DirectHomeAccess` sahibine bağlıdır. Core, başlangıç
pending/error, eski kaynak ve Direct → Core → Direct dönüşündeki tutulmuş
nesne read/save/clear yetkisini yeniden kazanmaz. Eski kapsamsız store çağrısı
uyumluluğu korunur. Yeni opsiyonel `isCurrent` callback'i save/clear sırasında
ortak sıralı yazı kuyruğuna ve her alan etkisinin öncesi/sonrasına taşınır.
Shared helper, backup allowlist'i ve diğer servislerin alanları değiştirilmedi.
Marker export veya backup journal alanı yapılmadı; mevcut 11-servis backup
marker politikası birleşik regresyonda korundu.

Yazı hataları otomatik rollback, retry, marker silme veya başka servisin
kaydına erişim başlatmaz. İlk marker yazısı ya da son marker kaldırma yanıtı
belirsizse hata yine bildirilir; tam eski/yeni kayıt gerçekte kalmış olabilir.
Bu sınır native Keystore transaction, disk fsync veya fiziksel restart
kanıtı değildir.

## Login, ekran ve kurtarma

Notifier ilk kaynak sahibini ve işlem kuşağını tutar. Store/factory await
öncesinde alınır; geç HTTP sonucu yeni kaynaktan store edinip yazamaz.
Mevcut en yeni login kazanır, logout eski doğrulamayı kapatır davranışı
korunur. Gerçek qBittorrent adapter'ı değişmedi: cookie'li login ardından
uygulama ve Web API sürüm GET'leri gerekir; yalnız login yanıtı başarılı
bağlantı sayılmaz. Cookie ve sürüm denetimleri sentetik HTTP testlerinde
mevcut adapter üzerinden çalışır.

`cancelSignIn(owner)` yalnız aynı form callback'ine ve güncel işlem kuşağına
ait doğrulama istemcisini kapatır. Eski/farklı owner yeni login'i veya normal
okuma istemcisini kapatamaz. Kapatma storage, logout veya yeni normal-reader
login'i başlatmaz; daha önce gönderilmiş HTTP isteği geri alınmış sayılmaz.
İptal edilen replacement, eski kullanılabilir config'i yeniden yayımlayıp
otomatik cookie login'i başlatmaz. Kısmi platform yazısı AsyncError olarak
kalır; iyimser başarılı bağlantı yayımlanmaz.

Connect ve Torrents ekranları Direct kaynak, native lifecycle,
AppInteraction epoch, TickerMode ve current-route kontrollerini kullanır.
Eski callback'e yeni taslak doldurulsa bile pencere/idle, arka plan, PIN,
route, source roundtrip veya dispose sonrası işleme devam etmez. Aktif
login sırasında bu bağlamın kaybı kalan sürüm GET'lerini ve credential
etkilerini durdurur. Torrents ekranının kendi confirmation modal'ı korunur;
üstüne açılan ilgisiz route eski eylemi emekliye ayırır. Normal Direct okuma
istemcisi yalnız formun eski owner'ı tarafından kapatılmaz.

Gerçek Settings PIN → Integrations → Manage Integrations → qBittorrent
akışı `pending_mutation`/`write_unconfirmed` için boş kurtarma formu gösterir.
Eski alanlar önceden doldurulmaz, LAN discovery kurulmaz. Kullanıcı tam URL,
kullanıcı adı ve parola ile yeniden bağlanabilir veya kayıtlı bağlantıyı
kaldırabilir. Clear yalnız captured bound store'u kullanır; başarılı durumda
boş form ve Done/Bitti kalır. Otomatik invalidate/reload ile discovery veya
login başlatılmaz. Alan etkisinde clear başarısızsa marker korunur ve statik
hata gösterilir; tekrar açık kullanıcı eylemi gerekir.

Standalone Connect route kendi provider aboneliğini doğrulama boyunca tutar.
Boş/pending form kendi login'i yüzünden emekliye ayrılmaz; önceki kullanılabilir
reader replacement başladığında kapanır. Başarı yalnız hâlâ current olan
kendi route'unu pop eder; geç cevap üstteki başka route'u kapatamaz.
Kullanıcı adı label'ı 320 px/TR/2× metinde satıra sarılır. İki yeni EN/TR anahtar
`qbittorrentConnectionIncomplete` ve `qbittorrentRemoveConnection` dışında
çeviri sözleşmesi değiştirilmedi. Platform/upstream hata gövdeleri ekrana
aktarılmaz.

## RED → GREEN ve yerel kanıt

| Dilim | Runtime RED | GREEN |
|---|---|---|
| Direct sahiplik / eksik tuple | `1f9b7e4`: 13 FAIL | `2941a00`: 19 PASS, önceki 6 provider testi dahil |
| Cookie doğrulama / eski kaynak işlemi | `5722222`: 13 PASS / 3 FAIL | `569f78d`: 22 PASS |
| Gerçek PIN kurtarma / eski callback / yarım alan yazısı | `7ca0dc6`: 2 PASS / 13 FAIL | `dcf4076`: 102 PASS |
| 320 px/TR/2× gerçek overflow | `01fe873`: 2 PASS / 1 FAIL | `66d3965`: 121 PASS |

Son genişletmede eski/farklı cancel owner, normal Direct reader pozitif
kontrolü, önceki kullanılabilir config'in iptal sonrası yeniden yayımlanmaması,
her alan etkisinde pencere kaybı, PIN değişirken gerçek login'in açık olması,
standalone pop, clear platform hatası, explicit başarısız-login retry ve
320×640/TR ile 1366×1024/EN 2× düzenleri bulunur. Önceki altı sign-in/sign-out
regresyonu aynen korunmuştur.

- **121 odaklı PASS**, 4 saniye: `direct_qbittorrent_boundary_test.dart` ve
  mevcut/yeni bütün qBittorrent testleri.
- **531 ilişkili PASS**, 13 saniye: ortak credential helper, dört Arr store
  ve action/form akışları, qBittorrent, MediaSessionState ve bütün backup
  testleri. Sayılar örtüşür; toplanmaz.
- **7 dosya analyze: 0 bulgu.** Formatter 7 dosyada 0 değişiklik;
  `git diff --check` temiz. Son iki test-only braces düzeltmesi davranışı
  değiştirmez.
- Odaklı LCOV: dört değişen üretim dosyası **496/527 = %94,1 satır**.
  Store 13/13, provider 102/108, Connect 145/152, Torrents 236/254.
  Generated kaynaklar bu hesaba dahil değildir; branch coverage iddiası yoktur.

Test fixture'ları gerçek HomeSessionController/provider ve secure-storage
MethodChannel sınırını kullanır. HTTP MockClient ile sentetiktir;
network_info platform kanalı null döndürdüğünden ev ağı keşfedilmez.
Derleme hataları ve kaydırma yardımcısının bulunmayan `.first` kontrolü runtime
RED sayılmadı; son overflow RED'i bu fixture hataları giderildikten sonradır.
Reddedilen login UI testi, adapter'ın HTTP 200 fakat başarısız body sözleşmesini
kullanır. Mevcut 401/403/parser testleri değişmedi.

Kanıt dosyaları `/private/tmp/larenor-direct-qbit-` önekiyle:
`red.log`, `store-green.log`, `actions-red.log`, `actions-green.log`,
`ui-red.log`, `ui-green.log`, `layout-red.log`, `final-green.log`,
`shared-regression.log`, `analyze.log`, `format.log`, `coverage.info`.

Canlı HA/LAN/qBittorrent çağrısı, gerçek torrent işlemi, cihaz kurulumu veya
fiziksel tablet testi yapılmadı. Bu izole kaynak push edilmedi. Bütün Client
ve sonraki exact GitHub CI teslimi, diğer medya/personal paketlerinin birleşimi
sonrasında root tarafından ayrıca doğrulanır.
