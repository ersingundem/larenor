# S06.3e — salt okunur network transport uygulama kararı

**Durum:** Tasarım; bu belge yeni transport uygulanmış veya Docker üzerinde doğrulanmış demek değildir. Kaynak incelemesi ortak HTTP extraction GREEN `f2431c7` ve test düzeltmesi `0582837` üzerindedir. Tam Server regresyonu tamamlanmadan kaynak/test değişmez. Bu alt adım yalnız list/inspect taşır; network create, journal effect köprüsü, daemon-context grant, API/IPC/CLI ve container attach yoktur.

## Dar dosya ve API sınırı

Yeni `server/larenor_server/plugins/network_transport.py` ve `server/tests/test_network_transport.py`; `engine_http.py` ile `test_engine_http.py` içinde yalnız iki GET şeklinin allowlist genişlemesi. Mevcut pure `network_resources.py`, journal ve image adapter sözleşmeleri korunur.

```python
NetworkReadLimits(total_seconds=10.0, idle_seconds=2.0, max_chunks=4096)
UnixNetworkEngine(endpoint: DockerEndpoint, *, limits=None, peer_uid=None)
engine.list(binding: NetworkBinding, intent: ResourceIntent, *, cancelled=None)
    -> NetworkListObservation
engine.inspect(binding: NetworkBinding, intent: ResourceIntent,
               network_id: str, *, cancelled=None) -> NetworkIdentity
```

Limitler özel operatör/test girdisidir; finite, strict ve pozitif değerlerle yalnız bu üst sınırlar azaltılabilir. List body sınırı sabit 131072, inspect body sınırı sabit 65536 bayttır. Mevcut HTTP header/version sınırları ve 0,25s read-cancel poll korunur. Bir çağrının tek transport deadline'ı version ve iş isteğini birlikte kapsar; list ile inspect iki açık çağrıdır, ortak dispatcher/job bütçesi veya otomatik yeniden deneme değildir. Bu özel istemci mevcut 5s read-only IPC operasyonlarına bağlanmaz.

Her çağrı önce `network_resources._inputs(binding, intent)` ile binding'e bağlanmış plan/katalog/policy kopyasını, resource, journal ID, nonce, specification digest ve receipt şeklini yeniden doğrular. Başka bir global katalog/policy nesnesinin sonradan değiştirilmesi bu bağlı kopyayı yenilemez; gerçekten güncel katalog, actor ve journal revision yetkisi çağıranın ayrı sorumluluğudur. Inspect 64 küçük harfli hex ID'yi I/O öncesinde reddeder veya kabul eder. Worker tarafından türetilen platform kullanılır. Bir yeni Unix bağlantıda aynı doğrulanmış socket üzerinden `/version` → tek GET yapılır. Synchronous consumer tam bounded body'yi okur, gerçek status/header tuple'ını `ProbeResponse` içine koyar ve mevcut `validate_network_list` veya `validate_network_inspect` çağrısını kullanır; böylece aynı kaynak bağı ve intent yanıt sonrasında da tekrar doğrulanır. Shared HTTP son identity/cancel/deadline kontrollerinden sonra sonuç döner.

## Exact request genişlemesi

- List yalnız `/v1.47/networks?` + `urlencode({'filters': canonical_json({'name': ['larenor-control-' + resourceId]})})`. Shared katman tek `filters` parametresi, exact canonical JSON/name biçimi, 32 küçük harfli hex son ek ve aynı canonical yeniden kodlama eşitliğini ister. Adapter hedefi yalnız `network_list_target(binding)` ile üretir ve validator'a aynı hedefi verir. Label/driver/scope filtresi çakışan ağı gizleyebileceği için eklenmez.
- Inspect yalnız `GET /v1.47/networks/{64lowerhex}`. İsim, kısa ID, yüzdeyle kodlanmış ID, slash/query/fragment, `verbose` ve `scope` seçeneği yoktur.
- Her ikisinde fixed `Accept: application/json`, body `None`; mevcut image GET/POST şekilleri değişmez. Network POST, DELETE, create/connect/disconnect/prune, arbitrary filters, auth, redirect/retry veya genel Docker proxy seçeneği açılmaz. Network GET için EOF-delimited body kabul edilmez.

