# S08.7 dilim 1 — Server üzerinden seçili HA anahtarı

8 Eylül 2026. Davranış kaynağı `51c633a2f8e7595e739eff688e8dbdd0a8bf40e5`,
taban `cd961acb1586680f24ec00eead8f4d972520df4c`.
Bu teslim gerçek admin bağlama ve yetkili durum okuma dilimidir. S08.7'nin
komut/makbuz, Direct aktarımı, Client ve Android kabulünü kapatmaz.

## Çalışan yol ve sınırları

Admin mevcut şifreli `home_assistant` service kaydını ve `kind=resource` Core
kaydını seçer. Süreli preview, gerçek sınırlı HA REST okumasını yapar; ayrı
onay, preview'daki bağlamayı olduğu gibi kalıcılaştırır. Oda/kişi bağlanamaz.
Üye yalnız mevcut READ ACL ile seçili anahtarın `on`, `off`, `unavailable`
projection'ını alır. `unknown` açıkça `unavailable` olur; desteklenmeyen ham
durum bir açık/kapalı değere çevrilmez. `commandAvailable` daima gerçek
boolean `false` değeridir; komut veya genel HA proxy yolu eklenmedi.

`services.service._home_assistant_connection` yalnız aynı DB transaction'ına
ait, türü ve revision'ı doğrulanmış şifreli service okumasıdır. Üyelere admin
service API'si, token, URL veya ham HA attributes açılmaz. Core hesabı ve
resource ACL, service/binding revision'larıyla ağdan önce ve sonra yeniden
okunur. Ağ I/O boyunca SQLite transaction'ı veya adaptör kilidi tutulmaz.
Yetkisiz/gizli kaynak `404` verir ve upstream çağrısı yapmaz. Geçerli Core
oturumunda HA `401`, `502 ha_upstream_unauthorized` olur; Core hesabını
reddetmez. Core oturumu gerçekten sona ermişse kendi `401` sonucu korunur.

HA hedefi yalnız canonical ASCII `switch.[a-z0-9_]+`, en fazla 128 karakterdir.
Sabit `GET /api/states/<entity_id>` dışında upstream çağrı yoktur. Mevcut
`ServiceTransport` tek deadline, TLS/URL doğrulaması, redirect/proxy/retry
kapalılığı ve framing/byte sınırlarıyla kullanılır. Yanıttaki entity kimliği
tam eşleşmelidir. Gözlem zamanı Server saatidir; upstream timestamp'i değildir.
Başarılı okuma, fiziksel HA kurulumu veya HA principal kimliği kanıtı sayılmaz.

## Sürüm 1 HTTP sözleşmesi

Ortak ref `{schemaVersion:1, coreId, homeId, kind:'resource', id}`;
kimlikler 32 küçük hex karakter, revision aralığı `1..2^63−1`.
Public taban `/api/v1/home-assistant/{coreId}/{homeId}/resources/{resourceId}`;
admin taban aynı yolun `/api/v1/admin/home-assistant/...` biçimidir.
Query alanları ve yinelenmiş Authorization reddedilir.

| İşlem | Sonuç |
| --- | --- |
| Public `GET /snapshot` | `200 {snapshot}`; ref, binding/resource/ACL/service revision, observedAt, remainingTtlMs ve kapalı projection |
| Admin `GET /binding` | `200 {binding}` veya `404 not_found` |
| Admin `POST /binding-preview` | `201 {preview:{id,expiresInMs,binding,projection}}` |
| Admin `POST /binding-confirm {previewId}` | `201 {binding}`; preview'daki binding ile birebir |
| Admin `DELETE /binding-preview/{id}` | `204`; yalnız kendi bekleyen preview'su |

Preview gövdesindeki `serviceId`, `expectedServiceRevision`,
`expectedRevision`, `expectedAclRevision`, `entityId` ve nullable
`expectedBindingId` zorunludur. İlk bağlama revision 1 alır. Açık rebind eski
binding ID'sini CAS olarak ister, yeni opaque ID ve artırılmış revision üretir.
Service değişikliği eski bağlamayı sessizce yeni upstream'e taşımaz.
Onay preview'yu bir kez tüketir; başarısız veya yanıtı kaybolmuş onay otomatik
tekrarlanmaz. Client mevcut binding GET'iyle sonucu yeniden okuyabilir.

