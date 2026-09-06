# CI106 kesin kaynaklı son teslim durumu

**Client teslimi onaylanmadı.** Kaynak `e7c15ad6f62352f77379e369f3e8524028c42aab` için Android E2E başarısız olduğu için imzalı APK işi atlandı. APK106 üretilmiş/doğrulanmış bir teslim olarak sunulmuyor; tam APK aktarımı **0**. Bütün gözlem ve aktarım süreçleri kapandı. Bu belge yeni CI sorgusu veya test çalıştırmadan, değişmeyen son makbuzdan üretildi.

Kaynak: [e7c15ad commit](https://github.com/ersingundem/larenor/commit/e7c15ad6f62352f77379e369f3e8524028c42aab). Üç koşunun da kaynak SHA’sı bu commit ve deneme numarası **1**.

| Koşu | Kesin sonuç ve kanıt |
| --- | --- |
| [Android106 /34016755111](https://github.com/ersingundem/larenor/actions/runs/34016755111) | **FAILURE**; E2E başarısız, imzalı APK işi **SKIPPED** |
| [Core33 /34016755141](https://github.com/ersingundem/larenor/actions/runs/34016755141) | **SUCCESS**; gerçek Linux JUnit **3311 PASS,0 hata/skip**,465,43s; iki mimari image smoke ve manifest yayını geçti |
| [Security106 /34016754957](https://github.com/ersingundem/larenor/actions/runs/34016754957) | **SUCCESS**;207 politika testi,24,764s; gitleaks temiz, bağımlılık taraması başarılı |

Android koşusundaki tam Flutter paketi **5056 PASS**, analiz **0 sorun**, biçim kontrolü **966 dosya/0 değişiklik**. Flutter işi06:32:31–06:47:02 UTC arasında **871s** sürdü;25dk iş sınırı içinde tamamlandı. Test adımı06:34:13–06:46:59 UTC arasında **766s** sürdü. Android’in ayrı Server alt işi de3311 PASS/0skip,467,58s verdi; bu aynı test kümesinin ikinci çalışmasıdır ve3311’e eklenmez. Native/JVM artifact XML’i **98 PASS,0 hata/skip** gösteriyor; aşağıdaki dört gerçek platform E2E senaryosu ile ayrı kanıttır.

## Doğrulanmış E2E hatası

[E2E işi101441748359](https://github.com/ersingundem/larenor/actions/runs/34016755111/job/101441748359), **4 platform +13 uygulama =17 senaryo** çalıştırdı. Sonuç **16 PASS/1 FAIL**: dört native platform senaryosu ve12 uygulama senaryosu geçti; oda arşivi senaryosu başarısız oldu. Beklenen133 fazın **130’u** günlükte var. İş günlüğü ve bir kez indirilen E2E artifact günlüğü aynı faz dizisini içeriyor.

Hata, [core_archive_journey.dart:259](https://github.com/ersingundem/larenor/blob/e7c15ad6f62352f77379e369f3e8524028c42aab/integration_test/support/core_archive_journey.dart#L259) içindeki `Core room archive → encrypted export → review → explicit scoped restore` testinde oluştu. `core_archive.preview_ready` sonrasında iptal düğmesine basıldıktan sonra `core-layout-archive-confirm` için hiçbir widget beklenirken bir `CupertinoDialogAction` bulundu. Sonuç bir **test assertion hatasıdır**; bu çalışmada zaman aşımı veya emulator hazırlık hatası olarak raporlanmıyor.

Eksik fazlar:

- `core_archive.confirm_cancelled`
- `core_archive.scoped_restore_verified`
- `core_archive.reopened_readback`

Eski10 senaryo, kişi listesi ve arşivden sonra çalışan kişi yönetimi senaryosu geçti. Arşiv temizliği çalıştı. İlk faz ayrışması sıfır tabanlı114. indekstedir.130 faz görülmesi, başarısız restore yolunun kabul edildiği anlamına gelmez.

E2E betiği **06:40:58.0034752–06:51:56.7481110 UTC**, **658,744636s/1080s** sınırı içinde sonuçlandı. Bütün emulator adımı **06:39:52–06:52:01 UTC**, **729s/1500s** sürdü. Gerçek emulator sürümü **36.1.9.0**, build **13823996**, API35/default/x86_64, pixel_4. Uygulama yolculukları sentetik ev verisi kullanır; app remount fiziksel süreç/disk yeniden başlatma kanıtı değildir.

## Bilinen mekanizma ve henüz doğrulanmamış açıklama

Kesin kaynakta `press(cancel)` sonrasında doğrudan `findsNothing` kontrolü var. Paylaşılan `tapVisible`, dokunmadan sonra yalnız350ms frame pump yapıyor; route kaldırılmasının tamamlanmasını ayrıca beklemiyor. Üretimde iptal düğmesi mevcut sahiplik/generation kontrollerinden sonra `Navigator.pop(false)` çağırıyor.

**Animasyon/route-disposal zamanlamasının bu hataya yol açtığı henüz kontrollü runtime RED ile kanıtlanmadı.** Bu, dar onarım adayıdır; üretim guard’ının hatalı olduğu veya iptal işleminin kesinlikle yürüdüğü varsayılmıyor. Root’un ayrı dalındaki yeniden üretim ve düzeltme bu belgeye kabul edilmiş sonuç olarak eklenmedi. Tek cancel tap, preview ve değişmeyen kayıt fingerprint beklentileri korunmalıdır.

## Core yayını ve anonim erişim

Anonim repository erişimi ve bu commit’in AGPL-3.0-only [LICENSE dosyası](https://github.com/ersingundem/larenor/blob/e7c15ad6f62352f77379e369f3e8524028c42aab/LICENSE) doğrulandı. Core image için `ghcr.io/ersingundem/larenor-server:sha-e7c15ad6f62352f77379e369f3e8524028c42aab` ile `stable`, gözlem anında aynı OCI index’ine işaret etti:

`sha256:5aad0b0f8c5837e522528cb99e3bb50b2053f906ab906a732c0d86aa26cca5de`

| Platform | Doğrulanan immutable manifest digest |
| --- | --- |
| linux/amd64 | `sha256:810df5fc96120c1cb8476e4707988d4c3dfe8b729d2396de9f34eeccc044fa94` |
| linux/arm64 | `sha256:9fe34392eca84d2ee78775307730b817580ef87a7c7208a046c1e96d377c622d` |

İki config digest’i, mimari, source revision, source/license URL ve AGPL metadata’sı makbuzda mevcut. Yalnız manifest/config verisi okundu; image katmanı indirilmedi. Bu başarılı Core yayını, başarısız Client teslim kapısını açmaz. Ev Server’ına Client yayını, cihaz kurulumu veya gerçek ev işlemi yapılmadı.

## Saklanan kanıt

- [Son makbuz](/private/tmp/larenor-e7c15ad-delivery-evidence.json) — SHA256 `78ac82abbf271cd56ebd16f91e647d6f551d1fa599c2826357af07acb24594f9`; durum `blocked_android_e2e`, `deliveryAccepted=false`.
- [E2E iş günlüğü](/private/tmp/larenor-e7c15ad-e2e.log) ve [son ayrıntılı özet](/private/tmp/larenor-e7c15ad-finalize-failure.log).
- [Flutter günlüğü](/private/tmp/larenor-e7c15ad-flutter.log), [Core JUnit özeti](/private/tmp/larenor-e7c15ad-server-junit.log), [native/JVM JUnit özeti](/private/tmp/larenor-e7c15ad-native-junit.log).
- [Security günlüğü](/private/tmp/larenor-e7c15ad-security.log), [Core build/smoke günlüğü](/private/tmp/larenor-e7c15ad-server-container.log), [anonim OCI kanıtı](/private/tmp/larenor-e7c15ad-anonymous-image.log).
- E2E artifact **9984400580** yalnız bir kez alındı. APK aktarımı0; rerun, yeni CI tetiklemesi ve ev deployment’ı0.
- [CI105 başarısızlık makbuzu](/private/tmp/larenor-38e78a3-delivery-evidence.json) ile [ayrı105 E2E harvest](/private/tmp/larenor-38e78a3-e2e-harvest.json) değiştirilmedi. Önceki kaynakların başarıları CI106’ya atfedilmedi.
