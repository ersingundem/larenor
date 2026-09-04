# Larenor müzik, yayın ve Android arka plan oynatım araştırması

Araştırma tarihi: 5 Eylül 2026. Bu belge bir uygulama planı ve uyumluluk değerlendirmesidir; cihazlarda oynatımın çalıştığını gösteren test raporu değildir. Canlı Home Assistant üzerinde bu çalışma kapsamında komut çalıştırılmadı, hesap bağlanmadı veya sunucu kurulmadı.

## Doğrulanmış ihtiyaç ve karar

Kullanıcının son düzeltmesi esas alınmıştır: **Music Assistant sunucusu yoktur**. Spotify, Apple Music ve YouTube Music abonelikleri vardır. Chromecast/Google TV, Apple TV ve HomePod hedefleri istenmektedir; kesin modeller, işletim sistemi sürümleri ve eşleştirme durumları ayrıca cihaz envanterinden doğrulanmalıdır. Daha önceki “Music Assistant kurulu” varsayımı geçersizdir.

İstenen sonuç: Larenor içinde ortak müzik kütüphanesi, arama, kuyruk, oda/çıkış seçimi, çalan parça ve kontroller; telefon ekranı kapalıyken uygun kaynaklarda oynatım ve kilit ekranı kontrolleri. **Music Assistant sunucusunun tamamını Android APK içine koymak**, onun özelliklerine benzeyen yerel arayüz veya harici sunucu istemcisi geliştirmekten farklı bir iştir. Harici bağlantı ekranı, gömülü sunucu isteğinin tamamlanması olarak sunulmamalıdır.

Önerilen uygulanabilir sıra: Larenor'un kendi müzik arayüzü ve ortak oynatıcı modeli → mevcut HA hedefleri → yerel/Jellyfin/radyo arka plan oynatımı → sağlayıcıların resmî Android yolları → kullanıcı ayrıca isterse ev sunucusunda isteğe bağlı Music Assistant köprüsü. Bu yol gömülü MA sunucusu değildir; o hedef için aşağıdaki ayrı fizibilite kapısı korunur.

## Sunucuyu Android içine taşıma fizibilitesi

