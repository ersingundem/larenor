# Core logout: kalıcı niyet ve görünür hata

Bu dar S08.5 parçası, başarısız çıkıştan sonra eski kaydın otomatik kullanılmasını ve Core ana ekranına dönüldüğünde çıkış hatasının kaybolmasını ele alır. Restore protokolü, ev federasyonu, Server auth API'si ve kişisel/cihaz kayıtlarının taşınması değişmez.

İzole çalışma: `/private/tmp/larenor-core-logout-boundary`, `codex/core-logout-boundary`, taban `1592ced762a62ec8d7a4ec2ae0fa4fe16e224606`. Ana checkout, kuyruk ve PROGRESS değiştirilmedi; bu daldan push veya CI başlatılmadı.

## Davranış

`ServerAccountController.signOut` önce generation'ı artırır, mevcut transport'u kapatır ve session/pending context'i bellekten çıkarır. Böylece eski ev erişimi ve callback'leri kalıcı I/O beklemeden kapanır. Mevcut HomeSessionScope, Core seçimini koruyarak eski router ve provider kapsamını kapatmaya devam eder; Direct'e otomatik geçiş yoktur.

Ardından aynı `_writes` kuyruğu içinde mevcut v2 session zarfına `authMutationPending` niyeti yazılır ve tek session anahtarı silinir. Controller'da pair henüz yoksa (örneğin devam eden initialize veya ikinci logout) kayıt bu kuyruk içinde okunur. Her await sonrası generation yeniden doğrulanır. Yeni login, eski logout'un sonraki disk adımını durdurur; sıraya daha önce girmiş platform yazısı tamamlandıktan sonra yeni pair kaydedilebilir. Eski uzak logout yalnız yakalanmış eski token ailesini kullanır, geç gelen hatası yeni login'in başarısını değiştirmez.

Niyet yazısı doğrulanamazsa açık silme yine denenir; silme doğrulanamazsa uzak logout yine denenir. Statik `storage_failed` veya `logout_not_confirmed` korunur. Başlangıçtaki mevcut intent kontrolü, kalan işaretli kaydı `/me`, `/context` veya refresh göndermeden reddeder. Yeni schema/key, clear-all veya farklı kayıtları tarama yoktur.

Core status, mevcut EN/TR güvenli depolama ve doğrulanamayan uzak çıkış mesajlarını bir live region olarak gösterir. Mesaj için eski hesap route'u tutulmaz; yeniden hesap yönetimi mevcut PIN kapısından geçer. Hata metni, raw response veya platform exception içeriğini içermez.

## Garanti sınırı

Bütün yerel kalıcı yazma/silme işlemleri **etkiden önce** başarısız olur ve uzak revoke da yapılamazsa disk üzerindeki normal kayıt değiştirilemez. Sonraki süreç eski kaydı görebilir. Testler bu teknik sınırı saklamaz: mevcut süreçte session/scope kapalı ve `storage_failed` görünürdür, fakat hiçbir başarılı kalıcı etki yokken restart güvencesi iddia edilmez. Intent yazısı veya silme gerçekten etkili olduğunda, sonradan platform hata döndürse bile eski normal pair'in otomatik kullanılması engellenir.

Testlerde "restart", aynı sentetik platform map'i üzerinden yeni `SecureServerSessionStore` ve `ServerAccountController` oluşturulmasıdır. Gerçek Android Keystore/process-death veya fiziksel cihaz kanıtı değildir. HTTP, mevcut bounded API transport üzerinden `MockClient` ile yürür; gerçek endpoint, ev veya router kullanılmaz.

## TDD ve kabul kanıtı

