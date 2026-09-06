# Prepared restore, Core kasası ve hane profilleri birleşimi

Birleşik uygulama/test kaynağı `c0d814505227e894bb1eb9e884201517a185170c`.
Sonraki belge düzenlemeleri aynı uygulama ve test ağaçlarını korur.
Bu paket, CI103'ün `2cced39` ve CI104'ün `64bdf58` kaynaklarından ayrıdır.

| Dilim | İncelenen kaynak | Yerel kanıt |
| --- | --- | --- |
| Dosyadan prepared restore | `4667456` (üretim44c3eb6) | 376 ilgili test; transaction dalının satır kapsamı%88,91; analiz0 |
| Core kasasından prepared restore | `79f313b` | 387 ilgili test; controller/screen satır kapsamı%97,51; analiz0 |
| Erişilebilir kasa onayı | `1ab3483` (üretim01bb288) | 73 ilgili test; EN/TR,320/600/1280,2×,48px,klavye ve ekran okuyucu; analiz0 |
| Hane kişi API/SQLite | `7588ff0` (son test789026a) | 104 ilgili test; dal dahil toplam%89; bağlı schema nesnesi düzeltmesi bağımsız incelendi |

Bu sayılar örtüşen alt kümelerdir; toplam test sayısı olarak birleştirilmez.
RED/GREEN checkpoint'leri ve başlangıçtaki hatalar ilgili belgelerde korunur:
[dosya restore](prepared-backup-restore-implementation-2026-09-06.md),
[kasa](server-vault-prepared-restore-implementation-2026-09-06.md),
[hane](home-people-registry-implementation-2026-09-06.md).

## Birleşim incelemesi

İki gerçek restore ekranı ortak `PreparedBackupRestore` ve
`ConfigurationScope.restorePrepared` yolunu kullanır. Kaynak/PIN/hesap/route,
hedef okuma kümesi ve Core kasa revision'ı onayla bağlanır. Eski providerların
kapanması sonrasında typed devir sınırı işlemi yönetir. Recovery, kendi tam
journal kaydını, güncel kalıcı kaynağı/oturumu ve izinli HA tuple sırasını doğrular.

`lib` taramasında eski raw handler'ın uygulama içi tüketicisi kalmadı;
yalnız tarihsel tanımı durur. Eski uyumluluk birim testleri API'yi kullanır.
Yeni private journal v2, dışa aktarılan backup v1/v2 biçimini genişletmez.
Before-only eski journal'da farklı mevcut veri otomatik ezilmez; veri ve
journal korunarak recovery hatası görünür kalır.

Restore ve Vault üretimi root tarafından ayrı son kaynaklarda incelendi;
somut açık P1/P2 yok. Son EN/TR büyük yazı önizlemelerinde başlık, seçilen
veri sayıları, mevcut hedef ve iki eylem okunabilir. Bu dar ekran incelemesi
uygulamanın son genel tasarım ya da fiziksel tablet kabulü değildir.

## Birleşik testlerin durumu

Tüm Client testi **4.544 PASS / 6:09**; tam analiz **0 bulgu / 12,4sn**;
biçim kontrolü **912 dosya / 0 fark / 3,34sn**. Uygulama ve test kaynağı
`c0d8145` olarak aynıdır. Loglar:
`/private/tmp/larenor-prepared-vault-combined-{full-client,analyze,format}.log`.
İlk tam Server koşusu aynı Server ağacında **3.291 PASS / 5 FAIL / 11 Linux skip /
560,15sn** verdi: eski v1/v2 şemalarını kuran iki test yardımcısı, o sürümlerde
bulunmayan yeni kişi tablolarını bırakıyordu. Üretimin scope integrity denetimi
bu tutarsızlığı reddetti. Tarihsel fixture için iki yeni RED kontrolü5db91ad
ile doğrulandı; yalnız fixture düzeltmesi7819866 ile **137 ilgili PASS/33,55sn**
verdi. Eski key/vault/user/rollback beklentileri ve üretim korumaları değişmedi;
bağımsız kaynak incelemesi CLEAR. Son tam koşu **3.298 PASS / 0 FAIL /
11 Linux skip / 321,74sn** verdi. JUnit3309test/0error/0failure; skip nedenleri
Linux SO_PEERCRED/procfs/Unix davranışlarıdır. Server/test kaynağı7819866.
Log/XML: `/private/tmp/larenor-home-people-full-server-final.{log,xml}`.
İlk başarısız tam log `larenor-home-people-full-server.{log,xml}` korunur.
İlk yanlış çalışma dizininden açılan koşu modül yolu doğrulanınca durduruldu;
sonuç sayılmaz ve `larenor-home-people-full-server-wrong-cwd-aborted.log` olarak
ayrıca korunur.

Yerel207 politika testi ilk koşuda206 PASS/1 FAIL verdi. Başarısız test sentetik
ADB başlangıcında süreli önkoşuldan çıkmıştı; aynı test tek başına2,708sn'de
geçti. Kaynak/politika değiştirilmedi. İlk log ve izole tekrar ayrı tutulur;
kaynak değişmeden kontrollü tam tekrar **207 PASS/48,195sn** verdi
(`larenor-restore-integration-policy-recheck.log`). Android backup/CI trust policy statik
kontrolü geçti. Yeni commit geçmişi redakte gitleaks taramasında temiz.

## Açık kabul

Bu birleşimin kendi uzak CI/Android emülatör ve imzalı APK kabulü henüz yok.
CI103 logout yeniden kurulumundaki test beklemesinde başarısız oldu; CI104
yalnız bu bekleme onarımını doğrular. 64bdf58 yeni destek testi ve E2E çağrısı
olarak birleşime alındı; eski4.544 tam Client sonucu yeni3testi içermez. Core oda arşivi,
Sonraki yerel birleşime80996cdf arşiv modeli, dcbc29a codec, da740a4 restore
controller ve2b550c7 kişi sözleşme/model/API adaptörü eklendi. Bunların
odaklı testleri geçti; eski4.544 tam Client sonucu bu ekleri içermez. Gerçek
kişi ve arşiv ekranları ayrı sonraki dilimlerdir. Server üretim/test ağacına
yalnız2 yeni HTTP sözleşme testi eklendi; birleşimde ikisi tekrar geçti.
Bu nedenle S08.5/S08.6 ve seçilmiş63 özellik tamamlandı sayılmaz.
Gerçek evde migration, servis kurma, cihaz yükleme veya kapı/medya/ağ işlemi
yapılmadı; sentetik depolama testleri native Keystore veya süreç ölümünden
sonra fiziksel kurtarma kanıtı değildir.


## Sonraki genişletilmiş yerel birleşim

`634bc10f22241a49f776e954735746eee8a0f8b0` kişi controller/provider4184289
dilimini de içerir. Yeni58 mounted test, tüm kişi135 ve ilgili418 test geçti;
470/478 satır, analiz7/0 ve format7/0. İlk test/source incelemesi temizdir.
Bu kaynakta **4.870 tam Client PASS / 5:14**, tam analiz **0 / 3,8sn**
ve biçim **931dosya / 0fark / 2,88sn** elde edildi. Sonraki belge commit'lerinde
lib/test/integration_test/Android/pubspec ağaçlarının aynı kaldığı doğrulandı;
loglar `/private/tmp/larenor-archive-people-combined-{full-client,analyze,format}.log`.
Gerçek yeni ekranlar bu test kaynağına henüz dahil değildir.
