# S06 dilim 3 — sahiplikli kaynak hazırlığı için dar karar notu

**Uygulama durumu:** aşağıdaki metin başlangıç karar kaydıdır. Sonradan eklenen
kod, test kanıtı ve ayrı journal kararı [uygulama kaydında](resource-preparation-implementation-2026-09-05.md)
izlenir; bu nottaki öneriler tek başına kabul değildir.

5 Eylül 2026. Salt okunur inceleme; kod, kurulum, Docker veya ev cihazı işlemi yapılmadı. İncelenen checkout: `62b2054`. Bu not uygulanmış özellik listesi değildir. Önerilen dilimde `installAvailable=false`, katalog `installable=false` ve özel bootstrap/otomatik eşleştirme engelleri korunur. Mevcut `/media/inspections` işi salt okunur kalır; kaynak hazırlığı onun durumlarının veya yetkisinin yeniden yorumlanmasıyla açılmaz.

Mevcut temel: `server/larenor_server/plugins/worker.py` yalnız dahili, sınırlı container create/start ilkelleri sunar. `ContainerBinding` kalıcı mount'ları ve imajın `Config.Volumes` alanını reddeder; `_matches` mount içeren mevcut container'ı sahiplenmez. `UnixDockerEngine` sabit v1.47 Unix HTTP yollarını kullanır, yanıtı en çok 1 MiB olarak toplar; bu taşıma uzun pull akışına doğrudan uygun değildir. `WorkerJournal` v1 `(job, step)` ve `(installation, step)` benzersizliği ile hazırlanmış niyet/sonuç/belirsizlik saklar. `stack_plan.py` her bileşen için `installationId`, `operationId`, `stepId` türetir; fakat beş mevcut adım arasında image pull/ağ hazırlığı yoktur. `catalog.py` appdata alt yolunu bugün kullanıcıya görünen `instanceName` üzerinden kurar ve bridge bileşenlerinde `0.0.0.0` portları, Music Assistant'ta host ağı ister. Bu istekler güvenli bootstrap planı değildir.

Aşağıdaki altı adım bir sonraki uygulamanın sınırıdır. Yeni dahili adların ve Docker seçeneklerinin kaynağı Client olmaz. Client yalnız kalıcı hazırlık kimliği/revizyonu/plan özeti gibi mevcut doğrulanabilir kimlikleri seçebilir; kullanıcıya görünen ad host kaynağı adına dönüşmez.

## 1. Kaynak hazırlığına özgü, worker tarafından türetilen sözleşme

**Karar:** Ayrı, sürümlü bir dahili `ResourcePreparationPlan` tanımla: Core/ev/hazırlık kimlikleri, mevcut stack hash ve katalog digest'i, worker politika sürümü/özeti, resource ID'leri ve sınırlı `ensure_image`, `prepare_appdata`, `prepare_control_network` etkileri. Child `operationId` mevcut create/start worker'ına ileride `job_id` olarak bağlanır; bütün stack işinin ID'si altı aynı adlı adım için kullanılmaz. Stack ortak ağına ayrı bir resource ID verilir. Mevcut `MediaStackPlan` v1 ve geçmiş hash'leri yeniden yazılmaz; yeni kaynak planı bu plana açıkça bağlanan ayrı bir katmandır.

**Kod bağımlılığı:** `stack_plan.verify_media_stack_plan`, `catalog.verify_plan`, `MediaInspectionManagement._conditions` içindeki güncel actor/family/context/preparation/catalog kontrolleri; `WorkerStep` ve `WorkerJournal` kimlikleri. Dahili mutation dispatcher ayrı olmalı; `PreflightWorkerServer` mevcut salt okunur op kodları değişmez.

**Kabul:** Aynı hazırlık/politikadan aynı kaynak kimlikleri çıkar; altı child ve stack ortak kaynağı çakışmaz. Client'tan image URL, root path, resource name, driver, mount veya Docker JSON eklenmesi reddedilir. Eski catalog/hash, başka Core/ev, iptal edilmiş hazırlık veya güncelliğini kaybetmiş yetki hiçbir kaynak işlemi doğurmaz. Eski v1 hazırlık geçmişi aynen okunur.

