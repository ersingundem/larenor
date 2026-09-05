# Client ev kaynağı ve oturum kapsamı — S08.3 ilk teslim

Bu teslim açık cihaz tercihini gerçek Android uygulaması yoluna bağlar. Core
adaptörleri veya yeni bir ev panosu uygulamaz. `verifiedCore` seçiliyken yalnız
bağlantı/doğrulama durumu ve PIN korumalı hesap/kaynak yönetimi açılır; mevcut
HA bağlantısı, medya rotaları, pano önbelleği veya yerel ortam fotoğrafları bu eve
kendiliğinden taşınmaz. Core ekranı bu sürümde ev görünümünün bulunmadığını söyler.

## İzole teslim sınırı

- Çalışma ağacı: `/private/tmp/larenor-client-home-session-scope`
- Dal: `codex/client-home-session-scope`; taban `8678982fa19352fafb104489665d704692aaebaf`.
- Kaynak/E2E hazırlığı `13586ae`, izole freeze `10d3eb1`; ana dala
  `4ba7024` ile birleştirildi. Birleşik tam Client kontrolü geçti; emülatör CI kabulü ayrıca bekleniyor.
- Ayrı kabul edilmiş S08.2 ve daha eski CI sonuçları bu yeni kodun CI kanıtı değildir.

## Davranış ve sahiplik

`main.dart` içindeki `ConfigurationScope → HomeSessionScope → LarenorApp`
yolu hesap ile kaynak tercihini uygulama çalışma kapsamının dışında tutar.
`HomeSessionScope` her kaynak/kimlik için **üst kapsayıcısız** bir Riverpod
container oluşturur. Tam `CupertinoApp.router`, görünüm, PIN, ekran politikası,
IdleGate, router ve ev sağlayıcıları bu tek container içinde yaşar. Hesap
controller'ı paylaşılır; kaynak değişimi hesabı dispose etmez. Böylece Ayarlar'ın
tema veya ekran açık tutma yazıları görünen uygulama ile aynı sağlayıcıyı günceller.

Kimlik `(coreId, homeId, userId)` üçlüsüdür; token, nesne adresi veya görünen ad
kimlik değildir. Aynı kimliğin yenilenen token'ı ve bekleyen context GET'i
hesap kurtarma rotasını korur. Bu güvenli rota pencere/IdleGate/PIN kurallarını
izlemeye devam eder; kendi doğrulama GET'ini etkileşim kaybıyla iptal etmez.
Farklı doğrulanmış kimlik, çıkış veya kaynak değişimi eski etkileşim epoch'unu
kapatır. Eski bütün router/ikincil rota/dialog widget'ları kaldırıldıktan sonra
container dispose edilir ve yeni çalışma kapsamı kurulur. REST/WS kaynaklarının
mevcut dispose yolları çalışır; geç yanıtlar yeni görünümde kullanılmaz.

`home_source_v1` yalnız `directLocal` veya `verifiedCore` saklayan, gizli olmayan
cihaz tercihidir. Eksik anahtar eski doğrudan kullanım için `directLocal`
anlamına gelir. Bozuk/okunamayan değer ve false/exception ile başarısız yazı
kurtarma görünümü açar; sessiz fallback yoktur. Değişim ilk async yazıdan önce
etkileşimi kapatır. Okuma reload ve okuma/yazma `ConfigurationWrites` sırası
kullanılır; başarısız optimistic SharedPreferences cache'i yetki kazanmaz.

Tercih çıkıştan, context 404'ten ve olağan yeniden açılıştan sonra korunur.
Backup'un sabit allowlist'ine eklenmez; gerçek BackupRepository export/restore
regresyonu hedef cihazın tercihini koruduğunu doğrular. Global preference clear
veya HA/cache veri taşıma yoktur. Core/recovery boşta ekranı yalnız saat/tarihtir;
yerel HA hava durumu veya fotoğraf kütüphanesini okumaz. Direct modun ortam
fotoğrafı davranışı korunur.

Kaynak satırında görünür checkmark ve tek selected semantics vardır. İlk
kurulum Server ekranından açılan kaynak sayfası da SettingsGate altındadır;
sayfa açıkken PIN oluşturmak bu sayfayı ve eski callback'ini kapatır.

## Kanıt

RED/GREEN checkpoint'leri korunmuştur:

