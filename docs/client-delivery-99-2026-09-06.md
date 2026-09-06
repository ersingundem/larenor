# Android 99 ve Core teslim doğrulaması

Kaynak: `4bc79dcc66eb9e3ce2a5044bd240db2fafd0d695`.
6 Eylül 2026'da bu kaynağın üç workflow'u ve bağımsız APK kontrolü tamamlandı.

| Kapı | Sonuç | Kanıt |
| --- | --- | --- |
| Core | 2.951 PASS, 0 hata/atlama; ilk deneme | [Core CI](https://github.com/ersingundem/larenor/actions/runs/34002121806) |
| Güvenlik | 207 araç testi, secret ve bağımlılık taraması geçti | [Security CI](https://github.com/ersingundem/larenor/actions/runs/34002121729) |
| Flutter | 3.941 PASS; analiz 0; 860 dosya, 0 biçim farkı | [Android CI](https://github.com/ersingundem/larenor/actions/runs/34002121963) |
| JVM | 18 test grubu, 98 PASS, 0 hata/atlama | [Native rapor](https://github.com/ersingundem/larenor/actions/runs/34002121963/artifacts/9979898887) |
| Emulator | 4 native + 7 uygulama = 11 PASS; 65/65 faz sıralı | [Android CI](https://github.com/ersingundem/larenor/actions/runs/34002121963) |
| İmzalı APK | Tek tam indirme ve ayrıca imza/metadata doğrulaması | [APK 99](https://github.com/ersingundem/larenor/actions/runs/34002121963/artifacts/9980085515) |

Emulator 36.1.9.0 / build 13823996 kullanıldı. Sınırlı E2E komutu
344,058 saniye, emulator hazırlığı dahil adım 416 saniye sürdü; sırasıyla
18 ve 25 dakikalık sınırlar içindedir. Remount testi uygulama ağacını yeniden
kurar; fiziksel cihaz yeniden başlatma kabulü değildir.

## APK'nın bağımsız kontrolü

- Paket `com.ersingundem.larenor`, sürüm `1.0.0` / `100000099`.
- minSdk 26, `debuggable=false`; kaynak commit ve workflow metadata eşleşti.
- ZIP 56.391.525 bayt, APK 120.389.161 bayt. Tam indirme sayısı: **1**.
- APK SHA-256: `099476a93aa3492c8c4aae283be8868d3c536f448ddcfecdab9c9b980a93b396`.
- Sertifika SHA-256: `d7c8be0fd89daa2d60aa97a249aa1e3615aed92fcb7e4135bbbd7456eb5882a0`.
- Java 17 / sabit apksig 9.1.0 kullanıldı; doğrulayıcı jar SHA-256:
  `562cd0a88890960d2ece48e116c61f12872222f1dcc306890799382bc019b201`.

## Core yayını ve sınırlar

Anonim registry sorgusu, immutable `sha-4bc79dcc66eb9e3ce2a5044bd240db2fafd0d695`
etiketiyle stable indeksinin eşleştiğini ve `linux/amd64` + `linux/arm64`
manifestlerinin doğru kaynak/AGPL metadata içerdiğini doğruladı. İndeks:
`sha256:5c584f0a5bb4c344bf17c6317383728465aead62bd16ae4e80718139b77c38cd`.
Registry katmanı indirilmedi. Medya hazırlığı smoke'u gerçek ev kurulumu
veya çalışan Music Assistant/media stack kabulü değildir.

Ev Core'una koşullu yayın atlandı; APK kurulmadı. Huawei, DeX, HomePod,
gerçek router ve medya cihazı kabulü açık. Sonraki Keenetic pilotu,
operasyon ekranları, dashboard WebView sınırı, Core metadata yönetim ekranı,
grant Client API'si ve volume gözlemi bu APK'ya dahil değildir.
Bu teslim, tüm S08.4/S08.6 veya 63 özellik için kabul sayılmaz.

Önceki başarısız Android 97 ve başarılı APK 98 kanıtları korunur.
