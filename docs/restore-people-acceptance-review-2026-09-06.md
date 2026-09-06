# S08.5 / S08.6 — kabul ölçütlerinin kaynak incelemesi

İncelenen yayın kaynağı `e7c15ad6f62352f77379e369f3e8524028c42aab`.
Sonuç: **yerel yazılım kapsamı karşılanıyor; CI106 ve bağımsız imzalı APK
doğrulaması tamamlanana kadar kapanış koşullu.** Bu kayıt yeni test koşusu,
fiziksel cihaz kabulü veya bütün S08'in bittiği anlamına gelmez.

## S08.5: geri yükleme, çıkış ve hedef sahipliği

| Kabul ölçütü | Üretim yolu ve sınır | İncelenen karşılık |
| --- | --- | --- |
| Eski evdeki önizleme yeni evde uygulanamaz | `CapturedRestoreAccess` canlı kaynak, runtime epoch, Core/ev/kullanıcı, PIN ve kalıcı oturum özeti yakalar. `PreparedBackupRestore` hedef okuma kümesini tekrar doğrular; başka owner eski onayı devralamaz. | `prepared_restore_test.dart`, `prepared_restore_platform_test.dart`, `prepared_restore_recovery_binding_test.dart`; değişen kaynak/hedef ve doğru Core'da yalnız cihaz ayarının korunumu |
| Bilinçli provider kapanışı onaylı işi bozmamalı | `ConfigurationScope.restorePrepared` yazı kuyruğunda son canlı denetimi yapıp sahipliği devralır. Sonraki adımlar canlı UI providerı yerine kalıcı kimliği ve scope sahibini doğrular. | `prepared_configuration_scope_test.dart`; olumlu devir, yaşam döngüsü/odak ve eski sınır |
| Journal ve kurtarma başka yazıyı ezemez | `backup_restore_transaction.dart` özel v2 kayda kaynak/hedef özeti, intent, owner, before/after ve applying/committed aşaması yazar; kalıcı kaydı geri okur. Üçüncü değer veya yabancı journal korunur. Eski v1 için after/owner uydurulmaz. | `prepared_restore_journal_test.dart:100`, `prepared_restore_races_test.dart`, `prepared_restore_recovery_binding_test.dart`; üçüncü değer, kesilme, eski session ve belirsiz sonuç |
| Dosya ve Server kasası aynı korumaları kullanır | Gerçek `BackupScreen` ve `ServerVaultScreen` prepared işlem yoluna bağlıdır. Vault revision, hedef değişikliği, PIN ve tutulmuş callback ayrıca sınanır. | `prepared_backup_screen_test.dart`, `server_vault_prepared_screen_test.dart:407`; iki gerçek ekranın ayrı RED→GREEN kanıtı |
| Core düzeni açık ve aynı bağlamda yedeklenir | Ayrı `CoreLayoutArchiveV1`, şifreli codec ve controller yalnız pasif oda düzenini taşır. Core/ev/kullanıcı uyuşmazlığı hedef okunmadan reddedilir; hedef revision/fingerprint tekrar okunur, tek kullanımlık onay 5 dakika geçerlidir. | `core_layout_archive_controller_test.dart:169`, codec/scope/outcome/UI testleri; değişen hedef, yanlış parola, iptal, readback ve belirsiz ACK |
| Logout eski oturumu geri açmaz | Secure session store kalıcı logout niyetini kullanır; scope hemen kapanır, hata yeni ekranda görünür. Yeni login eski silme/401 sonucundan korunur. | `server_logout_store_test.dart:143`, `core_logout_runtime_test.dart`; gerçek store ve yeniden açılan UI |

Arşiv auth tokenını, Core kimliğini veya Direct HA eşlemesini geri yüklemez.
Zengin mevcut düzen oda arşiviyle sessizce azaltılmaz. Kalıcı depoya tüm
yazma/silme ve uzak revoke birlikte başarısızsa süreçler arası garanti
kurulamaz; uygulama bunu başarı göstermeden recovery hatasını korur.

`ConfigurationWrites` aynı süreç içindeki yazıları sıralar; kalıcı yeniden
okuma gözlenen değişiklikleri reddeder. Bu, çok süreçli atomik CAS, dış
yazara karşı kilit veya arada değişip eski değerine dönen kaydı (ABA)
ayırt etme garantisi değildir. [Uygulama sınırı](prepared-backup-restore-implementation-2026-09-06.md)
bu kabul özetinde de korunur. Bağımsız ikinci inceleme kapsamı CLEAR
buldu; bu sınır cümlesi onun önerisiyle eklendi.

