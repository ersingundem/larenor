# S08.6 — Core kayıt metadata yönetimi

6 Eylül 2026. İzole `codex/core-home-resource-admin` dalı, ana kaynak
`4bc79dcc66eb9e3ce2a5044bd240db2fafd0d695` üzerinden açıldı. Önceki doğrulanmış
[metadata API paketi](core-home-resource-admin-api-implementation-2026-09-06.md)
`8e00548` yerel `4c22246` merge checkpoint'iyle alındı. Son üretim checkpoint'i
`68e77b81c01f01aad496de9d116b322592f757a1`.

Bu dilim önceki API'yi **gerçek Client yönetici akışına bağlar**. Doğrulanmış
Core sayfasındaki yönetici, **Kayıtları yönet** → mevcut Settings PIN kapısı
üzerinden oda/kaynak oluşturabilir, adını veya görüntülenme sırasını
değiştirebilir, registry kaydını silebilir. ACL düzenleme, cihaz komutu,
HA import, servis çalıştırma, kullanıcı profili veya kişisel vault erişimi
getirmez. Bütün S08.6 kabulü veya fiziksel tablet kabulü sayılmaz.

## Akış ve bağlama

- `HomeResourceAdminScreen`, `SettingsGateDestination.homeResources` içinde
  açılır. Ana Core listesinden ayrı controller kullanır; yönetim rotası ana
  listeyi örttüğünde eski read controller görünürlük yetkisini bırakır.
- `HomeResourcesController(adminManagement: false)` varsayılan salt okunur
  davranışı korur. Yönetim ekranı bunu açıkça `true` yapar. Current admin rolü,
  hazır parola, doğrulanmış Core/ev, taze session ve hesap generation'ı tekrar
  okunur. Client rolü yalnız arayüz ipucudur; mevcut Server her HTTP işleminde
  gerçek yetki/context/revision kontrollerini sürdürür.
- Form mevcut `room` / `resource` türlerini, 1–80 Unicode codepoint label ve
  `0..10000` tamsayı sırasını kullanır. UUID/owner/grant Client tarafından
  oluşturulup gönderilmez. PATCH/DELETE mevcut strict kaydın hem record hem
  ACL revision'ını taşır; kind/id/context değiştirilemez.
- Her async adım current account, exact session, Core kaynağı, etkileşim
  epoch'u ve form sahibini yeniden kontrol eder. Tek mutation sürerken ikinci
  tıklama veya elde tutulmuş numeric-submit callback'i yeni HTTP başlatmaz.
- Gate'in dış root rotası ve PIN generation/değeri ayrıca bağlanır. PIN
  loading/error/rotation/removal geçişleri eski nested sayfayı geçersiz kılar.
  PIN kaldırıldıktan sonra eski form geri gelmez; yeni PIN'siz yönetim akışı
  açılabilir. PIN store hatasından sonra başarılı açık reload da yeni form
  oluşturur; hata aşamasında metadata veya key/message gösterilmez.
- Pencere/native focus, foreground, TickerMode/route ve AppInteraction
  kaybında form metni ve silme hedefi temizlenir; yalnız bu controller'ın HTTP
  transport'u kapatılır. Eski yanıt current session'ı sonradan logout edemez.
  Gönderilmiş HTTP'nin geri alındığı veya Server yazısının iptal edildiği iddia
  edilmez.
- Aynı `GlobalKey` state'i başka Core/Direct `ProviderContainer` altına
  taşınırken eski container/account canlı kalsa bile hem yönetim ekranı hem
  mevcut read sliver, current provider identity ile bağlı home controller'ı
  karşılaştırır ve kapanır. Yeni görünür scope eski endpoint'e callback veya
  yeni okuma gönderemez.

## Sonuç, silme ve geçmiş

Başarı yalnız strict API'nin bağladığı record veya gerçek boş 204 silme
cevabı üzerinden gösterilir. No-op metadata mevcut revision'ı korur. Bilinen
başarı görünür kaydı günceller; eski pagination snapshot'ı kapatır ve **listenin
tamamını kontrol etmek için yenile** metnini gösterir. Sessiz POST tekrarı yoktur.

Conflict ayrı mesajdır. Bağlantı hatası, timeout veya bozuk/eksik yanıt
**sonuç doğrulanamadı; değişiklik kaydedilmiş olabilir** olarak ayrılır.
Eski target/liste kaldırılır; yeni mutation için açık liste yenilemesi gerekir.
Bu GET yenilemesinin de başarısız olması önceki POST'u tekrarlamaz. Keyfi
Server/proxy hata mesajları UI'ye aktarılmaz.

Silme onayı immutable hedef adı/revision'larına bağlıdır. İptal HTTP göndermez.
Açıklama yalnız Larenor registry kaydının kaldırıldığını söyler; upstream
cihaz, servis, disk veya container üzerinde silme yoktur. Geçmiş lazy liste
kullanır; 51 kayıt ve son sayfadaki kayıt üzerinde gerçek widget update akışı
sınanır. Mevcut 512 kayıt sınırını doğrulayan read regresyonu korunur.

