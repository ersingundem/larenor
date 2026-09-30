# Gerçek üretim yolları denetimi — 30 Eylül 2026

Bu envanter test sayısından bağımsız olarak normal Core bileşimini, Client
girişini ve gerçek upstream sözleşmesini inceler. `implemented` önceki kod
durumudur; eksik provider veya bağlantısız UI varsa kapanış kanıtı değildir.
F01–F21 ve F22–F44 iki bağımsız ajan tarafından salt okunur incelendi.

| İş | Somut açık | Düzeltme / kabul |
| --- | --- | --- |
| F01 | Ekranda yalnız metin girişi ve sınırlı taslak parserı | Gerçek ses girişi; açık supported intent sınırı; kullanıcı onayı |
| F02/F03 | Service health zamanı Client tarafından gerçek olay diye gönderiliyor | Server kaynaklı HA event/trace, kimlik/revizyon, bounded history ve replay |
| F07 | Rutin gözlemi Client service-health sayımından geliyor | Gerçek ev gözlemi, server authority ve tekrar/boş veri sınırı |
| F08 | Queued kayıtlar yalnız yanıtta running oluyor; worker consumer/CPU/RAM uygulaması yok | Trusted admission/lease, gerçek dispatch/cancel ve OS limit/readback |
| F10 | Client health/measurement iddiaları supported kanıtı olabiliyor | Registry/provider kimliğini Core çözmeli; Client yalnız seçim/revizyon göndermeli |
| F17 | Özel append endpointinin serverı veya dağıtımı yok | Gerçek append-only backend + readback/recovery |
| F18 | Gerçek Proxmox yürütmesi var, NUT olay producerı dağıtılmıyor | NOTIFYCMD/EXEC bridge, sıralama/tazelik, pinned paketleme; fiziksel UPS kapısı ayrı |
| F22/F25/F27/F28/F29/F30 | Gerçek worker kodu var, unified paket socket/env/mount/başlatma sağlamıyor | Paketlenmiş read/action/music/playback worker bileşimi, gerçek IPC ve normal Core kabulü |
| F23 | Normal Core provider/recorder boş; Client admin source kurulumu yok | Gerçek Live TV/recording providerı ve kaynak UI |
| F24 | İki bağımsız dil-tercih deposu; player yalnız birini okuyor | Tek production store/route, migration ve player kabulü |
| F28 | Ready kullanıcı API'si Client admin filtresiyle erişilemiyor | Role uyumlu gezinme, UI ve gerçek worker |
| F35 | Upload gerçek, OCR adayı daima null | Bounded gerçek OCR, kullanıcı onayı, hata/iptal |
| F51 | Viewer/action var, Client yerleştirme yok | Admin gerçek catalog, bütün registry revizyon CAS, mevcut geometry onarımı ve erişilebilir inline editor |

F04–F06, F09, F11–F16 ve F19–F21'de bu tarama yeni dummy/ölü normal
production yolu bulmadı. Bu gözlem kapsamlı CI veya fiziksel cihaz kabulünün
yerine geçmez. F15 configured component worker gerektirir; F16 effect-disabled
geçici Core restore çalıştırır; F21 player raporu ve yerel playback/seek uygular.
F09 ve diğer yeniden açılan görevlere bağlı işler bağımlılık kapanana kadar
kuyrukta pending kalır; tamamlanan kod dilimleri silinmiş sayılmaz.

F42 gerçek Frigate/FFmpeg yolu ve F57 gerçek mqtt_room yolu odaklı normal Core
ve gerçek Flutter TCP kabulünden geçti. F58 OpenEPaperLink yolu geliştiriliyor.
F45–F63 kök ajan incelemesinde F51 açığı bulundu; native/device koşulları
`MANUAL.*` kayıtlarında kalır. Tam envanter ve exact commit geniş CI açık.

Sözleşme dayanakları: [rest-server append-only](https://github.com/restic/rest-server),
[restic REST protocol](https://github.com/restic/restic/blob/master/doc/REST_backend.rst),
[NUT 2.8.1 manual](https://networkupstools.org/historic/v2.8.1/docs/user-manual.pdf).
Larenor'un özel append yolunun bu protokolle eşit olduğu varsayılmadı.

Kullanıcının ek Core web UI teslimi kuyruğa işlendi: 37/127 (%29,1) iş,
3/63 (%4,8) seçili özellik kabul edilmiş durumda. Yeni eksikler kapanmadan ve
exact CI geçmeden sayaç artırılmaz; sıradaki FINAL başlatılmaz.
