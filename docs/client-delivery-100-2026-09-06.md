# Android 100 ve Core teslim doğrulaması

Kaynak: `1c2db575e7377e28e41bbd83aa34d4408e2029c1`.
6 Eylül 2026'da üç workflow ilk denemede ve bağımsız APK kontrolü tamamlandı.

| Kapı | Sonuç | Kanıt |
| --- | --- | --- |
| Core | 3.050 PASS, 0 hata/atlama, 389,50 saniye | [Core CI](https://github.com/ersingundem/larenor/actions/runs/34004246308) |
| Güvenlik | 207 araç testi, secret ve bağımlılık taraması geçti | [Security CI](https://github.com/ersingundem/larenor/actions/runs/34004246204) |
| Flutter | 4.301 PASS; analiz 0; 882 dosya, 0 biçim farkı | [Android CI](https://github.com/ersingundem/larenor/actions/runs/34004246242) |
| JVM | 18 test grubu, 98 PASS, 0 hata/atlama | [Native rapor](https://github.com/ersingundem/larenor/actions/runs/34004246242/artifacts/9980531395) |
| Emulator | 4 platform + 8 uygulama = 12 PASS; 76/76 faz sıralı | [Android CI](https://github.com/ersingundem/larenor/actions/runs/34004246242) |
| İmzalı APK | Tek tam indirme ve ayrıca imza/metadata doğrulaması | [APK 100](https://github.com/ersingundem/larenor/actions/runs/34004246242/artifacts/9980713220) |

Core JUnit raporu [9980520158](https://github.com/ersingundem/larenor/actions/runs/34004246308/artifacts/9980520158)
ile ayrıca okundu. Android içindeki tekrar kullanılan Core işi de 3.050 PASS /
0 skip / 592,16 saniye verdi; aynı testler ikinci kez toplam sayıya eklenmez.

Emulator 36.1.9.0 / build 13823996, API 35 default x86_64 / pixel_4.
E2E komutu 398,46166 saniye; emulator hazırlığı dahil adım 457 saniye sürdü.
Bunlar sırasıyla 18 ve 25 dakikalık sınırlar içinde. App remount fiziksel
process death veya cihaz yeniden başlatma kabulü değildir.

## APK'nın bağımsız kontrolü

- Paket `com.ersingundem.larenor`, sürüm `1.0.0` / `100000100`.
- minSdk 26, `debuggable=false`; kaynak commit ve workflow metadata eşleşti.
- ZIP 56.472.586 bayt, APK 120.618.537 bayt. Tam APK indirme sayısı: **1**.
- APK SHA-256: `e3b98de96efbb1a13b967e024760655aa9f27d2b72be5b1c1f8df43075188e1a`.
- Sertifika SHA-256: `d7c8be0fd89daa2d60aa97a249aa1e3615aed92fcb7e4135bbbd7456eb5882a0`.
- Java 17 / sabit apksig 9.1.0, exact-source doğrulayıcı kullanıldı; jar SHA-256:
  `562cd0a88890960d2ece48e116c61f12872222f1dcc306890799382bc019b201`.
- Son yerel teslim makbuzu SHA-256:
  `cb3472bf6eaad4e96712313d2ee01b9ba8fc933c6f519d8cdb7c7ca57ee45ef1`.

## Core yayını ve kabul sınırı

Anonim depo/AGPL kaynağı ve registry metadata'sı doğrulandı. Immutable
`sha-1c2db575e7377e28e41bbd83aa34d4408e2029c1` ile stable eşleşiyor;
`linux/amd64` ve `linux/arm64` doğru kaynak/AGPL metadata içeriyor. İndeks:
`sha256:8ea23fa52fa073865e09fc8f61b46103e4b1a7b64d7f813343bec27cb671d1ff`.
Registry katmanı indirilmedi. Her iki container smoke geçti; medya hazırlık
kontrolü gerçek Music Assistant/media kurulumu kabulü değildir.

Ev Core'una koşullu yayın atlandı; APK kurulmadı ve workflow tekrarlanmadı.
Huawei, DeX, HomePod, gerçek router/medya cihazları fiziksel kabulü açık.

Bu paket S08.4'ün kalıcı kayıt sınırı için gereken uzak kapıyı sağlar;
[üç madde ve 22 kayıt sınıfı incelemesi](client-boundary-acceptance-review-2026-09-06.md)
ile birlikte kabul edilir. Core metadata oluşturma/düzenleme/silme ekranı ve
sekizinci Android yolculuğu bu pakette. Kaynak erişimi yönetim ekranı,
volume journal ve dokuzuncu Android yolculuğu sonraki pakettedir. S08.5 restore,
S08.6 bütünü, typed adaptörler ve 63 özellik tamamlandı sayılmaz.

[Önceki APK 99 kanıtı](client-delivery-99-2026-09-06.md) ve başarısız Android 97
kayıtları korunur; yeni kabul eski sonuçları değiştirmez.
