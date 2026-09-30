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
| F28 | Catalog/member/playback alt dilimi kapandı; deadline pause/stop yazılımı açık | 35 Server + 24 Flutter + gerçek normal Core/provider gate catalog/resume kanıtıdır; sleep enforcement ve restart/arka plan uygulanmadan F28 kapanmaz |
| F35 | Kapanmış: encrypted blob→bounded Poppler/Tesseract OCR, source/confidence binding ve ayrı kullanıcı onayı var | 24 Server + 14 Flutter + 1 gerçek Flutter→normal Core→actual OCR + 21 container policy geçti; image/exact-head ve fiziksel belge açık |
| F51 | Kapanmış implementation: admin gerçek catalog/four-revision CAS ve erişilebilir inline floor/room/device editor var | 9 Server + 13 Flutter ve iki gerçek Client→normal Core→TCP HA fazı geçti: tek mutation/replay, CAS repair ve restart; exact-head CI ve fiziksel ölçüm açık |

F04–F06, F09, F13–F16 ve F19–F21'de bu tarama yeni dummy/ölü normal
production yolu bulmadı. Bu gözlem kapsamlı CI veya fiziksel cihaz kabulünün
yerine geçmez. F15 configured component worker gerektirir; F16 effect-disabled
geçici Core restore çalıştırır; F21 player raporu ve yerel playback/seek uygular.
F09 ve diğer yeniden açılan görevlere bağlı işler bağımlılık kapanana kadar
kuyrukta pending kalır; tamamlanan kod dilimleri silinmiş sayılmaz.

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

F19 iki bağımsız gerçek Core, gerçek Client registry ve owned Jellyfin TCP iki fazında kabul edildi; `awaiting_ci`. F37 kabulündeki edit history eksikliği gerçek kod incelemesinde bulundu ve yalnız bu özellik aktif geliştirmeye alındı; ödeme/create/export varlığı tam kabul sayılmaz.

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

1. **F22 — yeniden çalışılıyor:** `personal_channels/service.py` yalnız programme resolve, Client route tek playback isteği yapıyor. Otomatik sonraki programme yürütücüsü ve gerçek Client→normal Core→provider kesintisiz kanal kabulü eksik. Mevcut worker/package kanıtı bu davranışı kanıtlamaz.
2. **F28 — yeniden çalışılıyor:** `longform_sessions/service.py` `sleepTimerEndsAt` değerini doğrular ve saklar; sürede yetkili pause/stop, restart ve arka plan kapanışı yok. Fiziksel receiver kontrolü bu eksik yazılım yerine sayılamaz.
3. **F47 — yeniden çalışılıyor:** normal reserve/source/authority akışı gerçek iki yaşamda geçti. Ancak kuyruktaki geçmiş/backtest minimum rezerv kabulü için API/UI yok; alt dilim kanıtı korunur.
4. **F60 — yeniden çalışılıyor:** Sunshine Core host API var, Client kayıt/eşleme UI yok; `MoonlightAppGameStreamEngine.kt` handoffOnly/zero-intent/unsupported durumda. Native playback/input hazır sayılmaz.
5. **F61 — native kanıt bekliyor:** run `36769953343` exact `f1713f65` fresh Gradle launcherı geçti ancak generated Flutter outputs olmadan normal app derlemesi native testten önce durdu. Kilitli pub→l10n→build_runner önkoşulları ve exact class/method bir test/sıfır skip receipt uygulanır; yeni gerçek hosted sonuç gerekir.
6. **F62 — native kanıt bekliyor:** run `36768544534` exact `ebf00c06` her iki AAR/APKyi oluşturdu, NLA host/emulator başladı. Android test runtime classpath `androidx.test:runner` 1.7.0 ile app strict 1.3.0 çatışması instrumentationdan önce durdurdu. Dar dependency fix ve yeni exact packaged one-test/no-skip receipt gerekli.
7. **F63 — named eski exact CI geçti:** run `36769844212`, exact `1dd8ca98a3c22ba66b30c57c632ba0cfea423636`, gerçek Linux SSH/SFTP/tunnel, normal Core/no-replay, Android APK ve kontrat adımlarını yeşil bitirdi. Daha güçlü yedi named test/sıfır skip/sourceRevision receipt ve geniş sonraki HEAD CI ayrıca doğrulanacak.

K09 ve PRODUCT.CAMERA root bağımsız software kapıları kapandı; CI bekliyor tablosundalar. Bu hosted receipts fiziksel cihaz kanıtı değildir. VNC/RDP/SSH hedef hostları, DeX/IME, kamera donanımı, MQTT broker deploymentı ve household ağ davranışı ilgili `MANUAL.*` kapılarında ayrıca kalır. FINAL.FUNCTION yalnız gerçek yazılım açıkları kapanınca ilerler; ikinci FINAL aktif değildir.
