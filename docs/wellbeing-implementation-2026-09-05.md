# Kişisel sağlık ve tartı verileri

2026-09-05. Kişisel sağlık alanı Sistem ekranından açılır. Mevcut uygulama PIN'i
gereklidir; PIN yoksa önce Ayarlar'a yönlendirir. Üretim HA, sağlık sağlayıcısı
veya kişisel cihaz üzerinde veri okuma/izin testi bu dilimde çalıştırılmadı.

## Kaynak ve destek matrisi

| Kaynak | Uygulanan yol | Kalan koşul |
| --- | --- | --- |
| Home Assistant | Açık kişi/sensör eşlemesiyle ağırlık ve yağ yüzdesi mevcut durumunu salt okunur alma | Doğru kişi ayrımı ve mevcut sensör HA'da sağlanmalı; geçmiş ölçüm çıkarılmaz |
| Health Connect | Android native SDK ile ağırlık, yağ yüzdesi, günlük adım toplamı | Uygun cihaz, kurulmuş/güncel sağlayıcı ve kullanıcı okuma izni |
| Google Fit / Mi Fitness | Health Connect'e gerçekten paylaşılmış kayıtlar üzerinden | Üretici uygulamasının o veri türünü aktarması gerekir; hesap şifresi alınmaz |
| Huawei Health | Gereken sağlayıcı uygulama onayı görünür | Health Kit geliştirici kaydı, kapsam onayı ve cihaz kabulü henüz yok |
| Apple Health | Platform/entegrasyon durumu açık | Android'den doğrudan HealthKit erişimi yok; iOS native HealthKit köprüsü bu dilimde uygulanmadı |

Android SDK bağımlılığı `androidx.health.connect:connect-client:1.1.0` sabittir.
Kütüphane manifesti nedeniyle uygulama minimum API 26 / Android 8'e yükseltildi;
Android 7.x'e yeni APK kurulmaz. Sağlık sağlayıcısı için API 28 / Android 9+
gereksinimi ayrıca çalışma anında kontrol edilir. GMS varlığı varsayılmaz.
[Health Connect başlangıç ve izinler](https://developer.android.com/health-and-fitness/health-connect/get-started).

## Veri ve izin akışı

1. PIN ile özel alanı aç, özelliği etkinleştir ve kişi etiketi belirle.
2. Kaynakları açıkça kontrol et; okunacak veri türlerini kaydet.
3. Okuma iznini ayrı sistem akışında incele. Sadece seçilen türlerin READ
   izinleri istenir; yazma, silme, geçmiş veya arka plan sağlık izni yoktur.
4. Sistem ekranından dönünce gerekirse PIN'i yeniden gir; **Seçili verileri oku**
   eylemiyle yeni bir okuma başlat. İzin sonucu otomatik okuma başlatmaz.

Okuma penceresi en fazla 30 gün, sonuçlar toplam en fazla 500 kayıt, sayfalar
ve günlük zaman dilimi aralıkları ayrıca sınırlıdır. Adımlar ham kayıtları
toplamak yerine SDK aggregate API'sinden yerel takvim gününe göre alınır;
23/25 saatlik yaz saati günleri korunur. Kaynaklar arasında otomatik toplam
veya kişi tahmini yapılmaz. [Okuma sınırları](https://developer.android.com/health-and-fitness/health-connect/read-data),
[Aggregate davranışı](https://developer.android.com/health-and-fitness/health-connect/aggregate-data).

HA'daki genel ağırlık sensörü insan ölçümü kanıtı değildir. Kullanıcı sensörü
kişiye kendisi bağlar. `last_updated`, tartılma zamanı diye gösterilmez:
ölçüm zamanı, kaynak güncellemesi ve okuma zamanı ayrı tutulur. Geçersiz birim,
NaN/sonsuz veya bozuk aralık güvenli hata olur. Bilinmeyen/boş sonuç sıfıra
dönüştürülmez. Apple HealthKit'in okuma iznini gizlemesi nedeniyle ilerideki boş
HealthKit sonucu da tek başına erişim başarısı sayılmayacaktır.
[HA sensör tanımı](https://www.home-assistant.io/integrations/sensor/),
[Apple HealthKit authorization](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data).

## Özel alan sınırı

Ölçümler yalnız bellekte kalır. Kişi etiketleri ve bağlantı eşlemeleri ayrı güvenli
depo anahtarındadır; şifreli uygulama yedeğinin allowlist'ine alınmaz. Kayıtta HA
tokenı veya sunucu adresi yerine hesap parmak izi tutulur. Hata mesajları ve
günlükler kişisel değer, kayıt kimliği veya sağlayıcının ham hatasını göstermez.

Yedek veri şeması **v2**, ölçüm ve kişi eşlemelerinden ayrı bir gizleme ilkesi
taşır: yalnız özel varlık kimlikleri ve gerekiyorsa gizlilik incelemesi bayrağı.
Geri yükleme mevcut ve gelen gizleme kurallarını birleştirir, mevcut kısıtlamayı
kendiliğinden kaldırmaz. Bu politika bağlantı/pano kayıtlarıyla aynı geri alma
günlüğünde atomik uygulanır. Bozuk veya okunamayan özel depo yedek oluşturmayı
durdurur; politika kaybıyla başarılı yedek üretilmez.

v1 yedekler okunabilir. HA bağlantısı/pano içeren eski yedekte kural bilgisi
olmadığından ortak HA listeleri, Sistem → Kişisel sağlık → Kaynaklar bölümünde
PIN ile gizlilik kontrolü yapılana kadar kapalıdır. Özel sensörler bağlandıktan
sonra inceleme açıkça tamamlanır. Taşınan gizleme kuralını kaldırmak da ayrı,
adı gösterilen onaydır; kalan kişisel sensör bağı ayrıca korumaya devam eder.

Android özel pencere koruması native `FLAG_SECURE` doğrulanmadan kişi etiketini
ve ölçümleri açmaz. Arka planda okuma hakkı iptal edilir; son özel kare Recents'te
açılmasın diye flag, maskeli ön plan karesinden sonra bırakılır. Eski sayfanın
geç kapanışı yeni özel sayfanın korumasını kaldıramaz. Önceden başka bileşenin
sağladığı flag korunur. Bu Android yoludur; iOS için mutlak ekran görüntüsü
engeli vaat edilmez. OEM Recents davranışı fiziksel cihazda ayrıca sınanmalıdır.

Bağlanan HA varlıkları ortak arama, özetler, oda/kart seçicileri, kaydedilmiş
kartlar ve geçmiş okumalarından çıkarılır. Özel filtre yüklenemiyorsa ortak
görünüm eski veriyi kullanmaz. Özelliği kapatmak bağları görünür yapmaz; yerel
bağ ancak ayrı onayla kaldırılır. Bu işlem HA verisini silmez. Genel yönetici
API araçları HA hesabının yetkileriyle çalışır; uygulama PIN'i HA sunucusunun
ayrı kullanıcı yetkilendirmesi yerine geçmez.

Idle, arka plan, PIN değişimi, HA hesabı değişimi veya görünmez sayfa oturumu
bitirir. Özel Navigator altındaki taslak ve onaylar kaldırılır, geç tamamlanan
izin/okuma yayınlanmaz. Başka bir kök dialog silinmez. Testler bu geçişlerde
sıfır eski okuma/yazma, kısmi izin, sınırlı sayfalama, zaman dilimi ve %200 yazılı
telefon/tablet düzenini sınar. Native sağlık testleri Android CI'daki normal
`:app:testDebugUnitTest` işine dahildir.
