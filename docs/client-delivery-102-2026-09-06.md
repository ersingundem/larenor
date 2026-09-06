# Android 102 — teslimi durduran E2E hatası

Kaynak: `38bc2bc24aa5f0174bbeb20257ea56d304f1fe5c`. Son tam doğrulanmış
Client, [APK101](client-delivery-101-2026-09-06.md) olarak kalır.

| Exact-source kontrol | Sonuç |
|---|---|
| [Core CI](https://github.com/ersingundem/larenor/actions/runs/34006880414) | Linux 3.203 PASS / 0 skip / 426,33 sn |
| [Android102](https://github.com/ersingundem/larenor/actions/runs/34006880503) | Flutter 4.417 PASS; analiz0; 898 dosya biçim farkı0; JVM98 PASS |
| Android içindeki tekrar Core işi | 3.203 PASS / 428,07 sn; üstteki sayıya eklenmez |
| [Güvenlik](https://github.com/ersingundem/larenor/actions/runs/34006880305) | 207 PASS; taramalar geçti |
| Android E2E | 4 platform + 9 uygulama PASS; onuncu uygulama FAIL; toplam13 PASS/1 FAIL,90/99 sıralı faz |
| İmzalı APK102 | İmzalama işi skipped; APK aktarımı0; teslim kabulü yok |

E2E süre aşımı değildir: script466,538423 sn, emülatör adımı526 sn.
`integration_test/app_journeys_test.dart:1192` içindeki `target['id']`
ifadesi null döndürdü; sözleşmede kimlik `target['ref']['id']` içinde.
`core_logout.begin` sonrasında, uygulama mount edilmeden TypeError oluştu.
Bu koşu logout ekranının uçtan uca çalışmasını doğrulamaz. İlk dokuz
uygulama yolculuğunun kanıtları korunur; yeni yolculuk sonraki kaynakta
tekrar doğrulanacaktır. Hatalı okuma cleanup kapsamına da taşınmalıdır.

Anonim kaynak/AGPL ve iki mimarili Core manifesti doğrulandı:
`sha256:30ecf1ab15ed24e462fde2fc80e494091668760cebdc1bd3b16146d9edd521b6`.
İmaj katmanı indirilmedi; evde yayın, kurulum veya cihaz işlemi yapılmadı.
Üç CI ilk denemedir; rerun0. Gözlem süreçleri sonlandırıldı.

Özel makbuz: `/private/tmp/larenor-38bc2bc-delivery-evidence.json`.
SHA-256: `4b41ae704999888b17c7a4e0738571f956edc401b81453c1efb55e70e3bd7003`.
Durum: `delivery_blocked_e2e_failure`; `deliveryAccepted=false`.
Bu belge paket102'nin sonuç kaydıdır; sonraki düzeltmenin kabulü değildir.
