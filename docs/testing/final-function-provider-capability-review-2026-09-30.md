# FINAL.FUNCTION sağlayıcı ve gerçek dünya yetenek incelemesi — 30 Eylül 2026

Bu inceleme F01–F63'ün yalnız Larenor kaynak kodunda adlandırılmış olmasını
kabul kanıtı saymaz. Her dış entegrasyon için sağlayıcının resmî belgesinde
gerçek bir protokol, işlem veya çalışma koşulu arandı. Resmî belge yalnız dış
sistemin bu yeteneği sunduğunu kanıtlar; Larenor uygulamasının doğruluğunu ise
odaklı testler, tam paketler ve exact-head CI kanıtlar. Fiziksel cihaz, özel ev
ağı, gerçek hesap, ücretli sağlayıcı ve OEM davranışı `MANUAL.*` kapılarında
kalır.

## Sonuç

- **63/63 özellik için gerçek bir ürün veya protokol dayanağı belirlendi.**
  Larenor'a özgü hakem, günlük, iş akışı, rezervasyon ve planlama davranışları
  dış üründe varmış gibi gösterilmedi; bunlar doğrulanmış dış veri/komut
  yüzeyleri üstündeki Larenor işlevleridir.
- **Deneysel yüzeyler üretim garantisi sayılmadı.** evcc yük yönetimi ve
  optimizer belgelerinde deneysel olarak işaretlidir; F47–F48 bu nedenle
  danışmanlık, görünür plan ve geri bildirim sınırını korur.
- **Donanım ve istemci farkları saklanmadı.** Jellyfin çevrimdışı indirme ve
  giriş/kapanış atlama desteği istemciye göre değişir; Frigate semantik arama
  en az 8 GB RAM ve belirli CPU özellikleri ister; Android bağlı ekran, OEM
  arka plan ve RDP/VNC/SSH uçtan uca kabulü gerçek cihaz kapılarında kalır.
- **Belge kalitesi de bir sınırdır.** Audiobookshelf API sayfası kendi
  belgesinin güncel tutulmadığını bildirir. F28 bu nedenle sürüm sabitleme ve
  gerçek sağlayıcı kabulü olmadan tamamlanmış dış uyumluluk iddiası taşımaz.

## F30 üretim sözleşmesi incelemesi

Unmanic 0.4.1'in resmî kaynak sözleşmesi Larenor'daki ilk F30 iddiasını
daraltmayı gerektiriyor:

- `POST /unmanic/api/v2/pending/test` yalnız dosyanın karar eklentilerince
  kuyruğa uygun olup olmadığını döndürür; çıktı boyutu veya tasarruf garantisi
  değildir.
- `POST /unmanic/api/v2/pending/create` dosyanın Unmanic dosya sisteminde
  bulunmasını ister. Jellyfin item kimliği doğrudan Unmanic yolu değildir;
  yetkili Jellyfin yeniden okuması, açık mount çevirisi ve izin verilen kök
  denetimi gerekir.
- İç görev modeli `creating`, `pending`, `in_progress`, `processed` ve uzak
  görevlerde `complete` değerlerini kullanır; ancak public
  `/pending/status/get` başarı alanını döndürmez. Yerel terminal iş task
  tablosundan silinip yeni bir history satırına taşınır ve public history
  çıktısı gönderilen pending kimliğiyle dayanıklı bir bağ sunmaz. Bu nedenle
  “pending kaydından kayboldu” başarı kanıtı değildir; exact terminal makbuz
  için sabitlenmiş bir Larenor callback eklentisi veya adapter gerekir.
- Çalışan görev için atomik job-id iptal ucu yoktur. Pending satırını silmek
  veya durum okumasından sonra worker'ı sonlandırmak görev kimliğine bağlı bir
  iptal makbuzu değildir ve yarış koşulu taşır.
- Unmanic API'si iş başına “orijinali koru” veya duplicate/retention silme
  işlemi sunmaz. Korunan kopya, kota, ayrı cleanup onayı ve sonuç uzlaştırması
  Larenor worker'ının gerçek ve kalıcı davranışı olmalıdır. Varsayılan
  postprocessor çıktıyı kaynak üzerine taşıyabilir veya başarılı farklı hedef
  taşınmasından sonra kaynağı silebilir; Larenor ayrı kopyayı submission'dan
  önce checksum, boyut ve kaynak kimliğiyle doğrulamalıdır.