Pure `NetworkResourceError` kodları aynen kalır. Yeni `NetworkTransportError` yalnız `invalid_network_limits`, `network_engine_unavailable`, `network_timeout`, `network_cancelled`, `network_api_unsupported` sabitlerini taşır. Common invalid request → mevcut `invalid_network_binding`; protocol → mevcut `network_protocol`; stream limit → mevcut `network_response_limit`; kalan transport hataları ilgili sabite eşlenir. HTTP 200 dışındaki status statik `network_engine_unavailable` olur ve bağlantı kapanır; error body veya Location izlenmez/yansıtılmaz. Özellikle 404 ve 206 hiçbir zaman `missing` üretmez.

## Journal ve kanıt anlamı

`ResourceIntent` (`resource_journal.py:129`) özel in-process girdidir. Nonce bugün `begin` veya `reconcile` callback'i içindeki intent'ten gelir. Transport journal açmaz, `prepare/begin/reconcile` çağırmaz, güncel revision kilidi veya actor yetkisi verdiğini iddia etmez. Test fixture'ının geçerli intent oluşturmak için temporary journal kullanması production effect köprüsü değildir.

Tam, bounded, 200 listte exact-name eşleşmesi yoksa `missing`; tek uygun kayıt varsa yalnız `candidate`; aynı adlı foreign veya iki kayıt mevcut pure conflict/multiple sonucudur. List attached endpoint'leri eksik bildirebildiği için candidate → ownership receipt dönüşümü yoktur. Exact-ID inspect bütün özellikler/etiketler ve açık boş `Containers` ile `NetworkIdentity` döndürebilir; bu zaman noktasındaki gözlem güncel namespace/egress/bootstrap güvenliği, devam eden ayrıcalık veya attach/create yetkisi değildir. Uncertain intent ile okuma mümkün kalır, kayıp create yanıtı üzerinden yeni create yapılamaz.

## İlk RED ve regresyon kanıtı

1. **Gerçek sentetik Unix akışı:** amd64/arm64 × content-length/chunked list ve inspect; her bağlantıda version → exact GET, dört istekle list-candidate → full-ID inspect. Empty list yalnız missing; listte `Containers` yokken candidate ve inspect'te attached endpoint varsa conflict. Başarılı list bile otomatik inspect/create çalıştırmaz.
2. **Gönderim öncesi bağ:** değiştirilmiş katalog/policy/resource/nonce/spec/receipt, bool revision, prepared receipt ve kısa/uppercase/path ID sıfır socket isteği üretir. Geçerli uncertain intent yalnız okuma yapar. Liste adı veya inspect ID hiçbir zaman Client URL'sine dönüşmez.
3. **Absence saldırıları:** same-name foreign/two IDs, label-only/custom query, malformed unrelated row, duplicate IDs/JSON keys, 129 kayıt, byte sınırı, truncated content-length/chunk/trailer, EOF-only, 206/Link/Content-Range/gzip, redirect/404/500 asla missing veya matched değildir. Orijinal framing headers validator'a korunarak gider.
4. **Lifecycle yarışları:** yanlış UID sıfır HTTP; yanlış API/arch yalnız version; version sonrası cancel veya socket/ancestor replacement sıfır iş GET'i; yanıt sırasında binding değişimi reddedilir; final identity/cancel ve stalled total/idle timeout sonucu geri çeviremez. Hata/cancel sonrası socket kapanır ve canlı iterator kaçmaz. Dispatcher/job veya daemon-context grant testi iddia edilmez.
5. **Yan etkisizlik/regresyon:** wire kayıtlarında yalnız `/version`, exact name-list ve full-ID inspect vardır; POST/DELETE/attach/create/shell/subprocess yoktur. Gerçek temporary journal row/revision değişmez. Mevcut image transport/preparation, resource journal/plan ve pure network testleri birlikte geçer; yeni modül branch coverage ≥%80. macOS injected UID sentetik kanıttır; gerçek `SO_PEERCRED` testi Linux CI'da ayrı çalışır. Gerçek Docker/registry/ev ağı acceptance bu paketin dışındadır.

Dayanaklar: `network_resources.py` `_inputs`, `network_list_target`, `validate_network_list`, `validate_network_inspect`; `resource_journal.py` `ResourceIntent`, `begin`, `reconcile`; `engine_http.py` `EngineHttpRequest`, `VerifiedEngineHttp.exchange`. Resmî protokol kaynakları mevcut pure modülün Docker Engine 1.47/Moby v27.5.1 atıflarıdır; bu keşifte yeni internet veya Docker erişimi yapılmadı.
