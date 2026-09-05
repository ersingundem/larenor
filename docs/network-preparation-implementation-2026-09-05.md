# S06.3e — özel network journal köprüsü

**Uzak yazılım kabulü:** `9138e617a35d40fc4ab811f980021fb9e3e7a403`,
[Server CI](https://github.com/ersingundem/larenor/actions/runs/33986835291) ve
[güvenlik](https://github.com/ersingundem/larenor/actions/runs/33986835178)
başarılı: 2.566 Linux testi atlamasız, 202 araç testi, iki mimarili Core
restart/medya hazırlığı/iptal smoke'u ve anonim yayın doğrulandı.
Bu backend dilimi S06.3c ile aynı kapılardan kabul edildi. Aynı commit'in
Android odak testi Quickstep ANR nedeniyle başarısızdır ve APK 92 yoktur;
tablet teslimi B5.1 içinde açık kalır. Gerçek Engine üzerinde kaynak kurulumu
S06.3f'ye, host yetkisi ve dispatcher sonraki kendi adımlarına aittir.

**Uygulanan dilim:** `JournaledNetworkOperations` artık sabit katalog/resource planı, mevcut özel `ResourceJournal`, salt okunur `UnixNetworkEngine` ve ayrı `UnixNetworkCreator` arasında senkron bir köprü kurar. Bu dilim özel worker primitive'idir. API/IPC/CLI, dispatcher, gerçek host/daemon yetki üreticisi veya otomatik kurulum bağlantısı eklenmedi; `installAvailable=false` korunur. Network attach/delete/prune ve container işlemi yoktur. Önceki [protokol ve etki tasarımı](network-effect-bridge-plan-2026-09-05.md) geçerlidir.

```python
receipt = JournaledNetworkOperations(journal, reader, creator).apply(
    plan, stack, catalog, policy, resource_id,
    authorize_create=None, cancelled=None,
)
```

`authorize_create` ve `cancelled` keyword-only parametrelerdir. Bağımlılıkların yaşamını çağıran taraf yönetir; köprü constructor'ı I/O yapmaz. Tüm `apply` boyunca process/file lease tutulur, HTTP çağrıları boyunca SQLite write transaction tutulmaz.

## Kalıcı davranış

- Yeni kayıtta önce private callback'in literal `True` sonucu, iptal ve kaynak bağı doğrulanır. Yetki yoksa kayıt `prepared` kalır ve network list çağrısı bile yapılmaz. Başarılı kontrolden sonra `begin` diske committed `mutating` intent/nonce yazar; ilk list bunun ardından gelir.
- Yalnız bu çağrıda yeni begin edilen ve tam list sonucu `missing` olan kayıt tek create'e ulaşabilir. Creator'ın aynı socket'teki `/version` doğrulaması ardından çalışan kapı; current journal revision, original apply source, stored complete snapshot, intent/nonce/spec, canonical body, iptal ve literal-True yetkiyi yeniden denetler.
- İlk listte candidate bulunursa yeni journal intent ile tekrar list ve tam ID inspect yapılır. ID değişimi conflict'tir. Foreign veya multiple kayıtlar `needs_attention`; okunamayan veya bozuk gözlem `uncertain` üretir.
- 201 ACK tek başına ready değildir. Yeni list ACK ID'siyle uyuşmalı, son full-ID inspect tüm ownership label'ları ve kapalı network özelliklerini doğrulamalıdır. ACK sonrası missing/belirsiz yanıt `uncertain`; farklı ID veya bağlı endpoint/özellik conflict'i `needs_attention` olur.
- Kayıp cevap veya ordinary create hatası `uncertain` bırakır. Process interruption sonrası `mutating` ve `uncertain` kayıtlar yalnız list/inspect ile uzlaştırılır; missing sonucunda bile yeniden create gönderilmez. Terminal receipt tekrarları tarihsel kaydı döndürür. Otomatik silme, sahiplenme veya yeniden deneme yoktur.

Reentrant callback daha yeni revision yazarsa eski sonuç onun üstüne yazılmaz. Bridge kendi receipt/resource ID snapshot'ını, okuyucuya verilen intent alias'ından ayrı tutar. Begin sonrası iptal veya ilk body türetilirken bağ değişimi `uncertain` kalır. Son gözlemin ardından original apply source tekrar türetilir; yalnız adapter'ın bound plan kopyasını kontrol etmekle yetinilmez. Journal write hatası statik hata olarak kalır, başarı veya gizli retry üretilmez.

## Kanıt ve sınırlar

İzole `codex/network-effect-bridge` dalında production `20d8ed69c0bcee7e9c574c5b3287b8620d89f205` üzerinde **105 yeni bridge testi** geçti. Image/create/read transport, pure network, resource journal ve planner ile birleşik koşu **846 PASS / 4 Linux-only skip**, 62.81 saniye. Branch-inclusive kapsam: bridge **%94**, create adapter **%100**, ortak HTTP **%98**. İki mevcut FastAPI/Starlette deprecation uyarısı çıktı. Bu Mac koşusu yayımlanmış Linux CI veya gerçek Docker kabulü değildir.

Testler gerçek geçici SQLite journal'ı ve sentetik Unix socket'leri kullanır. İki platform × content-length/chunked başarı, gerçek version-handshake sırasında yetki iptali ve kayıp ACK sonrası journal restart akışı birlikte doğrulandı. Crash testleri begin sonrası list, POST gönderim aşaması, ACK sonrası, inspect ve ready write öncesini; eşzamanlılık testleri aynı ve ayrı journal instance'larını kapsar. Kaynak/revision/nonce değişimi, cancellation, farklı ID, malformed private return, nonliteral grant ve failed uncertain-write ayrıca sınanır.

RED/GREEN checkpoint'leri: `bd0c763` → `5257939`; begin/receipt yarışları `a094a63` → `fb986c0`; body-derivation yarışı `0c88991` → `20d8ed6`. Son bağımsız kaynak/test incelemesinde yeni P1/P2 bulgu çıkmadı.

`ready` yalnız geçmişteki internal ownership/özellik gözlemidir. Güncel sağlık, atomik list+inspect, firewall/egress izolasyonu, receiver ağı veya private bootstrap yetkisi vermez. Private authorizer gerçek actor/session/preparation/catalog/policy/daemon/host/disk grant'i üretmez; bu güncellik future caller/dispatcher sorumluluğudur. En uzun fresh akış dört HTTP exchange yapar; her transport çağrısı 10 saniyeye kadar bütçe kullanabilir. Güvenilir callback'in kendi bounded sözleşmesi ayrıca gerekir. Bu akış 5 saniyelik preflight IPC veya doğrudan Client isteğine bağlanmadı.

Yerel main birleştirmesi `6ec4af3697888af43c14d07472cc032e24265203`:
tam Server **2.559 PASS / 7 Linux-only skip**, 190,40 saniye; birleşme
aralığının sır taraması temiz. Client kaynağı önceki doğrulamayla aynı:
**2.739 test ve tam analiz geçti**. Üç kaynak incelemesinde P1/P2 kalmadı.
S06.3e yazılım/Unix protokol kapısı kendi sonraki CI'ını bekler; izole gerçek
Engine ile iki mimarili kaynak kurulumu S06.3f'ye aittir, döngüsel önkoşul değildir.