MA'nın desteklediği kurulumlar HAOS uygulaması ve bağımsız Docker konteyneridir. Sunucunun sürekli açık olması, en az 2 GB RAM ve oyunculara uygun yerel ağ erişimi gerekir. Android uygulama içi kurulum desteklenen yöntemler arasında değildir. Dolayısıyla “Flutter'a paket ekleyerek tüm sunucu çalışır” varsayımı yanlış olur. [Resmî kurulum ve destek kapsamı](https://www.music-assistant.io/installation/).

İncelenen MA kaynak sürümü `52d52ee8d6bff777b7502047e4dafba91b8adbb6` (4 Eylül 2026) Python 3.14 ve çok sayıda yerel bağımlılık kullanıyor; Docker yapısı sistem FFmpeg/PyAV ve Linux için AirPlay yürütülebilirlerini paketliyor. Bu geliştirme dalı tespitidir; kurulacak kararlı sürümün bağımlılıkları yeniden sabitlenmelidir. Android için Python/native kütüphane portu, ABI paketleme, multicast, hizmet yaşam döngüsü, depolama, güncelleme, lisans/NOTICE ve pil testleri ayrı bir mühendislik projesidir. Termux veya WebView tek başına bunları çözmez. [Sunucu bağımlılıkları](https://github.com/music-assistant/server/blob/52d52ee8d6bff777b7502047e4dafba91b8adbb6/pyproject.toml), [Docker yapısı](https://github.com/music-assistant/server/blob/52d52ee8d6bff777b7502047e4dafba91b8adbb6/Dockerfile).

Gömülü sunucu için önerilen ilk çıktı, üretim sözü yerine 3–5 günlük sınırlı prototip değerlendirmesidir: tek Android arm64 cihazda yerel açık ses dosyası → kuyruk → ekran kapalı oynatım → bir AirPlay hedefi. Python/native bağımlılıkları veya işletim sistemi hizmet sınırlamaları engel olursa sonuç açıkça kaydedilir. Üç ücretli sağlayıcı, DRM ve tüm MA eklentileri bu prototipin başarısından türetilmez. Tam portun süresi bu kapı geçilmeden güvenilir biçimde tahmin edilemez.

MA frontend deposu Apache-2.0 lisanslıdır. Kod/asset taşınacaksa lisans ve bildirim yükümlülükleri incelenmeli; marka ve üçüncü taraf sağlayıcı kuralları ayrıca ele alınmalıdır. Öneri, mevcut Larenor tasarım sistemiyle arama/kuyruk/çıkış etkileşimlerini yeniden kurmaktır. [Frontend lisansı](https://github.com/music-assistant/frontend/blob/main/LICENSE).

## Uyumluluk matrisi

“Uygulanabilir” henüz entegre edildi veya fiziksel cihazda geçti anlamına gelmez.

| İhtiyaç | Android / Larenor yolu | HA / isteğe bağlı MA yolu | Önkoşul ve sınır |
| --- | --- | --- | --- |
| Yerel dosya, radyo, Jellyfin sesi | Uygulamanın kendi oynatıcı ve medya oturumu | HA hedeflerine uyumlu URL; MA kurulursa kütüphane köprüsü | İçeriğe erişim ve gerçek codec/transcode profili; internet radyosunda seek/kuyruk farklı olabilir |
| Chromecast / Google TV | Resmî Cast sender SDK; yerel ve uzak çıkış geçişi | HA Cast `media_player`; MA varsa native Cast sağlayıcısı | Alıcıdan erişilebilir medya adresi ve desteklenen format; hedef seçimi gerçek cihazdan gelir |
| Apple TV | HA üzerinden kumanda/oynatıcı; doğrudan Android AirPlay gönderici ayrı çalışma | HA Apple TV; müzik için MA AirPlay | Eşleştirme, tvOS uygulamasının desteklediği komutlar; tüm uygulamalar aynı değildir |
| HomePod / stereo çift | MusicKit katalog erişimi doğrudan HomePod transport SDK'sı sayılmaz | MA AirPlay köprüsü en somut ortak kaynak yolu | MA kurulumu, AirPlay erişimi/eşleştirme, model ve stereo testleri; mevcut durumda hazır kabul edilmez |
| Spotify | App Remote ile Spotify uygulamasını kontrol; Web API ile desteklenen Connect hedefi | HA Spotify varsa onun yetenekleri; MA opsiyonel sağlayıcı | Android App Remote sesi Spotify uygulamasında oynatır; kendi bağımsız ses motorumuz değildir |
| Apple Music | MusicKit Android ile uygulama içi oynatım/kütüphane mümkün | MA sağlayıcısı isteğe bağlı, Apple'ın resmî playback desteği değildir | Apple yetkilendirmesi, abonelik ve developer-token altyapısı; resmî SDK ile MA yolu ayrıdır |
| YouTube Music | Resmî uygulamaya içerik bağlantısı; varsa mevcut HA hedef kontrolü | MA'nın resmî olmayan sağlayıcısı, ayrı isteğe bağlı kurulum | Resmî üçüncü taraf tam katalog/arka plan ses motoru doğrulanmadı; abonelik bunu otomatik sağlamaz |
| Odalara anons / yayın | Hedef, ses düzeyi ve önizleme seçimi | Mevcut HA TTS/announce veya MA `play_announcement` | Kaynak/çıktı bunu desteklemeli; tüm odalar arası kusursuz senkron ve kaldığı yerden devam garanti edilmez |

### Hedeflerin gerçek sınırları

HA Cast medya URL'sini alıcıya gönderir: telefonun URL'ye erişmesi yetmez, Chromecast de erişebilmeli ve adı çözebilmelidir. Yerel HTTP medya mümkünken HA dashboard'unu Cast ile göstermek ayrı HTTPS gereksinimine sahiptir. Mobil Jellyfin oynatıcı profili doğrudan Cast profili olarak kullanılmamalıdır. [HA Cast](https://www.home-assistant.io/integrations/cast/).

Cast codec/çözünürlük desteği modele göre değişir. HLS/DASH, altyazı ve CORS gereksinimleri vardır; DRM için uyumlu özel receiver ve yetkili lisans akışı gerekir. Abonelik servisinin web bağlantısı açık medya URL'si değildir; bir Netflix/Spotify/Apple Music sayfasını generic Cast URL'sine dönüştürmek çözüm sayılmaz. [Cast formatları ve DRM](https://developers.google.com/cast/docs/media), [Android sender entegrasyonu](https://developers.google.com/cast/docs/android_sender/integrate).

HA Apple TV'de oynat/duraklat uygulamanın desteğine bağlıdır. Ses seviyesi HomePod, HDMI-CEC veya IR kullanımına göre farklı çalışır; bazı kurulumlarda yalnızca arttır/azalt vardır. AirPlay medya formatı ayrıca denenmelidir. [HA Apple TV](https://www.home-assistant.io/integrations/apple_tv/).

MA AirPlay HomePod ve Apple TV'yi destekler, ses aktarımını MA sunucusu yapar. Apple TV eşleştirme ister; HomePod erişim ayarları/parola bağlantıyı engelleyebilir. Arayüz eşleştirme durumunu göstermeli; kullanıcının Home güvenlik ayarlarını otomatik gevşetmemeli veya cihazı Home'dan kaldırmamalıdır. Protokoller arası eşzamanlama, stereo ve AirPlay sürümü kurulu MA sürümü/gerçek donanımla doğrulanır. [MA AirPlay](https://www.music-assistant.io/player-support/airplay/).

### Sağlayıcı hesapları ve oynatım

Spotify Android SDK, Spotify uygulamasını kontrol eder; ses, önbellek, audio focus ve sistem entegrasyonu Spotify'a aittir. Bu yolda Larenor'un ikinci ve yanıltıcı bir “yerel ses oynatılıyor” oturumu üretmemesi gerekir. [Spotify Android SDK](https://developer.spotify.com/documentation/android). Web API playback transferi Premium ve `user-modify-playback-state` ister, çağrıda tek cihaz destekler; alıcı listesi Spotify Connect listesidir, genel HomePod listesi değildir. [Transfer API](https://developer.spotify.com/documentation/web-api/reference/transfer-a-users-playback).

Doğrudan Spotify Web API bağlanırsa mobil istemci için desteklenen PKCE akışı, minimum scope ve doğru callback doğrulaması kullanılmalıdır; secret APK'ya konmamalıdır. Güncel development mode uygulama sahibinin Premium olmasını ve en çok 5 kullanıcının allowlist'e eklenmesini ister. Genel dağıtım ayrı kota/onay engeli taşır. 429 için bekleme ve istek birleştirme gerekir. [Spotify PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow), [kotalar](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).

MA Spotify mevcut belgede Premium, OAuth ve ayrıca playback onayı/eşleştirmesi istiyor. Varsayılan topluluk motoru librespot bazı hesaplarda çalışmayabilir; Soloist yolu ek anahtar/eşleştirme ve MA'nın açıkça belirttiği kullanım koşulu belirsizliği taşır. Larenor bu motorları sessizce kurmamalı veya kalite/çoklu eşzamanlı yayın vaat etmemelidir. [MA Spotify](https://www.music-assistant.io/music-providers/spotify/).

Apple MusicKit Android kimlik doğrulama ve gerçek uygulama içi playback kütüphaneleri sunar; arka plan ve kilit ekranı kontrolü desteklenir. Auth akışı Apple Music uygulamasını kullanabilir. Apple Music API için developer token ve kullanıcı yetkisi gerekir; imzalama özel anahtarı uygulamanın içinde tutulmamalıdır. Bu yol ayrı native entegrasyon ve güvenli token sağlama tasarımı ister. [Apple MusicKit](https://developer.apple.com/musickit/).

MA Apple Music sağlayıcısı ücretli abonelik ve ayrı yetkilendirme ister; kendi belgesi playback'in Apple tarafından resmî desteklenmediğini belirtir. Belgelenen ses sınırı AAC 256 kbps'dir; bunu Apple Music'in tüm kalite/DRM özelliklerinin karşılığı olarak sunmamalıyız. Hesap işlemleri MA'nın kendi kurulum akışında yürütülmeli, Larenor Apple parolası veya tarayıcı cookie'si toplamamalıdır. [MA Apple Music](https://www.music-assistant.io/music-providers/apple-music/).

MA YouTube Music belgesi resmî API bulunmadığını, best-effort destek, ücretli hesap, cookie ve PO-token servisi gerektirdiğini söylüyor; cookie süresi dolunca yeniden işlem gerekebilir. Bu resmî Google Android SDK'sı değildir ve temel entegrasyon “hazır” sayılmamalıdır. [MA YouTube Music](https://www.music-assistant.io/music-providers/youtube-music/). YouTube Data/IFrame API'leri üzerinden gizli/arka plan player veya videodan ayrı ses çıkarma tasarımı da uygun çözüm değildir; Google bu kullanım biçimlerini yasaklıyor. Güvenilir başlangıç, resmî uygulamaya açma ve zaten mevcut cihaz kontrolüdür. [YouTube geliştirici kuralları](https://developers.google.com/youtube/terms/developer-policies-guide).

## Mevcut koddan en az bağımlılıkla ilerleme

İncelenen kodda HA WebSocket `callService(..., returnResponse: true)` ve REST hizmet kataloğu/response desteği hazırdır. Dashboard medya kutusu temel önceki/oynat/sonraki/ses hizmetlerini kullanıyor. Jellyfin ekranı `media_kit` kullanıyor; pubspec'te özel müzik background/session köprüsü bulunmuyor. Mevcut player'ın widget içinde yaşaması tek başına ekran kapalı/Activity yokken güvenilir ses hizmeti sağlamaz.

1. `MediaOutput` ve `PlaybackSession` ortak domain modeli: kaynak kimliği, hedef kimliği, bağlantı tazeliği, desteklenen işlemler, parça/konum/süre, bekleyen işlem. Başlık yerine kalıcı entity/player ID; aynı fiziksel cihazın HA ve MA kopyaları körlemesine birleştirilmez.
2. Yerel Flutter müzik ekranı: Kütüphane, Ara, Kuyruk, Çıkışlar; ortak mini-player. Dashboard/Settings ile aynı boşluk, yüzey, tipografi, hata/boş/yükleme dili; mevcut Latince slogan dışında slogan eklenmez. Kaynak ve çalma hedefi ayrı görünür.
3. HA `get_services`, entity registry ve `supported_features` üzerinden yetenek seçimi. Desteklenmeyen seek/group/volume düğmesi çalışıyormuş gibi gösterilmez. `unavailable`, eski veri ve auth hatası farklı durumdur. HA hizmeti başarı yanıtı fiziksel ses çıktısının kanıtı değildir. [HA medya işlemleri](https://www.home-assistant.io/integrations/media_player/).
4. MA yoksa sadece ilgili gelişmiş kaynak/oda özelliklerinde açıklayıcı kurulum durumu; yerel oynatma/HA kontrolleri kullanılabilir kalır. MA yüklemek HA yapılandırma değişikliğidir ve mevcut salt-okunur canlı kontrol izninin kapsamında değildir.
5. Uygulama içi sunucu portu ve optional bridge ayrı feature flag/teslim kapsamı olur. Sadece WebView açmak native arayüz, medya oturumu veya gömülü MA tamamlandı sonucunu üretmez.

### İsteğe bağlı MA bağlanırsa

İlk tercih HA üzerinden entegrasyondur: ayrı MA tokenı saklamadan `music_assistant.search`, `get_library`, `get_queue`, `play_media`, `transfer_queue`, `play_announcement` kullanılabilir. HA entegrasyonu ayrıca kurulmuş olmalıdır; yalnız MA server olması yeterli değildir. Güncel belge minimum MA 2.4 ve kullanıcı eşleştirmesini anlatıyor; gerçek HA/MA sürümleri ve kullanıcı yetkileri çalışma anında doğrulanır. [HA Music Assistant](https://www.home-assistant.io/integrations/music_assistant/).

HA **2026.8.3 kaynak kodunda** `search`, `get_library`, `get_queue` response-only servislerdir. WS çağrısında `return_response:true` gerekir. `search/get_library` için `config_entry_id`, kuyruk ve playback için hedef entity kullanılır. `limit`, `offset`, `library_only` UI bölüm başlıklarının içine gömülmez; service data'da düz alanlardır. `play_media.enqueue`: `play`, `replace`, `next`, `replace_next`, `add`. Bu listeyi gelecekteki servis kataloğunun yerine sabitlemeyin. [Servis şeması/handler](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/music_assistant/services.py), [alan açıklamaları](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/music_assistant/services.yaml).

HA'nın sunmadığı kuyruk düzenleme/sağlayıcı yönetimi gerekirse ayrı MA API adaptörü eklenir. Resmî HTTP API: `POST /api`, `Authorization: Bearer …`, JSON `{message_id, command, args}`; komut şemaları kurulu sunucunun `/api-docs` adresindedir. Token MA profilinden üretilir, HA tokenı otomatik MA tokenı değildir. [MA API](https://www.music-assistant.io/api/).

İncelenen MA kaynak sürümünde `GET /info`, `/ws` ve `/api-docs/commands.json`/`schemas.json` yolları bulunur. WS ilk server-info mesajından sonra `{message_id:"auth-1",command:"auth",args:{token:"…"}}` ile doğrulanır; başarıdan sonra event akışı başlar. Komut cevapları ID ile eşlenmeli, kopuş sonrası durum tekrar alınmalı, auth reddinde sürekli reconnect yapılmamalıdır. Bu kaynak bulgusu gelecekteki veya eski sunucuyla koşulsuz uyumluluk değildir. [HTTP yolları](https://github.com/music-assistant/server/blob/52d52ee8d6bff777b7502047e4dafba91b8adbb6/music_assistant/controllers/webserver/controller.py), [WS handshake](https://github.com/music-assistant/server/blob/52d52ee8d6bff777b7502047e4dafba91b8adbb6/music_assistant/controllers/webserver/websocket_client.py).

Yeni MA adaptörü mevcut `ServerBoundClient` origin/prefix/redirect sınırlarını, redaksiyon ve secure storage yaklaşımını kullanmalı. Artwork veya medya URL'sine HA/MA bearer tokenı körlemesine eklenmemeli. Cast hedefi, stream URL'sinde credential gerekiyorsa bunun ayrı bir paylaşım sınırı olduğu açıklanmalı; öncelik kısa ömürlü ve kapsamı dar URL, generic uzun ömürlü HA tokenını alıcıya aktarmak değil. Log/diagnostics/backup içine stream query tokenları ve provider cookie'leri girmemeli.

## Android ekran kapalı, kilit ekranı ve güç davranışı

Kendi oynatımımız için `Player` ve `MediaSession`, Activity'den ayrı `MediaSessionService` içinde yaşamalıdır. Android izinleri `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, hizmet türü `mediaPlayback`; controller yalnız izin verilen oynatıcı işlemlerine erişir. Metadata/kapak, duration, gerçek konum ve izin verilen komutlar oturumda tutulur. Native Media3 audio servisi + Flutter bridge, mevcut Jellyfin video ekranını hemen değiştirmeden değerlendirilebilir; iki motorun aynı sesi çalmasını önleyen tek playback sahibi gerekir. [Media3 background playback](https://developer.android.com/media/media3/session/background-playback).

Audio focus, kulaklık çıkması, arama, Bluetooth/çıkış değişimi ve ağ kaybı ele alınmalıdır. Android 15+ hedefleyen uygulama focus'u yalnız üstteyken veya foreground service çalışırken isteyebilir. [Audio focus](https://developer.android.com/media/optimize/audio-focus). Android 17'de arka plan ses etkileşimleri için tüm uygulamalar görünür Activity veya `shortService` olmayan foreground service gerektirir; target 37 için kullanıcı girişiminden doğan while-in-use yeteneği ayrıca önemlidir. Müzik için alarm izniyle kural aşma tasarlanmaz. [Android 17 ses kuralları](https://developer.android.com/about/versions/17/changes/bg-audio).

Medya oturumu bildirimleri Android 13 bildirim izni davranışının istisnasıdır. Genel HA uyarıları için bildirim izni ayrı amaçla, gerektiği anda istenir; reddedilmesi müzik oynatmayı gereksiz yere kilitlemez. Mikrofon, kişiler, tüm dosyalar veya bildirim okuma erişimi sırf kendi müziğimizi oynatmak için talep edilmez. [Bildirim izni](https://developer.android.com/develop/ui/compose/notifications/notification-permission).

Android 17 / target 37'de doğrudan LAN erişimi için `ACCESS_LOCAL_NETWORK` veya uygun sistem aracılı picker yolu gerekir. Cast output-switcher daha dar izinli seçenek olabilir; HA IP bağlantısının kapsamını otomatik çözmez. Target 36 ve altı için bu runtime izin istenmez. Reddetme/sonradan iptal, “sunucu kapalı” yerine erişim durumu olarak açıklanır. [Yerel ağ izni](https://developer.android.com/privacy-and-security/local-network-permission).

Güç ekranı “arka planda oynatım”, bildirim durumu, yerel ağ izni, Android pil ayarı ve son kesinti nedeni gösterir. Varsayılan, doğru medya foreground service ve ekranı kapatabilmektir; sürekli ekran/CPU kilidi veya bütün sistem için optimizasyon kapatma değildir. Sorun görülürse kullanıcıya uygulamanın pil ayarlarını açan eylem sunulur. Doğrudan Doze istisnası talebi sınırlı kullanım/politika koşuluna tabidir. [Doze rehberi](https://developer.android.com/training/monitoring-device-state/doze-standby).

Uzak HA/MA hedefi çalarken telefon ses kaynağı olmayabilir; yalnız remote kontrol için yerel audio focus alınmamalıdır. MA kuruluysa sunucu müziği sürdürür; telefonun bağlantısı koptuğunda kilit ekranı eski bilgiyi aktif göstermez. Spotify App Remote yolunda sistem oturumunun sahibi Spotify'dır. Kullanıcı force-stop yaptığında otomatik yeniden başlatma veya yeniden kurulum sonrası otomatik ses başlatma vaat edilmez.

## Uygulama sırası ve kabul kapıları

Tahminler tek geliştirici için ilk uygulama ve test aralıklarıdır; harici hesap onayı/donanım bekleme süresi içermez.

| İş | Yaklaşık kapsam | Bitmiş sayılması için |
| --- | --- | --- |
| Ortak müzik arayüzü + HA çıkışları | 3–5 gün | Fake HA kataloğu ve state akışıyla doğru yetenekler; 401/403/offline/stale; native ekranlar arasında tutarlı UI |
| Kendi audio service + kilit ekranı | 4–7 gün | En az API 33/35/37 emülatör ve bir fiziksel Android'de ekran kapatma, arama/focus, kulaklık, stop/resume, task dismiss |
| Spotify App Remote + sınırlı Web API | 3–5 gün | Gerçek kayıtlı uygulama/callback, kullanıcı izni, Spotify kurulu/kurulu değil, Premium/403/429 ve Connect hedef testleri |
| MusicKit Android | 5–10 gün | SDK, güvenli developer-token üretimi, gerçek abonelik/auth, background/DRM/session testleri; APK'da private key yok |
| Cast ve isteğe bağlı MA/HomePod | 4–8 gün | Gerçek receiver/model, eşleştirme, ağdan URL erişimi, queue transferi, tekil/grup ses testi; MA kurulumu ayrıca yetkilendirilmiş |
| Gömülü MA sunucusu | Önce 3–5 günlük fizibilite | Android arm64 native bağımlılıklar ve ekran kapalı yerel/AirPlay prototipi; başarı olmadan tam port tarihi verilmez |

CI'ya eklenebilecek anlamlı otomatik kontroller:

- Fake kataloglarda eksik servis/feature: desteklenmeyen işlem gönderilmez; HA response-only servisleri doğru `return_response` ve düz parametrelerle çağrılır.
- Oynatma komutu kabulü ile yeni state ayrımı; timeout/bağlantı kopmasında aynı komut otomatik tekrarlanmaz. Slider istekleri birleştirilir, son hedef ve oturum değişiminde eski sonuç uygulanmaz.
- Kaynak/çıktı değişiminde yalnız bir aktif yerel player; eski abonelik/kapak isteği dispose edilir. Çok büyük kütüphane sayfalıdır; her saniye bütün liste yeniden çizilmez.
- URL güven sınırları, redirect, signed URL redaksiyonu, bozuk event/response ve token revocation; diagnostic export secretsizdir.
- Android instrumentation: gerçek service bildirimi/metadata/controller, bildirim reddi, LAN izni reddi/iptali, audio focus, task dismiss ve süreç ölümü sonrası güvenli kurtarma. Basit widget testi bu garantilerin yerine geçmez.
- Ayrı opt-in cihaz testi: Chromecast/Google TV codec ve transcode, Apple TV CEC/IR/HomePod ses modu, HomePod tekli/stereo, HA/MA restart, Wi-Fi değişimi, 30–60 dakika ekran kapalı oynatım ve ölçülen CPU/pil davranışı. Bu testler canlı sistemde ancak açık oynatma/eşleştirme yetkisiyle çalıştırılır.

Bu araştırmanın uygulanabilir sonucu, hangi işlevin hangi motor ve önkoşulla sağlanacağının açıklığa kavuşmasıdır. Hesaplar bağlanmadan, MA kurulmadan veya fiziksel oynatma ölçülmeden üç sağlayıcı ve tüm cihazların tam desteklendiği beyan edilmemelidir.