**Bağlam sınırı:** Yeni kaynak planının mevcut logical mount isteğini UID/host yoluna nasıl çevirdiği açık sürümlü bir politika kararıdır; var olan `instanceName/config` yolunu sessizce başka yere çevirmiş gibi gösterilmez. Bu dilimde ürünün install/confirm API'si açılmaz.

## 2. Kaynak niyeti, sahiplik ve yarım işlem makbuzları

**Karar:** Container journal'ını genel kaynak kabul edecek şekilde gevşetmek yerine, v2 journal'a doğrulanan ayrı `resources` tablosu ekle. Bir anahtar örneği `(preparationId, resourceId, kind)`; kayıtta Core/ev, child operation, plan/politika özeti, journal kimliği, sahiplik nonce'u, state, gözlenen daemon resource ID veya filesystem identity bulunur. Niyet yan etkiden önce kalıcılaştırılır. `prepared → mutating → ready | uncertain | needs_attention` sonuçları yalnız kaynak hazırlığını anlatır. İçerik adresli imaj cache'i silinebilir “bizim volume'ümüz” olarak sahiplenilmez.

**Kod bağımlılığı:** `WorkerJournal.locked`, FULL synchronous SQLite, `_read` doğrulaması, `_write_state` ve create yanıtı kaybolunca `_reconcile` düzeni. v1 metadata/schema kontrolü değişmeden migration/rollback tasarlanır; kayıt yokluğu otomatik yeniden başlangıç sayılmaz.

**Kabul:** Ağ veya dizin yaratıldıktan hemen sonra cevap/journal yazımı kaybolsun; restart'ta aynı kimlik+niyet+gerçek özelliklerle salt okunur uzlaştırma yapılır. Aynı adlı yabancı kaynak, sadece eşleşen label veya sadece boş dizin bulundu diye sahiplenilmez. Eksik/bozuk sahiplik makbuzu, değiştirilmiş journal veya birden çok eşleşme `needs_attention` olur. Aynı işi iki worker aynı anda sürdüremez. İptal/timeout kaynakları ya da medya dosyalarını otomatik silmez.

**Bağlam sınırı:** Label tek başına yetki değildir; özel journal ve tam kaynak özellikleri birlikte gerekir. Operatör/daemon yöneticisi güven sınırının içindedir; başka bir daemon yöneticisine karşı mutlak izolasyon iddiası kurulmaz.

## 3. Yalnız katalogdaki seçili digest'i edin ve yeniden doğrula

