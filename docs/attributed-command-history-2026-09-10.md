# F06 — seçili HA komutları için atfedilebilir işlem geçmişi

Bu ilk Server dilimi, [63 özellik planındaki F06](feature-expansion-plan-2026-09-05.md)
için mevcut seçili HA switch komutunu kullanır. Kullanıcının kimliği, kaynak,
isteğin nedeni, servis sürümü ve mevcut komut sonucu aynı `requestId` üzerinden
birleştirilir. Android açıklama ekranı, kurallar arası iz zinciri ve fiziksel
nedensellik kabulü bu teslimde yoktur; bütün F06 tamamlandı sayılmaz.

Başlangıç: `aee92b49d1855670674efac156a18603c7f38aae` (`origin/main`).
Dal: `codex/core-attributed-history`. Üretim: `880f11c`.

## Üretim davranışı ve sözleşme

- Mevcut `POST /api/v1/home-assistant/{coreId}/{homeId}/resources/{resourceId}/commands`
  ve tek komut sonucu yanıtları değişmez. Şifreli `StoredCommand` içine attribution
  eklenir; işlem niyetiyle aynı SQLite transaction'ında, ilk HA çağrısından önce
  kalıcılaştırılır. Sonuç, restart uzlaştırması ve idempotent tekrar bu metadata'yı korur.
- Yeni `GET /api/v1/home-assistant/{coreId}/{homeId}/resources/{resourceId}/history`
  salt okunur bir sözleşmedir. `limit` varsayılan 25, azami 50; isteğe bağlı
  `before` tam 32 küçük hex karakterli, görünür bir `requestId` olmalıdır. Bilinmeyen
  ve yinelenen query alanları reddedilir. Sıralama `createdAt` azalan, eşit zamanda
  `requestId` azalandır; zaman sırası nedensellik olarak sunulmaz. Sayfalama yeni
  kayıtları önceki cursor'un arkasına taşımaz; bütün sayfalar için sabit snapshot
  garantisi yoktur.
- Yanıt `schemaVersion`, `ref`, `entries[{attribution,receipt}]`, `nextBefore`
  içerir. [Sürümlü JSON fixture](../contracts/home-assistant-history.v1.json),
  gerçek Core auth/SQLite/ASGI yollarından ve yalnız fixture'a ait loopback HA'dan
  yakalanmış 8 GET yanıtıyla doğrulanır. Bu, native Android kabulü değildir.
- Attribution kaynağı kapalı `core_api | unknown`, nedeni kapalı
  `explicit_command_request | unknown` kümesidir. Yeni komutun `correlationId`'si
  mevcut idempotency `requestId`'sidir; `serviceId/serviceRevision` ilk dispatch
  öncesinde doğrulanan binding'den alınır. `actorId`, doğrulanmış Core hesabından
  gelen mevcut receipt içindedir. Caller source/reason/actor veya serbest neden
  metni gönderemez. `explicit_command_request`, doğrulanmış hesabın bu komut
  API'sini çağırdığını söyler; kullanıcının iç motivasyonunu veya fiziksel olayı
  kanıtlamaz. `causalityVerified=false` aynen kalır.

## Migration, yetki ve sınırlar

HA alt şeması v2 → v3 migration'ı, mevcut Core başlangıç transaction'ında önce
tam sınırlı inventory/HMAC'i doğrular. Eski AES-GCM satırlarını kapalı v2 modeliyle
açar, kimlik/kaynak kapsamını doğrular, attribution ekler, yeni ciphertext'i
yeniden okuyup karşılaştırır ve inventory HMAC'i ile marker'ı aynı commit'te yazar.
V1 binding migration'ı da v3'e ulaşır. Eski receipt ve actor/request ilişkisi
korunur; eski source/reason `unknown`, servis alanları `null` kalır. Güncel binding
veya yakın zamanlı olaylardan eski servis/neden uydurulmaz. Hatalı HMAC/ciphertext,
yabancı ev ve commit kaybında migration geri alınır; reset/otomatik tamir yoktur.
V3'te eksik/bozuk attribution kabul edilmez. V2 yazılımına sessiz downgrade yoktur.

Her GET aynı transaction içinde güncel oturum, kullanıcı durumu, Core/home ve
kaynak READ ACL'sini doğrular. Yönetici kaynağın tüm kayıtlarını; üye yalnız kendi
actor kayıtlarını görür. READ izni olmayan veya silinmiş kaynak, başka ev ve gizli
cursor `404`; kimliksiz/revoked oturum `401`, ilk parola `403` döner. Üyeye servis
yönetim API'si açılmaz. HA token/URL/entity/attributes geçmiş yanıtına girmez.

