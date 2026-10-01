# Gerçek üretim yolları denetimi — 30 Eylül 2026

Bu envanter test sayısından bağımsız olarak normal Core bileşimini, Client
girişini ve gerçek upstream sözleşmesini inceler. `implemented` önceki kod
durumudur; eksik provider veya bağlantısız UI varsa kapanış kanıtı değildir.
F01–F21 ve F22–F44 iki bağımsız ajan tarafından salt okunur incelendi.

Kanıt düzeyleri ayrıdır: normal-route kapısı production Client/Core/provider
bileşimini; adlandırılmış hosted koşu yalnız çalıştırdığı exact revision/jobı;
`MANUAL` ise disposable fixture ile kanıtlanamayan fiziksel cihaz, radyo,
ekran, kimlik bilgisi ve provider davranışını kapsar. Bunların hiçbiri tek
başına geniş latest-HEAD CI yerine geçmez.

## Güncel uzlaşma — 1 Ekim 2026

Normal Core oynatıcı ve çevrimdışı girişteki F21/F24/F25/F26/F27 bileşim açıkları root110 Client/46 Server ve bağımsız incelemeyle kapandı; bu beş iş CI bekliyor. Güncel toplam **58 seçili özellik/69 iş CI bekliyor**, kabul **35/127 iş ve3/63 özellik**. Yalnız **F60/F62 yeniden çalışılıyor**, yalnız **FINAL.FUNCTION aktif**. Exact191 geniş Android/tüm Server36826527140 sürüyor, Security36826516434 üç işi geçti. Strict F60/691/36825268673 beforeIssue/IllegalArgumentException ile başarısız; F62/6bbe/36826438225 sürüyor. Kesin F60 guard ve belirsiz yerel oturum kapanışı düzeltiliyor; gerçek runtime kabulü henüz yok. [Medya kapanışı](media-core-composition-closure-2026-10-01.md), [güncel named kapılar](final-function-acceptance-2026-09-30.md), [execution queue](../EXECUTION_QUEUE.md).

## Tarihsel kaynak incelemeleri ve checkpointler

Aşağıdaki normal-route, sayaç ve CI kayıtları adlandırdıkları önceki kaynakların kanıtıdır. Eski “güncel/latest” ifadeleri bugünkü kuyruk durumunun yerine kullanılmaz.

