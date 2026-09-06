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
yalnız bu bekleme onarımını14 E2E/99faz ve bağımsız APK104 ile doğruladı
([teslim](client-delivery-104-2026-09-06.md)). 64bdf58 yeni destek testi ve E2E çağrısı
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

## Yeni HTTP sözleşmesi dahil tam Server koşusu

`eb7a473` Server/contract ağacında **3.300 PASS /0 FAIL /11 Linux skip**,
JUnit3311test/0error/439,183sn elde edildi. Daha önceki3.298 tam koşuya
sonradan eklenen2 gerçek kişi HTTP sözleşme testi bu kez tam koşunun içindedir.
İlk3.291 PASS/5 FAIL ve tarihsel fixture onarımı yukarıda korunur.
Sonraki kişi UI/Android belge birleşimlerinde Server ve contracts Git tree
kimliklerinin aynı kaldığı doğrulandı.

Log/XML `/private/tmp/larenor-archive-people-expanded-full-server.{log,xml}`;
makbuz `/private/tmp/larenor-archive-people-expanded-full-server-evidence.json`.
Doğru `server/` dizininden import yolu önceden doğrulandı; Java17 ve sabit
apksig ile gerçek APK doğrulama testleri de çalıştı. Linux'a özgü11skip yerelde
korunur; bu paketin kendi Linux CI ve yeni Client/Android kabulü henüz yok.

## Gerçek tablet ekranları ve Android senaryoları birleşti

`b57d534`, kişi UI`eed3916` +üye journey`754d87e` ve arşiv UI`523a07f`
+arşiv journey`56607c6` içerir. Kişi55 yeni/608 ilgili, arşiv61 yeni/410
ilgili test geçti; bu alt kümeler toplanmaz. İki UI'deki actual PIN, form,
onay, source/account/window/route sınırları ve2×tablet görselleri bağımsız
incelendi. ARB birleşiminde tüm eski anahtar/değerler korunur; people40 ve
archive25 anahtar çakışmasız birleşti. SettingsGate'in iki ayrı dalı ile
model/codec/controller/Backup/ConfigurationScope korunumu ayrıca CLEAR.

Üye ve arşiv Android senaryoları eski on gövdeyi,99fazı ve timeout/assertion'ları
byte-identical korur.8+12 yeni fazla hedef119faz/4platform+12app yolculuktur.
Arşiv dosyası yalnız ciphertext memory adapter ile seçilir; gerçek OS picker,
focus sonrası PIN reauth veya fiziksel disk kabulü değildir. Bu native
senaryolar henüz çalıştırılmadı. Kişi admin/ACL senaryosu ayrıca hazırlanıyor.

UI birleşimi `11ff916` sırasında tam analiz0 ve955dosya biçim farkı0 alındı;
sonraki native yardımcı dosyaları bu ara kontrolün dışında tutulur. Son tüm
Client koşusu ve aynı kaynakta GitHub CI/APK yayımlama kapısı sıradadır.

## Yeni ekranlarla ilk tam Client sonucu

`9c8d4ca` üzerinde **5.014 PASS /4 FAIL /5:51**. Dört hata aynı logout
recovery testinde EN/TR,600px,2× ve yerel silme/uzak logout hata durumlarıdır.
`ensureVisible` ardından çizim frame'i beklenmeden yapılan dokunma, önceki
ekran koordinatını kullanarak hedefi kaçırdı. Mevcut PIN ve kaynak koruma
beklentileri değişmeden, testin gerçek görünür hedefe dokunması ayrı dalda
sınanıyor. Diğer5.014 testin geçmesi tam koşunun geçtiği anlamına gelmez.

İlk log `/private/tmp/larenor-people-archive-ui-full-client.log`; SHA256
`274f11efdfe0de9bc733bf82950c9f917916a3057e45b7dc5cffcd9f829027f3`.
Makbuz `larenor-people-archive-ui-full-client-evidence.json` source/tree
kimliklerini, exit1 ve reaped durumunu tutar. Bu kaynak yeni kişi/arşiv UI ve
üye/arşiv Android kaynaklarını içerir; native yolculuklar bu host komutunda
çalışmaz. Admin Android fixture/journey bu koşuya henüz dahil değildir.

## Son birleşik kaynak yerelde geçti

Uygulama/test kaynağı `bd9d4256f210e0608ee40bfffd3f90df6ff11c39`:
**5.056 tam Client PASS /0 FAIL /5:19**, tam analiz **0 /3,1sn**,
biçim **966dosya /0fark /2,83sn**. İlk5.014 PASS/4FAIL logu yukarıda
korunur; dar kaydırma onarımı ve yeni admin fixture/yolculuğu bu tam koşuda
birliktedir. Süreç exit0 ile kapatıldı. Aynı Server/contracts ağaçlarının
3.300PASS/11Linuxskip tam Server makbuzuyla eşleştiği yeniden doğrulandı.

Yeni admin dalı `2c2896b` **38 yeni/151 ilgili host PASS** ve bağımsız CLEAR
ile birleşti. Üye, arşiv, admin kayıt sırası kaynak manifestinde doğrulandı:
eski10gövde/99faz byte olarak aynı;8+12+14 yeni fazla **13 app +4platform =
17 E2E /133faz hedefi**. Bu host komutu native Android senaryolarını çalıştırmaz.
Birleşik kaynak incelemesi CLEAR; varsayılan AppHarness/üye hesabı ve üretim
korumaları korunur. Sonraki adım bu paketin kendi GitHub CI ve imzalı APK'sıdır.

Loglar `/private/tmp/larenor-tablet-integration-final-{full-client,analyze,format,gitleaks}.log`;
source/tree/hash makbuzu `/private/tmp/larenor-tablet-integration-final-evidence.json`.
Gizli bilgi taraması64bdf58..bd9d425 aralığında geçti. Önceki207 politika testi
ve Android backup/CI trust statik kontrolü, değişmeyen politika kaynağına aittir;
uzak CI bunları yeniden çalıştırır. Sonraki yalnız belge commit'leri bu
yerel testin uygulama/test ağaçlarını değiştirmez. Fiziksel tablet kabulü açıktır.