Geçmiş GET hiçbir HA çağrısı ve hiçbir command/binding/audit mutation yapmaz;
mevcut standart read-rate-limit sayacı güncellenebilir. `pending`, yalnız saklanmış
niyet durumudur; canlı worker veya tamamlanmış fiziksel etki iddiası değildir.
History GET, restart sonrasında pending kaydı settle etmez ve POST'u tekrar etmez.
Mevcut tek-command result GET uzlaştırması kullanılabilir.

Mevcut sınırlar korunur: en çok 1.024 saklanmış komut, şifreli satır en çok 4.096
byte. Sorgu bu sınırlı inventory'yi doğrular, en çok 50 kayıt döndürür. Yeni TTL,
otomatik silme veya kota dolunca yeniden dispatch açabilecek pruning eklenmez.
Silinmiş kaynak geçmişi current ACL sınırı nedeniyle gizlidir. Ayrı dış kontrol
noktalı değişiklik tespiti/F20, genel ev geçmişi ve fiziksel kabul açık kalır.

## TDD ve kanıt

| Aşama | Checkpoint / sonuç | Kanıt |
| --- | --- | --- |
| İlk RED | `c725beb`, 3 gerçek runtime FAIL: eksik endpoint ve v2→v3 migration | `/private/tmp/larenor-command-history-red.log` |
| İlk GREEN | `08c61a6`, aynı 3 vaka PASS | `/private/tmp/larenor-command-history-green.log` |
| Güvenlik RED | `5759602`, strict version hedefinde 1 PASS / 1 FAIL | `/private/tmp/larenor-command-history-version-red.log` |
| Son üretim GREEN | `880f11c`, 32 focused PASS / 24,64 s | `/private/tmp/larenor-command-history-focused-green.log` |

İlk güvenlik keşfi 27 PASS / 2 FAIL idi: biri gerçek boolean schemaVersion açığı,
diğeri fixture'ın Core'un statik `StartupError` dönüşümü yerine ham SQLite hata
türü beklemesiydi. İkincisi üretim RED'i sayılmadı. İlk RED komutunun pytest logu
tamamlandıktan sonra shell'in readonly `status` değişkenine atama wrapper hatası
verdi; kaydedilmiş 3 pytest failure gerçek çalışma sonuçlarıdır.

Testler, yeni metadata'nın dispatch öncesi kalıcılığını, member/admin ayrımını,
revoked/ilk parola/foreign scope/duplicate query sınırlarını, aynı zamanlı
sayfalamayı, pending restart'ta salt okumayı, INSERT IGNORE/ABORT/deferred COMMIT
ile sıfır dispatch ve atomik geri almayı, ikinci bozuk legacy kaydı ve malformed
metadata'da statik hata davranışını kapsar. Yalnız mevcut iki legacy testin v3
hedefi ve unsupported v4 beklentisi güncellendi; startup koruması gevşetilmedi.

Python import kaynağı bu izole worktree olarak doğrulandı:
`/tmp/larenor-server-test-venv-1789025227538/bin/python`, `PYTHONPATH=server:.`.
Coverage 7.10.7 yalnız `/private/tmp/larenor-f06-coverage` içine kuruldu;
paylaşılan Server ortamı değiştirilmedi.

Tek ilgili son Server kapısı **338 PASS, 0 skip, 175,21 saniye** tamamlandı:

```sh
COVERAGE_FILE=/private/tmp/larenor-command-history-related.coverage \
PYTHONPATH=server:.:/private/tmp/larenor-f06-coverage \
/tmp/larenor-server-test-venv-1789025227538/bin/python -m coverage run \
  --branch --source=larenor_server.home_assistant -m pytest \
  server/tests/test_command_history*.py server/tests/test_home_assistant*.py \
  server/tests/test_home_resource*.py server/tests/test_core_context*.py \
  server/tests/test_admin_migration.py -ra
```

Bu kapı yeni 33 testi, mevcut public command/receipt ve HA fixture paritesini,
resource ACL/storage/contract, context ve eski migration davranışını kapsar.
Log: `/private/tmp/larenor-command-history-related.log`. İki mevcut
Starlette/httpx deprecation uyarısı vardır; hata/skip yoktur.

Beş değişen HA modülünün (models/schema/service/command_storage/history_api)
branch dâhil kapsamı **%92**: 678 executable statement, 37 miss; 210 branch,
35 partial. Yeni `command_storage.py` ve `history_api.py` ayrı ayrı **%100**.
Tamamı eski API/routerları içeren global uygulama kapsamı olarak sunulmaz.
Raporlar: `/private/tmp/larenor-command-history-coverage.{log,json}`.

`git diff --check` temiz. Global Server/Flutter, CI, deployment, gerçek HA/ev veya
medya kurulum işlemi çalıştırılmadı. Değişiklikler yalnız yerel commitlerdir;
push/PR yapılmadı. Bağımsız kaynak incelemesi ve exact-commit CI bu yerel test
kanıtından ayrıdır.