| İş | Somut açık | Düzeltme / kabul |
| --- | --- | --- |
| F01 | Kapanmış: Android on-device STT/TTS ve güncel HA hedefli taslak/confirm akışı bağlandı | 10 native + 11 Flutter + 3 Server + 1 gerçek Flutter→normal Core→TCP HA kapısı geçti; model/cihaz ve exact-head CI açık |
| F02/F03 | Kapanmış: normal Core gerçek HA registry ve trace/list/get kaynağını kullanıyor; Client gerçek olay iddiası kabul edilmiyor | 8 Server + 2 Flutter loopback + 1 gerçek Client→normal Core→HA WS kapısı geçti; uzun gerçek geçmiş/DST ve exact-head CI açık |
| F07 | Kapanmış: authenticated HA entity registry + bounded REST history, sealed provenance ve yeterli-baseline kapısı var | F07/F10 ortak kapısında 13 Server + 1 gerçek Flutter→normal Core→HA TCP/WS geçti; household baseline kalitesi manuel |
| F08 | Kapanmış production composition: Docker Core→özel IPC→UID10003 worker→systemd user-manager cgroup dispatch/cancel/readback yolu paketlendi | 42 Server + 6 package geçti; exact 09a912b4 Linux CI 36750577813 gerçek ayrı UID/cgroup stress/release kapısını geçti; geniş güncel HEAD CI ve gerçek model açık |
| F10 | Kapanmış: Core registry/provider kimliğini ve history'yi çözüyor; arbitrary Client sources sentetik ve repair preview-only | F07/F10 ortak 13 Server + gerçek Flutter/normal Core/HA kapısı geçti; fiziksel diagnosis doğruluğu manuel |
| F11 | Kapanmış: signed/hash-pinned gerçek Wasmtime artifacti, fuel/linear memory/epoch ve tek current-home import; WASI ve optional proposals kapalı | 17 Server, 4 Flutter, gerçek Flutter→TCP Core→Wasmtime ve wheel artifact kabulü geçti; broad CI açık. Arbitrary upload, CPU-ms/host RSS garantisi yok; Python 49.0.1 yayını olmadan affected proposals kapalı kalır |
| F12 | Kapanmış transport/lifecycle: custom bearer JSON-RPC route `notifications/initialized`→empty 202, bounded protocol negotiation/standard `_meta`, Origin/protocol header kontrolü ve standart JSON-RPC hata zarflarını uygular | 8 F12 + 12 ortak boundary testi ve normal Uvicorn Core'a bağlanan official Python MCP SDK 2.2.0 initialize→initialized→tools/list→live revoke kapısı geçti. Yetki bilinçli olarak admin-provisioned bearer + exact client header'dır; OAuth Protected Resource Metadata/`WWW-Authenticate` yoktur ve generic OAuth istemci uyumu iddia edilmez |
| F17 | Kapanmış: ayrı TLS append hedefi ve dağıtımı eklendi | `append-target.compose.yaml`; 7 Server + 38 Flutter + 12 boundary odaklı kanıt. Ayrı fiziksel hedef ve disaster restore manuel kalır |
| F18 | Kapanmış: UID10006 NUT producer ve UID10005 Proxmox worker paketlendi | Normal Core `/run/larenor-workers/proxmox` bileşimi; 75 focused + 8 package geçti. Exact `888dfd46f197808f91eaf0f85a4878e15ed27f8e`, run `36762186381`, production offline bundle/install/socket/mount/start ve gerçek cross-UID systemd kapısını geçti. Geniş latest-HEAD CI ile fiziksel UPS/Proxmox etkisi ayrı MANUAL kanıttır. |
| F22/F25/F27/F28/F30 | Kapanmış: unified read/action/music/playback/archive worker socket, mount ve başlatma bileşimi var | Her özellikteki adlandırılmış normal-Core/worker kanıtı korunur; exact-head Linux ve gerçek provider/cihaz kapıları ayrı |
| F29 | Kapanmış: Party DJ gerçek `MusicPlaybackRuntime` ile normal Core'dan owned TCP Music Assistant fixture'ına gidiyor | 35 testlik adlandırılmış kapı restart, duplicate vote, quorum, lost-ACK no-replay ve `needs_attention` davranışını geçti; gerçek receiver eşzamanlılığı manuel |
| F23 | Kapanmış: normal Core gerçek Jellyfin guide/timer provider/recorderını ve inline admin source setup'ı kuruyor | 8 Server + 1 gerçek Flutter→normal Core TCP→Jellyfin geçti; tuner/storage ve exact-head CI açık |
| F24 | Kapanmış: legacy ve aktif player route tek AES-GCM kişi deposunu kullanıyor; authenticated migration atomik | 10 Server + 8 Flutter + 1 gerçek Flutter→normal Core TCP geçti; gerçek track/rendering manuel |
| F28 | Kapanmış: durable deadline pause, family/user/target/media authority ve gerçek production IPC enforcement | 57 F28/music, root ortak 46 Server/37 Flutter ve actual Client/Core/Unix IPC iki yaşamı geçti; geniş CI ve fiziksel receiver ayrı |
| F35 | Kapanmış: encrypted blob→bounded Poppler/Tesseract OCR, source/confidence binding ve ayrı kullanıcı onayı var | 24 Server + 14 Flutter + 1 gerçek Flutter→normal Core→actual OCR + 21 container policy geçti; image/exact-head ve fiziksel belge açık |
| F51 | Kapanmış implementation: admin gerçek catalog/four-revision CAS ve erişilebilir inline floor/room/device editor var | 9 Server + 13 Flutter ve iki gerçek Client→normal Core→TCP HA fazı geçti: tek mutation/replay, CAS repair ve restart; exact-head CI ve fiziksel ölçüm açık |

F04–F06, F09, F13–F16 ve F19–F21'de bu tarama yeni dummy/ölü normal
production yolu bulmadı. Bu gözlem kapsamlı CI veya fiziksel cihaz kabulünün
yerine geçmez. F15 configured component worker gerektirir; F16 effect-disabled
geçici Core restore çalıştırır; F21 player raporu ve yerel playback/seek uygular.
Bu eski taramada yeniden açılan bağımlılıklar daha sonra aşağıdaki kabul
dilimlerinde kapatıldı. Güncel kuyrukta F09 dahil 58 seçili özellik/toplam67 iş
CI bekliyor; F60/F62 yeniden çalışılıyor ve yalnız FINAL.FUNCTION aktiftir.

