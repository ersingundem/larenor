# S08.6 — Core kaynak erişim yönetimi

6 Eylül 2026. İzole `codex/core-resource-grants-ui` dalı
`8d9e4d2bdbbf55f685e35f5f5979b61303c2d67e` üzerinden açıldı. Üretim
checkpoint'i `9492bdb`, son test checkpoint'i `c63c16b`.

Bu dilim mevcut strict grant API'sini **gerçek Client yönetim akışına bağlar**:
doğrulanmış Core → Kayıtları yönet → mevcut Settings PIN kapısı → kaydın
**Erişimi yönet** düğmesi. Kullanıcı, mevcut Core hesapları arasından seçilir;
manuel subject ID, yeni hesap, rol değişimi veya varsayılan grant eklenmez.
İlk seçim yalnızca okumadır. Saklanan mevcut izin varsa o gösterilir.

## Gerçek sözleşme ve yetki sınırı

Yeni `HomeResourceGrantsController` ve `HomeResourceGrantsScreen`, mevcut
metadata controller'ından ayrıdır. Metadata ekranına yalnız açık giriş ve
mevcut root/gate-current callback bağı eklenmiştir. Grant sayfası örtüldüğünde
kendi okuma/yazma sahibi sona erer. Geri dönünce metadata ekranının mevcut
visible-read davranışı yeni ACL revision'ını GET ile alır; önceki PUT
tekrarlanmaz.

Mevcut `ServerAdminApi.users()` ile en fazla 256 Core hesabı alınır. Ardından
`HomeResourceGrantsApi.read()` aynı session-owned transport üzerinden hedefin
ACL snapshot'ını okur. Kullanıcı API'si strict modelini korur; bu controller
subject'lerin ayrıca tam 32 küçük hexadecimal karakter olduğunu doğrular.
Seçim yalnız bu okumadan gelen aynı `AdminUser` nesnesine bağlanır. Aynı ID'yi
taşıyan dışarıda oluşturulmuş başka bir nesne mutation başlatamaz.

Kullanılan mevcut HTTP yolları:

- `GET /api/v1/admin/users`
- `GET /api/v1/admin/home-resources/{coreId}/{homeId}/{id}/grants`
- `PUT /api/v1/admin/home-resources/{coreId}/{homeId}/{id}/grants/{subjectId}`

PUT yalnız `expectedAclRevision` ve `permissions: {read, write}` gönderir.
Seçenekler yalnızca okuma, okuma/yazma ve kayıt izni yoktur. Sonuncusu mevcut
Server sözleşmesindeki `false/false` grant kaldırmasıdır; DELETE kullanılmaz.
No-op revision'ı korur; değişen grant revision'ı bir artırır. Response mevcut
strict target/context/subject/permission/revision bağlamasına tabidir. Bir kez
doğrulanmış ACL revision'ı, başarısız GET ardından daha eski cevapla gerileyemez.

Client admin rolü bir arayüz ipucudur. Server mevcut transaction içindeki
current actor, scope, target ve ACL kontrollerinin yetkili tarafıdır. Bu UI
admin rolünü kaldırmaz; engellenmiş hesabı etkinleştirmez. Ekran bunu açıklar.
Grant subject auth hesabıdır; HA person, hesapsız hane profili veya kişisel
vault sahibiyle birleştirilmez. Kişisel vault/auth/session/credential verisi
bu kayıt türlerine veya ekrana alınmaz.

## Callback, onay ve belirsiz sonuç

- Kaynak yalnız doğrulanmış Core; hazır parola, current admin, exact session,
  hesap generation'ı, Core/ev context'i ve AppInteraction epoch'u her async
  adımdan sonra yeniden kontrol edilir. Hesap GET'i emekliye ayrılırsa ikinci
  ACL GET'i başlatamaz.
- PIN/root gate bağına ek olarak bu sayfanın nested route'u, TickerMode,
  foreground, pencere/native view focus ve current home provider identity
  kontrol edilir. Aynı GlobalKey eski Core container'ı canlı tutularak yeni
  Core/Direct scope'a taşınırsa eski seçim ve yeni görünür eylemler kapanır.
- Kaynak/route/PIN/window/session kaybında seçili hesap ve izin taslağı
  temizlenir; yalnız bu sayfanın transport'u kapatılır. Gönderilmiş isteğin
  Server'daki etkisinin geri alındığı iddia edilmez. Retired 401 shared auth'a
  iletilmez, current hesabı sonradan logout edemez.
- Kayıt izni kaldırma önce ayrı, adı gösterilen bir onay durumuna geçer. Bu
  geçiş yeni callback generation'ı açar. Eski Save veya eski izin seçeneği
  callback'i onayı atlayamaz ya da onaylanan izni değiştiremez. Yalnız yeni
  onay düğmesi PUT gönderebilir. İptal HTTP göndermez.
- Tek mutation sürerken ikinci tıklama yeni PUT başlatmaz. Başarı strict
  response ile gösterilir. Conflict, reddedilen değişiklik ve doğrulanamayan
  sonuç farklı statik mesajlardır. Belirsiz sonuç/çatışma sonrası hesaplar,
  snapshot ve seçim temizlenir; açık GET yenilemesi gerekir. Otomatik PUT
  retry yoktur; proxy/Server ham hata metni gösterilmez.

