# Yönetilen volume için salt okunur Unix taşıyıcı ve kalıcı gözlem

Bu teslim iki ayrı yerel increment içerir: `UnixVolumeReader` ve `JournaledVolumeObservations`. Hazır olan volume planı, saf inspect doğrulayıcısı ve `VolumeJournal` üzerine kuruludur. Bir volume oluşturmaz, silmez, bootstrap çalıştırmaz ve kurulum yetkisi vermez. `installAvailable=false` sözleşmesi değişmedi.

## Kaynak ve sahiplik

- İzole çalışma ağacı: `/private/tmp/larenor-managed-volume-read-transport`.
- Dal: `codex/managed-volume-read-transport`; başlangıç `f9a3faa485dd619d00107eb3cff8dc303cb9b124`.
- Üretim: `server/larenor_server/plugins/volume_transport.py`, `volume_observation.py` ve `engine_http.py` içinde yalnız yeni exact GET şekli.
- Testler: `server/tests/test_volume_transport.py`, `test_volume_observation.py`.
- Mevcut image/network işleyişi, volume planı/journal şeması, public API, IPC, worker etkinleştirme, kurulum/deploy dosyaları değişmedi. Ana dal ve yürütme kuyruğu bu dalda düzenlenmedi.

## İlk increment: tek doğrulanmış Unix okuması

`EngineHttpRequest` yalnız `GET /v1.47/volumes/larenor-appdata-v1-<32 lowerhex>` biçimini ekler. Listeleme, keyfi isim, query, encoded ayraç, gövde, ek auth başlıkları ve volume mutasyonları kapalıdır. Hedef ve beklenen etiketler Client girdisinden alınmaz; tam plan/stack/catalog/policy, resource, journal kimliği ve nonce üzerinden yeniden türetilir.

`UnixVolumeReader(endpoint, limits=None, peer_uid=None).inspect(binding, cancelled=None)` mevcut `VerifiedEngineHttp` üzerinden aynı Unix stream'de `/version` ve ardından tek inspect yapar. API 1.47, seçili `linux/amd64` veya `linux/arm64`, peer UID, socket/ancestor kimliği, framing ve cancellation kontrolleri ortak taşıyıcıda kalır. Sınırlar 10 saniye toplam, 2 saniye idle, 4.096 chunk ve 65.536 yanıt baytıdır; özel güvenilir limitler yalnız bu varsayılanları daraltabilir. Bu süre private okuyucu içindir; mevcut IPC görev süresini değiştirmez.

Gerçek status ve framing başlıkları saf `validate_volume_inspect` doğrulayıcısına geçer. Yalnız 200 tam eşleşme üretir; 201/404 dahil diğer statuslar varlık/yokluk veya yaratılma kanıtı değildir. Redirect/retry/fallback yoktur. Mountpoint yalnız mevcut saf modelde sınırlı metin olarak doğrulanır ve atılır; açılmaz, ölçülmez ve journal gözlemine yazılmaz. Son binding/nonce kontrolü de `consume` içinde çalışır; mevcut son deadline/cancellation/socket kontrolünden sonra yeni sonuç türetme adımı bulunmaz.

