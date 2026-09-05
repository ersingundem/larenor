# S06.3e — özel network create ve journal köprüsü tasarımı

**Durum:** Yalnız tasarım ve kaynak araştırması. `3076f5f` salt okunur transport paketinin sonraki bağımlı adımıdır; burada production/test kodu veya Docker kaynağı değiştirilmedi. `installAvailable=false` kalır. Dispatcher, API/IPC/CLI, container attach/start, network delete/prune ve gerçek ev kurulumu açılmaz.

## Sabitlenmiş protokol bulguları

Engine API 1.47 create başarısı **201**; yanıt alanları `Id` ve tekil `Warning:string` olarak zorunludur. `Warnings` dizisi değildir. Router create çağrısı sonunda 201 yazar; Moby 27.5.1 local daemon yolu ID ile bir yanıt kurduğu için normal Warning boş string olur. [Sabit Swagger](https://raw.githubusercontent.com/moby/moby/v27.5.1/api/swagger.yaml), [CreateResponse tipi](https://raw.githubusercontent.com/moby/moby/v27.5.1/api/types/network/create_response.go), [router](https://raw.githubusercontent.com/moby/moby/v27.5.1/api/server/router/network/network_routes.go), [daemon create](https://raw.githubusercontent.com/moby/moby/v27.5.1/daemon/network.go).

Moby 27.5.1 controller aynı ada göre kilit alır, var olan adı `NetworkNameError` ile reddeder; conflict HTTP **409** olur. Bu 409 Swagger create cevap listesinde ayrıca yazılmamıştır. Dolayısıyla bu sürümde aynı local ad için paralel create'in korumasız olduğu söylenmemeli. Bununla birlikte Docker'ın genel belgesi ad çakışmasını engellemenin garanti olmadığını belirtir; önceki list ile create ve sonraki inspect tek atomik işlem değildir. Aynı adlı foreign/multiple kayıtlar hâlâ fail-closed ele alınmalıdır. [controller](https://raw.githubusercontent.com/moby/moby/v27.5.1/libnetwork/controller.go), [hata tipi](https://raw.githubusercontent.com/moby/moby/v27.5.1/libnetwork/error.go), [HTTP eşlemesi](https://raw.githubusercontent.com/moby/moby/v27.5.1/api/server/httpstatus/status.go), [Docker ad çakışması belgesi](https://docs.docker.com/reference/cli/docker/network/create/).

`CheckDuplicate` Go request tipinde eski istemciler için tutulmuş deprecated alandır; güncel daemon create yolu onu kullanmaz. Mevcut sabit gövdeye eklenmez. [Request tipi](https://raw.githubusercontent.com/moby/moby/v27.5.1/api/types/network/network.go).

**Kaynaklardan çıkarım:** Router backend create'e HTTP context iletmez; controller bazı kayıt/cleanup işlemlerinde `context.TODO()` kullanır. Socket kapandı veya çağrı timeout oldu diye create'in gerçekleşmediği sonucu çıkarılamaz. Ayrıca daemon `DefaultNetworkOpts` ekleyebilir; controller bazı firewall kurulum hatalarını yalnız loglayabilir. Boş Warning, varsayılan seçeneklerin veya bootstrap/firewall izolasyonunun kanıtı değildir. Son inspect bunları mevcut strict özellik sözleşmesiyle değerlendirir. [router](https://raw.githubusercontent.com/moby/moby/v27.5.1/api/server/router/network/network_routes.go), [daemon seçenek birleştirmesi](https://raw.githubusercontent.com/moby/moby/v27.5.1/daemon/network.go), [controller kayıt ve user-chain akışı](https://raw.githubusercontent.com/moby/moby/v27.5.1/libnetwork/controller.go).

## En küçük private API ve dosyalar

1. Yeni `plugins/network_effects.py` + `tests/test_network_effects.py`: strict create ACK doğrulayıcı ve `UnixNetworkCreator`. Mevcut `UnixNetworkEngine` salt okunur kalır.
2. Yeni `plugins/network_preparation.py` + `tests/test_network_preparation.py`: `JournaledNetworkOperations`. İlk sürüm mevcut ResourceJournal şemasını değiştirmez.
3. `engine_http.py` + ilgili testinde dar genişleme: yalnız sabit `POST /v1.47/networks/create`, canonical ve kapalı request body şekli; create için zorunlu, özel `before_dispatch` doğrulama kapısı. Image yolları ve hata/EOF davranışı ayrı regresyon kapısıdır.

```python
UnixNetworkCreator(endpoint, *, limits=None, peer_uid=None)
creator.create(binding, intent, *, before_dispatch, cancelled=None)
    -> NetworkCreateAcknowledgement(network_id)

JournaledNetworkOperations(journal, reader, creator)
operations.apply(plan, stack, catalog, policy, resource_id,
                 *, authorize_create=None, cancelled=None) -> ResourceReceipt
```

Creator yalnız `build_network_create_body(binding,intent)` çıktısını üretir; raw JSON, hedef, ad, label, driver, Options/IPAM, auth veya query parametresi kabul etmez. Bound source/intent mutating revision2 olmalı. Request en çok4096 bayt; fixed Accept ve Content-Type application/json; Content-Length transport tarafından hesaplanır. Shared request doğrulaması exact alan kümesi, sabit boolean/driver/scope değerleri, üretilmiş ad ve sabit label şemasını canonical yeniden kodlama ile sınırlar. Katalog/nonce/spec eşlemesi creator'da tekrar türetilir; ortak taşıma bunu yetki kanıtı saymaz.

ACK en çok4096 bayt,128 chunk, total10s/idle2s; mevcut64KiB version ve32KiB header sınırları korunur. Yalnız tam framed201 JSON, exact `Id`/`Warning`,64 küçük harfli hex ID ve boş Warning kabul edilir. Nonempty Warning, bozuk/truncated yanıt, redirect,409,5xx ve timeout statik hata üretir; Warning/message/Options hiçbir log veya makbuzda tutulmaz. ACK yalnız olası oluşturulan ID'dir, `NetworkIdentity` veya `ready` değildir. **Network POST için EOF framing yasaktır:** mevcut image pull EOF istisnası method==POST üzerinden genellenmemeli, exact image-pull şekline bağlı kalmalıdır.

`before_dispatch` sadece güvenilir in-process, kısa ve yan etkisiz doğrulama callback'idir. Shared HTTP aynı socket'te version/API/platform kontrolünü tamamladıktan sonra literal True ister; ardından immutable request, endpoint identity, cancel ve deadline tekrar kontrol edilip tek POST gönderilir. Callback içinde resource mutation yoktur; `DockerProbe.observe.during` hiçbir zaman mutator olmaz. Keyfi bloklayan callback'in zaman sınırı bu tasarımla kanıtlanmış sayılmaz; gerçek grant issuer'ın kendi bounded sözleşmesi sonraki üretim kapısıdır.

## Journal akışı ve authority kapıları

`locked()` bütün apply süresini kapsar. Snapshot rederivation yalnız verilen binding/source nesnelerine aittir; yeni global katalog/policy, actor/session veya gerçek daemon lease güncelliğini otomatik keşfetmez.

1. Kaynak bağını, Event/callback tiplerini doğrula; kilit altında `prepare` al. `ready/needs_attention` tarihsel receipt olarak geri döner; mevcut fiziksel sağlık iddiası oluşmaz. `mutating/uncertain` için doğrudan salt okunur reconciliation yoluna git; create callback'ini kullanma.
2. Yeni `prepared` kaydında **durable begin öncesi** `authorize_create() is True`, iptal yokluğu, fresh binding ve aynı journal receipt kontrol edilir. Eksik/false/exception callback prepared bırakır. Başarılıysa `begin` committed mutating intent/nonce üretir. Mevcut network validator begun intent istediği için image örneğindeki begin-öncesi inspect sırası kopyalanamaz.
3. Bu çağrıda yeni begin edildiğini yalnız yerel kontrol akışı bilir; kalıcı mutating state tek başına tekrar effect izni değildir. Bound intent ile readonly exact-name list yapılır. Candidate varsa full-ID inspect ile reconciliation; foreign/multiple varsa ilgili needs_attention; unavailable varsa uncertain. Hiçbiri create doğurmaz.
4. Yalnız bu taze çağrının list sonucu missing ise creator'a ilerlenir. Creator'ın **version sonrasındaki dispatch kapısında** tekrar literal True, Event, current receipt/revision, fresh binding ve başlangıçtaki canonical body eşitliği kontrol edilir. Authorizer reentrant journal/source değiştirirse yeni revision ezilmez ve POST atılmaz. İlk method çağrısından önce yapılan tek yetki kontrolü, version handshake sırasında gerçekleşen değişimleri kapatmaz.
5. Tek POST sonrası herhangi bir hata/iptal/yanlış ACK sonucunda kayıt mutating→uncertain olur; ikinci POST, otomatik cleanup veya retry yoktur.201 ACK tek başına ready yapmaz. Başarılı ACK için fresh exact-name list, aynı full ID ve bütün label/özellikleri doğrulayan full-ID inspect zorunludur. Listte farklı ID, foreign/multiple veya bağlı endpoint conflict'tir;404/unavailable veya eksik yanıt belirsizdir. Son source/receipt/cancel kontrolleri sonrası `ResourceObservation` yalnız doğrulanan `NetworkIdentity` ile journal reconcile içine verilir.

Reconciliation observer'ı yalnız list→candidate ise inspect yapar; create çağırmaz. Tam list missing ise needs_attention/resource_missing olur; yeni create izni doğmaz. Hatalı list/inspect gözlemi uncertain/unavailable, foreign/multiple/attached conflict veya multiple olur. Journal callback sonrası revision kontrolü yeniden girişle değişen durumu korur. Başlangıç listinden bilinen negatif conflict'i saklamak güvenli olsa da olumlu matched sonucu eski candidate'dan türetilmez.

201 ID'si son doğrulama bitmeden kalıcı sahiplik olarak yazılmaz. Crash bu arada olursa restart tam ad+aynı journal nonce/spec label'larıyla list yapar ve bulduğu full ID'yi inspect eder. Başarılı reconcile ID'yi mevcut typed observation alanında kalıcılaştırır. Unverified ACK ID'sini ayrıca kalıcılaştırmak istenirse bu ayrı şema tasarımıdır; bu küçük increment onu gerektirmez. Sonuç `ready` yalnız tarihsel internal gözlemdir; egress, alıcı ağı, private bootstrap veya kurulum yetkisi değildir.

Sınırlı çağrı sayısı: fresh missing yolunda list/create/final-list/inspect en çok4 HTTP exchange; her biri en çok10s. Candidate yolunda en çok3, restart yolunda en çok2 read exchange; retry döngüsü yoktur. Bu40s transport üst sınırı,5s IPC veya Client request bütçesine sığdığı iddiası taşımaz. Gerçek async dispatcher, toplam job bütçesi ve bounded authority issuer gelmeden public endpoint'e bağlanmaz.

## RED → GREEN kabul sırası

- **ACK/POST sınırı:** gerçek sentetik Unix server, amd64/arm64, content-length/chunked201; exact body+headers, boş Warning; malformed/duplicate/extra alanlar, short/bool ID, null/array/nonempty Warning, oversized/truncated/EOF body,409/redirect/500. Her bağlanış version→tek POST; auth/query/custom Options veya network attach/delete yoktur.
- **Gönderim kapısı:** eksik/false/nonliteral/exception authorize before-begin, ikinci kontrol ve version callback aralığında revocation; cancel before socket, during version, before send ve after send. Reentrant callback receipt/source/body değiştirince POST0 ve yeni receipt korunur. Deadline biten gate yeni effect başlatamaz; trusted callback'in sınırsız çalışması için sahte bounded iddia kurulmaz.
- **Crash matrisi:** begin commit öncesi/sonrası, initial list sonrası, POST bytes kısmen gönderilmişken, daemon yaratıp yanıt kaybolduğunda,201 sonrası final inspect öncesi ve matched receipt yazılırken process interruption. Yeniden açılan journal mutating/uncertain kayıtları yalnız list+inspect yapar; ağ bulunmasa bile POST0. Metadata kaybı/bozulması yeniden initialize edilmez.
- **Sahiplik ve yarış:** initial missing→create409→sonraki reconciliation foreign/multiple;201 ID ile list ID uyuşmazlığı; aynı adlı iki ID; doğru label'lı fakat attached endpoint/yanlış Options/IPAM/scope/internal; candidate sonrası delete/replace. `ready` yalnız final full-ID inspect'ten; geçerli ACK ve empty Warning bunu atlayamaz.
- **İdempotence ve kapsam:** aynı process/ayrı ResourceJournal instance eşzamanlı apply yalnız bir POST yapar; uncertain replay fresh read-only, terminal receipt tekrarında effect0. Gerçek temporary SQLite+Unix composition iki mimaride çalışır; journal observer hiçbir mutator içermez. Image/read transport/journal/network pure regresyonları ve yeni modül branch coverage≥%80; Linux SO_PEERCRED ayrı CI kapısı. Gerçek Docker veya ev ağı bu test paketinde çalışmaz.

## Açık üretim engelleri

Literal-True test callback'i gerçek actor/family/preparation/catalog/policy/daemon/host grant değildir. Native worker'ın kanıtlanmış daemon process/root/mount/network bağlamı, geçerli operatör politikası ve kaynak/bütçe izni ayrıca gerekir; Core container'ın socket erişimi bunu sağlamaz. Driver default seçenekleri strict inspect'i bozarsa yaratılmış kaynak otomatik silinmez, needs_attention bırakılır. Docker network yöneticisi güven sınırının içindedir; ona karşı mutlak izolasyon veya list+inspect atomikliği iddia edilmez. `Internal=true` host erişimini engellemez ve MA host-network bootstrap'ını çözmez. [Docker internal ağ sınırı](https://docs.docker.com/reference/cli/docker/network/create/#network-internal-mode---internal).
