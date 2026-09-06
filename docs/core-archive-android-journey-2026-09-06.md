# Core oda arşivi için Android yolculuğu

Bu test dilimi gerçek `HomeSessionScope`, Settings PIN kapısı, Core hesap HTTP
akışı, scoped `DashboardRepository`, arşiv codec'i ve restore controller'ını
kullanır. Yeni yolculuk henüz Android'de çalıştırılmadı; host test sonuçları
native kabul veya fiziksel cihaz doğrulaması değildir.

`SyntheticCoreArchiveFiles` yalnız işletim sistemi dosya seçme/kaydetme yüzeyinin
bellek karşılığıdır. Baytları kopyalar, en çok dört bekleyen seçim ve gerçek file
adapter'ının 3 MiB sınırını korur. Null seçim iptaldir. Adapter şifre çözmez,
kimlik doğrulamaz, restore yetkisi vermez ve dosya/ağ erişimi yapmaz. Gerçek
şifreleme üretim codec'inde PBKDF2-HMAC-SHA256 (600000) ve AES-256-GCM ile çalışır.
`AppHarness.mount` yalnız açıkça verilen `coreArchiveFiles` için runtime override
kurar; eski parametresiz çağrılar ve varsayılan fixture davranışı korunur.

Yolculuk Core hesabına PIN ile giriş yapar, Home source kapısını PIN ile açar,
şifreli arşiv dışa aktarır; dosya seçimini iptal eder, yanlış parolayı reddeder,
önizleme ve onay iptalinde hedefi değiştirmez, ayrı açık onayla restore uygular.
Scoped revision, tam Core/home/user bağı, gerçek repository readback ve
`SharedPreferences.reload` sonrasındaki kayıt karşılaştırılır. Yeniden açılan
arşiv ekranı kaydedilmiş odaları yeniden okur. Eski Direct düzen değişmez;
HA HTTP/WS, komutlar ve yabancı ağ sayaçları sıfır beklenir.

Kaynak ve farklı hedef odalar test kurulumu sırasında gerçek scoped repository
ile hazırlanır. Bu adımlar kullanıcı arayüzünde oda düzenleme kanıtı değildir.
SharedPreferences/secure storage mevcut AppHarness'in sentetik platform
backend'leridir; fiziksel disk veya uygulama süreç yeniden başlatması iddia
edilmez. Bellek adapter'ının hemen dönen future'ı gerçek OS picker, Android
odak/lifecycle kaybı veya dönüşte yeniden PIN girişini taklit etmez; bunların
ilgili UI host testleri ayrı kanıttır.

İlk on yolculuğun gövdeleri, 99 marker'ı ve timeout'ları değişmez.
`app_journeys_test.dart` yalnız import ve sonda kayıt çağrısı ekler. Yeni yardımcı
12 sıralı `core_archive.*` marker üretir: bu dalda 111 marker/11 app + 4 platform
hedefi; ayrı kişi yolculuğu son birleşimde ayrıca sayılmalıdır.

## Yerel kanıt

- Fixture runtime RED `80b69c4`: güvenli no-op adapter ile 9 FAIL.
- Minimal GREEN `783f898`: aynı 9 PASS/8sn. Gerçek codec/controller turu dahil.
- Journey kaynak checkpoint'i `2cb8be0`; UI GREEN `8ecc13d` ortak geçmişle alındı.
- UI GREEN birleşiminde 100 integration-support test PASS/8sn; beş dosyada
  analiz0, beş dosya format kontrolünde değişiklik0.
- Bağımsız review'un nested EditableText scrollable bulgusu runtime RED
  `6888189` ile doğrulandı: gerçek PIN'li arşiv ekranı 600×500 boyutunda,
  password alanları bağlıyken yanlış helper dikey sayfayı 376px'de bıraktı.
  GREEN `3589be6` aynı testi geçirir; scroll yalnız arşiv ekranındaki ListView'e
  bağlıdır. Cupertino bounce'un sıfıra dönüşü mevcut bounded `waitUntil` ile
  beklenir; global quiescence, timeout veya sonuç assertion'ı gevşetilmez.
- İlk 1000px yükseklikli fixture sayfaya sığdığı için oluşan precondition FAIL
  bug RED'i değildir. İlk seçim düzeltmesinde görülen -305px bounce ara FAIL'i
  de ayrı logda korunur; yalnız son `scroll-final-green` başarılıdır.
- Final UI `523a07f` ortak geçmişle alındı. Son **101 integration-support PASS/5sn**
  (dokuz file fixture + bir gerçek UI scroll testi dahil); altı dosyada
  **analiz0/3.1sn**, altı dosya format kontrolü **değişiklik0**.
- Bu yalnız test-support/journey dilimidir. Yeni üretim satırı kapsamı veya
  henüz çalışmayan Android journey için coverage yüzdesi atfedilmez.

Loglar `/private/tmp/larenor-core-archive-journey-*` ve
`/private/tmp/larenor-core-archive-scroll-*`; gövde/varsayılan harness koruma
kanıtı `/private/tmp/larenor-core-archive-journey-preservation.json`.
Yeni üretim API'si, CI değişikliği, cihaz kurulumu veya ev hizmeti işlemi yoktur.
