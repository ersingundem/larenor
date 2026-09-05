# HA bağlantı belirsizliği ve yedek sınırı

Bu dilim, Home Assistant adresi ve tokenı yarım kaydedildiğinde oluşabilecek
çiftin yeni bir yedeğe veya geri yükleme hazırlığına girmesini engeller.
HA bağlantısını kendiliğinden düzeltmez.

## Kaynak ve sahiplik

- İzole çalışma ağacı: `/private/tmp/larenor-ha-backup-boundary`.
- Dal: `codex/ha-backup-boundary`; başlangıç: `3018c57`.
- Bağımlılık: CredentialsStore'un gerçek public
  `pendingMutationKey = 'ha_connection_pending_v1'` sözleşmesini içeren
  `2bff8e1`, ortak geçmiş korunarak bu dala birleştirildi. Yerel kopya sabit yok.
- RED: `ce934c2`; minimal GREEN: `3f8768e`; son kaynak/test: `a9c5576`.
- Değişen üretim: `backup_repository.dart`, BackupScreen'in yalnız sabit hata
  eşlemesi ve bir EN/TR yerelleştirme anahtarı.
- ConfigurationScope, journal şeması, credentials/source/account yetkileri ve
  yedek allowlist'leri bu dilimde değiştirilmedi.

## Davranış

Connections seçili yeni capture/restore ve Connections grubu içeren normal
preview, HA işareti varsa `ha_connection_pending` sabit hatasıyla durur.
İşaretin boş veya tanınmayan metin olması, yanlış platform tipi ya da okuma
hatası da aynı güvenli sonucu üretir. Hata ayrıntıları ve işaret değeri kullanıcıya
aktarılmaz. Export/preview ekranı EN/TR olarak önce Home Assistant bağlantısını
yeniden kurmayı söyler.

Kontroller `ConfigurationWrites` sırası içinde, okumalardan önce ve sonuç
yayımlanmadan/journal oluşturulmadan önce yapılır. Restore ayrıca journal
yazıldıktan sonra ve commit öncesinde kontrol eder. Sonradan işaret görülürse
mevcut bounded rollback çalışır; tamamlanamayan rollback journal'ı korunur.

İşaret yedek verisi veya izinli journal hedefi değildir. Restore hiçbir zaman
onu temizlemez. Daha önce oluşturulmuş private restore journal'ının kurtarılması
HA işaretini okumadan/silmeden tamamlanabilir; böylece açılış kurtarması
kilitlenmez. HA çiftinin yeniden kullanılabilmesi için CredentialsStore üzerinden
açık tam save veya clear gerekir.

Yalnız settings/dashboard capture ve snapshot preview ile `connections=false`
restore bu işaret nedeniyle engellenmez. Karma dosyanın mevcut normal preview'si
tüm grupları inceler: bağlantı düzeltilmeden bu önizleme açılmaz. Bu dilim yeni
bir grup seçimi akışı eklemez.

## Yerel kanıt

Tüm Flutter/Dart komutları ortak kilit üzerinden çalıştırıldı:
`python3 /private/tmp/larenor-flutter-check.py <komut>`.

| Doğrulama | Sonuç |
| --- | --- |
| `flutter test test/features/backup/backup_ha_boundary_test.dart test/features/backup/backup_screen_test.dart` — ilk RED | 14 geçti, 23 başarısız. 22 hata eksik davranışı gösterdi; bir platform testi suite'in bellek backend'ini kullanıyordu ve GREEN aşamasında gerçek MethodChannel seam'ine düzeltildi. Bu ilk platform sonucu tip reddi kanıtı sayılmaz. |
| Aynı iki dosya — minimal GREEN | 37 geçti |
| Backup testlerinin tamamı + ConfigurationScope, HomeSourceStore, DirectHomeBoundary ve HA credentials recovery testleri | 143 geçti |
| Son iki dosya, gerçek store kurtarma testleri dahil | 40 geçti |
| Dört sahipli Dart dosyasında `flutter analyze` | Sorun yok |
| Aynı dört dosyada `dart format` son kontrol | 0 değişiklik |

Kapsam komutu:

```text
flutter test --coverage --coverage-path=/private/tmp/larenor-ha-backup-coverage.info test/features/backup test/core/configuration_scope_test.dart test/core/home_source_store_test.dart test/core/direct_home_boundary_test.dart test/features/auth/ha_credentials_recovery_boundary_test.dart
```

Repository satır kapsamı **223/227 (%98,2)**; BackupScreen **385/408 (%94,4)**.
Bu Dart LCOV satır ölçümüdür; branch veya fiziksel cihaz kapsamı iddiası değildir.

Anlamlı kabul senaryoları:

- Gerçek CredentialsStore ve pinned plugin MethodChannel seam'i ile adres yazısı
  tamamlanıp token yazılamaz; capture/preview/restore çift alanlarını okumadan
  durur. Açık save veya clear sonrası capture tekrar çalışır.
- İlk/son okuma arasında, journal hazırlanırken veya commit öncesinde ortaya
  çıkan işaret sonuç yayımlanmasını engeller; yeni HA çiftini onaylamaz.
- Başarısız rollback iki kurtarma kaydını korur; sonraki private journal recovery
  eski değerleri getirir ve HA işaretini bırakır.
- İşaret yanlış primitive tipindeyken, platform hata metni özel değer taşırken
  veya yazma sırası henüz tamamlanmamışken yalnız sabit hata döner.
- Gerçek BackupScreen export/preview yollarında EN/TR, 600/1200 tablet penceresi,
  2x metinde yönlendirme tek kez görünür; dosya export edilmez, HA yazısı yoktur.
- Mevcut PIN, idle/background, geç decrypt ve file-dialog testleri geçer.

Loglar: `/private/tmp/larenor-ha-backup-red.log`,
`/private/tmp/larenor-ha-backup-green.log`,
`/private/tmp/larenor-ha-backup-regression.log`,
`/private/tmp/larenor-ha-backup-final.log`,
`/private/tmp/larenor-ha-backup-analyze.log`.

## Kanıt sınırı

Bu yerel testler sentetik depolama/platform cevaplarını kullanır; canlı HA,
Android cihazı veya native Keystore üzerinde işlem yapılmadı. Yeni CI, APK,
push ya da release kabulü bu belgeye dahil değildir.

Preview sonrasında işaret oluşup restore ConfigurationScope'a devredilmişse
repository yine statik hatayla durur; mevcut scope genel güvenli restore hatasını
gösterir. Typed restore outcome arayüzü bu dilimin dışında kalır. Aynı süreçteki
ConfigurationWrites sırası bir işletim sistemi depolama izolasyonu veya başka
süreçlere karşı transaction iddiası değildir.
