# S08.4 — Direct Jellyfin kaydı, cihaz kimliği ve kurtarma sınırı

6 Eylül 2026. İzole dal `codex/direct-jellyfin-boundary`, başlangıç
`a2658ec902aea9b358e1ff0e10e093db773de238`. Üretim/test dondurması
`3b5c51b7369e66504a0b46d28389296be0d663b9`; son davranış düzeltmesi
`28ae3b7`, sonraki kaynak farkı format, süslü parantezler ve var olan
callback kontrolüne ek açık `mounted` kontrolüdür.

Bu dilim yalnız Jellyfin tüketicisini kapsar. Bütün S08.4, kalan credential
servisleri, Core Jellyfin adaptörü veya fiziksel tablet/LAN kabulü değildir.
Ortak Direct sahiplik helper'ı, HA/auth, backup ve global pencere kapsamı
bu dalda değiştirilmedi.

## Kayıt ve cihaz kimliği

`JellyfinCredentialsStore` mevcut constructor ve read/save/clear imzalarını
korur; isteğe bağlı `DirectHomeAccess` ve eylemler için `isCurrent` kullanır.
Üretim provider'ı nesneyi `directHomeAccessProvider` sahibine bağlar.
Kapsamsız eski store kullanımı test/legacy uyumu için korunur; üretim Core
kaynağını atlamanın yolu değildir.

URL, userId ve accessToken mevcut kapalı `DirectCredentialRecord` Jellyfin
üçlüsüdür. Okuma/değiştirme/temizleme `ConfigurationWrites` ile sıralanır.
`jellyfin_connection_pending_v1` ilk alan etkisinden önce yazılır; bütün
alan etkileri ve sahiplik kontrolleri tamamlanmadan kaldırılmaz. Marker
varken tuple alanları okunmaz. Her platform çağrısı öncesi/sonrası ve
çağıranın await continuation'ında Direct sahipliği korunur. Core,
başlangıcı bekleyen/hatalı kaynak veya emekliye ayrılmış nesne eski evin
kaydı üzerinde read/save/clear başlatamaz.

`jellyfin_device_id` credential tuple'ın parçası değildir. Mevcut değer
login, tam credential save ve logout/clear boyunca korunur. Üretim
sahipliği, device-ID okuması ve gerektiğinde ilk oluşturma yazısında da
zorunludur. Pending veya eksik tuple okuması yeni cihaz kimliği oluşturmaz.
Device-ID okuması sırasında kaynak kaybı yeni yazıyı engeller. Eşzamanlı
iki ilk istek tek kimlik oluşturur. Mevcut kimlik biçimi değiştirilmedi.

Platform hatası, yazının gerçekleşmediğinin kanıtı sayılmaz. İlk marker
veya son marker-delete yanıtı kaybolmuş olabilir; işlem statik
`write_unconfirmed` olarak başarısız kalır. Yarım tuple marker ile yeni
store örneğinde de reddedilir. Otomatik rollback, retry, marker temizliği
veya cihaz kimliği silme yoktur. Bu Keychain/Keystore transaction, fsync ya
da gerçek uygulama süreci yeniden başlatma kanıtı değildir. Testler
sentetik platform belleğinde yeni store örneğiyle kurtarma durumunu okur.

## Oturum, HTTP ve ekran

Connection notifier ilk Direct sahibini ve işlem kuşağını tutar. Eski
login HTTP sonucu, kaynak veya provider yenilendikten sonra kaydı yazamaz;
eski logout yeni sahibin kaydını silemez. Bekleyen ikinci login `busy`
olarak reddedilir. Logout/dispose mevcut kontrol istemcisini kapatır.
Login aynı mevcut `/Users/AuthenticateByName` POST protokolünü ve cihaz
header'ını kullanır. Doğrulama için oluşturulan HTTP istemcisi success,
error ve retirement sonunda kapatılır; qBittorrent'e özgü ek istek ya da
latest-wins davranışı taşınmadı. HTTP/parser/playback API'leri değişmedi.

Doğrulanmış bağlantı varken storage hatası eski `AsyncData` hesabını
kullanılabilir bırakmaz: `write_unconfirmed`, `pending_mutation` ve
`storage_failed` mevcut sahibin state'ini `AsyncError` yapar; eski okuma
istemcisi kapanır. Bu state yazılmadan önce kaynak/işlem yeniden doğrulanır.
Sıradan HTTP authentication reddi ayrı tutulur ve önceki doğrulanmış
bağlantıyı korur. Marker-delete yanıtı kaybı `pending_mutation` diye yeniden
adlandırılmaz; marker gerçekten bulunmayabilir.

Pending veya belirsiz yazma durumu boş bağlantı formunda açık tam login
veya clear ile kurtarılır. Gerçek Settings → PIN → Integrations → Manage
Integrations → Jellyfin yolu test edilir. Eski URL/user/password
önceden doldurulmaz, recovery otomatik LAN discovery başlatmaz. Clear
cihaz kimliğini korur, form boş kalır ve Done bildirir; otomatik provider
reload ile keşfe dönülmez. Diğer storage hataları güvenli genel hatadır.