- Unmanic'in yerleşik kimlik doğrulaması yoktur; API özel ağda veya kimliği
  doğrulayan reverse proxy arkasında kalmalıdır. Jellyfin 12 eski token
  header'larını varsayılan olarak kapatır; Larenor güncel `MediaBrowser`
  Authorization header'ını ve mümkün olan en dar kullanıcı tokenını kullanır.
- Jellyfin `Path` alanı network path substitution uygulanmış olabilir. Sunucu
  açık bir Jellyfin-prefix → Unmanic-mount eşlemesi uygulamalı, canonical yolu
  izin verilen kökte ve gerçekten var olarak doğrulamalı; istemciden dosya yolu
  kabul etmemelidir.

Kaynaklar: [Unmanic 0.4.1 sürümü](https://github.com/Unmanic/unmanic/releases/tag/0.4.1),
[pending API uygulaması](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/webserver/api_v2/pending_api.py),
[task durum modeli](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/libs/task.py),
[terminal callback verisi](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/libs/postprocessor.py#L378-L404),
[worker iptal yüzeyi](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/webserver/api_v2/workers_api.py),
[Unmanic auth sınırı](https://docs.unmanic.app/docs/guides/basic_auth_nginx),
[Jellyfin item sözleşmesi](https://github.com/jellyfin/jellyfin/blob/ee91c75e777da41a9c4f4855e70adc604fbf2ef8/Jellyfin.Api/Controllers/UserLibraryController.cs#L75-L108),
[Jellyfin path dönüşümü](https://github.com/jellyfin/jellyfin/blob/ee91c75e777da41a9c4f4855e70adc604fbf2ef8/Emby.Server.Implementations/Dto/DtoService.cs#L1827-L1837).

Repo incelemesinde public API ve Flutter ekranı bulunmasına rağmen normal
`create_configured_app` yolunun media archive read/action worker bağlamadığı,
deploy paketinde Unmanic veya media archive worker bulunmadığı ve action dilimi
için dedicated test olmadığı doğrulandı. Bu nedenle F30 yalnız “test bekliyor”
olarak bırakılamaz; üretim worker yolu ve yaşam döngüsü tamamlanana kadar aktif
geliştirmedir.

## Özellik-yetenek matrisi

Kapsam kimlikleri: F01, F02, F03, F04, F05, F06, F07, F08, F09, F10, F11,
F12, F13, F14, F15, F16, F17, F18, F19, F20, F21, F22, F23, F24, F25, F26,
F27, F28, F29, F30, F31, F32, F33, F34, F35, F36, F37, F38, F39, F40, F41,
F42, F43, F44, F45, F46, F47, F48, F49, F50, F51, F52, F53, F54, F55, F56,
F57, F58, F59, F60, F61, F62 ve F63.

| Özellikler | Gerçek dünya dayanağı | Larenor'da doğrulanan sınır |
| --- | --- | --- |
| F01–F04 | Home Assistant [Conversation API](https://developers.home-assistant.io/docs/intent_conversation_api/), [LLM API](https://developers.home-assistant.io/docs/core/llm/) ve [WebSocket service çağrıları](https://developers.home-assistant.io/docs/api/websocket/) konuşma, sınırlı araç ve durum/komut yüzeylerini gerçekten sunar. | Taslak, deneme, geçmiş tekrar ve çakışma hakemi Larenor'a aittir. Model çıktısı doğrudan komut değildir; şema, izin, kullanıcı onayı ve sonuç okuması korunur. |
| F05–F07 | Home Assistant WebSocket olayları bağlamsal kimlik ve durum değişimlerini taşır; [otomasyon izleri](https://www.home-assistant.io/docs/automation/troubleshooting/) gerçek çalıştırma adımlarını gösterir. | Uzun işin makbuzu, nedensellik bağı ve alışılmış düzenden sapma Larenor davranışıdır. Zaman yakınlığı tek başına neden sayılmaz. |
| F08–F10 | Home Assistant LLM API, araçları şemalı ve bağlamlı biçimde sunar; yönetim işlemlerini yerleşik Assist yüzeyinden dışarıda bırakır. | Kaynak bütçesi, süreli bellek ve kanıta dayalı teşhis Larenor'a aittir. Sırlar modele verilmez, bilinmeyen sonuçlar başarıya çevrilmez. |
| F11 | Docker'ın [container kaynak kısıtları](https://docs.docker.com/engine/containers/resource_constraints/) ve [seccomp profili](https://docs.docker.com/engine/security/seccomp/) sınırlı çalışma alanı için gerçek mekanizmalardır. | Mini eklenti kataloğu açık izin listesiyle çalışır; serbest host işlevi veya keyfi container yetkisi yoktur. |
| F12 | Model Context Protocol [yetkilendirme belirtimi](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization) HTTP tabanlı taşıma için OAuth tabanlı yetki akışını tanımlar. | MCP uyumu aracı güvenilir yapmaz; Larenor araç şeması, kapsamı, kullanıcı/ev bağı ve sonuç makbuzunu ayrıca doğrular. |
| F13–F15 | Docker [internal network](https://docs.docker.com/reference/cli/docker/network/create/#network-internal-mode---internal) ve [content trust](https://docs.docker.com/engine/security/trust/) belgeleri ağ yalıtımı ile imzalı içerik doğrulamasının gerçek fakat farklı kontroller olduğunu gösterir. | İnternet politikası HTTPS içeriğini okuduğunu iddia etmez. Destek oturumu süreli ve kapsamlıdır; upstream imzası olmayan bileşen için sahte imza güvencesi üretilmez. |
| F16–F17 | Home Assistant [backup entegrasyonu](https://www.home-assistant.io/integrations/backup/) yedek oluşturma/yükleme/indirme/silme işlemlerini; restic [append-only depo](https://restic.readthedocs.io/en/stable/060_forget.html#append-only-mode) ayrı yetki alanı modelini belgeler. | Kurtarma tatbikatı izole hedefte yürür. Silmeye kapalı hedef ayrı kimlik ve saklama politikası ister; hedef yöneticisinin ele geçirilmesine karşı mutlak güvence verilmez. |
| F18 | Network UPS Tools [kullanıcı kılavuzu](https://networkupstools.org/docs/user-manual.chunked/index.html) güç olayları, istemci/sunucu izleme ve kontrollü kapatma akışını belgeler. | Çalışma süresi tahmindir; gerçek UPS, işletim sistemi kapatma yetkisi ve ağ gücü fiziksel kabul ister. |
| F19 | Headscale [ACL belgeleri](https://headscale.net/stable/ref/acls/) kullanıcı, düğüm, etiket ve ağ erişimi kurallarını sunar. | Çoklu ev federasyonu Larenor'a aittir; evlerin token, önbellek, kayıt ve Core yetkileri paylaşılmaz. |
| F20 | Home Assistant olay bağlamı çağrıları ilişkilendirir; dış ankora sahip HMAC zinciri değiştirme farkındalığı için Larenor tasarımıdır. | Günlük fiziksel dünyanın doğruluğunu kanıtlamaz; zincir kopması, checkpoint ve dış ankora erişim ayrı gösterilir. |
| F21 | Jellyfin'in resmî [SyncPlay API'si](https://typescript-sdk.jellyfin.org/classes/generated-client.SyncPlayApi.html) grup oynatma, bekleme ve konum eşitleme işlemlerini sunar. | Her Cast/Apple TV hedefi uyumlu sayılmaz; gecikme, oturum üyeliği ve oynatıcı makbuzu doğrulanır. |
| F22–F23 | ErsatzTV [belgeleri](https://ersatztv.org/docs/) kişisel medya ile doğrusal kanal/EPG akışını; Jellyfin [Live TV](https://jellyfin.org/docs/general/server/live-tv/) tuner, rehber ve DVR kullanımını belgeler. | Yalnız sahip olunan veya yetkili kaynak işlenir. DRM aşma, yayın kilidi açma veya kaynaksız kayıt iddiası yoktur. |
| F24 | Jellyfin [oynatma isteği](https://typescript-sdk.jellyfin.org/interfaces/generated-client.SessionApiPlayRequest.html) ses ve altyazı akış indekslerini gerçekten destekler. | Dil seçimi mevcut izlerle sınırlıdır; dış altyazı sağlayıcısı hesabı, kota ve kullanıcı onayı korunur. |
| F25–F27 | Jellyfin resmî [istemci matrisi](https://jellyfin.org/downloads/clients/all/) indirme, çevrimdışı kullanım ve giriş atlama yeteneklerinin istemciye göre değiştiğini açıkça gösterir. | Algılama hataları görünür kalır, codec/HDR gerçek cihazda doğrulanır ve DRM'li abonelik içeriği dosya indirme yetkisi sayılmaz. |
| F28 | Audiobookshelf [API](https://api.audiobookshelf.org/) kitap/podcast kitaplığı ve ilerleme yüzeyini sunar; belge güncelliği uyarısı kabul sınırıdır. | Bölüm, yer imi, uyku zamanlayıcısı ve oturum akışı sabitlenen sürüm sözleşmesine bağlanır; ücretli sağlayıcı erişimi varsayılmaz. |
| F29 | Music Assistant [API](https://www.music-assistant.io/api/) sağlayıcı, oynatıcı ve kuyruk komutlarını tek sunucu yüzeyinde sunar. | Parti oylaması Larenor davranışıdır; gerçek sağlayıcı ve alıcının izin/yetenekleri aşılmaz. |
| F30 | Unmanic [belgeleri](https://docs.unmanic.app/docs/) medya kitaplığı tarama ve dönüştürme işçilerini sunar. | Kopya eşleme, kalite karşılaştırma ve kazanç önizlemesi Larenor'a aittir. Unmanic orijinali varsayılan olarak korumaz; exact terminal makbuz, ayrı doğrulanmış kopya ve onaylı cleanup Larenor adapter/worker sözleşmesidir. |
| F31–F33 | Home Assistant [todo entity](https://developers.home-assistant.io/docs/core/entity/todo/) öğe ekleme/güncelleme/silme işlemlerini sunar. | Tarif, porsiyon, stok düşümü, zamanlayıcı ve büyük ekran pişirme Larenor modelleridir; ocak/fırın otomatik kontrolü ilk kapsam değildir. |
| F34–F35 | Paperless-ngx [REST API](https://docs.paperless-ngx.com/api/) belge yükleme, görev durumu, etiket ve metadata işlemlerini sunar. | QR erişimi yetki denetiminden geçer; OCR ile bulunan garanti tarihi kesin kabul edilmez ve kullanıcıca doğrulanır. |
| F36–F37 | Spliit'in [resmî açık kaynak projesi](https://github.com/spliit-app/spliit) ortak gider bölüşümünün gerçek ürün örneğidir; Home Assistant todo yüzeyi görev listesinin gerçek taşıyıcısıdır. | Adalet puanı, görev döngüsü ve Larenor gider modeli yereldir; banka bağlantısı veya ödeme otomasyonu yoktur. |
| F38 | Immich [akıllı arama](https://immich.app/docs/features/smart-search/) CLIP tabanlı doğal dil, kişi ve bağlamsal fotoğraf aramasını sunar. | Model dili/bellek ve albüm izinleri gerçek kurulumda doğrulanır; arama sonucu kimlik kanıtı değildir. |
| F39 | Yjs [çevrimdışı düzenleme](https://docs.yjs.dev/getting-started/allowing-offline-editing) yerel kalıcılık ve sonradan eşitleme modelini belgeler. | Flutter köprüsü, ev/hesap yetkisi ve silinen özel notların önbellekten kaldırılması Larenor sorumluluğudur. |
| F40 | Home Assistant [calendar entity](https://developers.home-assistant.io/docs/core/entity/calendar/) olay okuma/oluşturma/silme yeteneklerini tanımlar. | Kaynak rezervasyon kuralı, çakışma ve zaman dilimi denetimi Larenor'a aittir. |
| F41–F45 | Frigate [semantik arama](https://docs.frigate.video/configuration/semantic_search/), [export](https://docs.frigate.video/usage/exports/) ve [ses algılama](https://docs.frigate.video/configuration/audio_detectors/) yüzeylerini gerçekten sunar. | Arama/algılama olasılıksaldır. Bulanıklaştırma, paylaşım yetkisi, evde profili ve türetilen sensörler Larenor katmanıdır; kilit açma kimliği veya sertifikalı alarm değildir. |
| F46–F48 | evcc [yük yönetimi](https://docs.evcc.io/en/features/loadmanagement/) ve [optimizer](https://docs.evcc.io/en/features/optimizer/) belgeleri şarj, güneş/batarya ve güç bütçesi verilerini sunar; her iki ileri özellik de deneysel sınırlar taşır. | Planlar danışmanlık ve açık kullanıcı kararıdır. Uyumlu sayaç, araç, şarj cihazı, inverter ve tarife olmadan otomatik gerçek dünya başarısı iddia edilmez. |
| F49–F50 | Home Assistant'ın sensör ve service-call yüzeyi nem, sıcaklık, CO2, debi, vana ve havalandırma entegrasyonlarını birleştirebilir. | Sulama/konfor önerisi kalibrasyonlu sensör ister; elektronik tesisat, tıbbi sonuç veya kesin küf teşhisi değildir. |
| F51 | Home Assistant WebSocket entity/area verisi gerçek zamanlı kat planı durumunu besleyebilir. | Plan geometrisi Larenor'da kullanıcı verisidir; otomatik ölçülmüş sayılmaz ve 3B performans cihazda ölçülür. |
| F52 | Android'in [bağlı ekran desteği](https://developer.android.com/develop/adaptive-apps/guides/support-connected-displays) ikincil ekran, pencere ve etkinlik davranışını belgeler. | DeX/OEM dock, odak, giriş aygıtı ve korumalı medya kabulü fiziksel cihazda kalır. |
| F53 | Fully Kiosk [remote admin](https://www.fully-kiosk.com/en/#remote-admin) ve cihaz yönetimi yüzeylerini sunar. | Her işlem device-owner yetkisine sahip değildir; Huawei/OEM izinleri ve gerçek filo işlemleri manuel kabul ister. |
| F54 | ntfy [Android belgesi](https://docs.ntfy.sh/subscribe/phone/) F-Droid sürümünde Firebase olmadan self-hosted teslimi ve anlık teslim için foreground service gereğini açıklar. | Servis kapalıysa gecikme görünürdür; Huawei/OEM pil davranışı ve 24 saat teslim ölçümü cihaz kapısıdır. |
| F55 | Home Assistant [ZHA](https://www.home-assistant.io/integrations/zha/) ile Zigbee2MQTT [OTA](https://www.zigbee2mqtt.io/guide/usage/ota_updates.html) desteklenen Zigbee cihaz güncellemelerini; Home Assistant [Matter](https://www.home-assistant.io/integrations/matter) ayrı Matter/Thread koşullarını belgeler. | Zigbee, Thread ve Matter aynı şey sayılmaz. Koordinatör, border router ve model desteği gerçek kurulumda doğrulanır. |
| F56–F57 | ESPHome [remote transmitter](https://esphome.io/components/remote_transmitter/) IR/RF gönderimini; [Bluetooth proxy](https://esphome.io/components/bluetooth_proxy/) BLE cihazlarını Home Assistant'a taşımayı belgeler. | Gönderilen IR sinyali cihaz durumunu kanıtlamaz; BLE oda varlığı yaklaşık sonuçtur ve kimlik/kapı anahtarı değildir. |
| F58 | OpenEPaperLink'in [resmî projesi](https://github.com/OpenEPaperLink/OpenEPaperLink) desteklenen e-paper etiketlere yerel içerik dağıtımının gerçek örneğidir. | Destekli etiket/AP gerekir; bu akış Android tablet uygulamasının yerine geçmez. |
| F59 | OctoPrint [job API](https://docs.octoprint.org/en/main/api/job.html) iş durumu ve kontrollü başlat/duraklat/iptal işlemlerini sunar. | İlk kapsam izleme odaklıdır; keyfi G-code ve denetimsiz uzaktan başlatma yoktur. |
| F60 | Moonlight [kurulum kılavuzu](https://github.com/moonlight-stream/moonlight-docs/wiki/Setup-Guide) Sunshine/GameStream uyumlu hosttan istemciye oyun akışını belgeler. | Uyumlu PC/GPU/ağ gerekir; Android native entegrasyon, codec ve lisans koşulları ayrıca kabul edilir. |
| F61 | RFB, [RFC 6143](https://www.rfc-editor.org/rfc/rfc6143), VNC framebuffer ve giriş protokolünü tanımlar. | Native motor, framebuffer, IME, modifier release, touchpad, zoom ve resize Larenor kabulidir; gerçek host/tablet hâlâ manuel kapıdır. |
| F62 | FreeRDP'nin [Android derleme belgesi](https://github.com/FreeRDP/FreeRDP/blob/master/docs/README.android) Android istemci yüzeyinin gerçek ve derlenebilir olduğunu gösterir. | Receipted native kaynak, sertifika pinleme, NLA ve paketlenmiş APK bağlantısı exact CI'da doğrulanır; fiziksel Windows/DeX ayrıca sınanır. |
| F63 | OpenSSH [özellik listesi](https://www.openssh.org/features.html) terminal, port yönlendirme ve dosya aktarımı için gerçek protokol temelini belgeler. | Host anahtarı, kimlik, tünel sahipliği ve tekrar edilmeyen komut/makbuz davranışı Larenor katmanıdır. |

## Kabulte özellikle açık bırakılanlar

1. Resmî belgede bir özellik bulunması, kurulu evde o sağlayıcının veya
   donanımın var olduğunu göstermez.
2. Sentetik sağlayıcı ve yerel host testleri fiziksel tablet, tuner, UPS,
   Zigbee/Thread ağı, kamera, şarj cihazı veya Windows/Linux host kabulünün
   yerine geçmez.
3. Olasılıksal AI/OCR/arama sonuçları kesin gerçek, güvenlik kararı veya sağlık
   sonucu olarak kullanılmaz.
4. Exact-head CI başarısızsa bu araştırma `FINAL.FUNCTION` maddesini tek başına
   kapatamaz.

## F30 kalıcı worker etkisi — 30 Eylül devamı

Normal Core giriş noktası read/action IPC istemcilerini artık yapılandırıyor.
Worker'a gönderilen transcode komutu kaynak ve hedef codec/bitrate, süre,
kaynak boyutu ve tam orijinal rezervasyonunu içeriyor. Eski rolü kaybolmuş
komutlar çalıştırılmıyor.

Worker'ın `media_archive_actions/journal.py` günlüğü tam komut digestini,
revizyonunu, etki durumunu ve doğrulanmış artifact kanıtlarını özel SQLite
kaydı olarak saklıyor. Etkiden önce kalıcı başlangıç, eski revizyonla güncelleme
reddi, işlem kimliği çatışması, terminal makbuzun yeniden açılması ve kayıt
hasarı odaklı 12 kabul kontrolüyle doğrulandı. Başarı makbuzu yalnız sağlayıcı
kabulüne dayanamaz; transcode için eşleşen orijinal kopya, doğrulanmış daha küçük
çıktı ve kurulum kanıtı, cleanup için ayrıca cleanup kanıtı gerekir.

Bu dilim packaged collector, protected file store, sağlayıcı effect handler,
iptal/callback yaşam döngüsü veya gerçek Client→Core→worker kabulünü tek başına
tamamlamaz; F30 aktif geliştirmede kalır.

## Ek production akışı bulguları

30 Eylül canlı kaynak incelemesi, arayüz/gateway varlığının concrete normal
runtime composition kanıtı olmadığını gösterdi:

- F18 startup sırasında hedefli `executing` adımı `queued` yapıyordu; etki
  sonrası kayıp makbuzda aynı kapatma/başlatma yeniden gönderilebilirdi.
  Normal runtime için güç executor bağlantısı da eksikti.
- F46/F48 normal runtime içinde evcc/şarj/sayaç adapteri, F55 içinde
  ZHA/Zigbee2MQTT topology/catalog/OTA adapteri bulunmadı.
- F59 sağlayıcısız preview/confirm, dış etki üretmeden `notDispatched` intent
  kaydediyordu. Bu fallback kaldırıldı; sağlayıcı yoksa işlem sunulmaz ve
  preview/confirm 503 döner. Önizleme sonrası sağlayıcı kaybı da boş intent
  oluşturamaz. Gerçek adapter ve production composition hâlâ uygulama işidir.

F18/F59 aktif, F46/F48/F55 ve F47'nin F48 uygulama bağımlılığı bekleyen
kuyruğa taşındı. Kabul sayaçları değişmedi.

Resmî dayanaklar: [NUT kapatma sıralaması](https://networkupstools.org/docs/man/upsmon.conf.html),
[evcc chargers](https://docs.evcc.io/en/reference/configuration/chargers/),
[evcc loadpoints](https://docs.evcc.io/en/reference/configuration/loadpoints/),
[ZHA](https://www.home-assistant.io/integrations/zha/),
[Zigbee2MQTT OTA](https://www.zigbee2mqtt.io/guide/usage/ota_updates.html),
[OctoPrint job komutları ve durum okuma](https://docs.octoprint.org/en/main/api/job.html).
