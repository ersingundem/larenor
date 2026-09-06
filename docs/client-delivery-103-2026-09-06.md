# Android 103 — yeniden kurulum beklemesi, teslim durduruldu

Kaynak `2cced392cbac18a8c5d9d9c038b5d06cbb628ef5`. Üç workflow ilk deneme;
Android başarısız, Core ve güvenlik başarılı. Bu kayıt APK103 kabulü değildir.

| Kanıt | Sonuç |
| --- | --- |
| [Android103](https://github.com/ersingundem/larenor/actions/runs/34012091515) | Flutter4.418 PASS, analiz0,898dosya biçim farkı0, JVM98 PASS |
| [Core30](https://github.com/ersingundem/larenor/actions/runs/34012091577) | Linux3.203 PASS/0skip/428,32sn |
| [Güvenlik103](https://github.com/ersingundem/larenor/actions/runs/34012091354) | 207 PASS; dependency ve redakte sır taraması geçti |
| Android E2E | 13 PASS/1 FAIL;97/99 sıralı alt küme, önceki89 faz tam |
| İmzalı APK | Signing işi atlandı; APK tam transfer0, cihaz kurulumu0 |

Onuncu yolculukta hesap girişi, PIN, çıkışı iptal etme ve kalıcı oturumu silme
geçti. `remount_begin` sonrasında ekran bir sonraki frame'de geçici olarak
yokken `tester.element` çağrıldı: `StateError: Bad state: No element`,
`integration_test/app_journeys_test.dart:1300:20`. Cleanup tamamlandı;
`remounted_without_session` ve `recovery_pin_required` fazlarına ulaşılamadı.
Log: `/private/tmp/larenor-2cced39-e2e.log:2060–2095`.

Emülatör script495,317sn, tüm adım558sn sürdü; timeout sınırlarına ulaşmadı.
Önceki CI102'nin `ref.id` fixture düzeltmesi bu kez geçti. CI103 hazırlanmış
restore, Vault veya hane kişi API paketini içermez.

Anonim Core stable/immutable manifest linux/amd64 ve linux/arm64 için aynı
kaynak, AGPL lisansı ve kaynak bağlantısıyla doğrulandı. Index digest:
`sha256:c541037eb3a22dd90dbc6b9d204d0e206afea6f5628c8ffd1da49bfe62bd8edc`.
İmaj katmanı indirilmedi; ev Core'una yayın ve gerçek cihaz işlemi yapılmadı.

Makbuz `/private/tmp/larenor-2cced39-delivery-evidence.json`, SHA256
`115dee70744e0e81faeeface6ee6886cccffc332aa92e4d3db16c140f27c1bb2`.
Bütün observer süreçleri tamamlandı; rerun0, APK transfer0. Son tam
doğrulanmış imzalı teslim [APK101](client-delivery-101-2026-09-06.md) kalır.

## Ayrı dar onarım

`64bdf58951ea371dc5ad0ed65348c533c8c777dc` yalnız tek mounted hedef hazır
olana kadar mevcut koşulu değerlendirir. [RED/GREEN ve koruma kanıtı](logout-remount-readiness-repair-2026-09-06.md):
1 PASS/2 FAIL→3 PASS;91 destek PASS, analiz0,899dosya biçim farkı0;
bağımsız inceleme CLEAR. İlk9 yolculuk/99 toplam faz, timeout ve son
account/HA/session doğrulamaları aynıdır. CI104 bu yeni kaynağın kabul kapısıdır.
