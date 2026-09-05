# Larenor — ortak ürün yapısı için 12 proje karşılaştırması

**5 Eylül 2026 · Araştırma ve uygulama önerisi.** Bu çalışma ilgili 12 projenin resmi belgelerini ve kaynak depolarını seçerek karşılaştırır; bütün akıllı ev projelerinin tarandığı veya Larenor'un bu ürünlerin bütün özelliklerini sağladığı iddiası değildir. Aşağıdaki değer/efor puanları ürün değerlendirmesidir, ölçülmüş kullanıcı araştırması değildir. Kod, görsel, marka veya model ağırlığı kopyalanmadı; üretim servisine ya da cihaza yazma yapılmadı.

## Başlangıç noktası

[Uygulama planının](product-implementation-plan-2026-09-05.md) güncel takip listesinde 0–3 ve 2a tamamlandı: yapılandırma yedeği, ortak gezinme/yerel arama, bağlantı ve işlem kanıtı, Bugün ve diafon temeli var. Eski plan metnindeki “ortak arama yok” ve “hata boş kütüphane oluyor” maddeleri ilk inceleme bulgularıdır; yeni öneriler bunları yeniden yaptırmaz. Canlı cihaz ve elektronik kabulü ayrı kalır.

Kodda `AppPageScaffold`, tipli gezinme hedefleri, `IntegrationHealth`, işlem makbuzları, `MediaLibraryIndex` ve kısmi okuma hatalarını taşıyan `MediaReadList` yeniden kullanılabilir. `TodaySnapshot` listeleri/takvimi/bildirimleri, `DoorStation` ise devreye alınmış diafon eşleştirmesini temsil ediyor. Yeni ürün yapısı bunların üzerine kurulmalı. Apple Home esintili ortak tema, mevcut logo ve **“Unus Lar, omnem domum servat.”** sloganı korunmalı; her modül kendi sloganını veya başka bir gezinme düzenini üretmemeli.

## Kaynak ve lisans matrisi

Lisanslar inceleme tarihindeki depo ana lisansıdır. Üçüncü taraf modüller, fontlar, logolar ve öğrenilmiş modeller ayrıca kontrol edilir. İleride kod aktarımı seçilirse ilgili dosya ve sürümün lisansı/NOTICE yükümlülükleri yeniden incelenir; kavramsal örnek almak doğrudan kaynak aktarımı anlamına gelmez. Bağlantılar canlı dallardır, değişebilir.

