# F30 Unmanic 0.4.1 HTTP ve terminal callback sözleşmesi

Bu kayıt yalnız Unmanic `0.4.1`, commit
[`1c324b8fc3974ffce3d7cc945adb938fe7182910`](https://github.com/Unmanic/unmanic/tree/1c324b8fc3974ffce3d7cc945adb938fe7182910)
için geçerlidir. Larenor worker başka sürümde bu şemaları sessizce
genişletmez; bilinmeyen alan, tür veya durum sağlayıcı sözleşme değişikliği
olarak kapanır.

## Sabit HTTP yüzeyi

Temel yol `/unmanic/api/v2`'dir. Başarılı veri cevaplarına Unmanic otomatik
`success` alanı eklemez; yalnız gövdesiz başarılar `{"success":true}` döndürür.
Hata gövdesi `error`, `messages` ve debug açıksa `traceback` taşıyabilir.
Dayanak: [handler ve success/error yazımı](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/webserver/api_v2/base_api_handler.py#L83-L179).

| İşlem | İstek | Başarılı cevap |
| --- | --- | --- |
| Dosyayı test et | `POST /pending/test`, `{"path":"/absolute/or/library-relative","library_id":7}` | `path`, `library_id`, `library_name`, üç değerli `add_file_to_pending_tasks`, `issues`, nullable `decision_plugin:{plugin_id,plugin_name}`. Bu yalnız library-management eklentilerinin kuyruk kararıdır. |
| Yerel görev oluştur | `POST /pending/create`, `{"path":"/absolute","library_id":7,"type":"local","priority_score":0}` | `id`, `abspath`, `priority`, `type`, `status`, opsiyonel `checksum`, `library_id`, `library_name`. Yol Unmanic dosya sisteminde gerçekten bulunmalı ve aynı yol için görev olmamalıdır. |
| Pending durumunu oku | `POST /pending/status/get`, `{"id_list":[31]}` | `{"results":[pending task...]}`. Yalnız hâlâ Tasks tablosunda bulunan satırlar döner. Bütün ID'ler kayıpsa endpoint `200 []` yerine `500` üretir. |
| Pending satırı sil | JSON gövdeli `DELETE /pending/tasks`, `{"selection_mode":"explicit","id_list":[31]}` | `{"success":true}`. Bulunmayan ID de başarılı görünebilir; bu terminal görev makbuzu değildir. |
| Worker durumu | gövdesiz `GET /workers/status` | `workers_status[]`: `id`, `name`, `idle`, `paused`, `start_time`, `current_file`, `current_task`, `current_command`, `worker_log_tail`, `runners_info`, `subprocess`. |
| Worker sonlandır | JSON gövdeli `DELETE /workers/worker/terminate`, `{"worker_id":"Default-0"}` | `{"success":true}`. Bu, worker redundant bayrağının ayarlandığını bildirir; task-ID ile atomik iptal değildir. |

Resmî uygulama ve şemalar:

- [pending route/uygulama](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/webserver/api_v2/pending_api.py#L53-L115), [create/test/status](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/webserver/api_v2/pending_api.py#L507-L764)
- [pending request/response şemaları](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/webserver/api_v2/schema/schemas.py#L656-L901)
- [status lookup yalnız mevcut satırları döndürür](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/webserver/helpers/pending_tasks.py#L288-L311)
- [worker route/terminate/status](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/webserver/api_v2/workers_api.py#L45-L81), [worker cevap şeması](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/webserver/api_v2/schema/schemas.py#L1811-L1914)
- [terminate yalnız redundant bayrağı ayarlar](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/libs/foreman.py#L559-L585)
- [resmî API kullanım sınırı](https://docs.unmanic.app/docs/using_unmanic/apis/)

## Terminal event eklentisi

Eklenti ZIP kökünde `info.json` ve `plugin.py` bulunur. `info.json` kimliği
yalnız küçük harf ve alt çizgiden oluşur, `compatibility:[2]` ile 0.4.1 plugin
handler'ına sabitlenir. Ana modül tam olarak şu runner'ı tanımlar:

```python
def emit_postprocessor_complete(data):
    ...
```

Resmî event şeması `library_id`, `task_id`, `task_type`, `source_data`,
`destination_data`, `destination_files`, `task_success`,
`file_move_processes_success`, `start_time`, `finish_time`,
`processed_by_worker` ve `log` alanlarını tanımlar. Alanlar runner şemasında
opsiyonel olduğundan Larenor eklentisi hepsini kendi içinde doğrular; eksik veri
başarıya çevrilmez. [Runner tanımı ve test verisi](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/libs/unplugins/plugin_types/events/postprocessor_complete.py#L36-L114).

Callback yerel görevde history satırı yazıldıktan sonra, metadata commit ve
pending satırı silinmeden önce çağrılır. Uzak görev yolu bu event'i çağırmaz.
[Çağrı sırası](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/libs/postprocessor.py#L203-L243),
[tam payload](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/libs/postprocessor.py#L573-L602).
Runner dönüş değeri kullanılmaz; istisna yalnız loglanır ve postprocessor devam
eder. Yerleşik callback retry/outbox yoktur.
[Executor davranışı](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/libs/unplugins/executor.py#L262-L364).
Plugin paket alanları için [resmî plugin geliştirme belgesi](https://docs.unmanic.app/docs/development/writing_plugins/introduction/)
kullanılır.

Larenor callback gövdesi canonical JSON'dur ve yalnız şu alanları taşır:

```json
{"destinationFiles":["/work/op/output.mkv"],"destinationPath":"/work/op/output.mkv","fileMoveProcessesSuccess":true,"finishTime":1790769660.5,"libraryId":7,"processedByWorker":"Default-Worker-1","schemaVersion":1,"sourcePath":"/work/op/source.mkv","startTime":1790769600.5,"taskId":31,"taskSuccess":true,"taskType":"local"}
```

`log` callback'e konmaz. Terminal `succeeded` yalnız `taskSuccess == true` ve
`fileMoveProcessesSuccess == true` birlikteyse üretilir; diğer doğrulanmış
terminal callback `failed` olur. Bu callback henüz Larenor install/codec/hash
başarısı değildir; file-store doğrulaması ve journal geçişi ayrıca gerekir.

Gönderici her denemede 64 küçük-hex nonce üretir ve gövdeyi şu header'larla
imzalar:

- `X-Larenor-Unmanic-Timestamp`: Unix saniyesi
- `X-Larenor-Unmanic-Nonce`: 32 rastgele byte'ın küçük-hex gösterimi
- `X-Larenor-Unmanic-Signature`: `HMAC-SHA256(derived_key, "v1\n" + timestamp + "\n" + nonce + "\n" + canonical_body)`
- `derived_key = HMAC-SHA256(shared_key, "larenor-unmanic-callback-v1")`

Alıcı en fazla 300 saniye saat farkı kabul eder, nonce'u private SQLite içinde
kalıcı saklar, aynı `(taskId, sourcePath)` için değişmiş gövdeyi reddeder ve
yalnız exact task/work-path lookup sunar. Aynı canonical gövde idempotent olarak
tekrar kabul edilir. Eklenti tarafında imzalamadan önce durable outbox'a atomik
yazım, sabit Larenor callback adresine deadline'lı gönderim, redirect/proxy
kullanmama, kabul makbuzundan sonra outbox silme ve restart retry hâlâ paketli
plugin runtime'ının zorunlu teslim parçasıdır.

## Adapter kararları

- Path yalnız trusted file-store resolver'dan gelir; Client/Jellyfin yolu
  doğrudan Unmanic'e taşınmaz. Resolver yalnız normalize work path ve library ID
  verir; source hash/byte gözlemi file-store tarafından gerçekten hesaplanır.
- Görev her zaman `type:"local"` oluşturulur. `remote` görev terminal callback
  sözleşmesine dahil değildir.
- Pending satırının kaybolması başarı, başarısızlık veya iptal sayılmaz. Terminal
  yalnız authenticated callback ve sonrasında file-store doğrulamasıyla kapanır.
- Queued/pending silme yalnız kuyruk satırı kaldırma isteğidir. `in_progress`
  worker terminate, status okuması ile mutation arasında yarıştığından exact
  iptal sunmaz; sonuç `uncertain/needs_attention` kalır ve callback + dosya
  readback ile uzlaştırılır.
- Unmanic yerleşik kimlik doğrulama sağlamadığından bağlantı private ağ veya
  kimlik doğrulayan reverse proxy arkasında kalır; adapter genel proxy, redirect
  veya caller-selected endpoint sunmaz. [Resmî nginx basic auth rehberi](https://docs.unmanic.app/docs/guides/basic_auth_nginx/).

## TDD kanıtı

Kullanıcı yolculuğu: izole F30 worker, sabit Unmanic 0.4.1 sözleşmesine göre
dosyayı test eder, yerel görevi oluşturur ve public polling'in kanıtlayamadığı
terminal sonucu authenticated callback store'dan exact task/work-path ile okur.

- RED: `uv run pytest tests/test_media_archive_unmanic.py` modül yokken import
  hatasıyla durdu.
- GREEN: `uv run pytest tests/test_media_archive_unmanic.py tests/test_media_archive_unmanic_terminal_store.py`
  sonucu `20 passed`.
- Kapsam: exact HTTP body/response, partial missing status, DELETE gövdeleri,
  worker-task eşliği, deadline/hata daraltması, callback başarı kuralı, HMAC,
  skew, canonical body, durable reopen, nonce replay, idempotency ve exact lookup.
- Repo bağımlılıklarında coverage aracı tanımlı olmadığı için ayrı satır kapsam
  yüzdesi üretilmedi.

## Korunan orijinal ve gerçek dosya kanıtı

`MediaArchiveFileStore`, onaylı library kökünden symlink izlemeden açtığı
dosyanın tamamını hashler; orijinali ve Unmanic çalışma dosyasını farklı
inode'lara kopyalar. Kaynak, iptal veya dönüştürme hatasında korunur. Daha küçük
çıktının hash/byte doğrulaması, korunan orijinal ve değişmemiş kaynak yeniden
okunmadan install yapılamaz. Atomik değişimden önce journal intent callback'i
kalıcı olmalıdır. Cleanup da kurulmuş çıktıyı tekrar okuyup doğrular.

- `test_media_archive_file_store.py`: `7 passed`; ayrı kopyalar, kota,
  symlink/kaynak değişimi, iptal, kaybolan install intent makbuzu ve cleanup.
- Journal, file-store, Unmanic HTTP ve terminal store birlikte: `39 passed`.
- Bunlar gerçek geçici dosyalarla yerel kanıttır. Tam worker runtime, paketli
  callback outbox, gerçek codec/decode doğrulaması ve deploy kabulü henüz
  tamamlanmadığı için F30 kapatılmamıştır.
