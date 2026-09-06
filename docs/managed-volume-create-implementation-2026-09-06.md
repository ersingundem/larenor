# S06.3d — özel managed-volume create protokolü

Taban `e7c15ad6f62352f77379e369f3e8524028c42aab`; çalışma dalı
`codex/managed-volume-create`. Bu paket ayrı bir kalıcı CREATE niyetini,
kapalı Unix Engine taşımasını ve o kaydı gerçekten tüketen akışı uygular.
API/IPC/CLI/runtime/installer bağlantısı yoktur. `installAvailable=false`
değişmez; S06.3d'nin UID/bootstrap veya gerçek kurulum kabulü değildir.

## Kaynak ve kapalı işlem

- `volume_create_journal.py`: mevcut `ResourceJournal` yalnız özel FD, flock,
  SQLite, fsync ve bütünlük kabuğunu sağlar. Yeni
  `larenor-volume-create-journal-v1` domain'i boş eski native veya volume
  observation journal'ını bile reddeder. Eski kayıtlar taşınmaz/yükseltilmez.
- `volume_effects.py`: `UnixVolumeCreator.probe/create` ve kapalı create body.
  Yalnız `/v1.47/volumes/create`, planın ürettiği ad, `Driver=local`,
  `DriverOpts={}` ve yeniden türetilen tam etiketler gönderilir. Aynı doğrulanmış
  Unix bağlantısında `/version` sonrası, POST öncesinde literal `True` gate
  gerekir. Body/kaynak, iptal, endpoint ve deadline tekrar denetlenir.
- `volume_preparation.py`: `JournaledVolumeCreates(journal, engine).apply(
  plan, stack, catalog, policy, resource_id, *, authorize_create=None,
  cancelled=None)`. Bütün çağrı aynı journal lease'i içinde kalır; callback
  sonrası güncel kalıcı revision, tam kaynak, bağımsız receipt kopyası ve
  nonce/etiket bağı tekrar eşleşir.
- `engine_http.py` yalnız bu yeni canonical POST biçimi için dar allowlist ve
  mevcut dispatch gate sınıflamasını genişletir. Image/network biçimleri,
  image pull'a özel EOF istisnası ve eski volume GET sözleşmesi korunur.

Yeni akış: `prepared → mutating` kalıcı begin → taze GET → yalnız bu yeni
çağrıda kanıtlanan eksiklik için tek POST → ayrı taze GET →
`observed_requires_bootstrap`. Bir önceki gözlem, ACK veya kayıt adı yeni
create izni sayılmaz. Foreign volume `needs_attention`; eksik/bozuk yanıt veya
belirsiz etki `uncertain` olur. `mutating/uncertain` yeniden açıldığında yalnız
GET/reconcile yapılır; volume hâlâ eksik olsa da POST tekrarlanmaz. Delete,
prune, otomatik sahiplenme, rollback, bootstrap veya container mount yoktur.

`observed_requires_bootstrap` ve `needs_attention` terminal kayıtları sonraki
çağrıda tarihsel sonuç olarak dönebilir. Bu, güncel availability, münhasır
sahiplik, writable UID veya runtime execution permit değildir.

## Yanıt, sınır ve yetki anlamı

Eski `UnixVolumeReader` bütün non-200 yanıtlarını unavailable tutar. Yeni
creator'da 404 yalnız tam/framed, bounded JSON hata gövdesi ve sabit üretilmiş
GET yolu için ayrı `VolumeAbsent` üretir. HTTP hata metni saklanmaz. 201
Volume JSON'u aynı katı özellik denetiminden geçer fakat yalnız
`VolumeCreateAcknowledgement` döner; journal'a doğrudan gözlem yazamaz.