Yeni statik hatalar: `ha_binding_changed` ve `ha_preview_invalid` (409),
`ha_limit_reached` (429), `ha_upstream_unauthorized`,
`ha_upstream_unavailable`, `ha_projection_unsupported` (502).
Sırlar ve upstream hata gövdeleri hata metnine alınmaz.

`contracts/home-assistant.v1.json`, gerçek FastAPI/auth/SQLite akışı ile
yerel TCP HTTP fixture'ından üretilen 18 karşılığı taşır (7 upstream GET).
Core HTTP tarafı
ASGI TestClient, upstream tarafı gerçek loopback socket'tir; gerçek HA değildir.
Fixture üreticisi `server/tests/test_home_assistant_contract.py` içindedir.
Son onarımlar bu JSON/DTO sözleşmesini değiştirmedi.

## Kalıcılık, kaynak ömrü ve cache

Binding kayıtları AES-GCM ile şifrelenir; AAD resource/binding/revision'a,
envanter HMAC'i Core/home ve bütün sınırlı şifreli kayıtlara bağlıdır.
Startup ek şema/bağlı index/trigger ve bozuk HMAC'i reddeder; eski DB'yi
sıfırlamaz. Kimlik/tag/payload uzunluğu Python'a alınmadan SQLite'ta byte
olarak denetlenir. `length(TEXT)` NUL sonrasını saymadığı için metadata
kontrolü `length(CAST(... AS BLOB))` kullanır.

Silinen Core resource'un orphan binding metadata'sı yalnız güncel admin
confirm transaction'ında kaldırılır. `HomeResourceRegistry._validated_ids`
startup'taki aynı context/HMAC, her şifreli kayıt, grant ve toplam doğrulamasını
yeniden kullanır. Önce bütün HA kayıtları da çözülüp doğrulanır; canlı,
yabancı kapsamlı veya bozuk kayıt temizleme gerekçesi yapılamaz. Ardından
yalnız gerçekten eksik Core ID'leri silinir, HA HMAC güncellenir ve kota
kontrol edilir. Yeni binding INSERT ve HMAC'in tam readback'i başarıdan önce
doğrulanır. INSERT/commit hatası veya yok sayılan yazı bütün temizliği geri
alır. Bu işlem upstream DELETE, cihaz işlemi veya arka plan temizliği değildir.

| Sınır | Değer |
| --- | --- |
| Kalıcı binding | 256 |
| Preview | 60 saniye; global 32, actor başına 4; yalnız süreç belleği |
| Snapshot TTL | 5 saniye monotonic |
| Cache | Global 256, kullanıcı başına 32 |
| Projection payload | Kayıt başına en fazla 2 KiB; toplam en fazla 512 KiB |
| Upstream | 3 saniye, 65 536 byte, en fazla 4 eşzamanlı okuma |

Payload sınırı bütün Python heap kullanımı iddiası değildir; ayrıca kapalı ve
sınırlı kimlik/fingerprint metadata'sı bulunur. Cache anahtarı Core, home,
kullanıcı, oturum token kimliği/aile, resource ve binding'e bağlıdır. Her cache
okuması yeniden yetkilendirilir; bilinen auth/source kaybında cache temizlenir.
Arka planda revocation gözlemcisi yoktur: kayıp istek doğrulamasında saptanır;
geri kalan saklama monotonic TTL/kota ile sınırlıdır. Saat gerilemesi cache ve
preview'ları siler. Restart preview/cache'i geri getirmez. 43 byte Latin-1
bozuk bearer, statik `401` verir ve başka oturumun cache'ini temizleyemez.

## Test ve inceleme kanıtı

Testler yalnız özel geçici SQLite dosyaları ve sahip olunan loopback fixture'ı
kullanır. Gerçek HA, ev, Docker veya Android işlemi yapılmadı. Python 3.12
`/private/tmp/larenor-server-project-env/bin/python` ile isolated `server/`
dizininden çalıştırıldı; import yolu bu çalışma ağacına aittir.

