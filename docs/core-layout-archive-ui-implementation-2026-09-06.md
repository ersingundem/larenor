# Core oda arşivi: tablet ekranı ve şifreli dosya akışı

Bu dilim, mevcut Core oda arşivi modeli, codec'i ve controller'ını gerçek
`HomeSourceScreen → SettingsGate → CoreLayoutArchiveScreen` yolunda birleştirir.
Yalnız doğrulanmış güncel Core/ev/kullanıcı için yerel oda kimliği, adı ve sırası
aktarılır. Eski backup v1/v2, restore journal, Direct düzeni, bağlantı bilgileri,
oturum, Server kaynak kaydı ve cihaz komutları bu akışa eklenmez. Model,
codec ve controller'ın mevcut sözleşmesi değiştirilmez.

## Dosya ve hedef sınırı

Yeni dosya adaptörü yalnız `.larenor-core-layout` uzantısını, pozitif ve en çok
3 MiB uzunluğu kabul eder. Bildirilen uzunluk akıştan önce, biriken uzunluk her
parçada ve bildirilen/gerçek uzunluk eşitliği sonunda denetlenir. Kopyalanmış
ciphertext işletim sisteminin dosya seçicisine/kaydetme arayüzüne gider; uygulama
plaintext geçici export dosyası oluşturmaz. Codec'in 2 MiB plaintext, kapalı
format/AAD/KDF ve 3 MiB dosya sınırları aynen uygulanır. OS hataları yol veya
exception içeriği taşımayan sabit kullanıcı mesajına çevrilir.

Export şifre ve tekrarını, mevcut PIN'den farklı geçerli arşiv şifresini ve
güncel PIN deposunu denetler; gerçek controller capture ve codec encryption'dan
sonra dosya kaydını başlatır. Şifre alanları encryption/dosya iptali sonrasında
boşaltılır. Import iptali eski preview'ı bırakmaz. Yanlış şifre, farklı scope veya
desteklenmeyen zengin düzen açık hata verir; sessiz dönüştürme yoktur.

Preview mevcut ve arşivdeki odaları ayrı başlıklarla gösterir. Açık değiştirme
onayı yalnız kendi, tek kullanımlık controller preview'ını tüketir. Onaydan önce
değişen hedef revision/fingerprint reddedilir. Başarı yalnız gerçek scoped
`DashboardRepository.saveIfUnchanged` ve yeniden okuma doğrulamasından sonra
gösterilir; scoped dashboard provider'ı yenilenir. Belirsiz false/throw ACK
başarı sayılmaz, kendiliğinden tekrar veya rollback yapılmaz. Kullanıcı güncel
odaları açıkça yeniden okur ve yeni bir önizleme başlatır.

## Ekran ve dosya diyaloğu ömrü

Ekran provider container'ını, HomeSessionController nesnesini, tam session ve
account generation'ı, scoped repository/access nesnesini ve beş dakikalık ömrü
başlangıçta bağlar. PIN yüklenmesi/hatası/değişimi, kaynak/oturum değişimi, farklı
container/native View, route örtülmesi, idle, native focus veya pencere durumu
eski callback ve draft'ları emekli eder. A→B→A dönüşü eski yetkiyi canlandırmaz.
Her await sonrasında güncel bağlar tekrar kontrol edilir; geç yanıt eski odaları
ve başarı mesajını yayımlayamaz.

OS diyaloğu mevcut `SettingsFileDialogRunner` lease'ini kullanır. Diyalog öncesi
plaintext alanlar, preview ve eski controller atılır; yalnız ciphertext korunur.
Aynı sahibin gerçek PIN yeniden doğrulaması ve gate'in sonraki frame'i tamamlanınca
yeni access/controller kurulur, mevcut hedef yeniden okunur. Genel gate,
Backup/Vault diyaloğu veya native focus politikası gevşetilmez. Yalnız homeSource
SettingsGate dalına dar runner/current callback geçişi eklenir.

Geri düğmesi yazma yetkisinden ayrı, güncel route/window/generation kontrolüyle
çalışır: süresi dolmuş ekrandan yeni Geri eylemi çıkabilir; elde tutulan veya
örtülü/unfocused callback başka route'u kapatamaz. Onay eylemleri 48 px, adlandırılmış
semantics ve Enter/Space desteği taşır. Preview ve sonuç geldiğinde oda incelemesi
üstte görünür; modal açıkken arka plan semantics'i erişime kapalıdır.