Sabit resmi şema: [Moby v27.5.1 / API 1.47 Swagger](https://raw.githubusercontent.com/moby/moby/v27.5.1/api/swagger.yaml), `GET /volumes/{name}` → 200 Volume / 404 / 500. Name ile seçim Moby şemasıyla uyumludur; bu ürün yalnız kendi üretilmiş ad altkümesini kabul eder. Moby'nin sunduğu create/update/delete yüzeyleri açılmaz.

## İkinci increment: SQLite + okuyucu kompozisyonu

`JournaledVolumeObservations(journal, reader).observe(plan, stack, catalog, policy, resource_id, cancelled=None)` exact `VolumeJournal` ve güvenilir process içi `inspect` bağımlılığı ister. Native `ResourceJournal`, derived journal ve eksik/bozuk bağımlılık reddedilir. Bu bağımlılık bir wire/Client enjeksiyon yüzeyi değildir; keyfi güvenilir Python koduna karşı sandbox iddiası yoktur.

Tek journal lease'i şunları kapsar:

1. Tam kaynak doğrulaması ve idempotent `prepare`.
2. Yeni kayıtta HTTP başlamadan önce kalıcı `observing` revision 2.
3. Journal'dan çözümlenen aynı nonce/kimlikle salt okunur inspect.
4. Mevcut journal'ın typed gözlem, kaynak, revision/CAS ve cancellation kontrolleriyle commit.

`observing` veya `uncertain` kayıttan yalnız yeniden GET yapılabilir. İstek kendi kendine tekrarlanmaz. `labels_observed` ve `needs_attention` tekrar çağrıda tarihsel receipt döndürür; fresh Engine gözlemi sayılmaz. İptal, tarihsel kaydın diskten dönüşü sırasında gerçekleşse de çağrı sonucu yayımlanmaz. Foreign etiketler `needs_attention`; timeout/protocol/ulaşılamama `uncertain` olur. Reentrant revision, değişmiş kaynak veya bozuk SQLite kaydı eski başarıyla ezilmez. Kesinti sonrası aynı journal kimliği/nonce ile yeniden okuma yapılır; yaratma/adopt yetkisi türemez.

## Runtime RED → GREEN kanıtı

| Dilim | RED | GREEN | Gerçek sonuç |
|---|---|---|---|
| Unix okuyucu | `6fc7787` | `e8654eb` | 18 FAIL / 12 PASS → 30 PASS; derlenen fail-closed stub ve gerçek geçici AF_UNIX |
| Kalıcı kompozisyon | `5a748b7` | `4b73478` | 8 FAIL → 8 PASS; gerçek SQLite + Unix |
| Tarihsel dönüşte iptal | `322578f` | `1b28da3` | 1 FAIL / 8 PASS → 9 PASS |
| Son binding doğrulamasında iptal | `9aa767e` | `c0371f4` | 1 FAIL → iki modülde 98 PASS / 1 Linux skip |

İlk yanlış çalışma diziniyle oluşan import/collection hatası runtime RED kabul edilmedi; RED, izole `server/` dizininde çalıştırıldı. `35e49b4` ve `41ed5bf` test kapsamını genişleten checkpoint'lerdir. Üretim son kaynak `c0371f4`; final test kaynağı `41ed5bf`.

Özel kanıt günlükleri:

- `/private/tmp/larenor-volume-transport-red.log`, `larenor-volume-transport-green.log`.
- `/private/tmp/larenor-volume-transport-regression.log`: **568 PASS / 5 Linux skip**, 63,94 saniye; ilk okuyucu ve mevcut Engine/image/network regresyonları. Sonraki private cancellation taşıma farkı bu sayıya dahil değildir; aşağıdaki final testte doğrulanır.
- `/private/tmp/larenor-volume-observation-red.log`, `larenor-volume-observation-green.log`.
- `/private/tmp/larenor-volume-observation-retired-red.log`, `larenor-volume-observation-retired-green.log`.
- `/private/tmp/larenor-volume-final-validation-red.log`, `larenor-volume-final-validation-green.log`: **98 PASS / 1 Linux skip**, 10,44 saniye.
- Final volume/native-journal regresyonu: `/private/tmp/larenor-volume-read-final.log`, **371 PASS / 1 Linux skip**, 26,79 saniye. `/private/tmp/larenor-volume-read-final.coverage`: yeni iki modül toplam **94/94 statement, 28/28 branch (%100)**; okuyucu 59+14, kompozisyon 35+14. Bu kapsam yalnız iki yeni modül içindir; tüm Server kapsamı değildir.

Testler gerçek geçici Unix socket/SQLite kullanır: iki platform, exact target, yanlış peer/version/socket, bounded/chunked/bozuk/partial yanıt, cancellation ve disconnect, journal domain/nonce/spec eşleşmesi, kalıcı intent, held lease, açık SQLite transaction bırakmama, reentry, source alias, corruption, kesinti/reopen ve yalnız manuel GET recovery. Sentetik hata/Mountpoint metni ne receipt'e ne gözlem kaydına çıkar.

Beş değişen/yeni Python kaynak-test dosyasında `python -m py_compile` ve `git diff --check` geçti. Depoda bu Python paketi için ek Ruff/mypy komutu tanımlı değil; bunlar çalıştırılmış gibi sunulmaz. Mevcut iki Starlette/httpx deprecation uyarısı sürdü. Root, ilk kaynak ve `1b28da3`/`c0371f4` son cancellation farklarını bağımsız salt okunur inceleyerek yeni P1/P2 bulgu olmadığını bildirdi.

## Kabul sınırı

Yerel macOS AF_UNIX testlerinde peer seam sentetiktir; production Linux `SO_PEERCRED` testi platform nedeniyle skip olur. Bu dal için yeni Linux CI, gerçek Docker Engine, iki mimaride container çalıştırma veya fiziksel ev kabulü henüz yapılmadı. Önceki CI 100 ya da başka teslimin kanıtı bu modüllere atfedilemez.

`labels_observed` tarihsel etiket eşleşmesidir. Docker yöneticisi etiketleri kopyalayabilir; volume'un değişmez Engine kimliği yoktur. Exclusive sahiplik, eklenmiş container güvenliği, namespace/daemon kökeni, UID/GID erişimi, `noCopy=true` bootstrap veya appdata yazılabilirliği kanıtlanmaz. Native bind/library kontrolleri ve gerçek UID/bootstrap/Engine effect bağlantısı sonraki ayrı dilimlerdir. Yeni actor/admin grant, public route veya install akışı yoktur.