F42 gerçek Frigate/FFmpeg yolu ve F57 gerçek mqtt_room yolu odaklı normal Core
ve gerçek Flutter TCP kabulünden geçti. F55'in UID10004 Zigbee2MQTT worker'ı da
unified pakete bağlandı: 26 worker/runtime/MQTT ve 11 paket/runtime testi geçti;
exact `888dfd46f197808f91eaf0f85a4878e15ed27f8e`, run `36762186381`, production
offline kurulum, cross-UID socket/mount ve systemd start sınırını kapattı. Daha
sonraki HEAD, gerçek coordinator/broker ve OTA/radyo davranışı ayrıca açıktır.
Keenetic UID10008
worker normal Core'un `/run/larenor-workers/keenetic` mountu üzerinden gerçek
Unix IPC ve owned TCP RCI fixture kanıtına sahip; gerçek router mutasyonu manuel.
F45'in gerçek Frigate→F54 notification handoff'u `cc01d968` ile commit/push
edildi: restart/lost-ACK dedupe ve commit öncesi kaynak/oturum/kamera yetkisi
odaklı kabulden geçti. Geniş exact CI bekliyor; fiziksel teslim manuel kalır. Native/device
koşulları `MANUAL.*` kayıtlarında kalır. Tam envanterin güncel dal üstündeki
geniş CI'sı ayrıca açıktır.