Form, mevcut `MediaSessionState` foreground/AppInteraction epoch ile
Direct sahibi, notifier kimliği, transient loading, route, TickerMode ve
ilgili native view focus kontrollerini birleştirir. Idle→wake, background,
route dönüşü, provider/source yenileme veya native focus kaybında eski
callback yeni taslakla bile çalışmaz. Başka pencerenin focus olayı bu
formu emekliye ayırmaz. Yeni görünür eylem çalışabilir. Bu kontroller
HTTP sonrasına ve her credential yazısına `isCurrent` ile taşınır.
Sırf idle durumuna girildi diye Direct arka plan okumasına kullanıcı eylem
izni şartı eklenmedi; mevcut PIN/medya eylem kapıları gevşetilmedi.

Discovery'nin mevcut UDP protokolü korunur. Enjekte edilebilir socket
factory yalnız testlerin gerçek yayın yapmadan lifecycle'ı çalıştırması
içindir. Bind beklerken stop/source kaybı oluşursa dönen socket kapanır,
yayın yapılmaz. Geç event eski veriyi okuyamaz, stop listener ve socket'i
kapatır. Formdan ayrılma timer/subscription/discovery'yi durdurur.
Boş kütüphane sonucu mevcut yerelleştirilmiş empty-state ile gösterilir;
boş `CupertinoListSection` assertion'ı böylece düzeltilmiştir.

## RED → GREEN kanıtı

| Dilim | Gerçek runtime RED | İlk GREEN |
|---|---|---|
| Kaynak/store/device sınırı | `3660965`: 1 PASS / 15 FAIL | `4dacc33`: 16 PASS |
| Geç login, logout, HTTP ömrü | `d24d99a`: 6 PASS / 5 FAIL | `5f37846`: 27 birleşik PASS |
| PIN recovery + discovery bind | `6e91cef`: UI 6 FAIL; discovery 1 PASS / 3 FAIL | `a3c49aa`: 37 birleşik PASS |
| Native focus ve aynı notifier'ın reload'u | `44a135d`: 15 PASS / 2 FAIL | `fe3ba65`: 17 UI PASS |
| Confirmed account + belirsiz storage | `b46949b`: 29 PASS / 8 FAIL | `28ae3b7`: 37 birleşik PASS |

Discovery RED checkpoint'inde eski davranışı koruyan socket/factory test
seam'leri de vardır; bunlar güvenlik GREEN'i olarak sunulmaz. İlk recovery
GREEN denemesi 9 PASS / 1 FAIL ile gerçek boş-kütüphane assertion'ını
buldu; final `a3c49aa` bu ek hatayı da kapatır. İlk lifecycle denemesi
widget fake-time içindeki yanlış fixture await'i yüzünden durduruldu;
`larenor-direct-jellyfin-lifecycle-red.log` tam koşu kanıtı değildir.
Düzeltilmiş fixture'ın ayrı runtime RED/GREEN logları yukarıdaki sayıları
verir; iptal edilmiş süreç başarı sayılmadı.

## Son yerel doğrulama

- Yeni dört test dosyası: **98 PASS**.
- Yeni testler + mevcut Jellyfin client/parser/player, medya hub/session,
  ortak record ve enabled-services regresyonu: **297 PASS**.
- Dokuz owned Dart dosyası analyze: **0 bulgu**; format: **9 dosya / 0 fark**.
- Aynı birleşik koşunun LCOV satır kapsamı: **404/448 = %90,2**.

| Üretim dosyası | Satır kapsamı |
|---|---:|
| `jellyfin_credentials_store.dart` | 37/37 — %100 |
| `jellyfin_providers.dart` | 86/90 — %95,6 |
| `jellyfin_discovery.dart` | 45/46 — %97,8 |
| `jellyfin_connect_screen.dart` | 201/209 — %96,2 |
| `jellyfin_home_screen.dart` (mevcut browse dahil) | 35/66 — %53,0 |

Yeni runtime vakaları cold Core/pending/error I/O sıfır, held store ve
login/logout retirement, before/after-effect platform hataları, bağımsız
device ID, confirmed client disposal, boş explicit recovery ve başarılı
standalone route pop içerir. EN/TR, light/dark ve 600×900 pencerede 2×
yazı gerçek Inter fontuyla taşma/scroll ve en az 48 yükseklik kontrollerini
geçti. Discovery testleri sentetik `RawDatagramSocket`; HTTP testleri
`MockClient`; depolama testleri gerçek plugin MethodChannel sınırındaki
sentetik platform handler'ıdır. Gerçek yayın, LAN servisi veya credential
kullanılmadı. Native Keystore/cihaz, Android E2E ve birleşmiş main CI bu
izole yerel koşunun kanıtı değildir.

Geçici kanıt dosyaları:

- `/private/tmp/larenor-jellyfin-confirmation-{red,green}.log`
- `/private/tmp/larenor-jellyfin-final-qa.log`
- `/private/tmp/larenor-jellyfin-broad-green.log`
- `/private/tmp/larenor-jellyfin-analyze-final.log`
- `/private/tmp/larenor-jellyfin-format-check.log`
- `/private/tmp/larenor-jellyfin-final-coverage.info`

Tüm Flutter/Dart komutları ortak `/private/tmp/larenor-flutter-check.py`
kilidiyle izole worktree'de çalıştırıldı. Bu dal main'e push yapmadı; ortak
birleştirme, tam Client koşusu ve yayın kabulü ana çalışma tarafından
ayrı doğrulanır.
