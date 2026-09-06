# Core bileşen tablet dilimi: birleşim doğrulaması

Bu belge yalnız `e7c15ad6f62352f77379e369f3e8524028c42aab` tabanı ile bağımsız B5.1 `7d0844286ee40ee25c5dca69afc3f2c130c0d13e` diliminin yerel birleşimini kaydeder. Önceki CI/APK kabulüne yeni kaynak eklemez.

- Dal: `codex/core-plugins-integration`
- Çalışma ağacı: `/private/tmp/larenor-core-plugins-integration`
- Test edilen merge commit: `9ca1ffed2a06f7c06533ea7c1196ac5077919055`
- Test edilen tam Git tree: `0be8971182910f70b257a9d30b167633937eeeda`
- Merge iki ebeveyni aynen korur: `e7c15ad6f62352f77379e369f3e8524028c42aab` ve `7d0844286ee40ee25c5dca69afc3f2c130c0d13e`. Squash veya amend yapılmadı; önceki RED/GREEN checkpoint'leri durur.

## Tam yerel sonuç

| Kontrol | Sonuç |
| --- | --- |
| `flutter pub get --offline` | exit 0 |
| `dart run build_runner build --delete-conflicting-outputs` | exit 0; 74 generated çıktı, 23 saniye bildirildi |
| `flutter test --reporter expanded` | **5.088 PASS, 0 FAIL**, tek tam koşu; log 5:54, wrapper wall 360,96 saniye |
| `flutter analyze` | **0 issue**, 8,3 saniye bildirildi |
| `dart format --output=none --set-exit-if-changed .` | **967 dosya, 0 değişiklik** |
| Git working tree | Kontrollerin sonunda temiz, source/tree değişmedi |

Bütün SDK komutları `python3 /private/tmp/larenor-flutter-check.py` ile ortak kilit altında yürütüldü. Önce `lib test integration_test` kapsamındaki biçim kontrolü geçti; ardından CI ile aynı depo geneli `.` komutu da geçti. Tam Client testi tekrarlanmadı. Bu birleşimde üretim veya test onarımı gerekmedi.

Koordinatör terminal oturumu `18150` ve depo geneli biçim kontrolü oturumu `72374` exit 0 ile toplandı. Her alt komutun başlaması, wall süresi, gerçek çıkış kodu ve toplanması özel execution makbuzundadır. B5 diliminin önceki **273 ilgili test / 32 tablet testi** kanıtı bu 5.088'e eklenmez; aynı testler tam koşunun içindedir.

## Kaynak korunum sınırı

Git subtree hash karşılaştırmasıyla aşağıdaki yollar hem `e7c15ad` tabanında hem test edilen birleşimde birebir aynıdır:

`server/`, `server/tests/`, `contracts/`, `android/`, `.github/`, `integration_test/`, `tool/`.

Kök `test/` ağacının tamamı aynı değildir: B5 diliminin beklenen iki farkı vardır. Biri yeni `server_plugins_tablet_accessibility_test.dart`, diğeri mevcut `server_plugins_screen_test.dart` içindeki kaydırma karesini bekleyip hit-test doğrulayan iki satırdır. Başka test farkı yoktur. Üretim farkı yalnız `lib/features/server/plugins/presentation/server_plugins_screen.dart` dosyasındadır; dilim belgesi de taşınmıştır. Bu birleşim belgesi test sonrasında eklenen tek yeni dosyadır.

Bu nedenle Server, policy veya tam Core testleri yeniden çalıştırılmadı. Main, CI106 kaynağı, Android/E2E akışı, sözleşmeler ve kurulum davranışı değiştirilmedi. Push, yeni CI, cihaz kurulumu veya gerçek ev/Server erişimi yapılmadı.

## Kanıtlar ve kabul sınırı

- `/private/tmp/larenor-plugins-integration-execution.json`: exact komutlar ve süreç sonuçları.
- `/private/tmp/larenor-plugins-integration-preservation.json`: ebeveynler, tam/subtree hash'leri ve kapalı dosya farkı.
- `/private/tmp/larenor-plugins-integration-full-client.log`: tek tam test koşusu.
- `/private/tmp/larenor-plugins-integration-analyze.log`: tam analiz.
- `/private/tmp/larenor-plugins-integration-format-all.log`: depo geneli biçim kontrolü.
- `/private/tmp/larenor-core-plugins-integration-delivery-evidence.json`: sonuç, log hash'leri ve son belge checkpoint'i.

Önceki bağımsız B5 kaynak incelemesi ve özel Inter/CupertinoIcons PNG kontrolü [dilim belgesinde](core-plugins-tablet-accessibility-2026-09-06.md) kayıtlıdır. Root test edilen `9ca1ffe` üretim farkını ve 1280 px/2x PNG'yi ayrıca inceledi; yeni somut P1/P2 bulmadı.

Bu, yerel birleşim doğrulamasıdır. Yeni paket CI/APK sonucu, fiziksel tablet/DeX erişilebilirliği ve genel B5.1/tasarım kabulü ayrı ve açıktır. Jobs history/detail için sonraki olası dilim bu kaynak veya bu test toplamının parçası değildir.