| Aşama | Checkpoint / kanıt | Sonuç |
|---|---|---|
| Gerçek RED | `8d03507`, `/private/tmp/larenor-logout-red.log` | İki test çalıştı ve amaçlanan nedenle başarısız oldu: restart sonrası session null yerine eski session; Core status'ta beklenen logout hata metni yok. İlk UI fixture type-inference derleme düzeltmesi RED kanıtı sayılmadı. |
| Minimal GREEN | `674b977`, `/private/tmp/larenor-logout-green.log` | Aynı iki runtime test 2 PASS. Üretim yalnız controller ve Core status. |
| Platform sınırları | `/private/tmp/larenor-logout-store-expanded.log` | 16 PASS: write/delete none/before/after matrisi, remote failure/revoke, pending initialize, dispatch edilmiş auth yazısı, yeni login, çift logout ve read failure. |
| Gerçek runtime/PIN | `/private/tmp/larenor-logout-runtime-expanded.log` | 9 PASS: ilk yolculuk + EN/TR ×600/1200×2x ×storage/remote failure; tek semantics mesajı, Core choice, HA read=0 ve yeniden PIN. İlk semantics-handle test cleanup hatası uygulama regresyonu sayılmadı; handle sonunda dispose edilerek aynı testler geçti. |

Bütün Flutter/Dart komutları `/private/tmp/larenor-flutter-check.py` ortak kilidiyle çalıştırıldı.

| Nihai kontrol | Sonuç / kanıt |
|---|---|
| `flutter test --no-pub --coverage --coverage-path=/private/tmp/larenor-logout-coverage.info test/features/server test/core test/features/home_scope test/features/home_resources` | **1.547 PASS**, 80 sn; `/private/tmp/larenor-logout-regression.log`. Bu ilgili test gruplarıdır, tam Flutter/Android/Server/CI koşusu değildir. |
| Son test-fixture getter düzeltmesi sonrası iki yeni dosya | **25 PASS**, 3 sn; `/private/tmp/larenor-logout-final-focused.log`. Bu 25 test yukarıdaki toplamın içindedir; sayılar toplanmaz. |
| Dört owned Dart dosyasına `flutter analyze --no-pub` | **0 issue**, `/private/tmp/larenor-logout-analyze-final.log`. İlk analizdeki iki test `overridden_fields` bilgisi backing-field/getter ile düzeltildi; production değişmedi. |
| Dört owned Dart dosyasına `dart format` | **4 dosya, 0 değişiklik**, `/private/tmp/larenor-logout-format-final.log`; `git diff --check` temiz. |
| Dart LCOV satır kapsamı | Account controller **296/304 (%97,37)**; yeni logout persistence helper **12/12**; Core status **68/68**; değişmeyen gerçek secure store **8/8**. `/private/tmp/larenor-logout-coverage.info` ve `larenor-logout-coverage-summary.json`. Bu satır ölçümüdür; tam branch kapsamı iddiası değildir. |

Bağımsız root incelemesi minimal üretim `674b977` ve genişletilmiş testler için yeni P1/P2 bulmadı. Sonraki review/final kabul, bu paket için ayrı CI/Android/fiziksel cihaz kanıtının yerine geçmez. Yeni emulator journey veya native process-death deneyi bu dilimde çalıştırılmadı.

## Dosya sınırı

- `lib/features/server/data/server_account_controller.dart`: yalnız logout'un kalıcı niyeti ve var olan yazma sırası.
- `lib/features/home_scope/presentation/core_home_status_screen.dart`: geç logout/depolama hatasının güvenli metni.
- `test/features/server/server_logout_store_test.dart`: gerçek secure-storage platform kanalı ve mevcut bounded transport ile sentetik HTTP.
- `test/core/core_logout_runtime_test.dart`: production HomeSessionScope, actual account screen ve PIN onayı.

Store model/anahtar, auth HTTP sözleşmesi, HomeSessionScope/controller, router, PIN/IdleGate, global credentials, backup, kişisel kayıtlar ve kaynak tercihi değiştirilmez. Scoped layout/kişisel/cihaz kayıtları için toplu silme eklenmez; sentetik HA/PIN/wellbeing anahtarları platform sınır testlerinde aynen korunur.