| Proje | Resmi kaynakta görülen yararlı davranış | Larenor'a taşınacak fikir / mevcut durum | Kaynak lisansı |
| --- | --- | --- | --- |
| Home Assistant Frontend / Sections | Bölümlere ayrılmış ızgara, sürükleyerek düzenleme, koşullu görünürlük ve başlık rozetleri. [Sections](https://www.home-assistant.io/dashboards/sections/) | Mevcut oda kartlarına düzenleme önizlemesi ve ortak ölçüler; yeni dashboard motoru yazılmaz. Aşama 6/8. | [Apache-2.0](https://github.com/home-assistant/frontend/blob/dev/LICENSE.md); GitHub otomatik sınıflandırması yerine lisans metni okundu. |
| Mushroom | Görsel düzenleyiciler, varlık türüne uygun kontrol kartları, ışık/koyu tema ve çeviri desteği. [Depo](https://github.com/piitaya/lovelace-mushroom) | Aynı ışık/iklim yeteneği her yerde aynı denetimi seçsin; yerleşik kart kayıt sistemi. Aşama 6/8. | [Apache-2.0](https://github.com/piitaya/lovelace-mushroom/blob/main/LICENSE) |
| Bubble Card | Bağlantıyla açılan içerik panelleri, varlık durumuyla açılma ve kart içinde düğme/kaydırıcı/seçim alt kontrolleri. [Pop-up ve sub-buttons](https://github.com/Clooos/Bubble-Card) | Oda ayrıntısı ve diafonun ortak, erişilebilir bağlam paneli; her olayda modal açma yok. Aşama 2a/6/15. | [MIT](https://github.com/Clooos/Bubble-Card/blob/main/LICENSE) |
| openHAB Main UI | Semantik model fiziksel yer, ekipman ve noktaları ilişkilendirir; ana sayfada konum/ekipman/özellik görünümleri üretir. [Model](https://www.openhab.org/docs/mainui/settings/model) | Oda kimliğini görünen addan ayırmak; sıcaklık, aydınlatma ve medya hedeflerini aynı oda bağlamında ilişkilendirmek. Aşama 6/8. | [EPL-2.0](https://github.com/openhab/openhab-webui/blob/main/LICENSE) |
| MagicMirror² | Saat, takvim, hava ve uyarı modülleri; gizlenen modülün zamanlayıcısını durdurabilecek `suspend`/`resume` yaşam döngüsü. [Modüller](https://docs.magicmirror.builders/modules/introduction.html), [yaşam döngüsü](https://docs.magicmirror.builders/module-development/core-module-file.html) | Bugün verisini kullanan sade ortam ekranı; görünmeyen kartlar için güncelleme bütçesi. Aşama 8/15. | [MIT](https://github.com/MagicMirrorOrg/MagicMirror/blob/master/LICENSE.md) |
| Homarr | Medya aramasında hazır/kısmi/işleniyor/istenmiş durumları; zaten istenmiş sezonu yeniden seçtirmeyen eksik sezon isteği. [Arama](https://homarr.dev/docs/management/search-engines/#media-request-search) | Yerel arama zaten var. Ek değer, medya ayrıntısında sezon ve kaynak kanıtını birleştirmek. Aşama 4. | [Apache-2.0](https://github.com/homarr-labs/homarr/blob/dev/LICENSE) |
| Homepage | Servis grupları, aynı serviste birden fazla widget, gösterilecek alan seçimi ve metrik vurgusu. [Servisler](https://gethomepage.dev/configs/services/) | Keenetic/Proxmox kartında kullanıcının seçtiği birkaç anlamlı metrik; ağ kontrolü ile uygulama verisi güncelliği ayrı. Aşama 7/8. | [GPL-3.0](https://github.com/gethomepage/homepage/blob/dev/LICENSE) |
| Music Assistant | Oynatıcı başına kuyruk ve başka oynatıcıya kuyruk aktarımı; kullanıcıların kaynak/oynatıcı erişimi sınırlandırılabilir. [Kuyruk](https://www.music-assistant.io/usage/), [aktarım](https://www.music-assistant.io/faq/masstransfer/), [kullanıcılar](https://www.music-assistant.io/settings/user-management/) | Oda değiştirirken hedef seçimi ve hesap sınırı; mevcut HA medya denetimlerinden ortak oturuma geçiş. Aşama 9–12. | Sunucu: [Apache-2.0](https://github.com/music-assistant/server/blob/dev/LICENSE) |
| Jellyfin Vue | Ayrı barındırılan arayüzün Jellyfin sunucusuna bağlanması; depo deneysel olduğunu, tam özellik sağlamadığını ve ana Web istemcisinin yerine geçmeyi hedeflemediğini açıkça söylüyor. [Depo](https://github.com/jellyfin/jellyfin-vue) | Arayüz varlığı, sunucu hesabı ve gerçek oynatma yeteneğini ayrı ele almak; eksik özelliği açık belirtmek. Aşama 4/son doğrulama. | [GPL-3.0](https://github.com/jellyfin/jellyfin-vue/blob/master/LICENSE) |
| Finamp | Jellyfin müziği için çevrimdışı/yeniden kodlanmış indirme, veri tasarruflu yayın, kesintisiz oynatma ve dinleme raporu. [Depo](https://github.com/finamp-app/finamp) | Müzik merkezi için ağ/indirme/oturum durumu; indirilen dosyanın profil sahipliği ve depolama bütçesi. Aşama 11/12, ilk sürümden sonra. | [MPL-2.0](https://github.com/finamp-app/finamp/blob/main/LICENSE) |
| Frigate | Aynı zaman aralığındaki nesneleri tek inceleme öğesinde toplama; uyarı/tespit ayrımı, düşük maliyetli önizlemeden ayrıntılı kayda geçiş. [Review](https://docs.frigate.video/configuration/review/) | Her algılama için ayrı bildirim yerine olay gruplama; diafon çağrısı ile kamera tespiti farklı öncelik. Yeni Frigate bağlantısı sonraki değerlendirme. | [MIT](https://github.com/blakeblackshear/frigate/blob/dev/LICENSE) |
| Dashy | Servis durumu/gecikme, tekrarlı kontrol aralığı ve renge ek şekille erişilebilir durum gösterimi. [Status indicators](https://dashy.to/docs/status-indicators/) | Var olan sağlık modelini tek dille göstermek; başarılı ping'i başarılı yetkili veri okuması saymamak. Aşama 2/7/8 genişlemesi. | [MIT](https://github.com/Lissy93/dashy/blob/master/LICENSE) |

## Seçilen iş paketleri

Değer: 1 düşük, 5 yüksek. Efor: K küçük, O orta, B büyük. Bunlar ayrı on iki entegrasyon projesi değil; mevcut aşamalar içinde kullanılacak dokuz ortak yapı önerisidir.

| Paket | Değer / efor | Mevcut sıradaki yeri | Temel bağımlılık |
| --- | --- | --- | --- |
| S01 · Ortak medya durumu ve sezon kanıtı | 5 / O | 4, hemen | Hesaba bağlı kimlik, kaynak durum dönüşümü |
| S02 · Oda bağlamı ve kontrollü eşitleme | 5 / O–B | 6 | HA area/device/entity kayıtları, yerel şema geçişi |
| S03 · Yeteneklere göre kart kayıt sistemi | 5 / O–B | 6/7/8 | Ortak denetimler, metrik birimleri, sağlık ve işlem modelleri |
| S04 · Tek olay merkezi | 4 / O | 3 üzerine 4/7/2a | Today kimlikleri, işlem makbuzları, medya ve çağrı olayları |
| S05 · Ortak bağlam paneli ve çağrı önceliği | 4 / O | 2a/6/13/15 | Router, yaşam döngüsü, güvenli eylem denetimi |
| S06 · Medya oturumu ve hedefe aktarım | 5 / B | 9–12 | Desteklenen oynatıcı/kaynak, sunucu yetkisi, platform oturumu |
| S07 · Ortam ekranı ve kaynak bütçesi | 4 / O | 8/15 | Görünürlük/boşta yaşam döngüsü, widget kayıt sistemi |
| S08 · Paylaşılan cihazda kişisel görünüm | 4 / B | Hesap önerisi + 14/17 | Gerçek servis hesabı/yetkisi, yerel koruma ve veri ayrımı |
| S09 · Kamera olayları ve isteğe bağlı yüz bağlamı | 3 / B | 2a + sonraki Frigate + 17 | Uyumlu kamera/sunucu, izin, model/lisans ve cihaz kabulü |

### S01 — Aynı film, aynı gerçek durum

Kullanım: Aramada bulunan dizide “1. sezonun 6 bölümü dosya olarak var, Jellyfin'de 4 bölüm görülebiliyor, 2. sezon sırada” denebilmeli. Tek “hazır” rozeti bu ayrımları kapatmamalı. Homarr'ın sezon seçimi buraya örnek; Larenor'da ortak medya kimlik indeksi ve kısmi hata altyapısı zaten mevcut.

**Ek iş:** İstek, aktarım, dosya varlığı ve oynatma kanıtını ayrı tutan model; kartın özeti bu kanıtlardan türesin. Aynı anda var olan bölümler oynarken diğer bölümler indirilebilir. Başlığa bağlı oturum kimlikleri güncel hesapla yeniden çözülmeli. Başka sunucunun Jellyfin ID'si veya Sonarr dosya sayısı doğrudan oynatma yetkisi olamaz.

**Kabul:** Bekleyen/onaylanan/reddedilen istek; sıra, duraklama, aktarım, içe alma ve hata örnekleri ayrılır. Bilinmeyen yüzde sıfır gösterilmez. Sezon 0 korunur; bilinmeyen bölüm toplamı tamamlandı sayılmaz. Radarr dosyası olup Jellyfin kaydı olmayan filmde doğrudan Play yoktur. Dizi kapsayıcısı bölüm ekranı açar. 401/kısmi servis kaybı ve hesap değişimi eski oynatma ID'sini kullanamaz. Eksik sezon isteği yalnız seçilmiş ve yeniden doğrulanmış kapsamı gönderir; zaman aşımı otomatik tekrar yazmaz.

### S02 — Oda, yalnız bir başlık olmasın

Kullanım: Salon görünümünde ışıklar, sıcaklık, TV hedefi ve film gecesi sahnesi aynı bağlama bağlı kalır; “Salon” adı değişse de kartlar ve rutin seçimi kaybolmaz. openHAB semantik modeli bu ilişkiyi görünür kılmak için yararlı örnektir. Larenor'a bütün openHAB modelini taşımak gerekmez.

**Ek iş:** Yerel oda kimliği + isteğe bağlı HA `area_id` eşleşmesi; cihaz/varlık ilişkisi ve kullanıcının tercih ettiği oda metrikleri. İçeri alma önce fark önizlemesi sunar; yerel sıra, gizlenenler ve favoriler ayrı katmandır. Ortak arama aynı ilişkiyi kullanır.

**Kabul:** Aynı adlı iki oda ayrılır; HA alan adı değişince yerel düzen korunur. Alan silinince oda sessizce silinmez. Bir cihaz başka alana taşınınca fark gösterilir. Kullanıcının onaylamadığı HA değişikliği yapılmaz. TV ve ışık adı “Salon” içermese de oda aramasıyla bulunur. Desteklenmeyen kontrol boş/yanlış bir düğmeye dönüşmez.

### S03 — Bir yetenek, bütün ekranlarda aynı kart

Kullanım: Keenetic kartında internet durumu, WAN IP, hız ve uptime içinden seçilen alanlar; Proxmox kartında seçilen VM ve bellek; oda kartında ışık/sıcaklık. Homepage alan seçimi, Mushroom tür tabanlı denetimleri ve HA Sections düzenlemesi burada birleşir.

**Ek iş:** Sınırlı yerleşik `WidgetDefinition` kaydı: kaynak/nesne kimliği, metrik veya kontrol yeteneği, ölçü/birim, izin koşulu, güncellik, boyut ve güncelleme politikası. Mevcut varlık denetimi ve işlem makbuzu kullanılır. İlk sürümde indirilen rastgele JavaScript, modül pazarı veya sır içeren serbest HTTP şablonu yoktur.

**Kabul:** Aynı metrik üç kartta gösterildiğinde üç polling döngüsü başlamaz. Sahte saatli testte görünmeyen kart yeni okuma başlatmaz; açılınca yalnız gerekli okuma yapılır. Eksik yetki, desteklenmeyen alan ve eski veri ayrı görünür. Yeniden sıralama ve dar/geniş pencere geçişi tercihi korur. 320 px genişlik, %200 yazı, klavye ve TalkBack'te alanlar okunur; durum yalnız renkle anlatılmaz. Sonlu olmayan sayılar veya bilinmeyen birimler grafik/maliyet uydurmaz.

### S04 — Bugün'den büyüyen tek olay merkezi

Kullanım: “Kapı çaldı”, “film isteği reddedildi”, “VM yedeği başarısız”, “ışık komutunun sonucu belirsiz” aynı merkezden ilgili hedefe açılır. Frigate'in çakışan nesneleri zaman aralığına toplaması, yinelenen bildirim gürültüsünü azaltmak için örnektir; her kaynağın kendi olayı korunur.

**Ek iş:** Mevcut Today bildirimlerine kaynak/hesap/olay ID'si, önem, zaman, hedef ve sonuç taşıyan ortak gösterim eklemek. Bir bildirimi yerelde okundu işaretlemek, sunucuda dismiss veya kaynak görevini tekrar çalıştırmakla karıştırılmaz. Çevrimdışı işlem kuyruğu oluşturulmaz.

**Kabul:** Yeniden bağlantı aynı bildirimi çoğaltmaz; aynı başlıklı farklı olaylar kaybolmaz. Eski hesaptan geç gelen sonuç listede görünmez. Derin bağlantı doğru oda/film/çağrıyı açar. Kapı olayı otomatik kilit açmaz. Kişisel sağlık, yüz adı, ağ adresi ve medya geçmişi misafir/ortam ekranına varsayılan olarak taşınmaz. Tekrarlanan uyarılar gruplanır; okunmamış kritik uyarı gruplanınca yok olmaz.

### S05 — Bağlam paneli, açık geri dönüş ve çağrı önceliği

Kullanım: Bir oda kartından ayrıntı açılır; tablet/DeX'te yan panel, telefonda uygun tam sayfa veya sheet görünür. Diafon çağrısı geldiğinde kullanıcı bulunduğu işi kaybetmeden kameraya geçebilir. Bubble Card'ın bağlantıyla açılan panelleri fikir verir; otomatik açılan çok sayıda iç içe panel Larenor için uygun değildir.

**Ek iş:** Mevcut route hedeflerinin ortak panel sunumu; tek aktif çağrı/uyarı öncelik yöneticisi. Arka plan, kilitli ekran, video oynatma ve DeX görünürlüğü açık kurallarla ele alınır. Kapı açma onayı kendi süreli/tek kullanımlı güvenlik denetiminde kalır.

**Kabul:** Geri/Escape doğru önceki hedefe döner, odak tetikleyiciye gelir. Pencere daralınca çift route/çift kamera oluşmaz. Aynı çağrının olayları üst üste modal açmaz. Çağrı bittiğinde açma niyeti geçersizdir; arka plan dönüşü eski onayı yürütmez. Kamera kapatılınca oynatıcı, mikrofon ve zamanlayıcı yaşam döngüsü sona erer. Sistem izin istemi ile uygulama uyarısı birbirinin üzerine zorla açılmaz.

### S06 — Ortak medya oturumu, oda değişince hedef seçimi

Kullanım: Mutfakta dinlenen müzik salona taşınır; oynayan öğe, kuyruk, konum ve kaynak hesabı anlaşılır kalır. Music Assistant'ın oyuncu başına kuyruk/aktarım yaklaşımı referanstır. Finamp'tan öğrenilecek ikinci konu, çevrimdışı içerik ve veri tüketimini kullanıcının kontrol edebilmesidir.

**Ek iş:** [Yayın/müzik araştırmasındaki](casting-music-research-2026-09-05.md) `MediaTarget` önerisini ortak oturumla birleştirmek; bir sağlayıcının her hedefte çalıştığı varsayılmaz. İlk teslim aktif oynatma/uzaktan hedef; çevrimdışı müzik indirme ve kesintisiz geçiş daha sonra, kaynak izinleriyle. Android uygulaması Music Assistant sunucusunun bütün motorunu hemen içine alacakmış gibi sunulmaz.

**Kabul:** Uygun olmayan Cast/AirPlay/hedef seçilemez veya gerekçesi açıklanır. Aktarım sırasında hedef erişilemezse eski oturum yanlışlıkla tamamlandı görünmez. Grup üyelerinden birinin hatası ayrı gösterilir. Kimlik/token akış URL'siyle ilgisiz sunucuya taşınmaz. Hesap değiştirme kuyruk/indirme metadatasını ayırır. Kilit ekranı ve uygulama aynı oturumu kontrol eder; uygulama arka plana geçince ikinci oynatıcı başlamaz. İndirilecek dosya miktarı, depolama sınırı, durdurma/silme ve yarım indirme toparlanması ayrıca test edilir.

### S07 — Boşta ekran, kontrollü kaynak tüketimi

Kullanım: Dokunulmayan duvar tabletinde saat, sıradaki etkinlik, ev özeti ve seçilen albüm görünür. MagicMirror'ın modüler yapısı ve görünürlük yaşam döngüsü burada yararlıdır; yeni slogan veya sürekli hareketli bilgi akışı gerekmez.

**Ek iş:** Aynı widget verilerini kullanan ortam düzeni; ekran parlaklığı/boşta politikası [Fully Kiosk çalışmasındaki](kiosk-capabilities-research-2026-09-05.md) sırayla. Animasyon, kapak çözünürlüğü, kamera önizlemesi ve polling için görünürlük bütçesi. WAN IP, kişisel bildirim ve sağlık verileri ortam görünümünde ayrı seçim ister.

**Kabul:** Gizlenen modülün zamanlayıcısı durur; eski veri son okuma bilgisiyle gösterilir. Kullanıcı dokununca odası/kaydırması korunur. Aktif görüşme veya oynatma yanlışlıkla boşta ekranıyla kesilmez. Düşük hareket tercihi ve %200 yazıda görünüm çalışır. Belirlenmiş cihazda uzun süre açık kalma/arka plan/DeX senaryosunda bellek, CPU, ısı ve pil ölçülür; birim testlere kararsız duvar saati eşiği konmaz.

### S08 — Kişisel görünüm ile gerçek erişim yetkisi ayrı

Kullanım: Misafir yalnız izin verilen oda kontrollerini görür; aile üyesi kendi müziğine geçer; kişisel sağlık verisi duvar ekranında açılmaz. HA'nın koşullu görünürlüğü bir sunum örneğidir. Music Assistant kullanıcı/oynatıcı/kaynak sınırları ise gerçek servis yetkisinin ayrıca ele alınması gerektiğini gösterir.

**Ek iş:** Yerel görünüm profili ile her servisin kimlik/yetki bağını ayrı saklamak. Mevcut Ayarlar PIN'i aile hesabı yetkilendirmesi değildir. Profil değişirken sadece kartları gizlemek yeterli olmaz; arama, önbellek, olay merkezi, deep link ve eylem sağlayıcıları da aynı sınırı kullanmalı.

**Kabul:** Misafir deep link veya ortak aramayla yönetici/sağlık alanına ulaşamaz. Yetki kaldırılınca açık ayrıntı/oynatma komutu yeniden denetlenir. Ortak servis hesabının sağlayamadığı kişi bazlı kısıt açıkça belirtilir. Yeniden başlatma ve yedekten geri alma profil kilidini atlatmaz. Yüz tanıma yalnız izin verilmiş görünüm önerisi olur; yönetici, sağlık ve kapı açma onayını tek başına geçemez.

### S09 — Kamera olayını görüntüle; yüzü güvenlik anahtarı yapma

Kullanım: Diafon çağrısı sırasında canlı görüntü; daha sonra kamera olayında kısa önizleme. Gelecekte uygun sunucuyla bilinen kişinin etiketi gösterilebilir. Frigate yüz tanımayı ayrı özellik olarak belgeliyor; yerel işleme ve varsayılan kapalı davranışın yanı sıra model/donanım koşulları var. Bu, aynı modelin Huawei Android üzerinde doğrudan çalıştığı kanıtı değildir. [Frigate yüz tanıma](https://docs.frigate.video/configuration/face_recognition/)

**Ek iş:** Üç kapsam ayrı tutulur: anonim yaklaşma/yüz varlığıyla ekran uyandırma; açık kayıtla kişisel görünüm önerme; kullanıcının var olan Frigate sunucusundan olay etiketi okuma. Kimlik tanıma, kendi kendine açılacak kamera veya kapı açma otomasyonu üretmez. Elektronik kapı köprüsü [Netelsan temelindeki](intercom-hardware-foundation-2026-09-05.md) devreye alma ve süreli komut sınırında kalır.

**Kabul:** Kamera/mikrofon/kimlik kaydı varsayılan kapalıdır; izin reddi normal ana ekranı bozmaz. Kayıt, yerel saklama kapsamı ve silme açıkça gösterilir. Model ağırlıkları/lisansı ve GMS gereksinimi pakete göre doğrulanır; Huawei çevrimdışı kurulum ayrıca denenir. Çoklu pencere/görüşme/oynatma sırasında tek kamera sahibi vardır. Fotoğrafla yanıltma ve belirsiz tanımada profil önerisi hassas veri açmaz. Ağ kesintisi, tanıma sonucu veya uygulama açılışı kapıya darbe göndermez.

## Uygulama ve doğrulama sırası

Önce **S01 / aşama 4**, ardından planlanan film gecesi akışı ve **S02–S03 / aşama 6–8**. S04 yeni bağımsız bildirim ürünü olmadan Today'ı genişletir. S05 diafon ve DeX kabulüyle; S06 aşama 9–12 ile; S07 kiosk ile; S08 kişisel sağlık ve hesap sınırlarından önce ele alınır. S09 ayrı izin/donanım kabulü ister. Bu sıra, aynı oda/kimlik/sağlık mantığının farklı ekranlarda yeniden yazılmasını azaltır.

Her teslim aynı route, boş/yükleniyor/kısmi hata/eski veri ve eylem sonucunu kullanmalı. CI'da saf model/fixture testleri, hesap değişimi ve geç yanıt, sahte saatle yaşam döngüsü, dar/geniş ekran ve erişilebilirlik senaryoları çalışır. Yayın hedefi, mikrofon/kamera, OEM güç yönetimi ve fiziksel diafon kabulü gerçek cihaz testidir; yalnız widget testinin geçmesi bunları tamamlanmış yapmaz. Canlı HA araştırması salt okunur kalır; komut testleri sahte istemciyle yürütülür.

## Aşama 4 için kısa kod incelemesi ve iş bölümü

Araştırma anındaki kodda somut düzeltme hedefleri:

- `MediaLibraryEntry.availability`, Arr `complete` bilgisini `inLibrary` sayıyor; bu Jellyfin oynatma kanıtı değil.
- Kuyruk kaydı durumuna bakılmadan indirme kabul ediliyor; `progressFraction ?? 0` bilinmeyen ilerlemeyi sıfıra çeviriyor.
- Jellyseerr `partiallyAvailable` tam kütüphane durumuna dönüşüyor; `jellyfinMediaId` doğrudan oynatma ID'si olabiliyor.
- Jellyfin Series kimliği `jellyfinItemId` içine konabiliyor; `MediaTitle.isPlayable` yalnız ID varlığını denetliyor.
- `MediaTitle.copyWith` nullable alanı temizleyemiyor; `enrich` bazı eski alanları koruyor. Ayrıntı/sayfa anlık görüntüsü hesap değişiminde yeni kaynakla doğrulanmalı.

| Bağımsız iş | Dosya alanı | Doğrulama |
| --- | --- | --- |
| A · Kanıt ve kaynak dönüşümü | `hub/domain`, `hub/providers/media_catalog_providers.dart`, Arr kuyruk/kütüphane modelleri; gerekli dar Jellyfin/Seerr model alanları | Resmi API fixture'larıyla aşama eşleme; sıfır/bilinmeyen; kısmi sezon; kimlik birleştirme; eşzamanlı hazır+aktarım; eski hesap alanlarının temizliği |
| B · Ortak medya sunumu | Hub, rozet, ayrıntı ve Jellyfin Series ekranı | Tek durum dili; diziye bölüm seçimi; stale/account guard; yeniden açma/arka plan; dar ekran; başarısız/kısmi kaynak |
| C · Doğrudan hedef çözümleme | Router hedef ekranı ve gerekli tekil katalog okuması | Akışlarda bulunmayan ID; doğru tür; bulunamadı/401; route'daki eski nesneyi yeni hesaba taşımama |
| D · Birleştirme ve sonraki rutin | Ortak API sözleşmesi, bütün test/CI, ardından aşama 5 | Saf GET araştırma sınırı; üretim komutu yok; kısmi başarı UI'sı ve tek yazma; gerçek cihaz oynatma kabulü ayrı |

Önce alan/enum sözleşmesi sabitlenmeli. İstek, transfer ve kütüphane kanıtları bağımsız kalmalı; tek doğrusal “ilerleme” bir dizinin eşzamanlı durumlarını kaybetmemeli. HTTP/body fixture'ları için uygulamadan önce Sonarr/Radarr, Jellyfin ve Seerr'in resmi şema/kaynakları doğrulanmalı. Bu belge A–D işlerinin tamamlandığını söylemez.
