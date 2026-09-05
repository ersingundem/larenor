# Larenor Core / Android Client — 60 özellik adayı

**Araştırma ve seçim: 5 Eylül 2026 · Durum: 60/60 özellik seçildi ve planlandı.**

Bu liste mevcut geliştirmeye paralel hazırlanmıştır. Kullanıcı 60 özelliğin tamamını açıkça seçti ve bağımlılık sırasıyla plana alınmasını istedi. Hiçbiri bu kararla uygulanmış veya doğrulanmış sayılmaz; seçim tamamlanmış iş miktarını artırmaz. Core burada backend rolünü anlatır; depodaki Larenor Server paketleri bu araştırmayla yeniden adlandırılmadı.

Her satır Larenor için bir ürün önerisidir. Bağlantılar resmi belgeler veya birincil proje kaynaklarıdır; teknik temel ve ürün örneği sağlarlar. Bu birleşik Larenor özelliklerinin hazır, bütün API sürümleriyle uyumlu veya fiziksel cihazda denenmiş olduğu anlamına gelmez.

Mevcut hesap/kasa, ortak arama, Bugün, oda/kart düzeni, temel medya akışı, HA kontrolleri ve kiosk işleri yeniden sıfırdan önerilmez. **Genişleme**, mevcut kapsamın üzerine eklenen ayrı yeteneği belirtir. **Yeni**, mevcut takip dosyalarında aynı iş paketi bulunmayan adaydır. Eforlar ölçülmüş süre değildir; küçük form düzenlemesinden farklı, orta/büyük/çok büyük mühendislik paketlerini anlatır.

Seçilenler tek Larenor kurulumu ve Android Client yönetimine uygun, isteğe bağlı modüller olarak tasarlanır. Bu, adı geçen her projeyi ayrı sunucu olarak kurmanı veya 60 bileşeni aynı anda çalıştırmanı gerektiren bir öneri değildir. Bazı kaynaklar yalnız örnek desenlerdir. Harici donanım, sağlayıcı hesabı ve gerekli kullanıcı yetkilendirmesi otomatik ortadan kalkmaz. Kaynak kodu/model alınacaksa seçilen sürümün lisansı ve dağıtım koşulları ayrıca korunur.

Uygulama mevcut S06 kurulum işleri, S07 bütünleşik medya/müzik, S08 merkezi adaptörler ve S09 kurulum/geri yükleme üzerine kurulur. Ortak kimlik/yetki/olay ve yazılım kurtarma temelleri erken hazırlanır; bağımsız modüller yalnız kendi önkoşullarını bekler. Bugün tamamlanan salt okunur gereksinim kontrolü otomatik kurulum değildir. [Canlı çalışma kaydı](PROGRESS.md), [mevcut bütünleşik medya kapsamı](integrated-media-stack.md).

## Kaydedilen seçim ve uygulama planı

**Seçilenler: 01–60, tamamı.** Ortak bağımlılıklar, teslim sırası, kabul testleri ve cihaz gereksinimleri [özellik genişleme planında](feature-expansion-plan-2026-09-05.md) izlenir. Bu kayıt planlama seçimini belirtir; özelliklerin hazır olduğu veya gerçek hizmetlerin kurulduğu anlamına gelmez.

**Seçim öncesindeki araştırma önerisi:** 01, 02, 04, 06, 16, 21, 24, 31, 34, 51, 54. Aşağıdaki “★ önerim” işaretleri ve JSON'daki `recommended` alanı bu eski başlangıç önerisini korur; güncel seçim bütün 60 özelliği kapsar. Uygulama sırasını bağımlılıklara göre yeni plan belirler.

Makine tarafından okunabilir aynı liste: [JSON](feature-candidates-2026-09-05.json). `selected` kullanıcı seçimini, `implementation.deliveryGroups` teslim sırasını, `implementation.requires` özellik bağımlılıklarını ve boş `acceptedFeatureIds` henüz yeni özellik kabulü olmadığını kaydeder.

## 01–10: Yapay zekâ ve otomasyon

### 01. Konuşarak otomasyon taslağı · ★ önerim

Ev boşalınca ne yapılacağını anlat; düzenlenebilir bir rutin taslağı oluşsun.

