# Kişisel sağlık ve akıllı tartılar

5 Eylül 2026. Bu belge uygulama kapsamını ve doğrulanacak bağlantı yollarını
tanımlar; aşağıdaki sağlayıcıların henüz bağlandığı anlamına gelmez. Kodda
`health` adı bağlantı/işlem durumları için kullanıldığından kişisel ölçümler
`wellbeing` özelliğinde tutulacak.

## Sağlayıcı yolları

| Kaynak | Uygulanacak erişim | Sınır / gereken hazırlık |
| --- | --- | --- |
| Apple Health | iOS HealthKit, cihazda kullanılabilirlik kontrolü ve yalnız seçilen okuma izinleri | Android'de HealthKit yok; iPhone'dan kullanıcı kontrollü aktarım veya HA/üretici köprüsü gerekir. iPadOS 17+ desteklenir. |
| Google Health / Health Connect | Android Health Connect, izin verilen kilo/vücut yağ oranı/adım gibi türler | Cihazda gerçek kullanılabilirlik kontrolü yapılır. Google Play servisleri olmayan Huawei tablet için kullanılabilir varsayılmaz. |
| Huawei Health | Huawei Health Kit'in yetkilendirilmiş okuma API'si | Uygulamanın Huawei kaydı, erişim kapsamlarının onayı ve kullanıcının veri türü izni gerekir; genel uygulama tokenı bu izinlerin yerini tutmaz. |
| Xiaomi / Mi Fitness | Mi Fitness'in Health Connect'e aktardığı veri türleri; uygun tartı için üretici veya HA yolu | Xiaomi'nin resmi Mi Fitness kaydı Health Connect eşitlemesini bildiriyor. Her modelin bütün ölçümlerini aktardığı varsayılmaz; kapalı bulut uçları taklit edilmez. |
| HA'ya bağlı akıllı tartılar | Kullanıcının seçtiği kişi ve ölçüm sensörleri, mevcut salt okunur entity akışı | Her tartı markası aynı entity/kişi yapısını kullanmaz. Otomatik olarak tüm evde gösterilmez; birim, kaynak ve ölçüm zamanı korunur. |

Apple cihazlarında HealthKit kullanılabilirliği çalışma anında sorgulanır;
kurumsal cihaz kısıtlamaları da erişimi engelleyebilir.
[Apple HealthKit kullanılabilirliği](https://developer.apple.com/documentation/HealthKit/HKHealthStore/isHealthDataAvailable%28%29)

Health Connect, Android 9+ ve Google Play servisleri gerektirir. Android 14+
sistem bileşenidir; daha eski destekli sürümlerde ayrı uygulamadır. Uygulama
kurulu olması ile veri türü izninin verilmiş olması ayrı durumlardır.
[Android kullanılabilirlik koşulları](https://developer.android.com/health-and-fitness/health-connect/availability)

Huawei Health Kit kullanıcı izniyle sağlık ve fitness verilerini açar. Okunabilir
veri, uygulamaya Huawei tarafından açılan kapsam ile kullanıcının izin verdiği
kapsamın kesişimidir; bazı tartı verileri genişletilmiş API üzerinden gelir.
[Huawei Health Kit](https://developer.huawei.com/consumer/en/hms/huaweihealth/),
[Huawei yetkilendirme](https://developer.huawei.com/consumer/en/doc/HMS-Plugin-Guides-V1/signing-in-and-pplying-for-permissions-0000001074001642-V1)

Mi Fitness'in resmi uygulama açıklaması Health Connect eşitlemesini destekler.
Bu, Larenor'a sınırsız Xiaomi hesap API erişimi sağlamaz; Health Connect'e gerçekten
yazılmış, izin verilmiş kayıtlar okunabilir.
[Xiaomi Mi Fitness resmi uygulama kaydı](https://play.google.com/store/apps/details?id=com.xiaomi.wearable)

## Uygulama ve kabul kontrolleri

- Sağlayıcı kartları: kullanılabilir, kurulum gerekli, izin gerekli, kısmi izin,
  okundu, güncelliğini yitirdi, desteklenmiyor. Kurulum açıklaması çalışan bir
  bağlantı gibi etiketlenmez.
- Veri modeli: kişi/kaynak/ölçüm türü, orijinal birim ve zaman, normalize edilmiş
  değer. Aynı ölçümün HA ve Health Connect kopyaları toplamları şişirmez.
- İlk sürüm okuma odaklıdır. Üçüncü taraf sağlık kaydı oluşturma veya değiştirme
  ayrı bir kullanıcı eylemi ve ayrı yazma izni gerektirir.
- Kişisel ölçümler ortak ev ekranına kendiliğinden eklenmez. Yetki iptalinde ve
  hesap değişiminde görünür önbellek temizlenir; ham ölçümler yapılandırma kasası,
  log, analitik, README ekran görüntüsü veya CI fixture'ına aktarılmaz.
- Tarih aralığı, sayfalama ve bellekte tutulan kayıt sayısı sınırlıdır. Başarısız
  okuma sıfır kilo/adım olarak gösterilmez. Eski ölçüme güncel saat atanmaz.
- Testler: kısmi/iptal edilmiş izin, sağlayıcı yokluğu, yanlış birim, çoklu kişi,
  yinelenen kayıt, hesap değişimi, zaman dilimi/gün sınırı, boş ve bozuk veri,
  Huawei'de GMS yokluğu, erişilebilir metin ölçeği ve tablet düzeni.

Huawei MatePad 11.5 S (2026) birincil Android/HarmonyOS hedefidir. Fiziksel cihaz
henüz bağlı olmadığından sağlayıcı yetkilendirmesi ve cihaz kabulü bekler.
