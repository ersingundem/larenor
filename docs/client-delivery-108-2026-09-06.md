# Client 108 — doğrulanmış teslim

**Sonuç: `delivery_verified`, `deliveryAccepted=true`.** Üç GitHub workflow'u aynı `960691c113b10e08ebddf75d464b99e74bdd4cb1` kaynağında ve ilk denemede başarılıdır. CI 6 Eylül 2026'da tamamlandı; kesinti sonrası metadata yeniden doğrulaması ve tek APK aktarımıyla bağımsız teslim doğrulaması 8 Eylül 2026'da tamamlandı.

[Kesin kaynak](https://github.com/ersingundem/larenor/tree/960691c113b10e08ebddf75d464b99e74bdd4cb1) · [Android Build #108](https://github.com/ersingundem/larenor/actions/runs/34019042417) · [Server Container Build #34](https://github.com/ersingundem/larenor/actions/runs/34019042355) · [Security #108](https://github.com/ersingundem/larenor/actions/runs/34019042181)

| Kabul kapısı | Gerçek CI sonucu |
| --- | --- |
| Flutter | **5.150 PASS**, analiz 0 sorun; 971 dosyada biçim farkı 0 |
| Linux Server | **3.447 PASS**, hata/atlama 0; 532,09 saniye |
| Android iş akışındaki Server doğrulaması | Aynı 3.447 test PASS; 685,63 saniye. Ayrı test toplamı olarak eklenmedi. |
| JVM / Robolectric | **98 PASS**, hata/atlama 0 |
| Güvenlik politikası | **207 PASS**, 24,684 saniye; gitleaks temiz, bağımlılık taraması başarılı |
| Gerçek Android E2E | **4 platform + 13 uygulama yolculuğu = 17 PASS**, **133 sıralı faz** |
| İmzalı APK | Derleme, CI doğrulaması ve bağımsız yerel doğrulama başarılı |
| Core imajı | amd64 ve arm64 derlemeleri, iki mimaride HTTP/kalıcılık/APK ve medya hazırlama smoke kontrolleri başarılı |

Flutter test adımı 928 saniye, bütün analiz/test işi 1.057 saniye sürdü; iş bütçesi 1.500 saniyedir. Bu sayılar yerel testlerden türetilmedi; kaynak bağlı CI logları ve gerçek JUnit dosyaları kullanıldı.

## Android yolculukları ve arşiv düzeltmesi

Emülatör **36.1.9.0**, derleme **13823996**, API 35 / default x86_64 / Pixel 4 profilidir. `run_android_e2e.sh` komut başlangıcı **07:32:46.6013912 UTC**, bütün 17 testin başarı satırı **07:42:29.9881264 UTC**: **583,386735 saniye**, 1.080 saniyelik dış sınır içinde. Hazırlık ve kapanışı kapsayan emülatör adımı **07:31:32–07:42:30 UTC**, toplam **658 saniye** sürdü; emülatör kapatma komutu ve başarılı kapanış kaydedildi.

**Arşiv iptal geçişi düzeltmesi, 133 faz korunarak gerçek Android E2E koşusunda geçti.** `core_archive.confirm_cancelled` 07:41:30.6939986 UTC, `scoped_restore_verified` 07:41:36.8719426 UTC ve `reopened_readback` 07:41:43.3061542 UTC fazları başarılıdır. People geri dönüşünün `core_people.return_no_read` fazı da 07:40:19.7316817 UTC'de geçti. Kesin kaynaktan registrar çağrı sırasıyla türetilen manifest, iş logu ve indirilen E2E logundaki **133 fazın tamamı** ile eşleşti.

Yolculuklar sentetik loopback servisleri kullanır. Yeniden açılma kanıtı aynı süreçte uygulama yeniden bağlamadır; fiziksel süreç/disk yeniden başlatması veya ev cihazı kabulü olarak sunulmaz. Önceki 105/106 sonuçları bu sürüme taşınmadı.

## Tek APK aktarımı ve bağımsız doğrulama

Üç workflow SUCCESS görüldükten sonra [imzalı APK108 artifact'i](https://github.com/ersingundem/larenor/actions/runs/34019042417/artifacts/9985241056) **bir kez** aktarıldı. Aktarım niyeti indirmeden önce kalıcı makbuza yazıldı. Artifact ID **9985241056**; ZIP boyutu **56.920.685 bayt**, APK boyutu **121.634.345 bayt**. ZIP özeti GitHub artifact özetiyle eşleşti.

Doğrulanmış APK (`/private/tmp/larenor-960691c-delivery-wgmmgqvu/app-signed-release-apk-108/app-release.apk`) · Bağımsız doğrulama JSON'u (`/private/tmp/larenor-960691c-delivery-wgmmgqvu/app-signed-release-apk-108/verification.json`)

| Alan | Bağımsız sonuç |
| --- | --- |
| Paket | `com.ersingundem.larenor` |
| Sürüm | `1.0.0` / `100000108` |
| Minimum SDK | `26` |
| Debuggable | `false` |
| Kaynak metadata | `960691c113b10e08ebddf75d464b99e74bdd4cb1` / workflow `34019042417` |
| APK SHA-256 | `109f2ebfb0ec69283c2e53ab49fb21ec0352353e8eec5e44d9ca41254a0b6fb5` |
| İmzalayan sertifika SHA-256 | `d7c8be0fd89daa2d60aa97a249aa1e3615aed92fcb7e4135bbbd7456eb5882a0` |

Doğrulama **Java 17**, SHA-256 ile sabitlenmiş **apksig 9.1.0** ve aynı Git kaynağındaki `VerifyApk.java` ile yapıldı. APK içindeki paket/sürüm/minSdk/debug/imza bilgileri ve yanındaki kaynak metadata'sı ayrı ayrı karşılaştırıldı. Kaynak commit'i APK içinden kriptografik olarak çıkarılmış bir bilgi değildir; kesin workflow, artifact metadata ve doğrulanan APK özetiyle bağlanmıştır.

## Anonim kaynak, lisans ve iki mimarili OCI

Anonim kaynak/lisans kontrolü 6 Eylül 2026 **07:26:48 UTC**, OCI metadata kontrolü **07:36:58 UTC** zamanında tamamlandı. Depo anonim erişime açık; kesin kaynak lisansı **AGPL-3.0-only** ile eşleşti. `ghcr.io/ersingundem/larenor-server:sha-960691c113b10e08ebddf75d464b99e74bdd4cb1` ve o anda `stable` aynı index'i gösterdi:

`sha256:5e60fd827fe7549192a35924da6b0e5c6d53743398c0f17aa5c5ecaeafa8ffc5`

| Platform | Değişmez manifest |
| --- | --- |
| linux/amd64 | `sha256:087e44b0a80dcd83661b66c3f9cd6f5d0e6d80bf903a5e221f1e45d128671715` |
| linux/arm64 | `sha256:ad00c72751ce4424e24626b272dda60879211f60fabd683c767c405d1ca4a649` |

İki mimarinin manifest ve config özetleri, kaynak revision/source URL ve AGPL lisans metadata'sı doğrulandı. İmaj katmanı indirilmedi. `stable` eşleşmesi belirtilen gözlem zamanına aittir.

## Kanıt ve kapanış

Son makbuz (`/private/tmp/larenor-960691c-delivery-evidence.json`) — SHA-256: `bd20ff6870e8dcdd1d40ad457e7185011df8caa0aa451498c30414e2c6191fba`.

Kaynak manifesti: source-manifest.json (`/private/tmp/larenor-960691c-delivery-wgmmgqvu/source-manifest.json`). E2E: iş logu (`/private/tmp/larenor-960691c-e2e.log`) ve artifact logu (`/private/tmp/larenor-960691c-delivery-wgmmgqvu/android-e2e-api35/android-e2e.log`). Diğer ham loglar/JUnit/OCI config ve APK doğrulama dosyaları makbuzda tam yolları ve özetleriyle bağlıdır. Root'un S08.5/S08.6 kaynak incelemesi (`/private/tmp/larenor-960691c-restore-people-review.json`) ayrı kaynak inceleme kanıtıdır.

Kesintiden kalan PID 68996 ve PTY 46908 artık mevcut değildi; watcher logu `ALL_RUNS_COMPLETE` ile bitmişti. Yeni watcher başlatılmadı. Tek APK aktarımı ve son doğrulama süreçleri tamamlandı; gözlemci kilidi serbest, aktif helper yok. Önceki 104 teslim, 105 başarısızlık/ayrı E2E hasadı ve 106 başarısızlık makbuzlarının dört SHA-256 özeti değişmedi.

Ev Server'ına yayınlama CI adımı **skipped**. Cihaz kurulumu, ev yayını, gerçek ev/HA/oynatma işlemi, workflow rerun veya push yapılmadı. Fiziksel cihaz kabulü bu teslim kanıtının kapsamında değildir.
