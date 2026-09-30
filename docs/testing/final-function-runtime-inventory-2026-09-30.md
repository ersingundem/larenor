# Gerçek üretim yolları denetimi — 30 Eylül 2026

Bu envanter test sayısından bağımsız olarak normal Core bileşimini, Client
girişini ve gerçek upstream sözleşmesini inceler. `implemented` önceki kod
durumudur; eksik provider veya bağlantısız UI varsa kapanış kanıtı değildir.
F01–F21 ve F22–F44 iki bağımsız ajan tarafından salt okunur incelendi.

| İş | Somut açık | Düzeltme / kabul |
| --- | --- | --- |
| F01 | Kapanmış: Android on-device STT/TTS ve güncel HA hedefli taslak/confirm akışı bağlandı | 10 native + 11 Flutter + 3 Server + 1 gerçek Flutter→normal Core→TCP HA kapısı geçti; model/cihaz ve exact-head CI açık |
| F02/F03 | Kapanmış: normal Core gerçek HA registry ve trace/list/get kaynağını kullanıyor; Client gerçek olay iddiası kabul edilmiyor | 8 Server + 2 Flutter loopback + 1 gerçek Client→normal Core→HA WS kapısı geçti; uzun gerçek geçmiş/DST ve exact-head CI açık |
| F07 | Kapanmış: authenticated HA entity registry + bounded REST history, sealed provenance ve yeterli-baseline kapısı var | F07/F10 ortak kapısında 13 Server + 1 gerçek Flutter→normal Core→HA TCP/WS geçti; household baseline kalitesi manuel |
| F08 | Kapanmış production composition: Docker Core→özel IPC→UID10003 worker→systemd user-manager cgroup dispatch/cancel/readback yolu paketlendi | 42 Server + 6 package geçti, 3 gerçek Linux kapısı macOS'ta skip; zorunlu Ubuntu cgroup stress/exact-head ve gerçek model açık |
| F10 | Kapanmış: Core registry/provider kimliğini ve history'yi çözüyor; arbitrary Client sources sentetik ve repair preview-only | F07/F10 ortak 13 Server + gerçek Flutter/normal Core/HA kapısı geçti; fiziksel diagnosis doğruluğu manuel |
| F11 | Açık: v2 Server/Client sözleşmesinden uygulanmayan CPU 50 ms/1 MiB iddiası kaldırıldı; renderer gerçek 1 KiB çıktı sınırını korur | Tam CPU/bellek izolasyonlu runtime hâlâ geliştirmede; 4 Server/4 Flutter ve analyze geçti, stop/tamper/ev sınırı korunur |
| F12 | Kapanmış transport/lifecycle: custom bearer JSON-RPC route `notifications/initialized`→empty 202, bounded protocol negotiation/standard `_meta`, Origin/protocol header kontrolü ve standart JSON-RPC hata zarflarını uygular | 8 F12 + 12 ortak boundary testi ve normal Uvicorn Core'a bağlanan official Python MCP SDK 2.2.0 initialize→initialized→tools/list→live revoke kapısı geçti. Yetki bilinçli olarak admin-provisioned bearer + exact client header'dır; OAuth Protected Resource Metadata/`WWW-Authenticate` yoktur ve generic OAuth istemci uyumu iddia edilmez |
| F17 | Kapanmış: ayrı TLS append hedefi ve dağıtımı eklendi | `append-target.compose.yaml`; 7 Server + 38 Flutter + 12 boundary odaklı kanıt. Ayrı fiziksel hedef ve disaster restore manuel kalır |
| F18 | Kapanmış: UID10006 NUT producer ve UID10005 Proxmox worker paketlendi | Normal Core `/run/larenor-workers/proxmox` bileşimi; 75 focused + 8 package geçti, 2 hosted-Linux kapısı yerelde dürüstçe atlandı. Fiziksel UPS/Proxmox etkisi manuel |
| F22/F25/F27/F28/F30 | Kapanmış: unified read/action/music/playback/archive worker socket, mount ve başlatma bileşimi var | Her özellikteki adlandırılmış normal-Core/worker kanıtı korunur; exact-head Linux ve gerçek provider/cihaz kapıları ayrı |
| F29 | Kapanmış: Party DJ gerçek `MusicPlaybackRuntime` ile normal Core'dan owned TCP Music Assistant fixture'ına gidiyor | 35 testlik adlandırılmış kapı restart, duplicate vote, quorum, lost-ACK no-replay ve `needs_attention` davranışını geçti; gerçek receiver eşzamanlılığı manuel |
| F23 | Kapanmış: normal Core gerçek Jellyfin guide/timer provider/recorderını ve inline admin source setup'ı kuruyor | 8 Server + 1 gerçek Flutter→normal Core TCP→Jellyfin geçti; tuner/storage ve exact-head CI açık |
| F24 | Kapanmış: legacy ve aktif player route tek AES-GCM kişi deposunu kullanıyor; authenticated migration atomik | 10 Server + 8 Flutter + 1 gerçek Flutter→normal Core TCP geçti; gerçek track/rendering manuel |
| F28 | Kapanmış: ready ev üyesi discovery, refresh, catalog ve playback/longform yollarına admin olmadan erişiyor | 35 Server + 24 Flutter + 1 gerçek Flutter→normal Core→production HTTP runtime→TCP Music Assistant geçti; provider/receiver manuel |
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
gerçek coordinator/OTA ile hosted-Linux kanıtı ayrıca açık. Keenetic UID10008
worker normal Core'un `/run/larenor-workers/keenetic` mountu üzerinden gerçek
Unix IPC ve owned TCP RCI fixture kanıtına sahip; gerçek router mutasyonu manuel.
F45'in gerçek Frigate→F54 notification handoff'u `cc01d968` ile commit/push
edildi: restart/lost-ACK dedupe ve commit öncesi kaynak/oturum/kamera yetkisi
odaklı kabulden geçti. Geniş exact CI bekliyor; fiziksel teslim manuel kalır. Native/device
koşulları `MANUAL.*` kayıtlarında kalır. Tam envanter ve exact commit geniş CI
açıktır.

Sözleşme dayanakları: [rest-server append-only](https://github.com/restic/rest-server),
[restic REST protocol](https://github.com/restic/restic/blob/master/doc/REST_backend.rst),
[NUT 2.8.1 manual](https://networkupstools.org/historic/v2.8.1/docs/user-manual.pdf).
Larenor'un özel append yolunun bu protokolle eşit olduğu varsayılmadı.

Kullanıcının ek Core web UI teslimi kuyruğa işlendi: 37/127 (%29,1) iş,
3/63 (%4,8) seçili özellik kabul edilmiş durumda. Yeni eksikler kapanmadan ve
exact CI geçmeden sayaç artırılmaz; sıradaki FINAL başlatılmaz.

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

F33, F40, F46, F48 ve F59 henüz bu sınıflandırmayı karşılamaz. F33'ün 17
Flutter/6 Server sonucu için adlandırılmış birleşik normal-Core runner yoktur.
F40'ın Core ve Flutter kapıları ayrı seamlerdir. F46 ve F48'in kendi kanıt
dokümanları tam Client→normal Core→servis kabulünü açık bırakır. F59'un canlı
kuyruk gerekçesi de birleşik Client→Core→provider yolunu açık bırakır. Bunları
sırf test sayısı veya dosya varlığı nedeniyle ilerletmek doğru olmaz.