## Tablet, DeX ve erişilebilirlik

AppPageScaffold yüzeyi ve mevcut tema korunur. EN/TR, 320/600/1280 piksel,
light/dark ve iki kat metin için gerçek Inter fontlarıyla 12 widget senaryosu
çalışır. Form açıkken alttaki kayıt eylemleri ağaçta bulunmaz. Alan adları,
seçili tür semantiği, görünür checkmark, live result metni, Tab/Shift+Tab/Enter
akışı ve en az 48×48 eylem hedefleri kontrol edilir.

Gerçek Tab odağında native varsayılan focus renginin kontrastı 2,02:1 çıktı;
yalnız bu ekranın button focus rengi mevcut uygulama primary rengine bağlandı
ve en az 3:1 kontrolü geçti. CupertinoNavigationBar leading alanının gerçek
44px yüksekliği de ayrı RED oldu. Bu ekranın küçük özel header'ı geri hedefini
en az 48px tutar; diğer ekranların navigation bar'ları değiştirilmez.

`home_resource_admin_tablet_test.dart`, yalnız açık
`--dart-define=CORE_RESOURCE_ADMIN_PREVIEW_DIR=/private/tmp/...` verildiğinde
RepaintBoundary PNG üretir. Normal CI'da dosya veya golden binary eklemez.
TR 600px form, TR 1280px koyu liste ve TR 320px form çıktıları `view_image` ile
incelendi. Bu sentetik Flutter görüntüleridir; fiziksel DeX/tablet kanıtı değildir.

## RED → GREEN ve doğrulama

| Checkpoint | Gerçek davranış kanıtı |
|---|---|
| `7b34263` → `b85673b` | Eksik yönetim girişi: 1 PASS / 3 FAIL → gerçek PIN/create/update/delete/cancel 4 PASS |
| `a178392`, `4e5458d` → `80ee051` | PIN/root pre-frame eski mutation ve late401; retained container eski Core okuma/yazma; 55 UI/scope PASS |
| `fd1de2a` → `a212735` | PIN kaldırma sonrası tıkanan eski sayfa → temiz yeni PIN'siz akış |
| `9901bfa` → `ee14d8c` | Gerçek Tab kontrastı ve görünür tür seçimi RED → 12 tablet senaryosu PASS |
| `443ae83` → `68e77b8` | Gerçek geri hedefi 44px RED → en az48px ve tüm 12 ölçü/tema senaryosu PASS |

Derleme/fixture hazırlık hataları RED kabul edilmedi. MockClient callback
assertion'ları `expectSync` kullanır: callback doğrudan çağrıldığında devam
eden tester.pump ile guarded `expect` çakışması üretim hatası değildir.
HTTP body/revision kontrolleri kaldırılmadı. MockClient AbortableRequest iptalini
uygulamadığı için testler tutulan cevabı açıkça serbest bırakır ve geç yanıtın
sonucunu kontrol eder.

Son üretim kaynağında ilgili tüm home_resources + settings + gerçek home
session/source + Server account/entry regresyonu: **431 PASS, 24 saniye**.
Bu koşu 66 odaklı yönetim/scope/widget vakasını da içerir; sayılar toplanmaz.
Analiz temizdir. LCOV satır kapsamı: yeni yönetim ekranı **349/354 (%98,59)**,
controller **235/235 (%100)**, mevcut read sliver **154/154 (%100)**. Eski ortak
SettingsGate'in tüm diğer özellikleri ayrı **142/187 (%75,94)**; bu oran yeni
modül kapsamıyla birleştirilmez. Branch coverage veya tüm Client suite iddiası
yoktur.

Bağımsız root kaynak incelemesi controller/gate/entry ve `ee14d8c` UI için
CLEAR verdi; son `68e77b8` header deltası ile güncel 600px form/1280px koyu
liste görüntüleri de ayrıca CLEAR olarak incelendi.

Başlıca özel kanıtlar:

- `/private/tmp/larenor-core-resource-admin-toolbar-regression.log`
- `/private/tmp/larenor-core-resource-admin-toolbar-analyze.log`
- `/private/tmp/larenor-core-resource-admin-toolbar-lcov.info`
- `/private/tmp/larenor-core-resource-admin-focused-final.log` (66 odaklı PASS)
- `/private/tmp/larenor-core-resource-admin-back-green.log` (12 son header/PNG)
- `/private/tmp/larenor-core-resource-admin-previews/`

Önceki API paketinin gerçek FastAPI/SQLite fixture'ı ve Client fixture parser
regresyonları bu dalda korunur. Bu UI dilimi Server üretimine dokunmaz. Hiçbir
canlı Core/ev isteği, cihaz komutu, deployment, push veya CI rerun yapılmadı.
Birleşik ana dal CI ve gerçek cihaz kabulü ayrı sonraki kapılardır.