## S08.6: kişi, oda, kaynak ve izin sözleşmesi

| Kabul ölçütü | Üretim yolu ve sınır | İncelenen karşılık |
| --- | --- | --- |
| Sürümlü sabit kimlikler | `home_resources` oda/kaynak sözleşmesi korunur; `home_people` ayrı kişi modeli/API/şifreli şema kullanır. ID Server'da üretilir; metadata ve ACL revision ayrıdır. Kişi profili login hesabı veya HA kişisi değildir. | `test_home_people_registry.py:32`, `test_home_people_contract.py:107`, `test_home_people_models.py`; eski kaynaklar/hesaplar ve restart korunumu |
| Başka kullanıcı veya ev kaydının reddi | `home_people/service.py` aynı DB transaction içinde güncel token/kullanıcı/rol/Core/ev ve ACL kontrolü yapar. Gizli kayıt ile bulunmayan kayıt aynı404; kapalı, sınırlı sayfalama yalnız görünür kayıt snapshot'ına bağlıdır. | `test_home_people_safety.py:18`, `:69`; iptal edilmiş oturum, rol/parola değişimi, yabancı scope, stale cursor ve gizli kayıt testi |
| Okuma/yazma ve iptal | Üye açık grant ile okur; admin PIN ekranından metadata/ACL değiştirir. Eski metadata revision, ACL değişimini ezemez; revoke sonrasında erişim kalkar. WRITE gelecekteki yetkili kaynak işlemleri için sözleşmedir, tek başına cihaz komutu değildir. | `test_home_people_safety.py:46`, `test_home_resource_authorization.py`, kişi/kaynak grants sözleşme ve UI testleri |
| Client'ta eski ekran yetkisiz iş başlatamaz | Kişi ve kaynak controllerları Core/ev/kullanıcı, güncel session/route/PIN/odak nesline bağlıdır. Eski isteğin401 sonucu yeni hesabı kapatmaz; eski callback mutation başlatmaz. | `home_people_controller_adversarial_test.dart`, `home_people_ui_boundary_test.dart`, `home_people_ui_reparent_test.dart`, `home_resources_authority_test.dart` |

Yeni kişi sözleşmesi actual Server HTTP → ortak JSON fixture → Client decoder
ile sınanır. Sentetik Android fixture bunun yerine uydurulmuş ayrı bir wire
şeması kullanmaz. Üye, arşiv ve admin yolculuklarının eklenmesi eski10
uygulama gövdesi/99 fazı değiştirmez: yeni8+12+14 fazla toplam13 uygulama,
4 platform testi ve133 faz hedeflenir.

## Kanıtı bağlama ve açık işler

- Exact uygulama/test ağacı: yerel **5.056 tam Client PASS**, analiz0 ve
 966 dosyada biçim farkı0. Alt dilimlerin örtüşen test sayıları toplanmaz.
- Linux CI105 **3.311 Core PASS / 0 skip**, native **17 E2E / 133 faz**
 verdi; Flutter işi süre sınırında kaldığı için105 teslim kabulü değildir.
- [CI106](client-delivery-106-2026-09-06.md) kendi üç başarılı koşusu ve
 bağımsız APK kaynağı/sürümü/imzası doğrulanınca bu yazılım kabulü kapanabilir.
 Başarısız105 ve önceki dilimlerin kaynakları arşivlenerek korunmalıdır.
- OS dosya seçicisi, gerçek Keystore/process death, Huawei tablet, TalkBack
 ve DeX fiziksel kabulü `MANUAL` kapsamındadır. Sentetik yerel/Android
 dosya arşivi yolculuğu gerçek cihaz/disk kabulü değildir.
- Typed HA snapshot/cache/komut ve Direct eşleme **S08.7**; medya/müzik ve
 altyapı adaptörleri **S08.8–9**. Çoklu ev/Core federasyonu **F19**.
 Bunları S08.5/S08.6 için önkoşul yapmak mevcut bağımlılık sırasını tersine çevirir.
- B5.1 eklenti kataloğu erişilebilirlik dalı CI106'da bulunmaz; bu inceleme
 bütün ekranların son tasarım kabulü değildir. Yeni63 özellik sayacı değişmez.

Bu incelemede canlı ev/HA, Docker Engine, kurulum veya cihaz komutu çalıştırılmadı.