- **Core:** Yerel model, izinli eylem kataloğu ve plan doğrulaması.
- **Android Client:** Etkilenen cihazlar, adımlar ve etkinleştirme onayı.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** Assist/rutinlerin üzerine eklenir; ses için STT/TTS ve yerel model gerekir. Model çıktısı doğrudan komut çalıştırmaz.
- **Dayanak:** [Ollama yapılandırılmış çıktılar](https://docs.ollama.com/capabilities/structured-outputs).

### 02. Otomasyonun deneme haftası · ★ önerim

Kural cihazları değiştirmeden bir hafta izlesin; gereksiz tetiklemeleri görelim.

- **Core:** Gerçek olayları yan etkisiz değerlendirip olası eylemleri kaydetme.
- **Android Client:** Deneme sonuçları ve etkinleştirme kararı.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** Rutinlere yeni deneme katmanı; fiziksel sonucu veya enerji tasarrufunu kanıtlamaz.
- **Dayanak:** [Home Assistant olay modeli](https://www.home-assistant.io/docs/configuration/events/).

### 03. Geçmişte otomasyon sınaması

Yeni kural geçen salı çalışsaydı hangi kararları verirdi, karşılaştır.

- **Core:** Kayıtlı olayları sahte adaptörlerde tekrar yürütme ve sürüm karşılaştırması.
- **Android Client:** Tarih seçimi, eski/yeni karar farkı.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** Eksik geçmiş veri bilinmeyen olarak kalır; canlı deneme modundan ayrı bir tekrar testi.
- **Dayanak:** [Temporal test ve tekrar araçları](https://docs.temporal.io/develop/python/best-practices/testing-suite).

### 04. Çakışan kurallar hakemi · ★ önerim

Uyku, misafir ve temizlik rutinleri aynı ışığı birbirine karşı yönetmesin.

- **Core:** Öncelik, süreli cihaz sahipliği ve çatışma çözümü.
- **Android Client:** Bekleme gerekçesi ve süreli elle geçersiz kılma.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** İlk kapsam Core üzerinden geçen eylemler; harici HA otomasyonları ayrıca eşlenir.
- **Dayanak:** [OPA politika dili](https://www.openpolicyagent.org/docs/policy-language).

### 05. Uzun süren ev iş akışları

Servisler arasında ilerleyen bir süreç yeniden başlatmada yerini kaybetmesin.

- **Core:** Kalıcı durum, son tarihler, insan kararı bekleme ve telafi adımları.
- **Android Client:** İlerleme, devam ve iptal ekranı.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** S06 işlerinden genel ev süreçlerine genişler; fiziksel komutlar körlemesine tekrarlanmaz. Temporal zorunlu bağımlılık değil, tasarım örneği.
- **Dayanak:** [Temporal kalıcı yürütme](https://docs.temporal.io/workflow-execution).

### 06. Bunu kim, neden yaptı? · ★ önerim

Kapanan ışığın veya duran müziğin hangi kullanıcı ya da kuralla ilişkili olduğunu gör.

- **Core:** Bağlam kimlikleriyle kullanıcı, kural, servis ve sonuç zinciri.
- **Android Client:** Anlaşılır neden açıklaması ve ilgili kurala bağlantı.
- **Efor / kapsam:** Orta · Genişleme
- **Gereksinim / sınır:** Mevcut işlem/audit kayıtlarının uzantısı; yalnız zaman yakınlığı nedensellik sayılmaz.
- **Dayanak:** [Home Assistant olay bağlamı](https://www.home-assistant.io/docs/configuration/events/), [OpenTelemetry izleri](https://opentelemetry.io/docs/concepts/signals/traces/).

### 07. Evin alışılmış düzeninden sapmalar

Her gece kopan hub veya giderek geciken servis için erken inceleme önerisi al.

- **Core:** Yerel istatistikler ve değişim algılama.
- **Android Client:** Kanıt grafiği, normal olarak işaretleme ve uyarı ayarı.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** İzleme ekranlarının uzantısı; yeterli geçmiş ve yanlış alarm ayarı gerekir.
- **Dayanak:** [River anomali ve değişim algılama](https://github.com/online-ml/river).

### 08. Yapay zekâ kaynak yöneticisi

Film izlenirken ağır AI işleri beklesin; hızlı komutlar öncelik alsın.

- **Core:** Model yükleme, kuyruk ve bellek/işlem bütçeleri.
- **Android Client:** Bekleme nedeni ile hız/kalite seçimi.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** Model ve donanıma göre ölçülür; küçük sunucuda büyük model hızı garanti edilmez.
- **Dayanak:** [Ollama bellek ve paralellik](https://docs.ollama.com/faq).

### 09. Görülebilir, süreli AI hafızası

Asistanın hangi tercihini neden hatırladığını gör; düzelt veya unuttur.

- **Core:** Kişi ve kaynak bazlı bağlam, sona erme ve silme.
- **Android Client:** Hafıza listesi ve kişi/oda/süre kontrolleri.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** Arama filtresi tek başına yetki değildir; silme indeks ve yedek politikasına da bağlanır.
- **Dayanak:** [Qdrant filtreleme temeli](https://qdrant.tech/documentation/search/filtering/).

### 10. Kanıta dayalı arıza yardımcısı

Jellyfin açılmıyorsa ağ, disk ve bağımlılıkları bir arada inceleyen yardım al.

- **Core:** Sınırlı tanılama, bağımlılık haritası ve kanıt toplama.
- **Android Client:** Olası neden, doğrulanan neden ve sonraki adımı ayırma.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** Mevcut servis sağlığının uzantısı; sırlar modele aktarılmaz, değişiklikler ayrı kullanıcı kararıdır.
- **Dayanak:** [OpenTelemetry hassas veriler](https://opentelemetry.io/docs/security/handling-sensitive-data/).

## 11–20: Core, güvenlik ve dayanıklılık

### 11. Sınırlı yetkili mini eklentiler

Özel hesaplama ve kural işlevi eklerken tüm sunucuyu açmak gerekmesin.

- **Core:** WebAssembly, süre/bellek sınırı ve izinli host işlevleri.
- **Android Client:** İstenen yetkiler, sürüm ve devre dışı bırakma.
- **Efor / kapsam:** Çok büyük · Genişleme
- **Gereksinim / sınır:** S06 Docker bileşenlerinden ayrı bir eklenti sınıfı; sınırsız host işlevleri izolasyonu bozabilir.
- **Dayanak:** [Extism manifesti](https://extism.org/docs/concepts/manifest/).

### 12. Yetkili MCP kapısı

Seçtiğin AI uygulaması yalnız izin verdiğin Larenor bilgileri ve araçlarına ulaşsın.

- **Core:** Dar araç kataloğu, kimlik, izin ve çağrı sınırı.
- **Android Client:** Asistan yetkilerini inceleme ve iptal etme.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** MCP uyumlu istemci gerekir; protokol desteği araçları güvenilir yapmaz.
- **Dayanak:** [MCP mimarisi](https://modelcontextprotocol.io/docs/learn/architecture).

### 13. Bileşen bazında internet izinleri

Hangi bileşenin hangi dış adrese bağlandığını gör ve gereksiz çıkışları kapat.

- **Core:** Yönetilen ağlar ve zorunlu çıkış geçidi.
- **Android Client:** Bağlantı amacı, hedef listesi ve izin farkları.
- **Efor / kapsam:** Çok büyük · Genişleme
- **Gereksinim / sınır:** İlk kapsam yönetilen bileşenler; host ağı kullanan müzik/keşif profilleri ayrıca çözülür. HTTPS içeriği okunmuş sayılmaz.
- **Dayanak:** [Docker bridge ağları](https://docs.docker.com/engine/network/drivers/bridge/), [Squid hedef kuralları](https://www.squid-cache.org/Doc/config/acl/).

### 14. Süreli destek oturumu

Yardım eden kişiye 20 dakika yalnız seçtiğin servislerin tanılamasını aç.

- **Core:** Nesne/eylem/süre bazlı yetki ve anlık iptal.
- **Android Client:** Kapsam, kalan süre ve yapılan işlemler.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** Mevcut admin/member rollerinin ötesi; uzak bağlantı ve her API'de yetki denetimi gerekir.
- **Dayanak:** [OpenFGA süreli koşullar](https://openfga.dev/docs/modeling/conditions).

### 15. Doğrulanabilir bileşen güncellemeleri

Yeni bileşenin yayıncısını ve değişen izinlerini güncellemeden önce gör.

- **Core:** İmza, üretici kimliği, digest ve derleme kanıtı doğrulama.
- **Android Client:** Kaynak/izin farkı ve yayın tercihi.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** Digest sabitlemenin ötesi; upstream imzası bulunmayabilir. İmza hatasızlık kanıtı değildir.
- **Dayanak:** [Sigstore doğrulama](https://docs.sigstore.dev/cosign/verifying/verify/).

### 16. Otomatik kurtarma tatbikatı · ★ önerim

Yedeğin yalnız var olduğunu değil, izole ortamda gerçekten açıldığını gör.

- **Core:** Geri yükleme, veritabanı ve uygulama smoke kontrolleri.
- **Android Client:** Son başarılı tatbikat, kapsam ve ölçülen süre.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** S09 yedeğinin uzantısı; ek disk/işlem bütçesi gerekir, test ortamı ev cihazlarına komut göndermez.
- **Dayanak:** [restic bütünlük kontrolü](https://restic.readthedocs.io/en/stable/045_working_with_repos.html).

### 17. Yedekleri silmeye kapalı kurtarma hedefi

Core'daki yedekleme hesabı ele geçirilse bile eski uzak kopyaları silemesin.

- **Core:** Şifreli, yalnız ekleme yetkili kopyalar ve kota izlemesi.
- **Android Client:** Korunan tarih aralığı ve geri dönüş noktaları.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** Ayrı yetki alanındaki NAS/uzak hedef gerekir; hedef yöneticisinin ele geçirilmesine karşı mutlak koruma değildir.
- **Dayanak:** [rest-server append-only](https://github.com/restic/rest-server).

### 18. Elektrik kesintisinde düzenli kapanış

UPS azalırken ağır işleri durdur; enerji gelince servisleri doğru sırayla aç.

- **Core:** UPS olayları ve bağımlılığa göre kapanış/başlangıç.
- **Android Client:** Kalan kapasite ve yürütülen adımlar.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** Desteklenen UPS ve işletim sistemi yetkileri gerekir; süre tahminidir, ağ cihazlarının gücü de hesaba katılır.
- **Dayanak:** [Network UPS Tools](https://networkupstools.org/features.html).

### 19. Birden fazla ev, bağımsız Core

Ev ve yazlık aynı Client'ta görünsün; her ev bağlantı kopsa da yerel çalışsın.

- **Core:** Evler arası güven, izinli veri paylaşımı ve bağımsız yerel kararlar.
- **Android Client:** Ev seçimi, bağlantı ve güncellik görünümü.
- **Efor / kapsam:** Çok büyük · Yeni
- **Gereksinim / sınır:** Headscale yalnız bağlantı temeli; Larenor federasyonu, yetki ve eşitleme ayrıca geliştirilir.
- **Dayanak:** [Headscale kapsamı](https://headscale.net/).

### 20. Değiştirilmesi fark edilen işlem günlüğü

Kritik izin ve işlem kayıtlarının sonradan oynanıp oynanmadığını denetle.

- **Core:** Kriptografik kayıt zinciri ve doğrulama noktaları.
- **Android Client:** Doğrulama, güvenilen kontrol noktasını dışa aktarma.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** Core dışında güvenilen kontrol noktası gerekir; fiziksel olayın doğruluğunu tek başına kanıtlamaz.
- **Dayanak:** [immudb doğrulama mekanizmaları](https://github.com/codenotary/immudb).

## 21–30: Medya ve müzik

### 21. Birlikte senkron film izleme · ★ önerim

Aile üyeleri farklı ekranlarda aynı filmi ortak duraklatma ve konumla izlesin.

- **Core:** Jellyfin SyncPlay grup/oturum eşleme ve erişim denetimi.
- **Android Client:** İzleme odası, davet ve ortak oynatma kontrolleri.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** Desteklenen oynatıcılar ve gecikme testleri gerekir; her Cast/Apple TV hedefi otomatik uyumlu sayılmaz.
- **Dayanak:** [Jellyfin SyncPlay API kaynağı](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/SyncPlayController.cs).

### 22. Kendi televizyon kanalların

Arşivinden çizgi film, belgesel veya nostalji kanalı ve yayın akışı oluştur.

- **Core:** Tunarr benzeri zamanlama ve dahili Jellyfin kaynak eşlemesi.
- **Android Client:** Kanal rehberi ve sürüklenebilir yayın planı.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** Sahip olunan/izinli arşivle çalışır; sürekli dönüştürme işlemci veya GPU kullanabilir.
- **Dayanak:** [Tunarr kanal ve zamanlama özellikleri](https://github.com/chrisbenincasa/tunarr).

### 23. Canlı TV ve kayıt merkezi

Yayın rehberini, tek program veya dizi kayıtlarını medya ekranından yönet.

- **Core:** Jellyfin tuner, EPG ve kayıt zamanlaması adaptörü.
- **Android Client:** Rehber, kayıt çakışması ve kayıtlı yayınlar.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** Uyumlu tuner veya yetkili yayın kaynağı ve EPG gerekir; abonelik yayınının kilidini açmaz.
- **Dayanak:** [Jellyfin Live TV](https://jellyfin.org/docs/general/server/live-tv/).

### 24. Akıllı altyazı ve dil tercihleri · ★ önerim

Türkçe altyazı, işitme desteği ve tercih edilen ses dili başlığa göre hazır olsun.

- **Core:** Bazarr altyazı profilleri ve Jellyfin mevcut ses izlerinin eşlenmesi.
- **Android Client:** Kişisel altyazı/ses dili tercihi, mevcut oynatıcı kanalları ve eksik dil durumu.
- **Efor / kapsam:** Orta · Genişleme
- **Gereksinim / sınır:** S07 altyazı adayının uzantısı; sağlayıcı hesabı/kotası gerekir. İstenen ses dili yalnız mevcut ve desteklenen ses izi varsa seçilir.
- **Dayanak:** [Bazarr dil profilleri](https://wiki.bazarr.media/Getting-Started/Setup-Guide/), [Android Media3 kanal seçimi](https://developer.android.com/media/media3/exoplayer/track-selection).

### 25. Jenerik ve kapanış atlama

Dizilerde giriş veya kapanış bölümlerini tercihinle atla.

- **Core:** Intro Skipper segmentleri ve sürüm uyumluluğu.
- **Android Client:** Atla düğmesi ve kullanıcıya özel otomatik atlama seçimi.
- **Efor / kapsam:** Orta · Yeni
- **Gereksinim / sınır:** Algılama hataları ve bölüm istisnaları görünür kalır; her istemcide eklenti desteği varsayılmaz.
- **Dayanak:** [Intro Skipper](https://github.com/intro-skipper/intro-skipper).

### 26. Oynatma kalitesi danışmanı

Bu filmi tablette veya TV'de neden doğrudan oynatamıyorum, anlaşılır biçimde gör.

- **Core:** Codec, ses, altyazı, bitrate ve transcode kanıtlarını birleştirme.
- **Android Client:** Cihaz uyumu ve kalite/işlem yükü seçenekleri.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** Medya durumunun ileri uzantısı; HDR/codec gerçek cihazda sınanır, dosya bilgisi tek başına garanti değildir.
- **Dayanak:** [Jellyfin transcoding](https://jellyfin.org/docs/general/post-install/transcoding/).

### 27. Seyahat için çevrimdışı medya

İzinli film ve müziği kota belirleyerek tablete al; bağlantısız devam et.

- **Core:** İndirme yetkisi, uygun sürüm ve hesap sahipliği.
- **Android Client:** İndirme yöneticisi, yarıda devam ve depolama bütçesi.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** Önceki çevrimdışı müzik fikrini genişletir. Spotify/Apple Music/Netflix aboneliği dosya indirme veya DRM aşma yetkisi değildir.
- **Dayanak:** [Android Media3 indirme](https://developer.android.com/media/media3/exoplayer/downloading-media), [Finamp çevrimdışı müzik](https://github.com/finamp-app/finamp).

### 28. Sesli kitap ve podcast merkezi

Bölümler, yer imleri, hız ve kaldığın yer farklı tabletlerde korunsun.

- **Core:** Audiobookshelf/RSS ve kullanıcı ilerlemesi eşlemesi.
- **Android Client:** Bölüm listesi, yer imi, uyku sayacı ve oynatma.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** Önceki müzik planının uzantısı; kaynak erişimi gerekir, her ücretli kitap sağlayıcısı desteklenmez.
- **Dayanak:** [Audiobookshelf özellikleri](https://audiobookshelf.org/docs/documentation/introduction/).

### 29. Parti DJ'i ve ortak şarkı oylaması

Misafirler sınırlı bir oturumda şarkı önersin; ev sahibi sırayı kontrol etsin.

- **Core:** Music Assistant kuyruğuna bağlanan Larenor oy/istek kuralları.
- **Android Client:** Ortak liste, oy ve ev sahibinin onayı.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** MA parti/kuyruk desteği temel alınır; oylama Larenor geliştirmesidir. Sağlayıcı ve oynatıcı izinleri korunur.
- **Dayanak:** [Music Assistant Party](https://www.music-assistant.io/plugins/party/), [Music Assistant API](https://www.music-assistant.io/api/).

### 30. Medya arşivi sağlık ve yer tasarrufu

Bozuk, gereksiz büyük veya gereksiz kopya içerikleri işlemden önce incele.

- **Core:** Dosya analizi, dönüştürme adayları ve doğrulanmış kopya işlemleri.
- **Android Client:** Kazanım tahmini, kalite farkı ve seçili işlem onayı.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** Unmanic işleme temeli; kopya eşleme ve önizleme Larenor'a ait. Varsayılan otomatik silme yok; kalite/kazanç ölçülür.
- **Dayanak:** [Unmanic Library Optimiser](https://github.com/Unmanic/unmanic).

## 31–40: Aile ve ev yaşamı

### 31. Haftalık menü ve tarif merkezi · ★ önerim

Tarifleri içe al, haftanın menüsünü planla ve gerekenleri alışverişe aktar.

- **Core:** Mealie tarif, menü ve alışveriş eşlemesi.
- **Android Client:** Haftalık tablet görünümü ve porsiyon seçimi.
- **Efor / kapsam:** Orta · Yeni
- **Gereksinim / sınır:** Mevcut basit alışveriş listesinden ayrı tarif modeli gerekir; kaynak siteden içe alma her sitede çalışmayabilir.
- **Dayanak:** [Mealie özellikleri](https://docs.mealie.io/documentation/getting-started/features/).

### 32. Dolap stoğu ve son kullanma takibi

Barkodla ekle; evde ne var, önce ne tüketilmeli gör.

- **Core:** Grocy stok, miktar, tarih ve ürün eşlemesi.
- **Android Client:** Barkod tarama, tüketim ve eksilenleri listeleme.
- **Efor / kapsam:** Orta · Yeni
- **Gereksinim / sınır:** Stok doğruluğu girişlere bağlıdır; son kullanma bilgisi görüntüden kesin çıkarılmaz.
- **Dayanak:** [Grocy stok ve barkod özellikleri](https://grocy.info/).

### 33. Büyük ekran pişirme asistanı

Tarifi büyük adımlarla izle; birden fazla zamanlayıcıyı aynı ekranda yönet.

- **Core:** Tarif oturumu ve ev üyeleri arasında adım eşitleme.
- **Android Client:** Dokunmatik pişirme görünümü, porsiyon ve adım zamanlayıcıları.
- **Efor / kapsam:** Orta · Yeni
- **Gereksinim / sınır:** 31 ile ortak tarif temeli; fırın veya ocak kontrolü ilk kapsamda otomatik değildir.
- **Dayanak:** [Mealie tarif/API temeli](https://docs.mealie.io/documentation/getting-started/api-usage/).

### 34. QR etiketli ev envanteri · ★ önerim

Eşyayı tara; bulunduğu yer, garanti tarihi, fatura ve bakım geçmişini aç.

- **Core:** HomeBox envanterine oda/cihaz ve belge ilişkileri ekleme.
- **Android Client:** QR üretme/tarama ve eşya ayrıntısı.
- **Efor / kapsam:** Orta · Yeni
- **Gereksinim / sınır:** Etiket ve garanti akışı Larenor tasarımıdır; QR kod tek başına özel belgeye erişim sağlamaz.
- **Dayanak:** [HomeBox envanter projesi](https://github.com/sysadminsmedia/homebox).

### 35. Ev belgeleri ve garanti hatırlatmaları

Fatura ve kılavuzları metinle ara; cihazın yanında doğru belgeyi bul.

- **Core:** Paperless OCR/arşiv eşlemesi ve tarihli hatırlatmalar.
- **Android Client:** Yetkili belge arama, önizleme ve cihaz bağlantısı.
- **Efor / kapsam:** Orta · Genişleme
- **Gereksinim / sınır:** Önceki Paperless araştırmasını somutlaştırır; OCR ile çıkarılan garanti tarihi kullanıcıca doğrulanır.
- **Dayanak:** [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx).

### 36. Adil ev işi paylaşımı

Ev işleri sırayla paylaşılsın; geciken işlerde sonraki tarih gerçek tamamlamaya göre oluşsun.

- **Core:** Donetick benzeri görev dönüşümü, tekrar ve tamamlanma geçmişi.
- **Android Client:** Kişisel görevler, devretme ve aile görünümü.
- **Efor / kapsam:** Orta · Genişleme
- **Gereksinim / sınır:** Bugün listesinin ileri uzantısı; dış API erişim kapsamı hedef sürümde doğrulanır.
- **Dayanak:** [Donetick atama ve zamanlama](https://github.com/donetick/donetick).

### 37. Ortak ev masrafları

Market, aidat ve ortak harcamalarda kimin ne ödediği görülsün.

- **Core:** Paylaşım kuralları, kayıtlar ve hesaplama.
- **Android Client:** Fiş ekleme ve kişi bazında denge özeti.
- **Efor / kapsam:** Orta · Yeni
- **Gereksinim / sınır:** Spliit ürün örneği; banka bağlantısı/ödeme otomasyonu yok. Para birimleri açık tutulur.
- **Dayanak:** [Spliit ortak masraflar](https://github.com/spliit-app/spliit).

### 38. Aile anıları ve fotoğraf araması

Aile fotoğraflarını konu veya tarihle bul; seçilen anıları tablet albümüne ekle.

- **Core:** Immich arama ve izinli albüm/asset eşlemesi.
- **Android Client:** Anı seçimi ve kişisel/paylaşılan albüm sınırı.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** Mevcut fotoğraf ortam ekranından ileriye gider; Türkçe model, bellek ve albüm izinleri ayrıca sınanır.
- **Dayanak:** [Immich arama](https://docs.immich.app/features/searching/).

### 39. Canlı aile panosu ve beyaz tahta

Bir tablette yazılan not veya çizim diğer aile ekranında anında görünsün.

- **Core:** Paylaşılan belge durumu, sürümler ve yetki.
- **Android Client:** Kalem/dokunma ile not ve çizim; bağlantı sonrası uzlaştırma.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** Yjs bir işbirliği örneğidir; Flutter veri köprüsü ayrıca yapılır. Silinen özel notlar önbellekten de kaldırılır.
- **Dayanak:** [Yjs ortak veri yapıları](https://github.com/yjs/yjs).

### 40. Ortak kaynak rezervasyonu

Araba, çalışma odası veya ortak ekipman için çakışmayan kullanım planı yap.

- **Core:** Takvim müsaitliği ve rezervasyon çakışma denetimi.
- **Android Client:** Kaynak/saat seçimi ve aile takvimi.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** Bugün takvim okumasının ötesi; kaynak kuralları Larenor'a ait, zaman dilimi ve çift kayıt testi gerekir.
- **Dayanak:** [Nextcloud Calendar](https://docs.nextcloud.com/server/latest/user_manual/en/groupware/calendar.html).

## 41–50: Kamera, enerji ve konfor

### 41. Kamera kayıtlarında doğal dille arama

Dün kapının önündeki kırmızı çantayı veya arabayı tarif ederek kaydı bul.

- **Core:** Frigate yerel anlamsal indeks ve yetkili olay araması.
- **Android Client:** Metin/görüntü araması ve olay önizlemesi.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** Frigate en az 8 GB RAM belirtiyor; Türkçe model ve sunucu mimarisi ayrıca doğrulanır. Sonuçlar olasılıksaldır.
- **Dayanak:** [Frigate Semantic Search](https://docs.frigate.video/configuration/semantic_search/).

### 42. Mahremiyet korumalı olay paylaşımı

Seçili kamera klibini kırp, özel bölgeyi bulanıklaştır ve süreli paylaş.

- **Core:** Yetkili export, yeniden kodlama ve süreli erişim.
- **Android Client:** Klip aralığı, gizlenecek bölge ve paylaşım önizlemesi.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** Frigate kayıt/export temel alınır; bulanıklaştırma ve link yetkisi Larenor geliştirmesidir. Sonuç kullanıcıca izlenir.
- **Dayanak:** [Frigate kayıt sistemi](https://docs.frigate.video/configuration/record/).

### 43. Evdeyken kamera kayıt profili

Seçtiğin odalarda Frigate kayıt ve algılama ayarlarını evde/misafir durumuna göre yönet.

- **Core:** Frigate kayıt/algılama politikası ve varsa üreticiye özgü gizlilik API doğrulaması.
- **Android Client:** Oda bazında görünür gizlilik durumu ve elle kontrol.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** Frigate ses algılamasını kapatmak mikrofonu kapatmaz; kamera veya başka kayıtçılar çalışabilir. Gerçek mikrofon kapatma/kapak yalnız üretici API’siyle doğrulanır.
- **Dayanak:** [Frigate MQTT kayıt/ses kontrolleri](https://docs.frigate.video/integrations/mqtt/).

### 44. Kameradan görsel sensörler

Sabit görüntü alanından garaj açık mı veya çöp kutusu dışarıda mı öğren.

- **Core:** Kullanıcı örnekleriyle sınıflandırma ve güven eşiği.
- **Android Client:** Alan çizimi, doğru/yanlış örnek ve bilinmiyor durumu.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** Önce kavram kanıtı; Frigate yolu eğitim ve çıkarımda AVX/AVX2 ister, ARM64 Core desteği varsayılmaz. Kilit açma kimliği yerine kullanılmaz.
- **Dayanak:** [Frigate State Classification](https://docs.frigate.video/configuration/custom_classification/state_classification/).

### 45. Havlama ve gürültü olayları

Seçili mikrofonlu kamerada olağandışı sesin zamanını ve kısa kaydını gör.

- **Core:** Yerel ses sınıflandırması, eşik ve olay saklama.
- **Android Client:** İzinli ses türleri, sessiz saatler ve yanlış alarm geri bildirimi.
- **Efor / kapsam:** Orta · Yeni
- **Gereksinim / sınır:** Mikrofonlu uyumlu kamera ve ev halkının tercihi gerekir; sertifikalı alarm veya acil durum sistemi yerine geçmez.
- **Dayanak:** [Frigate Audio Detectors](https://docs.frigate.video/configuration/audio_detectors/).

### 46. Elektrikli araç şarj planlayıcısı

Sabah hedef şarja hazır ol; uygun tarife veya güneş üretimini kullan.

- **Core:** evcc şarj planı, sayaç ve araç yetenekleri.
- **Android Client:** Ayrılış saati, hedef doluluk ve maliyet görünümü.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** Uyumlu araç/şarj cihazı gerekir; Türkiye tarifesi sabit veya elle tanımlı olabilir, dinamik fiyat API'si varsayılmaz.
- **Dayanak:** [evcc tarife ve şarj planı](https://docs.evcc.io/en/features/dynamic-prices/).

### 47. Güneş ve ev bataryası öncelikleri

Üretilen enerjinin önce eve, bataryaya veya araca ayrılmasını ayarla.

- **Core:** İnverter/sayaç durumu ve desteklenen batarya kontrolü.
- **Android Client:** Enerji akışı, rezerv ve öncelik ayarı.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** Uyumlu inverter/batarya gerekir; tahmin ayrı gösterilir. evcc optimizer şu anda deneysel ve bilgilendirici.
- **Dayanak:** [evcc Home Battery](https://docs.evcc.io/en/features/battery/), [evcc deneysel optimizer](https://docs.evcc.io/en/features/optimizer/).

### 48. Ev güç bütçesi

Yüksek tüketimli işler aynı anda yığılmasın; ertelenebilenler sıraya alınsın.

- **Core:** Sayaç verisi, öncelikler ve desteklenen yük sınırları.
- **Android Client:** Anlık bütçe ve hangi işin neden beklendiği.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** evcc load management deneysel; ilk kapsam uyumlu şarj yükleri. Evdeki tüm yükler veya elektrik koruması kapsanmış sayılmaz.
- **Dayanak:** [evcc Load Management](https://docs.evcc.io/en/features/loadmanagement/).

### 49. Bahçe sulama ve su bütçesi

Sulama bölgelerini, sürelerini ve mevcut ölçümle tüketimi birlikte yönet.

- **Core:** OpenSprinkler programları, hava/yağmur ve varsa debi verisi.
- **Android Client:** Bölge haritası, program ve su kullanım görünümü.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** Uyumlu kontrolcü/vanalar, debi için ayrıca sayaç gerekir; elektronik kurulum bu yazılım adayıyla tamamlanmaz.
- **Dayanak:** [OpenSprinkler Firmware](https://github.com/OpenSprinkler/OpenSprinkler-Firmware).

### 50. Oda konforu ve havalandırma planı

Sıcaklık, nem ve varsa CO₂ verisini birleştir; hangi odayla ilgilenileceğini gör.

- **Core:** HA sensör/iklim adaptörleri; veri birleştirme ve havalandırma önceliği Larenor geliştirmesidir.
- **Android Client:** Oda karşılaştırması, ölçüm kaynağı ve kullanıcı eşikleri.
- **Efor / kapsam:** Orta · Genişleme
- **Gereksinim / sınır:** Enerji/oda kartlarının uzantısı; sensör ve kalibrasyon gerekir. Tıbbi veya kesin küf teşhisi üretmez.
- **Dayanak:** [Home Assistant Mold Indicator modeli](https://www.home-assistant.io/integrations/mold_indicator/), [Home Assistant Sensor](https://www.home-assistant.io/integrations/sensor/), [Home Assistant Climate](https://www.home-assistant.io/integrations/climate/).

## 51–60: Tablet ve yeni cihazlar

### 51. Etkileşimli ev kat planı · ★ önerim

Işık, kamera ve sensörleri kart listesi yerine ev çizimi üzerinde kullan.

- **Core:** Kalıcı oda/cihaz eşlemeleri ve yetkili durum akışı.
- **Android Client:** Dokunulabilir 2D plan; isteğe bağlı hafif 3D görünüm.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** Mevcut oda/kart düzeninin yeni sunumu; 3D performansı ayrıca sınanır, plan otomatik ölçülmüş sayılmaz.
- **Dayanak:** [HA Floorplan](https://github.com/ExperienceLovelace/ha-floorplan).

### 52. DeX'te iki ekrana farklı görev

Harici ekranda film veya ev özeti, tablette kumanda ve ayrıntı göster.

- **Core:** Aynı kullanıcıya ait ortak medya/durum oturumu.
- **Android Client:** Bağlı ekran yönetimi ve ekran başına farklı görünüm.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** Aynı Android uygulamasıdır. Mevcut pencere uyumundan ileri; OEM, dock ve korumalı medya yolu cihazda sınanır.
- **Dayanak:** [Android bağlı ekranlar](https://developer.android.com/develop/ui/compose/layouts/adaptive/support-connected-displays).

### 53. Evdeki tabletleri tek yerden yönetme

Mutfak ve salon tabletine ayrı düzen, ekran programı ve güncelleme grubu uygula.

- **Core:** Cihaz kaydı, sürümlü profiller ve kademeli dağıtım.
- **Android Client:** Profil önizlemesi, uygulanma kanıtı ve yerel acil çıkış.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** Fully Kiosk/uzaktan yönetim planının ileri uzantısı; bazı işlemler device-owner ister, her Huawei/OEM izni varsayılmaz.
- **Dayanak:** [Android dedicated devices](https://developer.android.com/work/dpc/dedicated-devices).

### 54. Google servislerinden bağımsız bildirim · ★ önerim

Desteklenen Huawei/Android tablette Larenor olaylarını Google push'a bağlı olmadan al.

- **Core:** Kendi bildirim akışı, kimlik ve teslim/okunma ayrımı.
- **Android Client:** İzinli arka plan alıcısı ve pil politikası.
- **Efor / kapsam:** Büyük · Genişleme
- **Gereksinim / sınır:** ntfy yaklaşımı kalıcı bildirimli foreground service gerektirebilir; kapatılırsa teslim gecikebilir. Ayrı ntfy uygulaması zorunlu hedef değil. Huawei/OEM Android ve güç davranışı cihazda sınanır.
- **Dayanak:** [ntfy Google bağımsız Android teslimi](https://docs.ntfy.sh/subscribe/phone/).

### 55. Zigbee/Thread ağ ve güncelleme merkezi

Cihaz ağını, zayıf bağlantıları ve uygun firmware güncellemelerini aynı yerden gör.

- **Core:** Zigbee koordinatörü OTA/ağ adaptörü ve Thread border router durum bilgisi.
- **Android Client:** Ağ haritası, pil/uyumluluk önizlemesi ve güncelleme takibi.
- **Efor / kapsam:** Çok büyük · Yeni
- **Gereksinim / sınır:** Uygun koordinatör/border router gerekir; OTA ilk kapsamda desteklenen Zigbee modelleridir. Thread ve Matter aynı şey değildir; var olan HA ağı otomatik sahiplenilmez.
- **Dayanak:** [Zigbee2MQTT OTA](https://www.zigbee2mqtt.io/guide/usage/ota_updates.html), [OpenThread Border Router](https://openthread.io/guides/border-router).

### 56. Eski cihazlar için akıllı kumanda

IR kumandalı TV, klima veya ampliyi Larenor'da oda kumandasına ekle.

- **Core:** ESPHome köprüsü, kod/protokol ve izinli komut kaydı.
- **Android Client:** Kumanda öğrenme ve cihaza uygun kontrol yüzeyi.
- **Efor / kapsam:** Orta · Yeni
- **Gereksinim / sınır:** IR alıcı/verici donanımı gerekir; gönderilmiş sinyal cihazın durumunu doğrulamaz, protokol desteği değişir.
- **Dayanak:** [ESPHome Remote Transmitter](https://esphome.io/components/remote_transmitter/).

### 57. Oda düzeyinde yerel varlık algısı

İzin verdiğin etiketin hangi odada olabileceğini kullanarak oda deneyimini öner.

- **Core:** ESPresense/BLE ölçümleri, güven eşiği ve yerel geçmiş sınırı.
- **Android Client:** Katılım, oda kalibrasyonu ve öneri onayı.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** ESP32 düğümler/uyumlu etiket gerekir; BLE yaklaşık sonuç verir ve kimlik doğrulama veya kapı açma anahtarı değildir.
- **Dayanak:** [ESPresense](https://espresense.com/).

### 58. E-paper mini ev ekranları

Oda etiketi, çöp günü veya enerji özetini küçük, düşük tüketimli ekranlara gönder.

- **Core:** OpenEPaperLink şablonları, veri seçimi ve güncelleme bütçesi.
- **Android Client:** Ekran eşleştirme ve tasarım önizlemesi.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** Desteklenen e-paper etiket ve erişim noktası gerekir; Android Client'ın yerini alan yeni bir tablet uygulaması değildir.
- **Dayanak:** [OpenEPaperLink](https://github.com/OpenEPaperLink/OpenEPaperLink).

### 59. 3D yazıcı ve atölye merkezi

Baskı süresi, sıcaklık, kamera ve tamamlanmayı ev panelinde takip et.

- **Core:** OctoPrint iş/cihaz API'leri ve sınırlı eylemler.
- **Android Client:** Baskı kartı, olaylar ve açık onaylı duraklatma/iptal.
- **Efor / kapsam:** Büyük · Yeni
- **Gereksinim / sınır:** Uyumlu yazıcı ve OctoPrint gerekir; ilk sürüm izleme odaklı, keyfi G-code veya otomatik uzaktan başlatma yok.
- **Dayanak:** [OctoPrint REST API](https://docs.octoprint.org/en/main/api/index.html).

### 60. Tablette ev bilgisayarından oyun yayını

Oyun bilgisayarını seç, eşleştir ve tableti/DeX ekranını oyun ekranına dönüştür.

- **Core:** Desteklenen oyun hostu keşfi, yetki ve oturum yönetimi.
- **Android Client:** Moonlight tabanlı yerel yayın, gamepad ve gecikme kontrolleri.
- **Efor / kapsam:** Çok büyük · Yeni
- **Gereksinim / sınır:** Önce kavram kanıtı; Sunshine uyumlu oyun bilgisayarı/GPU gerekir. Android native entegrasyon ve lisans koşulları ayrıca değerlendirilir.
- **Dayanak:** [Moonlight ve Sunshine](https://moonlight-stream.org/).

## Ortak bağımlılıklar ve önerilen teslim ölçütü

- **01–10:** Yetkili olay/eylem modeli tamamlandıktan sonra. Önce kanıt zinciri ve deneme yürütücüsü; sonra AI önerileri. LLM doğruluğu güvenlik sınırı değildir.
- **11–20:** Mevcut eklenti, rol ve yedek temellerinin üzerine. Her yetenek için yetki iptali, yeniden başlatma ve hata kurtarma kabulü ayrı tutulur.
- **21–30:** S07/S08 ve gerçek medya hedefleri. Kaynak hakkı, provider oturumu, codec ve cihaz yeteneği aynı anda denetlenir.
- **31 + 33:** Ortak tarif altyapısını paylaşır; menü/alışveriş planı ile etkileşimli pişirme oturumu ayrı teslimlerdir.
- **34 + 35:** Envanter kaydıyla özel belgeleri bağlar; QR, belge yetkisini atlayamaz.
- **41–45:** Uyumlu kamera ve yeterli Core donanımı. Algılama, kayıt, mikrofon yakalama ve üretici gizlilik modu ayrı durumlar olarak sınanır.
- **46–49, 55–60:** Belirtilen ek donanım veya servis varsa değerlendirilir. Önce yetenek kontrolü ve salt okunur kabul; sonra izinli test ortamı.
- **51–54:** Aynı Android uygulamasının tablet deneyimi. Huawei/OEM, harici ekran, arka plan, büyük yazı, TalkBack ve klavye kabulü yapılır.

Plandaki her pakette ortak tasarım, yetki/account izolasyonu, çevrimdışı/yeniden bağlantı, boyut/zaman sınırları, unit/contract/widget ve uygun E2E testleri bulunur. Fiziksel kabul gerektiren durumlar sentetik testlerle tamamlandı sayılmaz. Üretim Home Assistant salt okunur kalır.
