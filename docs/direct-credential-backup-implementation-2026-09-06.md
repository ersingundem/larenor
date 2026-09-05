# Direct servis bağlantıları ve yedek sınırı

Bu S08.4 alt dilimi, yarım kaydedilen servis bağlantılarının yeni bir yedeğe veya
ilgili bağlantının import/restore işlemine taşınmasını engeller. Dört Arr store
(Sonarr, Radarr, Lidarr, Readarr) gerçek ortak credential sözleşmesini tüketir;
backup tarafı HA ile public enum'daki 11 servisin markerını tanır. Bu, kalan yedi
servisin kendi credential yazıcılarının bu pakette taşındığı anlamına gelmez.

## Kaynak ve sahiplik

- İzole dal: `codex/direct-credential-backup`.
- Çalışma ağacı: `/private/tmp/larenor-direct-credential-backup`.
- Gerçek başlangıç/bağımlılık: `0abf0f40c3de5e2d99de9d5517665f5447d9e2a4`
  (`fix: guard Arr credential records with private pending markers`). Git commit
  zamanı: **2026-09-06 01:37:24 +03:00**. Bu tarih bir yayın/merge tarihi değildir.
  Bağımlılık ortak Git geçmişinde korunur; marker anahtarlarının yerel kopyası
  veya varsayılan sabit listesi oluşturulmadı.
- RED: `e6e5fdbbcba0fdb60228b0468d4fe9d122b056fc`.
- Minimal GREEN: `404aa8c406a77ff96d9e0b2d25016a84d8abec9c`.
- Değişen üretim: `BackupRepository`, `BackupScreen` içindeki export/preview hata
  eşlemesi ve `backupConnectionPending` EN/TR anahtarı.
- Credential helper/stores/providers, auth, ConfigurationScope, backup şeması ve
  allowlist'ler değişmedi. Eski HA uygulama belgesi tarihsel kanıt olarak kaldı.

## Uygulanan davranış

Connections seçili capture, desteklenen tüm bağlantıları okuyacağı için HA'nın
`CredentialsStore.pendingMutationKey` anahtarını ve `DirectCredentialService`
enum'undaki 11 `pendingMutationKey` değerini ilk okumadan önce ve snapshot
üretilmeden önce kontrol eder. Eksik marker tek temiz durumdur. Boş/tanınmayan
metin dahil herhangi bir non-null değer, yanlış platform tipi veya okuma hatası
bağlantının tamamlandığına kanıt sayılamaz; işlem sabit hatayla durur.

Preview yalnız snapshot'ın Connections grubundaki servisleri kontrol eder.
Restore aynı grubun servislerini yalnız `selection.connections` seçiliyse
kontrol eder. İlgili servis için `keepExisting` de bu denetimi atlayamaz: mevcut
kaydın varlığını kontrol etmeden önce bütünlüğü doğrulanır. Settings/dashboard
snapshot'ları ve `connections=false` restore marker okumaz.

Bu kapsam önceki HA dilimine göre bilinçli daraltıldı: HA pending iken yalnız
Sonarr içeren bir importun preview/restore işlemi artık engellenmez. Aynı şekilde
Sonarr pending iken yalnız Radarr importu çalışır. Tüm bağlantıları capture etmek
ise bu pending kayıtlardan biri varken yine engellenir. Eski HA+Sonarr negatif
testi bu yeni sözleşmeye göre pozitif izolasyon testine çevrildi; HA içeren tüm
negatif senaryolar ve HA'nın hata kodu/metni korundu.

HA için `ha_connection_pending` aynen kalır. Diğer servisler için
`connection_pending` döner; adres, API key, marker değeri veya platform hata
ayrıntısı eklenmez. Export/preview ekranındaki EN/TR mesajı kullanıcıyı servis
ayarlarında yarım kalan bağlantıyı yeniden tamamlamaya yönlendirir.

## Journal ve kurtarma

Bütün kontroller mevcut `ConfigurationWrites` sırası içindedir. Restore ilgili
markerları hazırlık öncesinde, journal yazılmadan önce, durable journal sonrasında
ve commit öncesinde denetler. Geç marker görülürse mevcut bounded rollback çalışır.
Tam rollback sonrasında pending hata korunur; rollback tamamlanamazsa mevcut
`BackupRestoreException` ve private restore journal sonraki kurtarma için kalır.

