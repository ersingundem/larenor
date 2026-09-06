# Client105 — tablet restore ve kişi yönetimi yayını

Kaynak `38e78a34bc554c39647a8616b905aa2f9c9627b9` main'e gönderildi.
Durum: CI sürüyor; imzalı APK105 henüz teslim kabulü almadı. Önceki tam
doğrulanmış yayın [APK104](client-delivery-104-2026-09-06.md) olarak kalır.

| İlk deneme | Durum |
| --- | --- |
| [Android105](https://github.com/ersingundem/larenor/actions/runs/34015830766) | Çalışıyor |
| [Core32](https://github.com/ersingundem/larenor/actions/runs/34015830774) | Başarılı |
| [Security105](https://github.com/ersingundem/larenor/actions/runs/34015830712) | Başarılı |

Yerel kaynak `bd9d425` ile yayın kaynağının lib/test/integration_test/Android/
pubspec/Server/contracts Git ağaçları aynıdır. **5.056 Client PASS/5:19**,
analiz0 ve966dosya biçim farkı0; **3.300 Core PASS/11Linuxskip** yerel kanıttır.
İlk5.014PASS/4FAIL ve test onarımı [birleşim kaydında](prepared-vault-household-integration-2026-09-06.md)
korunur. Yayın kaynağına kadar gitleaks ve backup/CI trust statik kontrolü geçti.

Beklenen native kaynak manifesti **13 app+4platform=17E2E/133faz** içerir.
Bu sayı çalışma sonucu değildir. Üç yeni yolculuk kişi üye okuması, şifreli
arşiv restore ve kişi admin/ACL akışlarıdır; eski10gövde/99faz aynıdır.

Tek gözlemci exact SHA/run/attempt1 bağlarını doğrular. Üç CI geçmeden APK
transferi yapılmaz; sonra tek tam indirme ve bağımsız Java17/pinned-apksig
kontrolüyle source/package/version/certificate/debuggable doğrulanır. Anonim
Core image manifest/source/AGPL kanıtı ayrı tutulur; katman veya ev kurulumu yoktur.
Canlı özel makbuz `/private/tmp/larenor-38e78a3-delivery-evidence.json`.
S08.5/S08.6 kabulü, fiziksel cihaz ve gerçek ev kurulumundan ayrı izlenir.

## Doğrulanan ara uzak sonuçlar

Core Linux **3.311 PASS/0skip**, Android reusable Server işi ayrıca
**3.311 PASS/0skip** verdi; bunlar ayrı koşular, test sayıları toplanmaz.
Core JUnit3311/0failure/0error/0skip, JVM XML **98 PASS/0skip** olarak okundu.
Güvenlik207PASS/24,502sn, gitleaks0 ve OSV başarılı. Debug derlemesi tamamlandı;
gerçek API35 E2E ve Flutter kapıları henüz tamamlanmadı, APK transferi0.

Core amd64/arm64 smoke, kaynak ve AGPL metadata'sı anonim doğrulandı.
Stable ve exact-source manifest index'i aynıdır:
`sha256:821d3fa17fbdfbdb1ccfeda1929d862f41af07be0a2767d5c241e1ad0e692840`.
İmaj katmanı indirilmedi; bu doğrulama gerçek eve kurulum değildir.