Moby aynı isimdeki mevcut volume'u geri döndürürken create router yine 201
verebilir; bu nedenle ACK yeni kaynak kanıtı değildir.
[Moby 27.5.1 store](https://github.com/moby/moby/blob/v27.5.1/volume/service/store.go#L563-L579),
[create router](https://github.com/moby/moby/blob/v27.5.1/api/server/router/volume/volume_routes.go#L82-L119).
`NoCopy` container mount davranışıdır; CREATE body'ye eklenmez ve UID iznini
kanıtlamaz. [Docker volume davranışı](https://docs.docker.com/engine/storage/volumes/#mounting-a-volume-over-existing-data).

Her HTTP exchange en çok 10 s toplam/2 s idle, 65.536 response byte ve 4.096 chunk;
caller yalnız daraltabilir. CREATE body en çok 4.096 byte. Yeni başarı yolu
en çok üç exchange ve altı HTTP isteğidir (`/version` her exchange'e dahildir).
Bu bütün işlem için hard deadline değildir: trusted callback veya takılmış
filesystem/SQLite çağrısı burada preempt edilmez. Journal en çok 1.792 kayıt,
snapshot başına 98.304 byte ve devralınan 512 MiB DB sınırındadır.

Authorizer yalnız özel in-process protokol sınırıdır. Gerçek actor/session,
daemon incarnation/namespace, disk bütçesi veya supervisor yetkisi üretmez.
Docker yöneticisi etiketleri kopyalayabilir; isim/etiket kernel kilidi veya
değiştirilemez volume kimliği değildir. `Mountpoint` denetlenip atılır; hostta
açılmaz, journal/public receipt'e konmaz. Hiçbir gerçek Engine/ev çağrısı
yapılmadı; testler geçici SQLite ve sahip olunan sentetik Unix sunucularıdır.

## RED → GREEN zinciri

| Sözleşme | RED | Minimal GREEN | Kanıt |
| --- | --- | --- | --- |
| Ayrı CREATE journal | `e2502e4`, 27 runtime FAIL | `190f9d6`, 27 PASS | Yedi hedef, durable begin/restart, eski domain ret ve source/revision bağları |
| Journal genişleme | — | `d9e102f`, 46 PASS | Gerçek subprocess lock, dosya kimliği, corruption preserve ve kota; 136 statement + 8 branch %100 |
| Kapalı volume taşıması | `69ff89f`, 16 FAIL | `f8ebbcf`, 16 PASS | Aynı stream version + POST, literal gate, strict 404/framing ve iptal |
| Kalıcı kaydı tüketen akış | `1332c81`, 19 FAIL | `48ebcb4`, 19 PASS | SQLite + Unix iki platform × iki framing, tek POST ve fresh GET, lost ACK sonrası 0 replay |
| Çelişkili ACK/statik limit | `3ea278c`, 2 FAIL | `8f945df`, 39 PASS/1 Linux skip | Reddedilen gate'e rağmen ACK bildiren hatalı adapter receipt üretemez; stream-limit kodu korunur |
| Büyük integer limit | `a229617`, 2 FAIL | `6c38974`, 54 PASS/1 Linux skip | Float dönüşümünden önce aralık kontrolü; NaN/inf/bool ve büyük integer statik ret |

İlk RED'ler eksik yeni protokolü test gövdesinde doğruladı; derleme veya
dependency/fixture hatası RED sayılmadı. Yeni adversarial dosyasında ayrıca
crash görüntüleri, late cancel/source drift, reentrant revision, yanlış
socket/peer/platform, sınırlı deadline, kapalı body ve bozuk adapter sonuçları
sınanır. Gerçek `SO_PEERCRED` testi yalnız Linux'ta çalışır; Mac skip'i Docker
veya Linux kabulü diye gösterilmez.

## Son yerel doğrulama

Davranış kaynağı `6c38974`; ardından yalnız import/docstring ve bu kanıt
belgesi temizliği vardır. Aynı worktree'nin `server` dizininden, gerçek
Python 3.12 ortamı ve `PYTHONPATH=.` ile son geniş koşum **887 PASS / 7
Linux-only skip, 114,24 s** verdi. Dört yeni dosyanın bu koşumdaki payı
**135 PASS / 1 Linux-only skip**; önceki 120 PASS altkümesiyle toplanmaz.

Koşan dosyalar: `test_volume_create_journal`, `test_volume_effects`,
`test_volume_preparation`, `test_volume_create_adversarial`, eski
`test_volume_transport`, `test_volume_observation`, `test_volume_journal`,
`test_engine_http`, `test_image_resources`, `test_image_preparation`,
`test_network_effects`, `test_network_transport`, `test_network_preparation`.
Bu uyumluluk kümesi tam Server suite veya gerçek Linux CI sonucu değildir.

| Modül | Statement | Kaçan | Branch | Kısmi branch | Branch dahil coverage |
| --- | ---: | ---: | ---: | ---: | ---: |
| Yeni volume create journal | 136 | 0 | 8 | 0 | %100 |
| Yeni volume effects | 93 | 1 | 4 | 0 | %99 |
| Yeni volume preparation | 136 | 10 | 50 | 7 | %91 |
| Ortak engine HTTP | 287 | 7 | 66 | 4 | %97 |
| Toplam | 652 | 18 | 128 | 11 | %96 |

Yerel kanıtlar: `/private/tmp/larenor-volume-create-related-final.log`,
`/private/tmp/larenor-volume-create-final.coverage`,
`/private/tmp/larenor-volume-create-coverage.json` ve
`/private/tmp/larenor-volume-create-coverage.txt`.
Son kaynakların AST/syntax denetimi ve `git diff --check` temizdir;
repository'de bu Python paketi için tanımlı formatter/analyzer kapısı yoktur.
Paylaşılan `engine_http.py` dışında eski üretim modüllerinin byte içeriği
tabanla aynıdır; runtime/HTTP/IPC/CLI/installer'a yeni import eklenmedi.

## Açık kabul kapıları

Mevcut native root/lease gözlem yolu, eski volume observation, image/network
journal ve hazırlık davranışları değiştirilmedi. Gerçek iki mimarili Engine
üzerinde UID/başlangıç verisi/NoCopy/kalıcılık, güvenilir bootstrap, storage
bütçesi, worker container mount binding'i ve her effect için gerçek güncel
yetki/dispatcher hâlâ ayrı kabul kapılarıdır. Kullanıcı kütüphanesi taşınmaz;
native-root güvenlik önkoşulları gevşetilmez. Bunlar tamamlanmadan kurulum
düğmesi veya S06.3d/S06.3f tamamlanma iddiası yoktur.
