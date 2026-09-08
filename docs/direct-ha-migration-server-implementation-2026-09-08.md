# S08.7 — Açık Direct HA aktarımı: Server dilimi

8 Eylül 2026. Taban `25d438aed00b44cf10322a500a4dbb001c920dfd`.
Bu belge yalnız Server yazılım dilimini kapsar. Client PIN/kaynak deposu ve
Android kabulü ayrı kanıttır; bütün Direct ayarlarının aktarımı veya S08.7'nin
tamamlandığı iddia edilmez. Gerçek HA/ev bağlantısı veya komutu yapılmadı.

## Çalışan sınır

Güncel admin, tek HA URL/token çiftini ve mevcut, henüz bağlı olmayan bir
`kind=resource` hedefini seçer. Entity yalnız canonical `switch.*` olabilir.
Yeni servis ve binding kimlikleri Server tarafından üretilir. Var olan servis,
binding veya resource üzerine yazılmaz; room, scene, script, diafon, web-origin
izni ve genel düzen aktarımı bu endpoint'in dışında kalır. Direct kayıtlarının
korunması ve PIN/interaction epoch/fingerprint denetimi ayrı Client dilimidir.
Server bir URL'yi veya başarılı durum GET'ini fiziksel HA kimlik kanıtı saymaz.

Bütün yollar `/api/v1/admin/home-assistant/{coreId}/{homeId}/resources/{resourceId}/direct-migration`
altındadır. Üye ve eksik/retired oturum bu yönetim API'sini kullanamaz.

- `POST /preview`: requestId, name, baseUrl, token, entityId ve resource/ACL
  revision'larını alır; seçilmiş entity için tek GET yapar. 60 saniyelik
  one-use preview, önerilen PublicService/Binding ve komutsuz switch projection
  döner. Upstream attributes, ham token ve zaman damgaları yayınlanmaz.
- `DELETE /preview/{id}`: yalnız ilgili güncel admin preview'ını iptal eder;
  servis/binding/receipt veya upstream değişikliği yoktur.
- `POST /confirm`: aynı tam girdi ve previewId gerekir. Güncel admin,
  resource WRITE, revision'lar, unbound hedef ve keyed girdi eşitliği yeniden
  denetlenir. Şifreli servis + şifreli binding + şifreli sonuç makbuzu ve
  ilgili inventory HMAC'leri aynı mevcut registry transaction'ında yazılır.
  Son audit yazısından sonra tam pair/makbuz geri okunur. INSERT/COMMIT hatası
  hepsini geri alır; tüketilmiş preview otomatik yeniden kullanılmaz.
- `GET /results/{requestId}`: yeniden başlama veya yanıt kaybından sonra yalnız
  güncel admin, aynı oluşturan kullanıcı ve aynı Core/ev/resource için sonucu
  okur. Makbuz geçmişteki commit'i anlatır; sonradan değiştirilmiş bağlantıyı
  güncel kabul etmek veya bir HA komutunun gerçekleştiğini kanıtlamak değildir.

Aynı başarıyla commit edilmiş confirm body/previewId için Server aynı receipt'i
idempotent döndürebilir; yeniden servis/binding/ağ etkisi üretmez. Client'ın
kayıp ACK sonrası yolu açık sonuç GET'idir, otomatik confirm tekrarı değildir.
Yeni preview, result GET veya confirm kişisel Vault'a token yazmaz.

## Sayısal ve hata sınırları

Token 1–2 048 ASCII byte (`0x21..0x7e`), trim edilmeden; isim mevcut servis
kurallarıyla 1–80 karakter, canonical URL en çok 2 048 karakter. Entity ve
revision sınırları kabul edilmiş HA/resource modelleriyle aynıdır.

Bellekte en çok 32 preview, kullanıcı başına 4, TTL 60 saniye; geriye giden
monotonic saat pending preview'ları kapatır. Mevcut dört ortak HA ağ slotu,
3 saniyelik toplam transport deadline ve 65 536 byte yanıt sınırı kullanılır.
Redirect, retry, proxy, discovery veya upstream write yolu eklenmez.

Kalıcı receipt kotası 256, her ciphertext en çok 8 192 byte. Bu makbuzlar
kendiliğinden silinmez; kota dolunca yeni aktarım açıkça reddedilir. Mevcut
128 servis/256 binding kotası korunur. Yeni tablolar `direct_ha_migrations`
ve `direct_ha_state`, ayrı `direct_ha_schema=1` marker'ına sahiptir. SQL
byte-length/type preflight, NUL suffix dahil büyük ID/tag/payload'u Python'a
almadan reddeder; HMAC, ciphertext AAD ve decoded ref/ID/scope birlikte
kontrol edilir. Bu, key sahibi kötü niyetli bir hosta karşı rollback-proof
harici otorite iddiası değildir.

Yeni statik hatalar `ha_migration_changed`409,
`ha_migration_preview_invalid`409 ve `ha_migration_limit_reached`429'dur.
Core401 ile upstream HA401→502 ayrıdır. Belirsiz/değişmiş storage503'tür;
ham exception, credential, upstream attribute veya response body yayınlanmaz.

