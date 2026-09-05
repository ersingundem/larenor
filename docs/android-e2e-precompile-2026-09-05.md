# Android E2E — emülatör öncesi native derleme

5 Eylül 2026. Değişiklik `d53f8c3` RED → `d36a6bc` GREEN;
ana dal birleşimi `5fecbfc`. `3dde2f8` gerçek Android CI, imzalı APK 93
teslimi ve indirilen dosyanın bağımsız imza/metadata kontrolü geçti.

## Ölçülen sorun

[`9138e61` Android 92](https://github.com/ersingundem/larenor/actions/runs/33986835301)
2.739 Flutter, 98 JVM ve dört uygulama akışını geçti. Dört native kontrolden
odak testi başarısız oldu: filtrelenmiş pencere kaydı uygulama hata diyaloğunu,
ekran görüntüsü “Quickstep isn't responding” penceresini gösterdi. QEMU/adb
canlı, ekran uyanık ve kilitsizdi. Bu bulgu OOM veya QEMU çökmesi kanıtı değildir.

Emülatör başladıktan sonraki ilk Gradle derlemesi 363,9 saniye, ikinci derleme
36,1 saniye sürdü. Toplam emülatör/test akışı 673,224 saniye ile mevcut
18 dakikalık sınır içindeydi. 42 uygulama aşaması ve dört temizlik tamamlandı.
E2E 7/8 kaldığı için imzalı APK 92 işi atlandı; dosya üretilmedi.

## Dar değişiklik ve kabul sınırı

`prepare_android_e2e_build.sh`, kaynak üretimini ve x86_64 debug native test
APK derlemesini SDK hazırlığından sonra, emülatör başlamadan çalıştırır.
Bu bir yük azaltma önlemidir; ölçülmüş kök neden veya doğrulanmış ANR çözümü
olarak sunulmaz. Üretilen hazırlık APK'sı kurulmaz veya yayımlanmaz.

Hazırlık ve asıl koşu `android_e2e_gradle.sh` üzerinden aynı geçici CI Gradle
home'unu kullanır: heap 3 GiB, metaspace 1 GiB, iki worker, paralel proje
derlemesi kapalı. Yerel geliştiricinin Gradle ayarları değiştirilmez.
[Gradle property önceliği](https://docs.gradle.org/current/userguide/build_environment.html).

`flutter test integration_test` kendi oluşturduğu test harness'ini yeniden
derleyip açıkça seçilmiş, QEMU olduğu doğrulanmış emülatöre kurmaya devam eder.
Flutter 3.47.2 `IntegrationTestTestDevice.start` kaynak kodu bu ayrı entrypoint
ve `device.startApp` akışını doğrular; hazırlık APK'sı test yürütme kanıtı sayılmaz.
[Flutter gerçek cihaz entegrasyon testleri](https://docs.flutter.dev/testing/integration-tests).

Odak/önplan beklentileri, kiosk ve güç kuralları, sekiz gerçek senaryo,
18 dakika koşu ve 180 saniye test sınırları korunur. Hata diyaloğu kapatma,
başlatıcıyı devre dışı bırakma, testi atlama veya başarısızlığı yeniden deneme
eklenmedi. Derleme/kanıt boru hattı hataları sonraki adıma geçişi engeller.
Yeni `android-precompile.log`, mevcut test/odak kanıtlarıyla birlikte saklanır.

## Yerel kanıt

- Beş yeni test önce başarısız oldu; ardından beşi de geçti.
- 42 ilgili E2E araç testi ve toplam 207 araç testi geçti.
- `actionlint`, üç script için `shellcheck -x` ve diff kontrolü temiz.
- Bağımsız işlevsel inceleme tamamlandı; açık P1/P2 bulgusu yok.
- Yeni gerçek CI'da ilk hazırlık derlemesi, test harness derleme süreleri,
  native odak, dört uygulama akışı ve imzalı APK kapısı aşağıda ayrıca doğrulandı.

Bu değişiklik ev sunucusuna veya fiziksel Android cihaza işlem yapmaz.

## İlk gerçek CI ölçümü — 3dde2f8

[Android 93](https://github.com/ersingundem/larenor/actions/runs/33988283337)
2.739 Flutter/98 JVM ve dört native + dört uygulama senaryosunu geçti.
Hazırlık adımı emülatörden önce yaklaşık 403 saniye sürdü; bunun Gradle kısmı
349,7 saniye. Emülatör başladıktan sonraki ilk/ikinci Gradle derlemeleri
23,9 ve 36,0 saniye oldu (önceki koşuda 363,9 ve 36,1 saniye).
Test komutu 231,793 saniyede tamamlandı; 18 dakika sınırında 848,207 saniye kaldı.
Toplam hazırlık süresi bu ölçümden ayrı tutulur; uygulamanın veya bütün CI'nın
aynı oranda hızlandığı söylenmez.

Emülatör 36.1.9/build 13823996 ve ilk denemede stay-awake koşulu doğrulandı;
42 faz/dört temizlik tamamlandı. Odak hata işareti veya hata ekran görüntüsü
oluşmadı. Bu tek başarılı koşu, Quickstep ANR'nin kesin kök nedenini veya
sonraki bütün çalışmalarda tekrarlanmayacağını kanıtlamaz.

İmzalı APK 93 teslimi ve Java 17 + sabit apksig 9.1.0 ile bağımsız paket,
sertifika, kaynak ve metadata eşleşmesi de başarılı. S08.3 sonradan beşinci
uygulama akışını ekledi; yeni toplam dokuz E2E bu sekiz senaryoluk kanıtın
kapsamına girmez. [Güncel teslim kaydı](PROGRESS.md).