Sözleşme dayanakları: [rest-server append-only](https://github.com/restic/rest-server),
[restic REST protocol](https://github.com/restic/restic/blob/master/doc/REST_backend.rst),
[NUT 2.8.1 manual](https://networkupstools.org/historic/v2.8.1/docs/user-manual.pdf).
Larenor'un özel append yolunun bu protokolle eşit olduğu varsayılmadı.

Bu envanter kuyruk sayacını değiştirmez. Güncel sayılar yalnız execution queue
tarafından yönetilir; yeni eksikler kapanmadan ve exact CI geçmeden sayaç
artırılmaz, sıradaki FINAL başlatılmaz.

## `awaiting_ci` için kanıta dayalı sınıflandırma

F49 adlandırılmış kabul kanıtı gözden geçirilerek `3a0191b8` ile
`awaiting_ci` durumuna alındı; kabul sayaçları artırılmadı. Adlandırılmış
`docs/testing/f49-normal-core-tcp-acceptance-2026-09-30.md` kapısı 27 Server,
13 Flutter ve gerçek Flutter Client→normal `create_app` Core→owned TCP Home
Assistant/OpenSprinkler runnerını geçirdi; tek gönderim, kayıp ACK readback,
restart ve authority/session driftte sıfır mutation kapsanır. Açık kalan genel
Flutter Web signed-64 derlemesi geniş CI kapısıdır; F49 provider veya normal
composition boşluğu değildir.

F12 dilimi root review ve bağımsız yeniden doğrulamadan sonra aynı sınıfa alındı: 20 odaklı
test normal Core grant/HTTP yolunu, required lifecycle bildirimi, live revoke,
restart, JSON-RPC hataları ve ortak parser sınırlarını çalıştırdı. Ayrıca
disposable exact-version ortamındaki official Python MCP SDK 2.2.0 gerçek
Uvicorn TCP üstünde aynı initialize→notification→tools/list akışını ve revoke
sonrası 401'i gözledi. Standart OAuth
discovery desteklenmediği ürün sözleşmesinde açıkça yazılıdır; preconfigured
Larenor grant kullanan istemci yolu gerçek ve bağlıdır.

F33 adlandırılmış gerçek Flutter→normal Core TCP ve ayrı Core/Client restart kabulünü geçti. Kiler transaction/receipt ve Client digest hataları giderildi; 7 Server, 17 Flutter ve iki gerçek Client fazı doğrulandı. F33 `awaiting_ci` durumundadır; tablet/native notification kapıları ayrıca açıktır.

F46 adlandırılmış gerçek Flutter→normal Core→owned evcc TCP ve ayrı Core/Client restart kapısını geçti. 26 Server, 11 Flutter ve iki gerçek Client fazı tek upstream POST/lost ACK/readback davranışını doğruladı; F46 `awaiting_ci` durumundadır.

F40 adlandırılmış gerçek Client→normal Core ve ayrı restart kapısında tek catalog/create/cancel journal etkisini ve stale transport receipt uzlaşmasını doğruladı; `awaiting_ci` durumundadır.

F48 adlandırılmış gerçek Client→normal Core→owned evcc üç fazını ve 49 ilişkili Server testini geçti; etkilenen F46 gerçek runnerı root tarafından tekrar doğrulandı. Exact critical-load policy, son I/O actor/home/session drift, tek 6A/4140W readback ve restart hold kanıtıyla `awaiting_ci` durumundadır.

F59 authenticated service catalog ve inline Client kayıt akışı tamamlandı; job/material/safety taze gerçek provider GET gözleminden türetilir. Stable registration replay, mid-I/O admin revoke, tek pause dispatch/readback ve iki ayrı normal Core/Client ömrü root doğrulamasını geçti. `awaiting_ci`; filament grams/safety bilinmiyorsa unknown/null, fiziksel yazıcı ve broad CI kapıları ayrı.

F20 adlandırılmış gerçek Flutter→normal Core TCP iki yaşamında pin/compare/rotate ve restart doğrulamasını geçti. Gerçek HMAC tamper sonrası startup fail/no reset root tarafından doğrulandı; exact checkpoint query transport boşluğu kapandı. `awaiting_ci`; fiziksel secure-storage ve geniş exact CI ayrı.

F19 iki bağımsız gerçek Core, gerçek Client registry ve owned Jellyfin TCP iki fazında kabul edildi; `awaiting_ci`. F37 incelemesinde bulunan edit history eksikliği aşağıdaki immutable correction dilimiyle kapandı; güncel durumu `awaiting_ci`dir.

F13 actual Client→normal Core→owned RFC1918 HA iki yaşamında configure/restart/revoke ve exact iki GET/sıfır üçüncü çağrı kapısını geçti; `awaiting_ci`. Fiziksel ağ ve broad exact CI açık kalır.

F04 gerçek Client/normal Core/owned HA iki yaşamında manual→rule suppression, durable receipt ve exact replay kapısını geçti. Provider exact bir POST kalır; external observation non-authoritative. 5 Server/analyze geçti, root F04/F26 9 focused testi doğruladı; geniş exact CI bekler. Kanıt: `f04-normal-core-rule-arbitration-2026-09-30.md`.

F26 gerçek adapter/controller→normal Core→production JellyfinClient PlaybackInfo kapısında exact bir authenticated negotiation POST yaptı; playback mutation yok. 4 Server, 3 Flutter, Android bridge JVM/analyze geçti; Client 6/12/7 bounds kapalıdır. Reported evidence verified sayılmaz; geniş CI ve fiziksel codec/HDR/ağ açık. Kanıt: `f26-normal-core-playback-quality-2026-09-30.md`.

F21 gerçek iki Client→normal Core→MediaArchiveReadCollector→owned authenticated provider kapısı geçti. Explicit leader rejoin eski family bağını atomik yeniler; eski family reddedilir. 29 Python, prepare/restart gerçek Flutter fazları/analyze temiz; provider kapalı restartta sıfır ek I/O. Broad CI ve fiziksel receiver gecikmesi manuel. Kanıt: `f21-normal-core-acceptance-2026-09-30.md`.

F05 normal Flutter Client/Core/HA iki yaşam actual runnerı iki kez geçti: approval causal readback ve exact replay/cancel tek POST korur. 7 Server, 2 Flutter/analyze; root related 80 Server doğruladı. Broad CI ve household partial-effect açık. F52 public secondary-display normal Core, F53 profile/runtime ve F54 WorkManager TLS worker composition kapıları artık geçti; geniş CI ile fiziksel DeX/tablet/notification koşulları ayrı kalır.

F37 immutable correction/terminal balance/payment/export actual normal Client/Core iki yaşamı geçti. Read postflight, filtered superseded metadata, explicit departed-share editor ve inactive payer düzeltildi; bağımsız review blockers kapandı. 19 Server, 15 Flutter, iki TCP fazı, gerçek Chrome 2 ve analyze temiz. Broad exact CI açık; `f37-normal-core-expense-corrections-2026-09-30.md`.

## Son composition ve bağımlılık uzlaşması

- Host-worker open/socket/mount/start: exact
  `888dfd46f197808f91eaf0f85a4878e15ed27f8e`, run
  `36762186381`, production offline bundle ve installed Core ile dört gerçek
  cross-UID IPC/systemd vakasını geçti. Bu named exact kanıttır; sonraki HEAD
  için geniş CI sonucu değildir.
- F08: exact `09a912b4`, run `36750577813`, ayrı UID/cgroup
  dispatch/cancel/readback/stress/release kapısını geçti. Gerçek model kalitesi
  ve hedef donanım davranışı MANUAL kalır.
- F47: root gerçek Flutter Client→normal Core TCP→owned evcc/HA provider iki
  yaşamını geçti; yalnız bir yüzde 40 reserve POST, causal readback, restart ve
  stale resource revisionda sıfır ek write doğrulandı.
- PRODUCT.APPLETV root tarafından 67 focused testle geçti. PRODUCT.CAMERA root
  kapısı 30 test ve scoped analyze geçti. K09 gerçek normal-Core/TLS-MQTT
  kapısını root bağımsız tekrarladı; delayed-CONNACK/successor incelemesi, 25 focused test ve tam Flutter analyze temiz.
- F61/F62 managed-profile normal Core authority kapısı root tarafından geçti;
  shared focused subset 34 testti. Hosted native durum hâlâ kırmızı/pending:
  F61 runs `36764619917` ve `36765832888` production bridge testinden önce;
  F62 run `36765836443` instrumentation başlamadan önce durdu.
- F63 local normal Core/OpenSSH kanıtı geçti. Hosted run `36765828318` gerçek
  zero-prompt MFA hatasını buldu ve düzeltme yapıldı; run `36767901119` fixture'a
  ulaştı ancak `uv` bulunmadığı için normal-Core kabulünden önce durdu. Pinned
  setup sonrası yeni exact hosted receipt gerekir.

## Kalan somut yazılım ve kanıt boşlukları

1. **F22 — CI bekliyor:** kalıcı occurrence dispatcher, bearer bağımsız current family/user revision authority ve final receipt cancellation gate bağlandı. Root gerçek Client/Core/Jellyfin iki yaşamı, F22 35/ortak F22-F28 46 Server ve scoped analyze geçti. Handoff sonrası belirsiz etki replay edilmez; fiziksel receiver MANUAL ayrı.
2. **F28 — CI bekliyor:** durable deadline pause/production Unix IPC/taze provider medya readback bağlandı. Root gerçek Client/Core iki yaşamı, ortak 46 Server/37 Flutter ve scoped analyze geçti; effect/receipt arası takeover409 ve lost-ACK unknown/no replay korundu. Fiziksel receiver MANUAL ayrı.
3. **F47 — CI bekliyor:** recorded socTemp history ve current reserve karşılaştırması normal Core API/Client UIye bağlandı. Root 18 Server, F47/F28 ortak 37 Flutter, scoped analyze ve gerçek Client/Core/evcc/HA iki yaşamını geçti. Tarihsel policy/capacity/manual preference ve sürekli reserve uyumu bilinmiyor olarak korunur; fiziksel inverter MANUAL ayrı.
4. **F60 — yeniden çalışılıyor:** Exact Moonlight12.2 source/package ve iki byte-identical AAR, gerçek izole APK link/DEX/ABI kanıtı root tarafından doğrulandı (6 paket testi). Üretim Client pairing/catalog, Core v2 ve scoped native runtime entegrasyonu 1 Ekim odaklı kabulüyle bağlandı. Açık kalan kapı gerçek owned Sunshine discovery/iki yayın yaşamı/frame/full PCM/touch/gamepad/kopuş/local retirement receiptidir; paket kanıtı bu etkileri veya CI bekliyor durumunu kurmaz. [Kanıt](f60-moonlight-android-package-2026-09-30.md).
5. **F61 — CI bekliyor:** run36783304533 exactf83deee786ef0ce4f47a9beccbb6c3f0ed8bdea7 gerçek TigerVNC1.13.1 X509Vnc/SPKI/password/frame/input/960×720 resize/retirement/no replay kabulünü yeşil tamamladı. Root original class/method/1test/0skip/0failure/0error canonical receipt eşitliğini doğruladı; 5 gerçek TLS regresyonu ve54 araç testi de geçti. Geniş son HEAD CI ve fiziksel MANUAL ayrıca açık.
6. **F62 — native kanıt bekliyor:** run `36772277001` exact `f5b382ce` her iki AAR/APKyi, NLA host ve emulatoru geçti; named instrumentation çalışıp altı saniyede düştü. Generic saklanan log assertionı göstermedi. Bounded source/package bağlı public failure tanısı root 28 araç testini geçti; yeni exact packaged one-test/no-skip receipt gerekli.
7. **F63 — güçlü named exact CI geçti:** run `36772281257`, exact `f5b382cec7e3d4ced65535e8e538e696fbb3fec6`, gerçek Linux SSH/SFTP/tunnel, normal Core/no-replay, Android APK ve kontrat adımlarını yeşil bitirdi. Root güçlü yedi named test/sıfır skip/sourceRevision receiptini indirdi ve doğruladı. Geniş sonraki HEAD CI ve fiziksel MANUAL ayrıca açık.

K09 ve PRODUCT.CAMERA root bağımsız software kapıları kapandı; CI bekliyor tablosundalar. Bu hosted receipts fiziksel cihaz kanıtı değildir. VNC/RDP/SSH hedef hostları, DeX/IME, kamera donanımı, MQTT broker deploymentı ve household ağ davranışı ilgili `MANUAL.*` kapılarında ayrıca kalır. FINAL.FUNCTION yalnız gerçek yazılım açıkları kapanınca ilerler; ikinci FINAL aktif değildir.

### Önceki native kabul checkpointleri

Aşağıdaki başarısız koşular tarihsel teşhis kanıtıdır. F61 için güncel sonuç yukarıdaki başarılı exactf83deee7 receiptidir; F62 probe kabulü açık kalır.

F61 subsequent exact `2cf908b2` / run `36774361551` completed X509Vnc and returned the first 800×600 frame. The deterministic multicolor fixture repair closes only its initial solid-frame precondition; the full native lifecycle receipt still requires a new hosted run.

Exact 2a585d3c/run36776598508 still failed first-frame diversity. Root reproduced and fixed actual ExtendedDesktopSize control-message/false-frame and screen-ID behavior; 4 real TLS/0skip,49 native/1 intentional Linux skip and9 policy tests passed. A fresh exact TigerVNC receipt remains open; fixture-only inference is superseded.

F62 exact e3ae7cb3/run36776341714 built both AAR/APKs but instrumentation failed with report identity mismatch. Named-method execution remains unproven. Failure-only bounded identity/counts/owned constructor diagnostic repair passed30 tests; success identity/no-skip receipt unchanged. Actual packaged native receipt remains open.

F61 exact a7458639/run36779316558 now fails an owned frame wait at pumpUntil293 rather than the prior first-frame diversity assertion. Which wait timed out is unproven; failure-only source/count diagnostic tests12 passed, without changing the named one-test/no-skip success gate. Actual native acceptance stays open.

F60 Core v2 current-family/one-use grants/canonical catalog/empty-retirement/restart-unknown slice independently passed28focused and59related Server checks. Client/native channel/lifecycle and durable pair/catalog/revoke recovery are still in progress; package or Core proof does not close F60.

F61 exact6b2a7577/run36781108349 source-only frames locate the timeout at resized-frame test line150 (1 executed, 0skip, 1failure). Root passed5 actual TLS/0skip regressions including acceptance consumer intermediate-frame ACK ordering, plus54 workflow/queue/progress tests. This failed run is not CI-wait or done evidence.

F62 latest diagnostic: exact78b28815/run36779907094 safe receipt now establishes one expected class/method/zero skip failure in inspect certificate probe. The unretained raw XML does not prove aggregate shape. Four fixed private probe outcomes preserve public engineUnavailable and TLS/NLA/pinning; strict one-suite/count identity remains. Root 61 Python checks and receipted-AAR Kotlin compile passed; actual packaged NLA/frame/input/resize/clipboard/close acceptance remains open. See [probe diagnostic evidence](f62-probe-diagnostics-2026-10-01.md).

F61 latest acceptance supersedes the failed historical native checkpoints: [run36783304533](https://github.com/ersingundem/larenor/actions/runs/36783304533) exactf83deee786ef0ce4f47a9beccbb6c3f0ed8bdea7 passed the original named method once with zero skips/failures/errors. Root verified the complete canonical public receipt. Real TigerVNC frame/input/resize/retirement acceptance is closed; F61 awaits broad final-HEAD CI and physical MANUAL evidence remains separate.

F62 latest probe result: exactbc65ac5ab55f9d3709660c6bc1dc894d80c93454/run36784045011
original method/1test/0skip/1failure safe receipt identifies
connectionFailureBeforeCertificate. Pinned URI converter/cmdline review found
invalid disabled-channel arguments; production now omits them and checks
setConnectionInfo before connect. The original instrumented method adds two
actual JNI parser assertions for clipboard on/off. Root verified the cached
AAR receipt and compiled production/instrumentation Kotlin (279 tasks); this
does not replace the new owned-host native receipt. F62 stays test pending;
58 selected features/67 total tasks await broad CI and counters are unchanged.
See [URI parser evidence](f62-freerdp-uri-parser-contract-2026-10-01.md).

F62 latest source-bound result: exact1259f39e/run36786452264 original method/1test/0skip/1failure/0error passed actual JNI URI checks and real TLS certificate inspection. Strict request validation then rejected a padded SPKI fingerprint. The production encoder now removes trailing Base64 padding, and the original instrumentation explicitly checks the unchanged canonical 50-character pin contract. Root receipted-AAR production/instrumentation compile (315 tasks) and7 NativeContract tests/zero skips/failures/errors passed. Real changed-source owned-host NLA/frame/input/resize/clipboard/close acceptance remains open; F62 stays implementation-complete/test pending and58 selected/67 total tasks await broad CI. See [canonical SPKI evidence](f62-canonical-spki-pin-2026-10-01.md).

F60 owned Sunshine host hazırlığı pinned Ubuntu paket/TLS/API/Xvfb/PulseAudio/mDNS sınırlarını uygular; root47 host/policy testi geçti. Yeni hosted smoke henüz çalışmadı ve host_ready/streamAccepted=false receipt gerçek Android keşif/eşleme/yayın/girdi/stop/revoke kabulü yerine sayılmaz. F60 yeniden çalışılıyor ve sayaçlar korunur. [Owned host kanıtı](f60-sunshine-owned-host-2026-10-01.md).

F60 current integration: normal Core/Client/native v2 paths, PIN/current authority, durable cleanup and fresh-screen instance identity are wired. Native45/45, Flutter86+1 expected runner-only skip, scoped analyze, verified embedded/default APKs passed; root actual normal Core TCP1/1 and80 tool/queue/progress checks independently passed. Three hosted owned-Sunshine readiness runs produced no receipt; full production NSD/pairing/stream/frame/audio/input/stop/local retirement remains open. The new discovery-only workflow is strict source/package-bound and never calls this a stream acceptance. F60 stays reworking and58 selected/67 total tasks await broad CI. See [integration evidence](f60-moonlight-embedded-integration-2026-10-01.md).

F60 latest host result: exact768a5111/run36791861104 passed canonical owned Sunshine
host_ready receipt (SHA256905cee98), independently verified by root; streamAccepted=false.
The same exact Android discovery run36791864541 never entered instrumentation:
output_must_not_exist came from the workflow pre-created work directory. The narrow
mkdir repair passed7 discovery regression tests/actionlint. Real production NSD and
full pairing/stream/frame/audio/input/stop/local retirement receipts remain open; F60 stays
reworking and58 selected/67 total tasks await broad CI.

F62 latest actual result: exact7f673d55/run36789173329 passed TLS/NLA/SPKI and
first nonzero1280×800 frame, then failed ACK at original source line120 (1test/0skip).
Production ACK/frame race and terminal resurrection repairs passed2 old-behavior RED
regressions and14 fixed native tests/zero skips, plus receipted production/AndroidTest
compile. IME/bidirectional capability truth and current external-display snapshot
corrections remain active; F62 is reworking, broad CI counts58/67 unchanged.
See [ACK lifecycle evidence](f62-frame-ack-lifecycle-2026-10-01.md).

F60 output witness slice: real MediaCodec rendered-frame callbacks and full positive AudioTrack writes are exact-lease/connection/stop fenced, private and bounded to one witness each. Source-locked fresh AAR/APK verification,29 Moonlight and46 combined native tests/zero skips passed; root independently checked7 package tests,4 XML counts and both APK verifiers. This is linkage/lifecycle evidence; real owned-Sunshine frame/PCM observation and physical output remain open. F60 stays reworking,58 selected/67 total await broad CI,37/127 and3/63 acceptance counts are unchanged. See [output witness evidence](f60-moonlight-output-witness-2026-10-01.md).

F62 capability/authentication correction: IME unavailable, explicit conservative clipboard modes, honest credential-free certificate probe and mandatory Client NLA policy are wired. External/default classification drift retires the channel without replay; exact external-display identity is still unrepresented. Only accepted endpoint/SPKI plus real OnConnectionSuccess can publish security and frames; TLS1.2 min/max is enforced. Root22 native/zero-skip tests and315-task production/AndroidTest compile passed;38 RDP Flutter tests/scoped analyze passed. Owned-shadow baseline requires actual HID→XI2 effect, host-originated resize, acknowledged frames and close, and explicitly excludes clipboard/IME/clientDISP/physical keyboard. Changed-source real host and exact display/clipboard acceptance remain open; F62 stays reworking,58/67 await broad CI and37/127,3/63 acceptance counters are unchanged. See [authenticated output](f62-authenticated-output-boundary-2026-10-01.md) and [Client truth](f62-rdp-client-capability-truth-2026-10-01.md).

F62 owned display fixture correction: bare Xvfb resizing was not valid evidence. A direct Xorg dummy display now requires exact single-output CRTC and framebuffer transitions before the AAR build, with candidate-version install/readback. The precreated package directory is handled idempotently;31 runner/workflow checks passed. Actual changed-source hosted Xorg/FreeRDP execution remains open and does not promote the feature. See [owned shadow baseline](f62-owned-shadow-baseline-2026-10-01.md).

F60 primary-source blocker reconciliation: Moonlight GET `/unpair` is absent from the pinned Sunshine NvHTTP routes. The v2 Core/Dart `local_cleared` contract requires real local registration retirement/readback; provider pairing removal is a separate manual Sunshine administrator operation, outside the tablet-only product action. Owned admin teardown never proves product revocation. Discovery run36792376426 at exact04552c7 failed emulator boot before Python/NSD, after the receipted engine build. It proves neither discovery success nor a Sunshine fault. F60 remains reworking and all counters/CI-waiting labels remain unchanged.

F62 partial hosted evidence: exacte05df8ea/run36794954941, package(x86_64), named owned-Xorg preflight completed successfully. Root independently verified exact source and step result. This proves Linux single-output CRTC/root shrink+restore only; full Android/shadow and feature acceptance remain open. Counters/statuses stay unchanged.

F60 changed-source harness now requires usable hosted KVM and supported SwiftShader; the prior boot timeout occurred before provider code. Its named stream gate emits only `streamAndLocalRetirement`, `featureAccepted=false` and `providerPairingRemoved=false`; cancellation unwinds owned resources and strict Avahi stop precedes artifact upload. Root independently passed 95 focused tool/queue/progress checks plus actionlint. New hosted stream acceptance remains open.

## 1 Ekim actual CI hata uzlaşması

Exact0036260b F60 discovery36796250482 ve stream36796253857 engine/KVM
kapılarını geçti; `tool` modülü bulunamadığı için provider workspace, NSD ve
instrumentation başlamadan başarısız oldu.1887ff9a repo-root module çağrısı
ve regresyonlarını taşır; yeni discovery36797303341/stream36797304940 bu exact
kaynak üzerinde başladı. Hosted receipt henüz yoktur.

F62 exacte05df8ea/run36794954941 gerçek Xorg preflightı ve iki ABI APK
buildini geçti; dış XI2 witness ilgisiz UTF8 satırını ASCII çözerken düştü.
Terminal JUnit sayımı yoktur.1887ff9a byte parserı eski kaynağa karşı aynı
RED→GREEN regresyonu geçti; root91 birleşik workflow/runner/kuyruk/progress
kontrolünü ve actionlinti doğruladı. Android frame/key/resize/close kabulü
açık kalır. Bu düzeltmeler sayaçları veya F60/F62 durumunu artırmaz.

The F62 logical-display slice passed root49 Flutter RDP/window cases and13 native Window XML cases without skips/failures/errors. Removed Display objects cannot supply a tuple (`Display.isValid()`), stream closure emits unknown before completion, and tuple changes dispose without automatic reconnect. Scope is observed logical lifecycle only; physical identity and real hosted channel acceptance remain open.

F60 current input/disconnect gate requires two independent real frame/full-PCM
lifetimes, actual Game touch/mouse effects on owned XI2, and termination of the
exact owned Sunshine daemon followed by the second lease's real
`connectionTerminated`. Readiness is observed by the same XI2 process before
input, and its owned probe cannot count as Android input. Root verified
production/AndroidTest compile plus33 native XML tests/zero skips and105
combined tool/workflow/queue/progress checks. Exact1887 discovery36797303341
and stream36797304940 failed the shared bare-emulator identity probe before
provider workspace/NSD/instrumentation/receipt; the SDK-path regression is
old-source RED/current GREEN. New hosted input/disconnect and gamepad evidence
remain open, so F60 remains reworking and58/67 CI-waiting counts do not change.

F62 explicit clipboard software path is connected end to end through Flutter,
strict native admission and the packaged FreeRDP API. Root45 focused Flutter
cases,15 native XML cases/zero skips and full Flutter analyze passed. Foreground
explicit read, strict UTF-8/64KiB, sequence, payload erasure, read/submission
deadlines and successor no-replay are verified. Accepted submission is not
remote clipboard readback; the current NLA shadow fixture lacks cliprdr.
Exact7fccce52/run36797967344 passed initial frame/ACK/key and owned host
resize before its original1test/1failure/0error/0skip result. Five fixed
post-resize diagnostics preserve the original assertions; actual
AGP9.4.1/ddmlib32.4.1 no-type XML is now handled using the exact first throwable
header plus owned test/method/frame fences. Root27 parser tests, exact JAR
hash/bytecode and277-task receipted Kotlin compile record were verified.
Changed-source hosted result is still required. Full hosted channels remain open: F62 is reworking,58/67 await CI,
and37/127,3/63 acceptance counters stay unchanged.


F60 exact2af5e8cc discovery36799033298 and stream36799039362 completed failed
at copyJniLibsflutterBuildDebug: the fresh prebuild had skipped its Flutter JNI
producer. No terminal Android report or receipt exists. The shared real APK
prebuild now completes before provider timers; a subsequent real local build
exposed and corrected Moonlight's runner1.3.0/1.7.0 app/test conflict. Canonical
Moonlight install verification, full app/test APK assembly (400 tasks), and
source-locked APK verification passed. OSC touch must produce exact owned
UHID/evdev BTN_SOUTH down/sync/up/sync before stream stop. Byte-bounded XI2 key
parsing rejects unrelated Motion fields that previously completed a stale
release. These are build and gate-integrity results, not hosted effect receipt.
F60 stays reworking; all acceptance and CI-waiting counters are unchanged.
See [prebuild evidence](f60-apk-prebuild-2026-10-01.md).
