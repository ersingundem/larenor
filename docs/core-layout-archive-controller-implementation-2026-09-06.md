# Core oda arşivi: önizleme ve tek kullanımlık geri yükleme

Bu dilim `CoreLayoutArchiveController` ile mevcut `DashboardRepository.core`
üzerinde çalışır. Dosya seçici, şifreleme veya tablet ekranı burada bağlanmaz.
Caller güncel kaynak, hesap/ev, PIN, route ve pencere ömrünü `isCurrent` ile
bağlamak zorundadır; yalnız scope kimliği erişim yetkisi değildir.

Capture yalnız scoped kaydı reload ile okur, mevcut kişisel oda adlarını,
kimliklerini ve sırasını korur; UTC zamanı milisaniyeye indirir. Boş scoped
kayıt revision0 olarak yakalanır. Direct kayıt veya credential deposu okunmaz.
Modelin desteklemediği cihaz/alan/kart bağlantıları varsa sessiz filtreleme yoktur.

Preview aynı Core/ev/kullanıcı digest'ini disk okumasından önce denetler;
hedefin mevcut revision/fingerprint'ini, oda adlarını ve immutable arşivi
sahibine bağlar. Bu işlem henüz yazmaz. Apply yalnız kendi onayını, beş dakika
sınırını ve güncel callback'i kabul eder. Kendi onayı başarısız denemede de
kalıcı olarak tüketilir; saat geri alınarak süresi dolmuş onay canlandırılamaz.
Yabancı controller geçerli sahibin onayını tüketemez. Gözlenen callback false
veya exception controller'ı kalıcı kapatır.

Uygulama `ConfigurationWrites` kuyruğunda mevcut `saveIfUnchanged` CAS sınırını
kullanır. Onaydan sonra farklı revision veya aynı revision'da farklı içerik
reddedilir. Arşivdeki kaynak revision'ı hedefe kurulmaz; yerel hedef bir artar.
Ardından reload ile revision ve tam layout doğrulanır. Başarısız/yalancı ACK,
etkiden önce/sonra false veya throw, erişim kaybı ve okunamayan sonuç başarı
sayılmaz. Onay tekrarlanmaz, üçüncü taraf değerine rollback yazılmaz; kullanıcı
yeni okuma ve önizleme ister. Bu tek scoped key işlemidir; yeni journal veya
eski backup formatına genişleme yoktur.

## TDD ve doğrulama

- `fec89be` runtime RED: 2 PASS/23 FAIL; derlenen kapalı stub.
- `798964f` GREEN: aynı25 PASS.
- `dff72db` ek RED: 26 PASS/1 FAIL; süresi dolan onayın saat dönüşünde canlanması.
- `42dee5c` GREEN: aynı27 PASS, onay sahipliğinde tüketim sırası düzeltildi.
- Sonraki8 test zaten doğru kuyruk, readback ve callback davranışlarını doğrular;
  yeni üretim davranışı veya yeni RED iddiası yoktur.
- Final35 controller + model/legacy/scoped storage dahil **159 ilgili PASS**.
- Controller satır kapsamı **64/64 (%100)**; branch/cihaz kapsamı iddiası değildir.
- İki dosyada analiz0; biçim doğrulaması ayrıca kaydedilir.

Testler gerçek DashboardRepository ve sentetik SharedPreferences platformunda
çalışır. Üç yabancı scope, bozuk/zengin hedef, sıralı kimlikler, yalnız boş oda
silme, değişmiş hedef, owner/PIN callback kaybı, expiry/clock geri dönüşü,
kuyrukta tekrar onay, eşzamanlı iki preview, gerçek false/throw ACK ve başarı
ACK'sine rağmen farklı/okunamayan disk sonuçları kapsanır. Token/legacy/başka ev
anahtarları korunur. Gerçek ev veya Server API'sine istek gönderilmedi.

Loglar `/private/tmp/larenor-archive-controller-{red,green,related-final,analyze-final}.log`,
`larenor-archive-clock-{red,green}.log`, kapsam `larenor-archive-controller-final-coverage.info`.
Yerel kuyruk süreç içindedir; başka OS süreciyle atomik CAS, native Keystore,
process-death veya fiziksel disk kalıcılığı bu testlerle kanıtlanmaz. Güncel
bilginin sonra tekrar değiştirilmesi/ABA bütün platformlarda engellendi denmez.
S08.5 ve gerçek UI/Android teslim kabulü bu bağımsız dilimle tamamlanmaz.
