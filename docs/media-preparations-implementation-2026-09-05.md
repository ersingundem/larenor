# Birleşik medya hazırlığı — uygulanan sözleşme

**5 Eylül 2026 · S06, dilim 1.** Bir Larenor medya kurulumu için altı bileşen
artık tek hazırlık kaydında tutulur. Bu teslim kurulum başlatmaz, host kapasitesi
ölçmez ve servisler arasında API bağlantısı kurmaz.

## Client kullanımı

Yönetici hesabıyla **Ayarlar → PIN → Server hesabı → Sunucu bileşenleri → Medya
hazırlığı** yolunu aç. Bir ortak ad, uygulama verisi ve medya kökü kimliği,
isteğe bağlı müzik kökü ve hedef mimariyle hazırlığı kaydet. Bunlar onaylı
konumların kimlikleridir; Client serbest host dosya yolu gönderemez.

qBittorrent, Sonarr, Radarr, Jellyfin, Seerr ve Music Assistant aynı planda
görünür. Geçmiş, ayrıntı ve kayıt iptali Client'tan yönetilir. Yenileme açık
kullanıcı işlemidir. Bağlantı kesilirse aynı istek kimliğiyle kurtarma ikinci
bir hazırlık oluşturmaz. Ekranı tekrar açınca kalıcı geçmiş Server'dan okunur.

Music Assistant için ayrı URL/token formu yoktur. Henüz çalışan medya motoru
veya sağlayıcı giriş akışı eklenmiş sayılmaz. PIN yerel ekranı korur; gerçek
yönetici yetkisini Server yeniden denetler.

## Server API

Bütün yollar `/api/v1/admin/media/preparations` altında, ilk parolasını
değiştirmiş güncel yönetici oturumuna açıktır. Gerçek şema korumalı
`/api/v1/openapi.json` içinde yer alır.

| İşlem | Sözleşme |
| --- | --- |
| `POST /api/v1/admin/media/preparations` | `201 {preparation}`; `requestId`, `templateId: media`, gözden geçirilen `context`, `catalogDigest`, `platform`, ortak `settings` |
| `GET /api/v1/admin/media/preparations` | `{preparations, nextBefore}`; en yeni önce, `limit` 1–10 ve isteğe bağlı `before` |
| `GET /api/v1/admin/media/preparations/{id}` | `{preparation}`; oluşturucu çıkış yaptıktan sonra da güncel yöneticiler okuyabilir |
| `POST /api/v1/admin/media/preparations/{id}/cancel` | `{expectedRevision}`; kayıt revizyonu 1/prepared → 2/cancelled, kaynak silinmez |

Tam örnek yanıtlar, gerçek HTTP akışından üretilen
[ortak Python/Dart sözleşmesindedir](../contracts/media-preparations.v1.json).

İstek kimliği kullanıcı kapsamında tekildir. Aynı kimlik ve aynı içerik,
iptalden sonra bile aynı kaydı döndürür. Farklı içerik veya başka aktif
hazırlıkla çakışan ad `409 media_preparation_conflict` verir. Eski katalogla
yeni kayıt oluşturulmaz; geçmiş planı katalog değiştikten sonra
`catalogCurrent: false` ile okunabilir ve iptal edilebilir.

## Kalıcılık ve sınırlar

- Core/ev/hazırlık kimliğinden bileşen başına ayrı kurulum, işlem ve beş adım
  kimliği türetilir. Yeniden başlatma aynı adımları farklı kaynaklara dönüştürmez.
- Plan sabitlenmiş katalogdan yeniden hesaplanır. İmaj, yetki, port veya mount
  seçenekleri isteğe eklenemez. Plan özeti kanonik JSON'un SHA-256 değeridir.
- İstek ve plan AES-GCM ile şifrelenir; kayıt kimliği, sahiplik, sıra, revizyon,
  durum ve zaman alanları doğrulanan ek veriye bağlanır. Aynı Server kasa
  anahtarı kullanılır; anahtar ve veritabanı birlikte yedeklenmelidir.
- Ek şema ayrı bir migration ile oluşturulur. Boş tabloda bile sütunlar ve
  tekillik indeksleri doğrulanır; bozuk şema/kayıt başlangıcı durdurur.
  Geçmiş en çok 256 kayıt, aynı anda 8 aktif hazırlık; sayfa en çok
  10 kayıt ve şifreli kayıt en çok 128 KiB olabilir. İptal geçmişi silmez.
- Toplam 16 GiB bellek, 12 CPU eşdeğeri ve 48 GiB asgari disk **katalogda
  istenen bütçelerin toplamıdır**. Ölçülen kapasite veya medya arşivi boyutu
  değildir. PIDs toplamı 3.072'dir.
- Ortak `library` kökü indirme/film/dizi bileşenlerinde `/data` olarak
  kullanılır. Jellyfin yalnız doğrulanmış salt okunur `/media` görünümünü
  alabilir. Host inceleyicisinde diğer amaç/yazma sınırları korunur.

Üst plan `installAvailable: false`, her bileşen `installable: false`, ilk
kurulum erişimi `bootstrapExposure: unverified` olarak kalır. Yönetilen kurulum,
host doğrulaması, özel bootstrap ve otomatik eşleştirme açık engellerdir.

## Doğrulama ve sonraki teslim

Server HTTP/depolama testleri ile Client model/controller/widget testleri
mevcut CI test keşfine dahildir. Ortak sözleşme iki tarafta aynı alanları ve
gerçek Server yanıtını sınar. Sayısal son sonuçlar ve uzak CI durumu
[PROGRESS](PROGRESS.md#son-test-kanıtı) içinde tutulur.

Sıradaki teslim [S06 dilim 2](remaining-core-integration-slices.md): worker ve
Docker daemon'ın host bağlamını kanıtlamak; ortak depolama, port ve alıcı ağını
doğrulamak. Sonraki kaynak hazırlığı ve bootstrap adımları geçmeden bu kayıtlar
kuruluma açılmayacak. Ev sunucusuna kurulum en sonda kullanıcıyla yapılır.
