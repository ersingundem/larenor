# Android E2E — emülatör öncesi native derleme

5 Eylül 2026. Değişiklik `d53f8c3` RED → `d36a6bc` GREEN;
ana dal birleşimi `5fecbfc`. Yeni gerçek CI sonucu henüz alınmadı.

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
  native odak, dört uygulama akışı ve imzalı APK kapısı ayrıca doğrulanacak.

Bu değişiklik ev sunucusuna veya fiziksel Android cihaza işlem yapmaz.
