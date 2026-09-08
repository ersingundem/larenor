# Client 116 — doğrulanmış standart teslim

**Sonuç: standart Client teslimi kabul edildi; Jellyfin native depolama karakterizasyonu ayrı ve açıktır.** Android, Server Container ve Security iş akışları aynı `5cbff217cdcf719d9162b9b2b33bf22dd47a1996` kaynağında ilk denemede başarılı oldu. İmzalı APK GitHub artifact'inden bir kez indirildi ve kaynak metadata'sından bağımsız olarak paket, sürüm, minimum SDK, debug bayrağı ve sertifika özeti doğrulandı.

[Kesin kaynak](https://github.com/ersingundem/larenor/tree/5cbff217cdcf719d9162b9b2b33bf22dd47a1996) · [Android Build #116](https://github.com/ersingundem/larenor/actions/runs/34212319493) · [Server Container Build #35](https://github.com/ersingundem/larenor/actions/runs/34212319638) · [Security #117](https://github.com/ersingundem/larenor/actions/runs/34212319007)

| Kabul kapısı | Gerçek CI sonucu |
| --- | --- |
| Flutter | **5.220 PASS**, analiz 0 sorun; 973 dosyada biçim farkı 0 |
| Linux Server | **3.569 PASS**, hata/atlama 0 |
| JVM / Robolectric | **98 PASS**, hata/atlama 0 |
| Güvenlik politikası | **215 PASS**; gitleaks temiz |
| Gerçek Android E2E | **4 platform + 13 uygulama yolculuğu = 17 PASS**, **133 benzersiz faz** |
| İmzalı APK | CI derleme/doğrulaması ve bağımsız yerel doğrulama başarılı |

## İmzalı APK

Artifact ID **10051266925** ve APK boyutu **121.634.345 bayt**. Sertifika özeti ile APK özeti ayrı alanlar olarak doğrulandı.

| Alan | Bağımsız sonuç |
| --- | --- |
| Paket | `com.ersingundem.larenor` |
| Sürüm | `1.0.0` / `100000116` |
| Minimum SDK | `26` |
| Debuggable | `false` |
| APK SHA-256 | `cdef2c9d7d98a551f41aa3be712bda45b3ea136d54dc478515f381db5570d108` |
| İmzalayan sertifika SHA-256 | `d7c8be0fd89daa2d60aa97a249aa1e3615aed92fcb7e4135bbbd7456eb5882a0` |

`LARENOR_RELEASE_SERVER_URL` depo değişkeni yapılandırılmadığı için doğrulanmış Client'ı evdeki Larenor Server'a yayınlama adımı koşullu olarak atlandı. İmzalı artifact yayımlandı; uygulama hiçbir cihaza kurulmadı ve ev sistemlerinde işlem yapılmadı.

## Ayrı kalan native karakterizasyon

[Manual Jellyfin Native Storage Characterization #1](https://github.com/ersingundem/larenor/actions/runs/34213095299) iki mimaride de karakterizasyon adımında başarısız oldu ve makbuz üretmedi. Bu başarısızlık standart Android/Server/Security teslimini geçersiz kılmaz; S06.3d'nin gerçek native depolama kabulünü açık bırakır. Korunan logun SHA-256 özeti `b72781d47c47d8d7c8926cdf91063b3412da353da04571353c1a445ef8514467` olup, bir sonraki koşuda kapalı phase/hata kodu üretecek dar tanılama düzeltmesi hazırlanıyor.

## Kanıt sınırı

Makine okunur teslim makbuzu `/private/tmp/larenor-5cbff21-delivery-evidence.json`, SHA-256 `27f061a1bda5dcd7a8d6ffa3cde68c6509cbdbf7a9fa35bbab4f884676a91ba6`. Ham Android, Server ve Security logları ile E2E/JUnit artifact özetleri makbuzda kayıtlıdır. Fiziksel Huawei tablet, Samsung DeX, TalkBack ve gerçek ev cihazı kabulü bu yazılım teslimine dahil değildir.