| RED | GREEN | Gerçek davranış |
| --- | --- | --- |
| `72d80fa` | `0ceb1a0` | Kaydedilmiş Core açılışında eski HA config okuması 1 → 0 |
| `b47ea95` | `43ea7cf` | Kalıcı kaynak, hatalı değer/yazı, sıra ve backup sınırı |
| `baee4c6` | `1ff7ef1` | Core idle sırasında eski HA okuması 1 → 0 |
| `6c62932` | `13586ae` | İlk kurulum kaynak sayfası sonradan PIN ile kapanır |
| `30f6d45` | `13586ae` | Kaydedilmiş kaynak görünür checkmark ile seçilir |

Odaklı 50 test PASS: 22 kaynak deposu, 4 controller, 1 açılış ve 23 gerçek
uygulama kapsamı senaryosu. Login/ilk parola/bekleyen GET, aynı kimlik refresh,
farklı Core/ev/kullanıcı, context 404 GET-only retry, kaynak yazı bekleme/hatası,
PIN/arka plan/idle, geç REST+WS, ConfigurationScope restore ve gerçek Ayarlar
tema/ekran politikası kapsanır. EN/TR 600/1200 genişlikte 2x ölçekte çalışır.

Yeni modüller için satır kapsamı toplam **262/264 (%99,2)**: kaynak deposu15/15,
controller70/71, çalışma kapsamı38/39, birleşik etkileşim41/41, Core durum48/48,
kaynak ekranı50/50. Bu satır kapsamıdır; branch veya cihaz kapsamı iddiası değildir.
Odaklı analiz 18 öğede sorun bulmadı. Geniş core/settings/server/clientupdates/
navigation/auth/ambient/backup/shared regresyonu **1.093 test PASS** verdi;
seçili kaynağın gerçek semantics düğümleri için son ilave assertion da tek
hedefli koşuda geçti. Özel yerel kanıt dosyaları:

- `/private/tmp/larenor-home-scope-focused.log`
- `/private/tmp/larenor-home-scope-coverage.info`
- `/private/tmp/larenor-home-scope-analyze.log`
- `/private/tmp/larenor-home-scope-regression-final.log`

Gerçek bundled Inter/CupertinoIcons ile TR600, 2x, açık/koyu durum ve kaynak
PNG'leri `/private/tmp/larenor-home-scope-qa/` altındadır. Bunlar özel QA çıktısıdır;
README galerisine eklenmemiştir.

## Cihaz kapısı ve kalan sınır

Mevcut dört Android yolculuğunun harness'i `LarenorApp` bypass'ı yerine gerçek
`HomeSessionScope` composition kullanır. Beşinci synthetic loopback yolculuk
Direct HA → PIN → Core tercihi → eski WS kapanışı/HA okuması durması → yeniden
PIN → açık Direct tercihi → yeni WS aboneliği yolunu doğrulayacak şekilde yazıldı.
Dış ağ reddi, mock preference/secure storage, gerçek HA HTTP/WS loopback transportu,
mevcut assertion/timeouts ve statik aşama/cleanup işaretleri korunur. Native dört
senaryoyla toplam dokuz E2E senaryosunun **bu teslimde gerçek emülatör CI sonucu
henüz yoktur**; yalnız kaynak analizi yapılmıştır. Fiziksel tablet/Huawei/DeX
kabulü de ayrıdır.

Merkezi HA/medya adaptörleri, Core cache anahtarları ve kontrollü legacy veri
aktarma S08.4+ sınırındadır. Bu ilk teslim çoklu ev/federasyon veya tüm B3/S08'in
bittiği anlamına gelmez.

## Birleşik Client kontrolü

S08.3 ve dashboard birlikte main `8cc4665b2076cb80ad891bef10cf82931611ed7d`
üzerinde **2.815 Flutter testini 3:46 içinde geçti**. İlk başlatma yerel
üretilmiş çeviriler eski olduğundan durduruldu; `build_runner` ve `gen-l10n`
yenilendikten sonraki bu tam koşu başarılıdır. Geçici çıktı
`/private/tmp/larenor-home-dashboard-full-flutter-green.log`; gerçek emülatör
ve bu yeni kaynak sürümünün uzak CI kabulü ayrıca beklenir.
Tam `flutter analyze` 6,5 saniyede sıfır bulgu verdi; 801 Dart dosyasının biçim
kontrolü sıfır değişiklikle geçti. 24 kuyruk testi ve gitleaks taraması temiz.