## Doğrulama ve kabul sınırı

- `e412262`: derlenen kapalı ilk runtime RED, 10 PASS / 31 FAIL.
- `705125b`: gerçek UI/codec/repository ilk GREEN, 41 PASS.
- `52e5208`: OS-save hata görünürlüğü, farklı native View ve 48 px/klavye
  regresyonları; ayrı gerçek başarısızlıklar kaydedildi.
- `5ffd998`: elde tutulan Geri/window-loading runtime RED, 7 PASS / 1 FAIL.
- `8ecc13d`: son outcome/View/Geri/tablet grubu **19 PASS / 27 s**. Biçim ve
  semantics fixture yaşam döngüsü düzeltmesi sonrası gerçek davranış GREEN.
- `b284e9c`: biçim/analiz temizliği ve ek retained-Geri/modal regresyonu;
  üretim yetki sözleşmesi değişmedi. Bu kaynak üzerinde **410 ilgili PASS / 1:35**.

Yeni UI/adaptör test envanteri 61 vakadır: file access16, screen24, container
scope1, outcome4, native View1, tablet6 ve awaited PIN/Geri9. Bu vakalar yukarıdaki
410 ilgili toplamın içindedir; ayrı koşumların sayıları toplanmaz. Birleşik komut
bütün `test/features/home_scope` klasörüne ek olarak iki scoped dashboard testini,
SettingsGate, eski BackupScreen, prepared BackupScreen, prepared VaultScreen,
HomeSessionScope ve HomeSourceStore regresyonlarını çalıştırır.

Yeni iki üretim dosyası satır kapsamı **529/542 (%97,60)**: ekran510/521,
dosya adaptörü19/21. Adaptördeki iki eksik satır gerçek OS picker/save çağrılarıdır;
sentetik platform testi fiziksel picker testi diye sunulmaz. İlgili mevcut
HomeSourceScreen73/80 ve SettingsGate160/209 satırdır; bu dar koşu genel gate'in
bütün destinasyonlarını veya proje genel kapsamını ölçmez. 12 Dart dosyasında
analiz0; son format kontrolü12 dosya/0 değişiklik. Branch coverage iddiası yoktur.

Kaynak incelemesi ve TR600 form/onay ile TR1280 koyu form görselleri root tarafından
okunup CLEAR verildi. Dar native View/Geri/OS-save bulguları gerçek RED→GREEN ile
kapandı. PNG'ler EN/TR320/600/1280 px, yükseklik1000 px ve2× metinde üretildi;
form görüntüleri alana kaydırılmış ara QA durumudur, README galerisi değildir.

Testler gerçek Riverpod/SettingsGate, codec/controller
ve sentetik SharedPreferences/platform depolarıyla çalışır. Yerel testte OS
picker, gerçek ev, LAN veya Server mutasyonu yapılmaz. EN/TR, 320/600/1280 px,
2× metin, 48 px, Tab/Enter, focus contrast ve modal semantics sınanır. PNG üretimi
ancak `CORE_LAYOUT_ARCHIVE_PREVIEW_DIR` açıkça verilirse özel dizine yazılır.

Bu paket cihazlar arası kimlik eşleme, çok süreçli atomik CAS, fiziksel disk/OS
process-death kalıcılığı veya Android native dosya seçicisi kabulü iddiası taşımaz.
Gerçek Android yolculuğu ve CI teslimi ayrı kapıdır. S08.5 bütünü tamamlandı denmez.

Özel kanıtlar:

- `/private/tmp/larenor-core-archive-ui-related-final.log`
- `/private/tmp/larenor-core-archive-final-delta-green.log`
- `/private/tmp/larenor-core-archive-back-red.log`
- `/private/tmp/larenor-core-archive-ui-analyze-final.log`
- `/private/tmp/larenor-core-archive-ui-format-check.log`
- `/private/tmp/larenor-core-archive-ui-final-coverage.info`
- `/private/tmp/larenor-core-archive-ui-previews/` (12 PNG)
- `/private/tmp/larenor-core-layout-archive-ui-delivery-evidence.json`

