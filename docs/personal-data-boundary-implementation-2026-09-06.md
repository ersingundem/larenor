# S08.4 — Kişisel sağlık ve cihaz fotoğrafı sınırı

6 Eylül 2026. Bu dilim `20d92d7144998e40eb465887ef3fcac681dab39e`
tabanındaki `codex/personal-data-boundary` dalında geliştirildi.
Davranış kaynağı `7176d40`; yerel test ve inceleme için hazırlanmıştır.
S08.4 envanterinin kişisel/cihaz satırlarını kapsar; tüm S08.4, Core sağlık
adaptörü veya fiziksel cihaz kabulü tamamlandı iddiası değildir.

## Sahiplik ve izin

`WellbeingStore` içindeki özel profil, native ölçüm tercihleri ve açıkça
seçilmiş HA bağları ortak Core ev kaydı değildir. Cihazda korunur; Direct,
Core, kaynak yükleniyor veya kaynak okunamıyor durumları bunları silmez,
yeniden adlandırmaz, başka kullanıcıya aktarmaz. Özel profil ve sağlık
ölçümleri normal yedeğe eklenmez. `WellbeingDisclosurePolicy`, kişileri veya
ölçümleri taşımadan yalnız gösterimi kısıtlayan entity kimliklerini ve inceleme
gereksinimini yedekleyebilir. Gerçek BackupRepository testi bu ayrımı doğrular.

Global sağlık gizlilik filtresi bütün kaynaklarda çalışır. Ayar veya disclosure
kaydı okunamıyorsa, yükleniyorsa ya da yazı sonucu belirsizse filtre bütün genel
HA gösterimleri için kapalı kalır. Depolama hatası boş ve izin veren bir listeye
çevrilmez. Bir HA sağlık bağı, saklandığı Direct bağlantı parmak iziyle kullanılır;
Core kimliği HA adresi, tokenı veya bu bağ için bir yetki değildir.

Native sağlık sorgusu ayrı `WellbeingAccessSession`, güncel PIN doğrulaması,
özel pencere koruması ve görünür/etkin özel görünüm gerektirir. Core oturumu tek
başına controller veya native sorgu başlatamaz. Geçerli özel oturumla cihazın
native sağlık adaptörünün açıkça kullanılması Core altında da mümkündür;
platform okuma izni ve kullanıcı tarafından başlatılan okuma ayrı adımlardır.
Bu dilim bu kapıları gevşetmez veya otomatik izin/sorgu başlatmaz.

`ambient_photos_v1`, kullanıcının cihazda seçtiği özel fotoğraf arşividir.
Açık library/photo provider okuması Direct ve Core altında aynı cihaz arşivini
kullanabilir; bunun için eski HA bağlantısı veya yeni Core yetkisi üretilmez.
Core ambient ekranının mevcut saat görünümü arşivi otomatik yüklememeye devam
eder. Arşiv bozuksa hata verir; boş bir taşınmış arşiv sayılmaz. Yeni arşiv
taşıma, silme, içe aktarma, yükleme veya ağ paylaşımı eklenmedi.

## Gerçek düzeltmeler

- Secure-store save/clear ve disclosure save, platform I/O öncesinde ve sonrasında
  yakalanmış eylem yetkisini denetler. İstisna atan yetki callback'i statik bir
  hata olur; özel hata ayrıntıları dışarı çıkmaz.
- Provider mutasyonları ve yeniden okumaları mevcut `ConfigurationWrites`
  kuyruğunu kullanır. Bekleyen yazı bitmeden eski kayıt doğrulanmış sayılmaz.
  İşlem başlangıcındaki Riverpod `Ref` yakalanır; yeniden kurulmuş provider'ın
  state/future'ı eski işlemin sonucu veya hatasıyla değiştirilemez.
- Yazı sürerken gizlilik yükleniyor durumuna geçer. Yetkisi sona eren veya
  başarısı doğrulanamayan yazı, eski izin veren değeri doğrulanmış olarak tutmaz.
  Platformda gerçekleşmiş olabilecek yazı otomatik geri alınmaz ve tekrarlanmaz.
- Ambient ayarlarının yeniden okunması `SharedPreferences.reload()` ile kalıcı
  kaydı doğrular. `setString` false/istisna döndürdüğünde eski plugin önbelleğindeki
  yeni opt-in başarı sayılmaz. Okuma/yazı hatası statiktir; otomatik retry yoktur.