**Karar:** API v1.47 için sabit `POST /images/create?fromImage=<repository>@<platform-manifest-digest>&platform=<linux/amd64|linux/arm64>` kullan; `fromSrc`, `changes`, boş `tag`, serbest registry veya import yok. `fromImage` digest kabul eder; bağlantı kapanınca pull iptal edilir. Ardından sabit digest ile `GET /images/{name}/json` doğrulanır. Bu yollar ve alanlar resmi [Engine v1.47 OpenAPI](https://docs.docker.com/reference/api/engine/version/v1.47.yaml) üzerinden okundu. Digest pinleme hareketli tag yerine seçili içeriği belirtir. [Docker image pull](https://docs.docker.com/reference/cli/docker/image/pull/#pull-an-image-by-digest-immutable-identifier)

`UnixDockerEngine._exchange` üzerinden tüm progress çıktısını toplamak yerine sınırlı streaming okuyucu ekle: toplam monotonic süre, idle/read sınırı, satır/olay ve toplam bayt sayacı; ham registry hatasını/log/secret'ı dışarı verme. HTTP 200 tek başına başarı değildir; akıştaki hata ve son image inspect sonucu denetlenir. Bu sınırların sayısal varsayılanları operatör politikası olmalı; mevcut 5 saniyelik gözlem bütçesi pull'a taşınmamalı, her chunk'ta yeni süre de başlatılmamalı.

**Kod bağımlılığı:** `manifest.images[platform].digest/configDigest`, seçili `InstallPlan.image`, `UnixDockerEngine.inspect_image` ve yeni resource journal. Image ID/config digest ile platform manifest digest birbirine karıştırılmaz; OS/architecture ve beklenen repo digest ilişkisi yeniden doğrulanır. İleride `ContainerBinding.image_configuration` yalnız bu doğrulanmış inspect sonucundan türetilir.

**Kabul:** Yanlış mimari/config digest, 200 içinde error, kesilen veya limitsiz akış, cache'teki yanlış imaj ve registry 401 sabit hatayla durur. Doğru cache varsa pull yapılmaz. Cevap kaybolduktan sonra ilk işlem inspect olur; bulunamayan imaj için aynı resource ID ile açık resume gerekir. Kamuya açık katalog imajlarında Client registry credential girişi veya auth-header aktarımı yok.

**Bağlam sınırı:** Pull daemon'ın disk/cache ve ağını kullanır; worker appdata kökündeki 49.152 MiB hesabı daemon image-store boş alanını kanıtlamaz. Daemon image-store için ayrı politika/bütçe kontrolü gerekir. İptal edilen pull'dan kalan paylaşılan layer'ları prune/delete etme. Docker'ın bağlantı-kesilmesi davranışı da cache'in tamamen geri alındığı anlamına gelmez. [Pull iptali](https://docs.docker.com/reference/cli/docker/image/pull/#cancel-a-pull)

## 4. Yalnız onaylı kök altında sahiplikli appdata dizinleri hazırla

**Karar:** İlk kapsam mevcut opaque `HostPolicy` root ID'leri ve bind source hazırlığı olsun; named volume driver/plugin, NFS ve serbest mount seçeneği ekleme. Appdata fiziksel alt adları `installationId/resourceId` üzerinden üretilir. Worker'a ait özel üst dizin altında exclusive staging, journal'a bağlı sahiplik işareti, fsync ve var olan hedefi ezmeyen yayınlama gerekir. Root ve her alt bileşen descriptor üzerinden `O_NOFOLLOW` ile doğrulanır; kaynak identity işlemden sonra tekrar ölçülür.

**Kod bağımlılığı:** `HostInspector._root_descriptor/_managed_descriptor`, `HostRoot.purpose`, son aggregate kapasite kontrolü, `daemon_context` lease/pidfd ve v3 operatör politikası. Bunlar bugün gözlemdir; mutator aynı root/mount kanıtını işlem anında yeniden kurmalı. Sonraki container binding, tüm kalıcı `HostConfig.Mounts` kaynak/target/readOnly/propagation alanlarını açıkça eşleştirmeden mevcut mount-reject guard'ı kaldırılamaz.

**Kabul:** Symlink/root inode/mount değişimi, yabancı veya dolu hedef, UID/GID uyumsuzluğu ve mkdir/metadata/rename arasındaki her crash noktası test edilir. Var olan kullanıcı library/media kökü yeniden adlandırılmaz, recursive chown veya boşaltma yapılmaz; onaylı kullanım ile “bize ait appdata” ayrıdır. Tam journal sahipliği kanıtlanan staging devam eder, kanıtlanamayan kalıntı korunup insan incelemesine bırakılır. Read-only library görünümü gerçekten read-only ve beklenen target ile bağlı olmalıdır; image `Config.Volumes` ile gizli anonim volume oluşumu engellenir.

**Bağlam sınırı:** Bind source daemon hostunda çözülür; worker'da aynı yol metninin bulunması yeterli değildir. Farklı process-root/mount namespace, proxy socket, userns-remap/rootless UID eşlemesi kanıtsızsa kaynak hazırlanamaz. Mevcut dizini Docker'a örtülü olarak oluşturtmak yok. [Docker bind mounts](https://docs.docker.com/engine/storage/bind-mounts/#considerations-and-constraints)

## 5. Sahiplikli özel kontrol ağını tek başına hazırla

**Karar:** Sabit `POST /networks/create` için worker'ın ürettiği ad, `Driver=bridge`, `Scope=local`, `Internal=true`, `Attachable=false`, `Ingress=false`, `ConfigOnly=false` ve journal/plan/Core/ev/preparation/resource label'ları kullanılır. Serbest Options, IPAM, ConfigFrom, driver veya Client adı yok. Oluşan ID journal'a yazılır; restart'ta aynı ID'nin tam özellikleri incelenir. v1.47 şemasında bulunmayan `CheckDuplicate` alanına dayanılmaz. [Engine v1.47](https://docs.docker.com/reference/api/engine/version/v1.47.yaml)

**Kod bağımlılığı:** Yeni network binding/receipt; mevcut `_LABELS` ve `ContainerBinding.NetworkMode={bridge,host}` ağın sahibi/ID'si için yeterli değildir. Mevcut `0.0.0.0` portlu child plan doğrudan başlatılmaz. Ağ yaratmak bu dilimde container connect/start hakkı vermez.

**Kabul:** Aynı adı taşıyan yabancı ağ, iki aynı adlı eşleşme, eksik/yanlış label, farklı driver/scope/internal, beklenmeyen attached container ve kayıp create cevabı test edilir. Docker ağ adının benzersizliğini kesin garanti etmediğinden ad araması tek başına kabul sayılmaz; ID + kayıtlı niyet + bütün özellikler doğrulanır. [Docker network create](https://docs.docker.com/reference/cli/docker/network/create/)

**Bağlam sınırı:** `Internal` diğer ağlara erişimi sınırlar; hostun container IP'sine ve uygun gateway servisine erişimi mümkündür. Bu nedenle “özel kontrol ağı hazır” ilk-kullanıcı bootstrap'ının korunduğu anlamına gelmez. Bu dilimde port publish, container attach, Core container'ını mevcut ağından taşıma veya LAN firewall değişimi yok. [Internal network davranışı](https://docs.docker.com/reference/cli/docker/network/create/#network-internal-mode---internal) Music Assistant'ın host networking isteği bu özel bridge ile korunmuş sayılamaz; host modu host ağını paylaşır. MA başlatma/özel bootstrap ve normal çalışma egress/receiver ağı dilim 4–5 için açık engel olarak kalır. [Host network](https://docs.docker.com/engine/network/drivers/host/)

## 6. Yan etki sınırını kapatan kabul paketi ve sonraki dilime makbuz

**Karar:** Bu dilimin çıktısı mevcut hazırlığa bağlanan `resources_ready` benzeri dahili makbuzdur; `installed`, `healthy`, “tüm gereksinimler geçti” değildir. Önce saf plan/journal ve fake Unix Engine testleri; ardından yalnız geçici Linux amd64/arm64 CI ortamında küçük digest-pinned fixture image, özel boş appdata alanı ve yeni ağ ile gerçek uyum doğrulaması. Operatör izinli production yürütme bu nottan çıkarılmaz. Client ekranına Docker seçenekleri veya bağımsız bileşen kurulumu eklenmez.

**Kod bağımlılığı:** `test_plugin_worker.py`, `test_plugin_worker_startup_safety.py`, `test_daemon_context.py`, `test_media_host_preflight.py` ve `test_media_inspections_api.py` desenleri. Yeni testler resource journal ve yeni sınırlı engine endpoints için ayrı dosyalarda olmalı; mevcut readonly IPC ve media inspection testleri yan etkisizlik regresyonu olarak kalır.

**Kabul:** Gerçek Engine yol kaydı yalnız onaylı image pull/inspect ve network create/inspect yollarını içerir; container create/start/exec, volume plugin, prune/delete ve Docker CLI/shell çağrısı yoktur. İki mimaride yanlış pin reddedilir; restart aynı owned kaynakla devam eder; cancellation yeni yan etki başlatmaz. Test cleanup yalnız kendi disposable fixture kapsamını tanır, production rollback davranışı veri silmez. Her sınırda Core/ev/plan/policy/actor-family/cancel değişimi yeni işlemi durdurur; önceden tamamlanmış kaynak kaydı korunur.

**Bağlam sınırı:** API v1.47 yeteneği mutation socket'inde her yeniden bağlantıda doğrulanmalı; S06 dilim 2'nin ayrı read-only socket gözlemi otomatik yürütme yetkisi değildir. v1.47 destek aralığı yoksa sessiz API yükseltme/düşürme veya TCP fallback yerine unsupported sonucu verilir. [Docker API sürümleme](https://docs.docker.com/reference/api/engine/#versioned-api-and-sdk)

Önerilen ilk RED paketi: resource ID/journal crash matrisi ve yabancı kaynak çakışması. Ardından digest pull, owned appdata, özel ağ sırasıyla ayrı GREEN kapıları. Bu sıra dilim 3'ü somut kaynak hazırlığına indirger; bootstrap, servis anahtarları, alıcı keşfi, çalışan altı bileşen ve gerçek ev sunucusuna manuel kurulum hâlâ sonraki teslimlerdir.
