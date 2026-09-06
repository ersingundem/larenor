# Core oda düzeni arşivi — ilk kapalı model sözleşmesi

6 Eylül 2026. Bu dilim [S08.5 planının](client-restore-logout-implementation-plan-2026-09-06.md)
5. adımı için yalnız saf model ve testleri sağlar. Taban `07a1ab4`;
`CoreLayoutArchiveV1` henüz hiçbir ekran, dosya seçici, şifreleme, kalıcı kayıt
veya geri yükleme akışına bağlı değildir. S08.5 veya Core arşivi kabulü sayılmaz.

Kaynak: [core_layout_archive.dart](../lib/features/home_scope/domain/core_layout_archive.dart).
Test: [core_layout_archive_test.dart](../test/features/home_scope/core_layout_archive_test.dart).
Eski `BackupCodec` v1/v2 biçimleri, private journal v2, `ConfigurationScope`
ve `DashboardRepository` bu dilimde değiştirilmedi.

## Kapalı içerik

JSON yalnız `kind`, `version`, `capturedAt`, `scopeDigest`, `sourceRevision`
ve `rooms` alanlarını kabul eder. `kind` tam `core-room-layout`, `version`
tam tamsayı `1` olur. Her oda yalnız `{id,name}` içerir; liste sırası oda
sırasıdır. Boş liste geçerlidir, üst sınır 500 odadır. Kimlikler benzersizdir.
Oda kimliği/adı mevcut yerleşim doğrulayıcısıyla aynı sınırdadır: boş olmayan,
ASCII kontrol karakteri içermeyen en fazla 256 Dart UTF-16 birimi. Bu, 256
Unicode karakteri iddiası değildir; örneğin 128 ev emojisi sınır içindedir.
Boşluk kırpılmaz, ad veya kimlik yeniden üretilmez. Girdi ve dışarı verilen
JSON değişse bile model değişmez; oda listesi değiştirilemez.

`scopeDigest`, UTF-8 JSON dizisi
`["larenor-core-layout-archive-scope-v1",coreId,homeId,userId]` için SHA-256
küçük harf hex özetidir. Ham kimlikler arşive yazılmaz. Bu özet eşleşme
bilgisidir; gizlilik anonimleştirmesi, oturum doğrulaması veya yetki değildir.
`matchesScope` yalnız aynı Core/ev/kullanıcı üçlüsünü karşılaştırır.

`sourceRevision` 0..9223372036854775806 aralığında tamsayıdır ve yalnız
kaynak bilgisidir. Dosyadan alınan revizyon hedef revizyonuna dönüştürülmez.
`capturedAt` tam UTC milisaniye biçimindedir (`YYYY-MM-DDTHH:mm:ss.sssZ`).
Gelecekte capture katmanı saati açıkça UTC milisaniyeye dönüştürmelidir:
mikrosaniye içeren `DateTime.now().toUtc()` doğrudan kabul edilmez. Bu bilgi
zamanı, canlı yetki/TTL kontrolü veya geri yükleme işlem kimliği olmayacaktır.

`fromScopedLayout` ham yerleşimi önce mevcut `validateDashboardLayoutJson`
ile doğrular. Sonra yalnız pasif oda profilini kabul eder. Bilinen boş
varsayılanlar kabul edilir; dolu entity listesi, tile, favori/gizli entity,
kart boyutu, HA area binding veya web panel URL/ayarları açıkça
`unsupported_layout` verir. Bilinmeyen üst veya iç alanlar da reddedilir.
Önce genel modelden decode edip bilinmeyen alanları kaybetme ya da sessiz
filtreleme yapılmaz. Geçerli pasif schemaVersion 1/2 kaynaklarından açık
dönüşüm mümkündür; bu, legacy BackupSnapshot içe aktarma yolu değildir.
Factory parametresi olan scope tek başına ham yerleşimin sahipliğini kanıtlamaz.

