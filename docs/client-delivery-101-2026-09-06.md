# Android 101 ve Core teslim doğrulaması

Kaynak: `a27abeaa55a2ea94a0a0eaec1b9a74743c086a9c`. 6 Eylül 2026'da üç workflow ilk denemede geçti;
imzalı APK tek tam indirmeden sonra bağımsız doğrulandı.

| Kapı | Sonuç | Kanıt |
| --- | --- | --- |
| Core | 3.104 PASS, 0 hata/atlama, 420,31 saniye | [Core CI](https://github.com/ersingundem/larenor/actions/runs/34005590288) |
| Güvenlik | 207 araç testi, secret ve bağımlılık taraması geçti | [Security CI](https://github.com/ersingundem/larenor/actions/runs/34005590189) |
| Flutter | 4.390 PASS; analiz0; 895 dosyada0 biçim farkı | [Android CI](https://github.com/ersingundem/larenor/actions/runs/34005590269) |
| JVM | 18 test grubu, 98 PASS, 0 hata/atlama | [Native rapor](https://github.com/ersingundem/larenor/actions/runs/34005590269/artifacts/9980925261) |
| Emulator | 4 platform + 9 uygulama = 13 PASS; 89/89 faz sıralı | [Android CI](https://github.com/ersingundem/larenor/actions/runs/34005590269) |
| İmzalı APK | Tek indirme, bağımsız imza/paket/hash kontrolü | [APK101](https://github.com/ersingundem/larenor/actions/runs/34005590269/artifacts/9981149610) |

Core JUnit [9980912264](https://github.com/ersingundem/larenor/actions/runs/34005590288/artifacts/9980912264)
ayrıca okundu. Android'in tekrar kullanılan Core işi de3.104 PASS/0skip,
424,65 saniye verdi; aynı testler ikinci kez toplama eklenmez.
Emulator36.1.9.0/build13823996, API35/default/x86_64/pixel_4.
E2E komutu456,548115 saniye; hazırlık dahil emulator adımı518 saniye;
18/25 dakikalık sınırlar içinde. Uygulama remount'ları aynı süreçteki
sentetik depolamayı kullanır; dört native probe testi ayrı kapsamdır.

## Bağımsız APK kontrolü

- Paket `com.ersingundem.larenor`, sürüm `1.0.0` / `100000101`.
- minSdk26, `debuggable=false`; kaynak commit ve workflow metadata eşleşti.
- ZIP 56,525,993 bayt; APK 120,782,377 bayt; tam APK transferi **1**.
- APK SHA-256: `7050ae23bc370a9de978b1e7ea84ca52ab5b19f8be40d672cec5730fae2fec89`.
- Sertifika SHA-256: `d7c8be0fd89daa2d60aa97a249aa1e3615aed92fcb7e4135bbbd7456eb5882a0`.
- Java17 / exact-source doğrulayıcı; sabit apksig9.1.0 bağımlılığı jar SHA-256:
  `562cd0a88890960d2ece48e116c61f12872222f1dcc306890799382bc019b201`.
- Son yerel teslim makbuzu SHA-256:
  `12ed65910d857b41e73c38a147d7459478b6b1d4c674bb9af26401587966284b`.

## Core yayını ve kapsam

Anonim kaynak/AGPL ve immutable+stable iki mimarili OCI metadata doğrulandı:
`sha256:cf22f05ad388d9fb8fcda65aaf2f141e77ea6d95d74dd5007dfab313776ea735`.
linux/amd64 ve linux/arm64 exact-source etiketleri eşleşti; katman indirilmedi.
İki container smoke geçti. Ev Core'una koşullu yayın atlandı; APK kurulmadı,
workflow tekrarlanmadı. Huawei/DeX/HomePod ve gerçek ev cihazlarının fiziksel
kabulü bu sonuçlardan çıkarılmaz.

Bu pakette Core kaynak erişimi yönetimi, dokuzuncu ACL Android yolculuğu
ve kalıcı volume gözlem journal'ı bulunur. Volume Unix reader, logout
kalıcılık düzeltmesi ve onuncu Android yolculuğu sonraki pakettedir.
Restore/hane kişi modeli ve S08.6/S06.3d bütünü tamamlandı sayılmaz.
[Birleşim kanıtı](core-grants-volume-integration-2026-09-06.md) ve
[önceki APK100](client-delivery-100-2026-09-06.md) ayrı korunur.
