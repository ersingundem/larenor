# F34 Android QR paylaşım hedefi — TDD kanıtı

21 Eylül 2026. Bu dilim envanter etiketini Android'in yerel paylaşım sayfasına
yalnız açık kullanıcı eylemiyle ve dar bir dosya yetkisiyle aktarır. F34;
yazdırılabilir etiket yönetimi ve fiziksel tablet/kamera kabulü tamamlanana
kadar açık kalır.

## Üç kabul ölçütü

1. Flutter köprüsü yalnız typed `InventoryQrExport` kabul eder. Oturum kimliği,
   etkileşim epoch'u, canonical dosya adı, `image/svg+xml` türü ve 256 KB
   sınırı yerel çağrıdan önce doğrulanır; token, grant veya özel dosya yolu
   paylaşım isteğine giremez.
2. Android köprüsü paylaşımı yalnız resumed, odaklı, güncel oturum ve güncel
   epoch ile bir kez çalıştırır. Lifecycle, odak veya oturum değişimi önceki
   yetkiyi emekli eder; tekrar kullanım `busy`, eski kullanım `expired` ile
   kapalı reddedilir.
3. SVG içerik ve boyut denetiminden sonra atomik olarak uygulamanın özel cache
   alanına yazılır. Yalnız `inventory_exports/share` kökünü açan, export
   edilmeyen özel `FileProvider`; `ACTION_SEND` intent'ine süreli okuma izni
   verir. Başka cache dosyaları URI'ye çevrilemez.

## RED / GREEN ve doğrulama

- RED `5ebcccaf`: Flutter ve Robolectric sözleşmeleri üretim köprüleri yokken
  derleme/test hatasını kaydetti.
- `InventoryShareBridgeTest` hedefli Android görevinde **2/2 PASS**. Test
  izolasyonu Robolectric'in süreç çapındaki `FileProvider` önbelleğini her test
  öncesi temizler; üretim yolu değişmez.
- Flutter QR paylaşım paketi **2/2 PASS**; hedefli analiz temizdir.
- Android `MainActivity`, QR paylaşım köprüsüyle yerel bildirim köprüsünü aynı
  lifecycle ve pencere odağı akışında birlikte çalıştırır. Hedefli Gradle testi
  bu birleşik giriş noktasını da derledi.
- `python3 tool/check_security_policy.py`, kuyruk doğrulaması,
  `git diff --check` ve dal secret taraması kapanış kapılarıdır.

Bu yazılım dilimi ilerleme sayaçlarını tek başına değiştirmez. Fiziksel tablette
paylaşım sayfası, hedef uygulama ve gerçek etiket kabulü MANUAL kalır.