`decode` verilen JSON metninin UTF-8 boyutunu parse öncesinde, `encode`
üretilen metni döndürmeden önce 2 MiB ile sınırlar. Bu bir dosya okuyucusu
veya akış bellek sınırı değildir. 3 MiB şifreli dosya sınırı sonraki codec
için öneridir; bu modelde şifreli dosya veya codec uygulanmadı. Hatalar
yalnız `invalid_archive`, `unsupported_layout`, `archive_too_large` statik
kodlarını taşır; kaynak değerler exception metnine eklenmez.

## Test ve kontrol noktaları

- RED `8414d9c`: derlenen, reddeden stub üzerinde **84 PASS / 14 FAIL**.
  Geçerli arşivin oluşturulamaması gerçek runtime RED oldu.
- GREEN `3865a07`: aynı dosyada **98 PASS**; sonra yalnız biçim düzenlendi.
- Birleşik **149 PASS**, 1 saniye: 98 yeni test ile mevcut scope, legacy ve
  scoped dashboard repository/storage, legacy layout controller testleri.
  Bu sayılar birbirine eklenmez.
- Yeni modül LCOV satır kapsaması **94/95 = %98,95**; dal kapsaması ölçülmedi.
  İki dosyada analiz temiz; son format kontrolünde değişiklik yok.
- Root bağımsız `3865a07` kaynak incelemesinde yeni P1/P2 bulmadı.

Çalıştırılan SDK komutları ortak `python3 /private/tmp/larenor-flutter-check.py`
kilidi üzerinden geçti. Hazırlık offline pub get, build_runner ve gen-l10n;
odak komutu `flutter test --no-pub test/features/home_scope/core_layout_archive_test.dart --reporter expanded`.
Coverage koşusu aynı komuta `--coverage` ve `test/core/home_data_scope_test.dart`,
`test/features/dashboard/dashboard_repository_test.dart`,
`test/features/dashboard/scoped_dashboard_repository_test.dart`,
`test/features/dashboard/scoped_dashboard_storage_boundary_test.dart`,
`test/features/home_scope/legacy_layout_controller_test.dart` ekledi.
Özel kanıt dosyaları `/private/tmp/larenor-core-archive-{red,green,related,analyze,format-check}.log`.
Gerçek cihaz, ağ, Core veya Android yolculuğu çalıştırılmadı.

## Sonraki ayrı tasarım kararı

1. Ayrı kapalı şifreli dosya codec'i ve sınırlı dosya okuyucusu; legacy
   vault biçimini genişletmeden karşılıklı yanlış-format reddi.
2. Geçerli Core erişimiyle alınan target revision + ham kayıt fingerprint,
   dosya özeti ve aynı Core/ev/kullanıcıya bağlı tek kullanımlık hazırlık.
   Yeni hedef revizyonu mevcut hedef +1 olmalı; arşiv revizyonu yüklenmemeli.
3. Ortak typed handoff ve durable scoped-record adapter sözleşmesi root ile
   ayrıca belirlenmeli. Mevcut repository yazısı sonrası gerçek readback ve
   ayrı Core journal/recovery ailesi gerekir; eski journal'a key eklenmez.
   Aynı süreç kuyruğu çapraz süreç CAS veya ABA güvencesi değildir.
4. PIN korumalı kaynak ayarlarından gerçek capture/preview/confirmation
   akışı; kaynak, hesap, route, pencere ve hedef değişiminde eski onay kapanır.
   EN/TR 2× metin, 320/600/1280 genişlik, 48 px hedefler, klavye ve ekran
   okuyucu ile actual widget/Android kabulü ayrı teslimdir.

Yerel Core oda kimliği Server room/resource veya ACL kimliği değildir.
Bu dilim kaynaklararası eşleme, cihaz komutu, credential, session, auth/PIN,
kişisel sağlık/fotoğraf veya Server metadata/grant arşivi tanımlamaz.
