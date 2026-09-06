# Keenetic mevcut alt ekranlarında işlem yetkisi sınırı

Bu yerel dilim, Wi-Fi kapatma onayı ile cihaz/port yönlendirme okuma ekranlarının eski hesap veya pencere yetkisiyle işlem yapmasını engeller. Yeni router işlemi, yeni ağ API'si veya otomatik kurulum eklemez.

## Kaynak ve sahiplik

- İzole çalışma ağacı: `/private/tmp/larenor-keenetic-operational-actions`.
- Dal: `codex/direct-keenetic-operational-actions`.
- Başlangıç: `dc87062fcc606487964780d813702eaab8ab5604` — önceki Keenetic bağlantı/store pilotunun dondurulmuş yerel kaynağı.
- Son üretim/test checkpoint: `bd112f2744debdba7a09557a8c5d4cfd00a6923e`; önceki bağımsız kaynak incelemesi `fb77dea` için CLEAR, son üretim farkı blok parantezleri ve mevcut kontrolün açık `mounted` koşuludur.
- Üretim kapsamı: `keenetic_wifi_screen.dart`, `keenetic_devices_screen.dart`, `keenetic_port_forwarding_screen.dart` ve yeni `keenetic_session_guard.dart`.
- Test: `test/features/keenetic/keenetic_operational_boundary_test.dart`.
- Ortak auth/provider/client/MediaSessionState/HomeSessionScope API'ları ve Server değişmedi. Ana dal, CI, kurulum ve gerçek router bu çalışmada değiştirilmedi.

## Uygulanan davranış

`KeeneticSessionState`, mevcut `MediaSessionState` ile Direct kaynak yetkisini birlikte kontrol eder. Doğrulanmış mevcut Keenetic yapılandırması, yakalanmış kaynak nesnesi, hesap/görünürlük nesli ve callback anındaki route/TickerMode geçerliliği gerekir. Hesap yükleniyor, bozuk veya yokken alt ekran bağlantı formu başlatmaz; mevcut kök ekranın PIN korumalı yeniden bağlantı yolu kullanılır.

Wi-Fi kapatma onayı yalnız kendisine ait hâlen üstteki modal route tarafından tamamlanabilir. İptal, onay ve hata penceresinin Tamam callback'i tüketildikten sonra alttaki sayfayı kapatamaz. Görünürlük, odak veya hesap kaybında yetki eşzamanlı düşer; Navigator'dan modal kaldırma işlemi framework build evresine müdahale etmemek için frame sonuna bırakılır.

Geçerli onay, zaten hazır olan aynı client üzerinden mevcut tek RCI batch'ini gönderir: doğrulanmış `WifiMasterN/AccessPointN` arayüzü için `up`/`down` ve `system configuration save`. İstek sonrası gelen sonuç yalnız aynı ekran/hâlâ geçerli client tarafından işlenir. Daha önce gönderilmiş komutun router'da geri alındığı iddia edilmez. Cevap gelene kadar aynı arayüz için ikinci işlem engellenir; istemci mutasyonları otomatik yeniden göndermez ve bağlantı kaybını başarı saymaz.

Cihaz listesi yenileme, arama/filtre callback'leri ve ayrıntı açma; port yönlendirme yenilemesi aynı yerel yetkiyi kullanır. Ayrıntı route'u eski hesap değiştikten sonra eski cihaz IP/MAC bilgisini göstermeyi bırakır. Cihaz ve port yönlendirme ekranları salt okunur kalır.

## TDD kanıtı

| Aşama | Checkpoint | Gerçek sonuç |
| --- | --- | --- |
| Eski onay/okuma/cihaz ayrıntısı | `0b2c885` RED | 2 PASS / 9 FAIL |
| İlk yetki koruması | `b280a44` GREEN | 14 PASS; 11 yeni ve 3 mevcut ekran testi |
| Tüketilmiş onayın tekrar çağrılması | `024191b` RED | 1 FAIL; ikinci callback Wi-Fi sayfasını kapatıyordu. Öncesindeki genişletilmiş 35 test PASS |
| Modal kimliği ve üst route bağı | `fb77dea` GREEN | 39 PASS; 36 boundary ve 3 mevcut ekran testi |

Son odaklı paket 202 PASS içerir: 39 yeni operational boundary testi ile önceki 163 Keenetic/store/client testi. Native odak, idle, uygulama arka planı, TickerMode, başka route, hesap değişimi/reload/logout, disposal ve Core kaynak değişiminden sonra yakalanmış onay komut göndermez. Geçerli dönüşte yeni onay çalışır. İlgisiz native view olayı geçerli onayı düşürmez. Gerçek SettingsGate PIN yolunda iptal sıfır POST; yeni açık onay yalnız mevcut batch ile bir POST gönderir.

Ek kanıtlar: Core/pending/error kaynaklarında üç alt ekranın sıfır credential okuması ve sıfır HTTP; canlı tutulan eski Direct container'ın Core altına taşınmış gerçek GlobalKey ekranı yetkilendirememesi; gönderilmiş komutun geç 200/401/transport sonucundan sonra sıfır otomatik tekrar/yenileme/hata modalı; geçerli aktif hata yolunun hâlâ açık hata göstermesi; bozuk arayüz kimliğinin işlem sunmaması; eski yenilemenin reddedilmesi ve yeni yenilemenin çalışması.

EN/TR, 600/1200 genişlik, açık/koyu, 2x yazı ölçeği için sekiz gerçek bundled Inter testi, mevcut onay metninin taşmamasını, en az 48 yüksekliğinde dialog eylemlerini ve Escape ile komut göndermeden çıkışı doğrular. Bu, tüm Keenetic ekranlarının son tasarım veya fiziksel tablet kabulü değildir; README galerisine görüntü eklenmedi.

## Yerel doğrulama kayıtları

Tüm Flutter/Dart komutları ortak `/private/tmp/larenor-flutter-check.py` kilit sarmalayıcısıyla çalıştırıldı.

- RED: `/private/tmp/larenor-keenetic-operational-red.log`.
- İlk GREEN: `/private/tmp/larenor-keenetic-operational-green.log`.
- İkinci RED/GREEN: `/private/tmp/larenor-keenetic-operational-consumed-{red,green}.log`.
- 202 PASS: `/private/tmp/larenor-keenetic-operational-final.log`.
- Son geniş regresyon: **1047 PASS / 49 saniye**; `test/core`, Keenetic, Settings, Navigation ve Health. Kayıt: `/private/tmp/larenor-keenetic-operational-broad.log`.
- Son geniş koşuda dört üretim dosyasının satır kapsamı: **336/376 (%89.36)**; ortak guard 38/38. Kayıt: `/private/tmp/larenor-keenetic-operational-final-coverage.info`.
- Beş dosya analiz: `/private/tmp/larenor-keenetic-operational-analyze.log`; sıfır sorun.
- Dar format: `/private/tmp/larenor-keenetic-operational-final-format.log`.

Sentetik secure-storage platformu ve gerçek üretim HTTP client yolu üzerinden `MockClient` kullanıldı. `.invalid` adresler ve dokümantasyon IP'leri dışında router/LAN adresi kullanılmadı. Bu yerel checkpoint için yeni CI, imzalı APK veya fiziksel router kabulü iddiası yoktur. Önceki bağlantı pilotu ile bu operasyonel alt ekran dilimi ayrı kanıtlardır; S08.4 bütünü tamamlanmış sayılmaz.