## Gerçek sözleşme ve TDD izi

`contracts/home-assistant-direct-migration.v1.json`, gerçek FastAPI/auth/SQLite
isteklerinden 15 yanıt içerir. Test connector'ı yalnız
`http://fixture.invalid:8123` adresini sahipli ephemeral loopback listener'a
bağlar; gerçek request framing/response parsing çalışır. Yakalanan istek
metadatasından token kasıtlı çıkarılmıştır; yanıt gövdeleri değiştirilmez.
Üç gerçek HA GET, sıfır HA command ve yeni App/aynı SQLite ile result GET
kanıtı vardır. Dosya SHA-256:
`8b3c17a461b98db163a265da15248ce29f2ec7228a1d5cc3a5ed796087a43fdb`.

- `ee96418` ilk HTTP RED: 9 FAIL, preview endpoint404. Bu ilk hata, sonraki
  fault assertion'larının RED aşamasında çalıştığı anlamına gelmez.
- `c303f7c` ilk GREEN: 9 PASS; binding ABORT/IGNORE, receipt INSERT ve deferred
  COMMIT rollback dalları burada fiilen çalıştı.
- `abea6ce` son yazı RED: 3 FAIL/2 PASS; receipt INSERT trigger'ı servis veya
  binding'i bozunca yanlış201. `015f03b` tam son readback GREEN:14 PASS.
- `327a3b2` gerçek sözleşme ve adversarial testler; 45 güvenlik +20 storage/
  contract PASS. `481958a` kapasite, ID collision, başka kullanıcı/resource
  ve eşzamanlı request ID testlerini ekler (4 PASS).
- `2049c7a` iki tarihi fixtureabsence RED; `3dfda71` yalnız v1/v2 fixture
  builder'larından yeni tablolar/marker'ı çıkarır. İlgili33 PASS. Production
  startup veya HMAC kontrolü gevşetilmedi; mevcut kabul edilmiş veriyi koruyan
  additive migration testi ayrıca çalışır.

Kurulum/fixture hataları runtime ürün RED'i sayılmadı: ilk son-write komutunda
cwd yüzünden dosya yazılmadı; ilk başka-admin ek testinde helper'ın `username`
yerine `name` parametresi gerekiyordu. Başarısız loglar ayrı korundu.

`7231f95` ek gerçek RED'de ilk service INSERT IGNORE, yanlış404 verdi.
`c584ff7` yalnız yeni satırın varlığı/revision kontrolünü ekler;15 PASS.
`6267483`→`4f1e4f9` test-only ASGI kayıp ACK fixture'ıdır: Starlette send
OSError'ını disconnect olarak yutabildiği için ilk fixture yanlış exception
bekledi (ürün RED'i değil). Son fixture, actual201 commit'inden sonra hiçbir
response byte teslim etmez; caller hatası ve yeni App/aynı SQLite ile yalnız
GET sonucu1 PASS. Fiziksel Core TCP kesintisi simüle edildiği iddia edilmez.

## Son kanıt ve teslim sınırı

- Birleşik Server regresyonu: `481958a` kaynak/test ağacında **401 PASS,
  0 FAIL, 0 SKIP;191,10s**. Auth, service/probe/transport, mevcut HA binding/
  command/contract, context/migration ve yeni transfer testlerini kapsar.
- Son üretim `c584ff7` sonrasında own focused **86 PASS;65,55s** ve test-only
  son ASGI response-drop **1 PASS;0,93s**. Bunlar87 ayrı own vakadır;401 ile
  toplanıp daha büyük bir kabul sayısı üretilmez.401'in son3satırlık production
  deltası sonrası yeniden çalıştığı iddia edilmez; bütün Core/CI kapısı root'a
  aittir.
- Dört yeni migration modülü: **330/344 satır=%95,93;
  82/96 branch=%85,42; branch-inclusive=%93,64**. İki mevcut Starlette
  deprecation warning dışında test uyarısı yok; Linux/native/Android CI
  bu yerel kanıtın parçası değildir.
- Bağımsız kaynak incelemesi: `server_release_completion`, son davranış
  `015f03b`+`c584ff7` için **CLEAR**, açıkP1/P2 yok. İnceleme test/CI tekrarı
  veya Client PIN/Direct deposu kabulü değildir.
- Son test kaynağı `4f1e4f9`; bu belge dışında production/tests frozen.
  Gerçek sözleşme hash'i değişmedi. Client dalı ayrı çalışmaktadır.

Özel kanıtlar: `/private/tmp/larenor-direct-ha-migration-final-combined.log`,
`/private/tmp/larenor-direct-ha-migration-final-delta.log`,
`/private/tmp/larenor-direct-ha-migration-lost-ack-verified-green.log`,
`/private/tmp/larenor-direct-ha-migration-final-coverage.json`.
Dondurulmuş kaynak/log hash'leri
`/private/tmp/larenor-direct-ha-migration-final-evidence.json` içindedir.
Main, queue, CI, Flutter veya gerçek ev kurulumu bu Server dalında değişmedi.