Markerlar hiçbir zaman export payload'ına veya restore journal'ın izinli mutable
hedeflerine eklenmez. Backup hiçbir markerı yazmaz/silmez. Önceden oluşturulmuş
private journal recovery markerları okumadan bitmelidir; testler marker okumaları
hata veriyorken bunu doğrular. Bağlantının yeniden kullanılabilmesi için ilgili
credential store üzerinden açık, tam save veya clear gerekir. Restore bir
credential tamamlama veya otomatik onarım yolu değildir.

## Yerel doğrulama

Bütün Flutter/Dart komutları
`python3 /private/tmp/larenor-flutter-check.py <komut>` ile ortak kilitte çalıştı.
İzole ağaç `flutter pub get --offline`, `flutter gen-l10n` ve mevcut
`dart run build_runner build` ile hazırlandı; generated dosyalar commit edilmedi.

| Kontrol | Sonuç |
| --- | --- |
| Yeni boundary + eski HA boundary + BackupScreen runtime RED | **100 başarısız, 51 geçti**; üretim değiştirilmeden eksik marker koruması ve yeni ilgili-servis davranışı görüldü. |
| Aynı üç dosya minimal GREEN | **151 geçti**. |
| Tüm `test/features/backup` + `direct_arr_credentials_test.dart`, `direct_home_boundary_test.dart`, `configuration_scope_test.dart`, coverage | **245 geçti**, yaklaşık 10 saniye. |
| `home_source_store_test.dart` + `ha_credentials_recovery_boundary_test.dart` | **34 geçti**. |
| Son yeni `backup_direct_boundary_test.dart`, machine reporter | **107 geçti**, atlama/hata yok. Bu 107, yukarıdaki 151 ve 245 içinde zaten vardır. |
| Beş sahipli Dart dosyasında `flutter analyze` | **0 sorun**. |
| Beş sahipli Dart dosyasında son format kontrolü | **0 değişiklik**. |

Dart LCOV satır kapsamı: **BackupRepository 233/237 (%98,31)** ve
**BackupScreen 387/410 (%94,39)**. Yeni marker koruması, statik hata ve ekran
mapping satırları çalıştı. Bu branch veya fiziksel cihaz kapsamı ölçümü değildir.

Anlamlı regresyonlar:

- Dört gerçek ArrCredentialsStore ve pinned secure-storage MethodChannel seam'i:
  URL yazılır, cevap hata verir, eski API key kalır; marker nedeniyle gerçek
  capture/preview/restore durur. Açık save veya clear sonrası capture ve restore
  tekrar çalışır; backup markerı kurtarma adına temizlemez.
- Her public servis için non-null/bozuk/read-error marker reddi; Sonarr için
  gerçek plugin seam'inden yanlış primitive tipinin güvenli reddi.
- İlgisiz Sonarr/HA markerı Radarr importuna taşmaz; settings/dashboard yolu
  marker okumaz. ConfigurationWrites bekleyen credential yazısını öne alır.
- İlk/son okuma, pre-journal, journal sonrası, alan yazısı ve pre-commit
  aşamalarında geç marker: çıktı yok veya bounded rollback; başarısız rollback
  sonrası ayrı recovery, markerı koruyarak eski alanları geri getirir.
- Marker içeren sahte rollback hedefi ve backup alanı reddedilir; kalıcı
  journal snapshot'larında marker mutable hedef değildir.
- Gerçek BackupScreen export/preview: EN/TR, 600/1200 genişlik, 2x metin; rehber
  görünür, dosya export edilmez, marker yazılmaz, özel değer ekrana çıkmaz.
- Eski HA pending, başarısız rollback, PIN/idle/background, geç decrypt ve
  configuration-provider lifecycle testleri geçer.

Loglar `/private/tmp/larenor-direct-backup-` önekiyle: `red.log`, `green.log`,
`regression.log`, `ha-compat.log`, `boundary-final.jsonl`, `analyze.log`,
`format-final.log`, `coverage.info`. Setup logları aynı önekte tutuldu.

## Sınırlar

Bu paket sentetik depolama/platform cevaplarıyla yerel doğrulandı; canlı HA/LAN,
Docker, native Keystore veya fiziksel Android üzerinde işlem yapılmadı. Yeni
CI/APK/push, tüm S08.4 kabulü veya bütün servislerin credential geçişi iddiası yok.

Preview sonrası marker oluşup restore ConfigurationScope'a devredilirse
repository yine durur; mevcut scope sabit genel restore hatasını gösterir.
Scope el değiştirme ve provider ömrünü sonlandırma davranışı ve typed restore outcome
arayüzü değiştirilmedi. ConfigurationWrites aynı süreçteki iş sırasıdır; başka
süreçler için işletim sistemi depolama transaction'ı değildir.
