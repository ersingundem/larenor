# Android 103: logout remount hazır olma koşulu

Yayımlanan `2cced392cbac18a8c5d9d9c038b5d06cbb628ef5` Android103 E2E koşusunda login/PIN, logout iptali ve session silme geçti. Onuncu yolculuk `remount_begin` sonrası `tester.element(CoreHomeStatusScreen)` çağrısında `StateError: No element` ile durdu. Exact log `/private/tmp/larenor-2cced39-e2e.log:2060–2095`: 13 PASS/1 FAIL, 97/99 işaret. Bu bir test hazır olma koşulu hatasıdır; hazırlanmış restore veya kişi API paketi bu kaynakta yoktur.

Düzeltme yalnız `integration_test/support/single_element_ready.dart`, onuncu yolculuğun çağrı noktası ve yeni host testidir. Helper tek bağlı Element varsa mevcut ProviderContainer/account `initialized && !working` koşulunu değerlendirir. Boş veya çoğul sonuç false olur. Koşul içindeki hatalar yakalanmaz. Genel `waitUntil`, 30 saniyelik sınır, son account/session/HA doğrulamaları, cleanup ve zaman aşımları değişmedi.

- Dal `codex/logout-remount-readiness`, çalışma ağacı `/private/tmp/larenor-logout-remount-readiness`.
- Runtime RED `7b41356`: 1 PASS/2 FAIL. Gerçek mounted widget/provider sırası boş→hazır değil→yok→hazır ve duplicate durumda eski `.single` davranışını yeniden üretir. Üçüncü test koşul hatasının aynen yayılmasını doğrular.
- GREEN `6e64062`: aynı 3 test PASS. Helper en fazla iki eşleşmeyi inceler, yalnız tek bağlı hedefte callback çağırır.
- RED/GREEN logları `/private/tmp/larenor-remount-readiness-red.log` ve `/private/tmp/larenor-remount-readiness-green.log`.

## Koruma kanıtı

`/private/tmp/larenor-remount-preservation.json`, yayımlanan tabana karşı ilk dokuz yolculuğun gövdesinin byte-for-byte aynı olduğunu ve 89 işaretin korunduğunu doğrular. On yolculuğun toplam 99 işareti aynı sıradadır; timeout ifadeleri, AppHarness/`waitUntil` ve tüm üretim/CI kaynakları değişmemiştir. Yeni SDK çalışma ağacında yalnız ignored generated dosyalar `build_runner` ile hazırlanmıştır.

Son tüm `test/integration_support`: 91 PASS / 9 saniye; `/private/tmp/larenor-remount-support-final.log`. Tam `flutter analyze --no-pub`: 0 sorun / 6 saniye; `/private/tmp/larenor-remount-analyze.log`. Tam lib/test/integration_test format doğrulaması: 899 dosya/0 değişiklik; `/private/tmp/larenor-remount-full-format.log`. Bu kontroller biçim düzeltmelerinden sonra koştu; SDK ortak kilidi kullanıldı.

Bu teslim host/widget test kanıtıdır. Gerçek Android yeniden çalıştırma veya imzalı APK103 başarılı kabulü değildir. Push, CI başlatma, gerçek endpoint/ev/cihaz işlemi yapılmadı. Özel makbuz `/private/tmp/larenor-logout-remount-readiness-delivery-evidence.json`.
