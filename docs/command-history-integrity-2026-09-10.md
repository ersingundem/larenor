# F20 — şifreli komut geçmişinin bütünlük zinciri

Bu ilk Core dilimi, [F06 atfedilebilir komut geçmişini](attributed-command-history-2026-09-10.md)
[F20'nin](feature-expansion-plan-2026-09-05.md) eklemeli zinciri ve dışarıda
saklanabilecek checkpoint'i ile genişletir. Başlangıç exact
`45613e66967029554b8794831722b8cf15721959`; dal `codex/core-history-integrity`.
Üretim checkpoint'i `682a241`.

## Ne kanıtlanır?

Mevcut seçili HA switch komutunun ilk kalıcı niyeti ve sonraki sonuç yazısı,
aynı SQLite transaction'ında `command_history_chain` tablosuna eklenir. Snapshot,
mevcut AES-GCM ciphertext ve nonce'un kopyasıdır; aktör, neden, servis veya
komut içeriği yeni plaintext bir tabloya taşınmaz. Her entry; sıra numarası,
`baseline | command_write` türü, request/resource kimliği, ciphertext digest'i,
önceki hash, Core/home ve zincir kimliğini SHA-256 ile bağlar. Ayrı state satırı
zincir kimliği, sıra ve head hash'i Core'un DB dışında tutulan anahtarıyla HMAC
olarak doğrular.

Tam doğrulama sıra boşluklarını, yeniden sıralamayı, değiştirilmiş veya silinmiş
entry'leri ve head/count uyuşmazlığını reddeder. Her snapshot'ın şifresi açılıp
kapalı komut modeli/kapsamı da doğrulanır. Her mevcut komut satırı kendi son
append snapshot'ıyla byte olarak eşleşmek zorundadır. Eski HA inventory HMAC'i
ayrıca korunur. Komut yazısı ve zincir yazısı/okuma doğrulaması birlikte commit
olur; ikinci INSERT başarısızsa komut da geri alınır ve HA dispatch başlamaz.
Bitirme yazısı başarısızsa eski pending niyet kalır; kör tekrar eklenmez.

Zincir sorunu F06 geçmişini, komut okuma/yazılarını ve yeni doğrulama yolunu
`server_unavailable` ile kapatır. Başlangıç aynı mevcut
`home_assistant_storage_invalid` hata ailesini korur; tamir/reset/silme yoktur.
Bu paket tüm Core işlemlerini kapsayan bir audit sistemi değildir.

## Salt okunur yönetici API'si

`GET /api/v1/admin/home-assistant/{coreId}/{homeId}/history/verification`

İsteğe bağlı tek query alanı: `checkpoint` (en fazla 512 karakter). Yinelenen
query/Authorization, başka query alanı ve bu adresteki POST/PUT/PATCH/DELETE
reddedilir. Güncel admin oturumu ve ilk parola kontrolü ile aynı Core/home
transaction sınırı kullanılır. Üye `403`, oturumsuz/revoked hesap `401`, yabancı
kapsam `404` alır. Hiçbir HA HTTP çağrısı veya komut/zincir yazısı yapılmaz;
mevcut standart read rate-limit sayacı güncellenebilir.

Yanıt kapalı `verification` zarfıdır:

```text
schemaVersion: 1
scope: {schemaVersion: 1, coreId, homeId}
chainId: 32 küçük hex karakter
sequence: 0..2048
headHash: 64 küçük hex karakter
checkpoint: opaque, authenticated, en fazla 512 karakter
verified: true
comparedCheckpoint: true | false
causalityVerified: false
```

Checkpoint, kapsam/zincir/sıra/head bilgisinin canonical JSON + base64url +
HMAC temsilidir; token, URL, aktör, entity veya snapshot içermez. Yönetici
çıktıyı Core veritabanından bağımsız güvenilen bir yerde saklayıp sonraki GET'e
verebilir. Server önce tüm yerel zinciri, sonra checkpoint'in hâlâ aynı zincirin
bir prefix'i olduğunu doğrular. Eski geçerli prefix yeni append'lerden sonra da
geçerlidir; geri yüklenmiş eski DB'de eksik olan yeni prefix veya başka zincir
`409 revision_conflict` alır. Bozuk format `400 invalid_request` olur.

**Sınır:** Yerel DB ve içindeki HMAC/head birlikte eski bir geçerli snapshot'a
geri alınırsa, dış checkpoint verilmeden bu rollback tespit edilemez. Test bunu
başarı sanmadan açıkça gösterir: yerel kontrol geçer, dışarıda korunmuş yeni
checkpoint ile kontrol reddedilir. Bu paket bağımsız checkpoint deposu, Android
export UI'si veya Core'dan bağımsız verifier kurmaz. Core anahtarına ve verifier
koduna hükmeden saldırgana karşı mutlak değiştirilemezlik iddiası yoktur.
`causalityVerified=false`: fiziksel olay ve nedensellik kanıtı değildir.

## Migration ve kapasite

Yeni `command_history_schema=1` alt şeması, mevcut Core başlangıç transaction'ında
HA v3 doğrulamasından sonra kurulur. Eski saklanmış komutlar canonical requestId
sırasıyla `baseline` olarak içeri alınır. Tarihsel append zamanı veya eski
pending→sonuç olayları yeniden üretilmez. Eski ciphertext ve public receipt
değişmez. Yeni zincir kimliği ve ilk checkpoint bu baseline'ın başlangıcıdır.

Marker/tables kısmi veya bozuksa başlangıç kapanır. Bağlı yabancı index/trigger
nesneleri de şema kontrolüne dahildir. Migration commit hatası eski DB'yi ve
yeni tabloların yokluğunu korur. Gerçek eski şema fixture'ları yeni zincir
tablolarını/marker'ını da kaldıracak şekilde güncellenmiştir; üretim startup
korumaları gevşetilmemiştir.

Sınırlar: en çok 1.024 mevcut komut ve **2.048 append entry**; her şifreli snapshot
en çok **4.096 byte**. Tam doğrulama sınırlı inventory'yi tarar; bir sorgu için
yalnız bir checkpoint karşılaştırılır. SQL byte/type preflight, NUL sonrasına
eklenmiş dev TEXT'i Python'a taşımadan reddeder. Otomatik pruning/TTL veya
kontrol edilmemiş replay yoktur. Kota dolarsa yeni append/komut transaction'ı
geri alınır. Genel audit retention politikası sonraki kapsamdır.

## TDD ve yerel kanıt

| Aşama | Kanıt |
| --- | --- |
| RED `57e7722` | 3 gerçek runtime FAIL; `/private/tmp/larenor-history-integrity-red.log` |
| GREEN `931953f` | Aynı 3 test PASS / 2,32 s; `/private/tmp/larenor-history-integrity-green.log` |
| Güvenlik | 34 yeni test PASS / 26,39 s; `/private/tmp/larenor-history-integrity-safety-first.log` |
| Uyumluluk RED `f2d8e90` | Eski static startup kodu için 6 runtime FAIL; `/private/tmp/larenor-history-integrity-compat-red.log` |
| GREEN `682a241` | F06+F20 birlikte 67 PASS / 52,35 s; `/private/tmp/larenor-history-integrity-focused-green.log` |

İlk F06 uyumluluk keşfi 24 PASS / 8 FAIL idi. İki hata, fixture'ın v2 veriyi yeni
zincir yanında bırakmasından kaynaklanıyordu; bunlar ürün RED'i sayılmadı.
Diğer altı vaka gerçek error-code uyumluluğunu gösterdi ve üretimde tek statik
kod düzeltmesiyle kapandı.

Testler gerçek Core auth/SQLite/ASGI ve yalnız kendilerine ait loopback HA kullanır.
Yeni testler alter/delete/reorder, dış checkpoint ile tam geçerli DB rollback'i,
farklı zincir, eski prefix, admin/current session, malformed checkpoint,
NUL metadata/allocation sınırı, kota, ikinci INSERT reddi ve migration commit
rollback'ini kapsar. Yeni kontrolün kendisi HA yan etkisi üretmez.

Son ilgili gate **372 PASS, 0 skip / 222,69 s** ile tamamlandı:
`/private/tmp/larenor-history-integrity-related.log`. Bu tek genişletilmiş koşu,
F06/F20, HA adapter/commands, resource ACL, Core context ve admin migration
testlerini kapsar. Süreç exit 0 ile kapandı. İki mevcut FastAPI/Starlette
deprecation uyarısı test hatası değildir.

Branch coverage (`/private/tmp/larenor-history-integrity-coverage.json`): yeni
`command_chain.py` **%96**, yeni `integrity_api.py` **%100**; değişen `service.py`
dahil üç modül toplamı **%92** (546 statement, 29 eksik; 174 branch, 28 eksik).
Yeni iki modülün birleşimi **%96,84** (148 statement, 3 eksik; 42 branch, 3 eksik).

Çalıştırılan son komut (worktree kökünde):

```sh
COVERAGE_FILE=/private/tmp/larenor-history-integrity-related.coverage \
PYTHONPATH=server:.:/private/tmp/larenor-f06-coverage \
/tmp/larenor-server-test-venv-1789025227538/bin/python -m coverage run \
  --branch --source=larenor_server.home_assistant -m pytest \
  server/tests/test_command_history*.py server/tests/test_home_assistant*.py \
  server/tests/test_home_resource*.py server/tests/test_core_context*.py \
  server/tests/test_admin_migration.py -ra
```

Global Server/Flutter, CI, gerçek HA/ev, medya kurulumu, push veya PR çalıştırılmaz.
F20'nin tamamı, harici kontrol noktası saklama/bağımsız doğrulama ve fiziksel kabul
bu ilk yerel Server diliminden ayrı tutulur.