| Checkpoint | Gerçek sonuç |
| --- | --- |
| `9d7f146` → `ae0fc28` | İlk HTTP dikeyi: 2 RED → 2 GREEN |
| `d538bac` → `a881c07` | Anonymous/cache/payload/literal false: 4 FAIL + 3 PASS → 10 PASS |
| `0195b69` → `626caed` | Büyük metadata ve raw Latin-1 bearer RED → 12 ilgili PASS |
| `c73537b` → `ef6e4ff` | Üç NUL suffix RED → 8 ilgili PASS, 6.01 saniye |
| `73facc6` → `ca3afd8` | Orphan kapasite/rollback: 3 RED → 3 PASS, 5.37 saniye |
| `7401fd5` → `51c633a` | Yok sayılan INSERT/HMAC ve silinen sonuç: 3 RED → 9 lifecycle PASS, 10.24 saniye |

İlk geniş ilgili koşu 322 PASS/5 FAIL idi. Beş hata yalnız tarihsel v1/v2
fixture'larının gelecek HA tablolarını bırakmasıydı. İki gerçek fixture-absence
RED'inden sonra `440f2c1` test yardımcıları düzeltildi; startup gevşetilmedi.
İlgili log 33 PASS/15.37 saniyedir; önceki commit metnindeki 15 sayısı yanlıştı.
`ef6e4ff` commit metnindeki 5.64 saniye de logdaki 6.01 saniye ile düzeltilir.
İlk coverage import ve doğrudan fixture scriptinin editable-install/main
gölgelemesi kurulum hatalarıdır, ürün RED kanıtı değildir. Latin-1 için standart
TestClient header normalizasyonu hatayı üretmedi; gerçek 43 byte ASGI header
testi üretip düzeltti. Bu kayıtların eski logları korunur.

Son davranış kaynağı üzerinde tek ilgili koşu **448 PASS**, **0 FAIL**,
**0 SKIP**, **136.83 saniye**: 81 yeni adaptör testi ile mevcut auth, service,
transport, resource/ACL/snapshot, kişi registry, migration ve context
sözleşmeleri. İki mevcut Starlette/httpx deprecation uyarısı vardır.
Yeni `home_assistant` namespace kapsamı **447/468 satır (%95.51)** ve
**107/128 dal sonucu (%83.59)**; birlikte **%92.95**. Dahil edilen mevcut
resource ve service modülleriyle rapor toplamı %93'tür; bu tüm Server
kapsamı değildir. Tam suite yeniden çalıştırılmadı.

Kanıtlar:

- `/private/tmp/larenor-ha-adapter-final-related-green.log`
- `/private/tmp/larenor-ha-adapter-final-coverage.log` ve `-coverage.json`
- `/private/tmp/larenor-ha-adapter-final-namespace-coverage.json`
- `/private/tmp/larenor-ha-adapter-final-evidence.json`
- `/private/tmp/larenor-ha-adapter-orphan-{red,green}.log`
- `/private/tmp/larenor-ha-adapter-write-ack-{red,final-green}.log`

Contract SHA-256:
`aeea76f3ebb149883bcd9adfbaf41275da0fc54ffd377a96b7f7e5022fa0e1da`.
Son koşu gerçek fixture'ı yeniden üretip committed JSON ile birebir karşılaştırdı.
Bağımsız kaynak incelemesi `/root/server_release_completion` tarafından
`51c633a` için CLEAR: üç P2 kapalı, yeni P1/P2 yok. Root'un birleşik tam Server
koşusu ve exact-source CI/Client/Android kabulü bu yerel kanıttan ayrıdır.

## Birincil kaynaklar

- [Home Assistant REST API](https://developers.home-assistant.io/docs/api/rest/)
  seçili entity GET ve bearer sözleşmesi.
- [Home Assistant Core 2026.9.1 API kaynağı](https://raw.githubusercontent.com/home-assistant/core/2026.9.1/homeassistant/components/api/__init__.py)
  sabit sürümde entity state/missing karşılığı.
- [SQLite length](https://www.sqlite.org/lang_corefunc.html#length)
  TEXT NUL ve BLOB byte uzunluğu farkı. Kaynaklar 8 Eylül 2026'da doğrulandı.