- Özel Wellbeing ekranında “Kayıtlı ayarları yeniden oku” işlemi yalnız iki yerel
  ayar provider'ını yeniden okur. Buton mevcut özel oturuma bağlıdır; kilit,
  arka plan, görünürlük veya rota değişimi eski callback'i geçersiz kılar.
  Başarısız tekrar okuma açık hata ve yeniden deneme olanağı bırakır; native/HA
  query, izin talebi veya bağlantı değişimi başlatmaz. EN/TR metinleri eklenmiştir.

Riverpod hata/yükleniyor geçişlerinde önceki değeri saklayabilir. Bu yüzden
kanıt yalnız `.value == null` varsayımına dayanmaz: gerçek AmbientScreen testi
önceden etkin fotoğrafın hata sonrasında gizlendiğini ve yeni arşiv/byte okuması
başlamadığını da kontrol eder. Global sağlık filtresi zaten hata/yükleniyor
kontrolünü önce yapar; izin veren önceki değeri tüketmez.

## TDD ve yerel doğrulama

| Checkpoint | Gerçek sonuç |
| --- | --- |
| `9807a8b` RED | Yeni provider/store testlerinde 18 geçti, 17 beklenen davranış hatası; yerel retry UI testinde 1 beklenen eksik-butonu hatası. |
| `1b74b2b` GREEN | Provider/store sınırları ve mevcut özel ekran testleriyle 51 geçti. |
| `16de183` RED | Ayar, disclosure ve ambient provider yeniden okumasının devam eden yazıdan önce sonuçlandığını gösteren 3 davranış hatası. Kuyruk ve özel oturum ek regresyonları da kaydedildi. |
| `7176d40` GREEN | Üç yarış testi geçti; ilişkili wellbeing, ambient, backup ve kaynak oturumu regresyonu toplam 253 geçti. |

Son birleşik yerel koşu 18 saniyede **253 test** geçirdi. Bu sayı alt kapsamların
örtüşen toplamı değildir. Yeni iki provider/store dosyasında 44 test, mevcut
Wellbeing ekran dosyasında 3 yeni widget senaryosu bulunur. Sentetik platform
hataları etki öncesi/sonrası yazıyı, geç yetkiyi, kuyrukta süresi dolan eylemi,
yeniden kurulma yarışını ve açık yerel kurtarmayı kapsar. Türkçe 320 px / %200
metin testi hata ve tekrar okuma yolunu gerçek kaydırma/tap ile kullanır.

| Değişen üretim dosyası | Son LCOV satır kapsamı |
| --- | --- |
| `ambient/providers/ambient_providers.dart` | 33/33 (%100) |
| `wellbeing/data/wellbeing_store.dart` | 87/87 (%100) |
| `wellbeing/data/wellbeing_disclosure_policy.dart` | 55/55 (%100) |
| `wellbeing/providers/wellbeing_providers.dart` | 78/85 (%91,8) |
| `wellbeing/presentation/wellbeing_screen.dart` | Bütün mevcut dosya 327/479 (%68,3); bu dilimin yeni/değişen retry satırları 29/29. |

Git taban diff'iyle eşlenen bütün yeni/değişen çalıştırılabilir üretim satırları
**92/94 (%97,9)**. Bu LCOV satır ölçümüdür; branch kapsamı iddiası değildir.
8 sahipli Dart dosyasının analizi sorunsuz, format kontrolü 8 dosya / 0 değişiklik,
`git diff --check` temizdir.

Kanıtlar çalışma makinesindeki özel geçici dizindedir:

- `/private/tmp/larenor-personal-boundary-red.log`
- `/private/tmp/larenor-personal-ui-red.log`
- `/private/tmp/larenor-personal-boundary-green.log`
- `/private/tmp/larenor-personal-reload-red.log`
- `/private/tmp/larenor-personal-reload-green.log`
- `/private/tmp/larenor-personal-boundary-regression.log`
- `/private/tmp/larenor-personal-boundary-coverage.info`
- `/private/tmp/larenor-personal-boundary-coverage-summary.json`
- `/private/tmp/larenor-personal-boundary-analyze.log`
- `/private/tmp/larenor-personal-boundary-format.log`

Bütün Flutter/Dart komutları ortak SDK kilit wrapper'ından çalıştırıldı;
offline paket çözümleme, l10n ve codegen ayrı hazırlandı. Testler gerçek
secure-storage/SharedPreferences platform seam'lerini sentetik verilerle,
fotoğraf arşivini yalnız teste ait geçici dizin ve sentetik byte'larla kullandı.
Gerçek sağlık izni, kamera/fotoğraf arşivi, ev/LAN/HA/Core API veya Docker
çağrısı yapılmadı. Bu dal push, CI rerun veya dağıtım yapmadı; birleşik ana dal
ve yayın kabulü [merkezî ilerleme kaydında](PROGRESS.md) ayrıca izlenir.