## Tablet ve erişilebilirlik

AppPageScaffold ve mevcut tema kullanılır. Back ve tüm eylemler en az 48px;
seçim görünür checkmark ve seçili semantiğine sahiptir. Sonuç canlı bölge olarak
okunur. Kullanıcı listesi düzenleme/onay sırasında ağaçtan kaldırılır; alttaki
metadata sayfası nested route arkasında kalır. Tab/Enter ile hesap seçme,
izin değiştirme ve kaydetme gerçek Flutter focus davranışıyla sınanır.

EN/TR, 320/600/1280px ve 2× metin için altı tablet/window testi çalışır. Yalnız
`--dart-define=CORE_RESOURCE_GRANTS_PREVIEW_DIR=/private/tmp/...` verilirse
RepaintBoundary PNG üretilir; normal CI binary dosya eklemez. TR 600 ve 1280px
form görüntüleri `view_image` ile incelendi. Fiziksel tablet veya DeX kabulü
değildir.

## RED → GREEN ve ölçülmüş kanıt

| Checkpoint | Doğrulanan davranış |
|---|---|
| `5520c9d` → `fdb8d55` | Gerçek PIN/metadata akışında eksik ACL girişi: 4 runtime FAIL → hesap seçimi, read/read-write, revoke/cancel ve 409/503 açık recovery 4 PASS |
| `5e91148` → `aeb61fc` | Bilinen ACL revision'ını başarısız okumadan sonra geriye götüren cevap: 31 PASS/1 FAIL → monotonic minimum ve 5 UI PASS |
| `1729bc6` → `9492bdb` | Eski Save ve eski permission callback'lerinin revoke onayını aşması: 27 PASS/2 FAIL → yeni confirmation generation, ilgili48 PASS |
| `c63c16b` | Ek gerçek retained-provider ve pre-frame PIN/root late401 negatifleri: 33 ilgili PASS; final52 odak PASS |

Derleme/codegen hazırlık sorunları RED kabul edilmedi. Yeni controller testinde
widget ağacına bağlı olmayan controller'ın timer'ı test bitmeden açıkça dispose
edilir; üretim timer'ı kaldırılmadı. Semantics testi, gerçek birleştirilmiş hesap
adı + izin etiketi ve Flutter'ın `Tristate.isTrue` seçili değerini kontrol eder.

Çalıştırılan komutlar (Flutter/Dart komutları ortak SDK wrapper kilidinden geçti):

```text
python3 /private/tmp/larenor-flutter-check.py flutter test
  test/features/home_resources/home_resource_grants_ui_test.dart
  test/features/home_resources/home_resource_grants_boundary_test.dart
  test/features/home_resources/home_resource_grants_controller_test.dart
  test/features/home_resources/home_resource_grants_tablet_test.dart
  test/features/home_resources/home_resource_grants_scope_test.dart
  --reporter expanded --coverage

python3 /private/tmp/larenor-flutter-check.py flutter test
  test/features/home_resources
  test/features/settings/settings_gate_screen_test.dart
  test/features/server/server_admin_controller_test.dart
  test/features/server/server_admin_screen_test.dart --reporter expanded

PYTHONPATH=server /private/tmp/larenor-server-project-env/bin/python -m pytest
  server/tests/test_home_resource_grants_contract.py -q
```

- Final odak: **52 PASS**, 7 saniye; altı tablet senaryosu dahildir.
- İlgili geniş regresyon: **371 PASS**, 13 saniye. Önceki48 odak testi dahildir;
  son dört test-only negatif ayrıca final52 içinde geçti. Sayılar toplanmaz.
- Aynı worktree import'undan actual FastAPI/SQLite grant contract fixture:
  **2 PASS**. Mevcut versioned fixture yeniden doğrulandı; Server üretim
  dosyaları değiştirilmedi.
- Sekiz dosya targeted analyze: **0 issue**; targeted format: **8 dosya,
  0 değişiklik**; `git diff --check` temiz.
- Final LCOV: controller **158/160 satır (%98,75)**; ekran **277/280 satır
  (%98,93)**. Tüm projenin coverage oranı değildir.

Özel yerel loglar `larenor-grants-ui-delivery-focused.log`,
`larenor-grants-ui-regression.log`, `larenor-grants-ui-server-contract.log`,
`larenor-grants-ui-delivery-analyze.log` ve `larenor-grants-ui-delivery-format.log`
olarak `/private/tmp` altındadır. Birleştirilmiş makbuz:
`/private/tmp/larenor-core-resource-grants-delivery-evidence.json`.

Bu kaynak için tam Client koşusu, yeni Android ACL E2E, CI/imzalı APK ve fiziksel
cihaz doğrulaması bu dilimde yapılmadı. Metadata E2E başka bir teslimdir; ACL UI
kanıtı olarak sayılmaz. Bütün S08.6 kabulü root'un ayrı madde denetimine aittir.
Gerçek cihaz komutları sonraki typed integration kapsamıdır; bu grant sözleşmesi
bu UI diliminde cihaz çalıştırmaz, HA/Core hesabına canlı istek göndermez.
