# S08.4 — Ev kapsamlı düzen ve açık oda adı kopyası

6 Eylül 2026. Bu teslim S08.4'ün ilk yerel kayıt dilimidir; kalıcı ağ
önbelleği, diğer ev kayıtları, Core restore veya merkezi HA adaptörü değildir.
S08.3 kaynak/oturum sınırı korunur. Gerçek Android E2E ve yayın kabulü ayrı
kanıt gerektirir; bu dal bunları başlatmaz.

## Kaynak ve sahiplik

- İzole çalışma: `/private/tmp/larenor-client-scoped-layout`,
  `codex/client-scoped-layout`; başlangıç
  `394de0fc5e0f7e672dda8847c83b6e8d3b50e61b`.
- `HomeDataScope`: değişmez `(coreId, homeId, userId)`. Core/ev kimlikleri
  tam 32 küçük hex karakter; kullanıcı kimliği mevcut Server sözleşmesiyle
  uyumlu, boş olmayan en çok 128 karakter ve kontrol karakteri içermez.
- `DashboardRepository`: Direct kaynak `dashboard_layout` anahtarını korur.
  Core anahtarı `dashboard_layout_core_v1_` + canonical, domain-separated
  SHA-256 özetidir (89 ASCII karakter). Adres veya token anahtara girmez.
  Tek JSON kaydında sürüm 1, exact tuple, pozitif revizyon ve doğrulanmış
  DashboardLayout birlikte yazılır. En çok 2 MiB düzen + 1024 bayt zarf;
  revizyon en çok 2^63−2. Eksik kayıt boş kalır; bozuk, büyük veya başka
  tuple taşıyan kayıt hata verir ve legacy'ye düşmez.
- `dashboardRepositoryProvider` tek kaynak seçimi noktasıdır. HomeSessionScope,
  account/store/router ve global HA credentials mimarisi değiştirilmez.
  Auto-dispose provider'ı tüketen testlerin gerçek bir subscription tutması
  gerekir; üretim önizleme ekranı provider'ı watch eder.
- `home_layout_access.dart` kayıt erişimini güncel doğrulanmış account.session,
  generation ve interaction epoch'una bağlar. İlk parola, pending-context,
  logout ve 30 saniyelik token yenileme eşiğinde yetki kapalıdır. Retained
  runtimeIdentity erişim izni değildir. Aynı tuple için token değişmesi aynı
  kalıcı anahtarı kullanır; eski önizleme yeni oturuma taşınmaz.

## Görünür davranış

Mevcut PIN korumalı ev kaynağı ekranında **Yerel oda adlarını kopyala** girişi
vardır. Önizleme yalnız açık kullanıcı eylemiyle legacy düzeni okur; HA secure
credentials, REST, WebSocket, keşif veya servis adresi okumaz. Kayıtlı hedef
oda adları gösterilir. Hiçbir yerel oda önceden seçilmez.

Yalnız seçilen oda adları kaynak sırasıyla mevcut hedefin sonuna eklenir;
yeni oda kimlikleri üretilir. Entity/scene/service başvuruları, alan bağları,
kartlar, web adresleri/izinleri ve bağlantı bilgileri kopyalanmaz. Önizleme
hariç tutulan türleri ve referans/alan/kart sayılarını açıklar. Legacy kayıt
silinmez veya değiştirilmez. Hedefin 500 oda sınırında kısmi yazma yapılmaz.

Önizleme en çok beş dakika geçerli ve tek kullanımlıdır; kaynak özeti,
hedef revizyon/özeti ve exact account/epoch ile bağlıdır. ConfigurationWrites
sırası içinde kaynak, hedef ve yetki yeniden okunur. Kaynak/hedef değişikliği,
arka plan, idle, kapalı rota veya eski dialog callback'i yazamaz. Başarısız
veya belirsiz yazma otomatik tekrarlanmaz; güncel düzenin açıkça yeniden
incelenmesi gerekir. Diske yazıp false/exception dönen platform başarı olarak
sunulmaz. Sonraki okuma önce prefs.reload yapar; optimistic cache kalıcı
kayıt yerine geçmez. Bu tek kayıt operasyonu, Core backup/restore journal'ı
uygulandığı anlamına gelmez.

E2E giriş sözleşmesi:
`home-layout-preview-entry`, `home-layout-room-<index>`,
`home-layout-copy-selected`, `home-layout-confirm-copy`,
`home-layout-copy-complete`, `home-layout-refresh-preview`,
`home-layout-current-room-<index>`.

## Yerel doğrulama

- İlk görünür giriş runtime RED: `fcb7a17`; compiling controller RED:
  `659d0b8` (10 beklenen hata). İlk production GREEN: `e067836`.
- Kapalı dialog callback RED `6b84797` → GREEN `be594d0`: belirsiz yazma
  sonrasında eski Navigator callback'i artık işlem başlatamaz.
- Mevcut legacy hata türleri `6233c61` ile korundu (3 mevcut regresyon →
  38 odaklı PASS). Override uyumu `ddc1da2` ile korunur: eski save imzası
  değişmez, yeni karşılaştırmalı yazma `saveIfUnchanged` kullanır.
- Gerçek HomeSessionScope/PIN: EN/TR, 600/1200 genişlik, 2× metin; minimum
  48 piksel hedef, tek seçili button semantics, klavye Space/Tab/Shift-Tab,
  iptal, gizlenen rota ve callback emekliliği. App remount testi kalıcı kayıt
  yeniden okumasını kanıtlar; native OS process/disk restart iddiası değildir.
- İlk microtask sınır testi tamamlanmış Future sonrasına retirement koyduğu
  için zamanlaması düzeltildi; bu deneme ayrı bir üretim kusuru RED kanıtı
  olarak sayılmaz. Okuma yayınından önceki yetki kontrolleri korunur.

Son production/test checkpoint'i `6b95900`:

- `ddc1da2` geniş regresyonu: **1.236 PASS**; core, dashboard, home_scope,
  settings, backup, server ve client_updates. Log:
  `/private/tmp/larenor-scoped-layout-broad-final.log`.
- Bağımsız incelemenin platform FormatException bulgusu: `55867f6` gerçek
  platform RED (**10 PASS / 4 FAIL**) → `6b95900` GREEN. Core statik
  `read_failed`/`write_failed`; Direct aynı exception türünde sabit mesaj
  döndürür. Son odaklı regresyon **93 PASS**:
  `/private/tmp/larenor-scoped-layout-final-green.log`. Bu 93, geniş sayıya
  eklenen bağımsız yeni test toplamı olarak sunulmaz.
- Son beş çekirdek dosyada satır kapsamı **444/458 (%96,9)**:
  HomeDataScope %100, DashboardRepository %96,8, HomeLayoutAccess %97,3,
  LegacyLayoutController %100, LegacyLayoutScreen %95,5. LCOV:
  `/private/tmp/larenor-scoped-layout-final-coverage.info`.
- Son scoped analyzer: **0 sorun**;
  `/private/tmp/larenor-scoped-layout-final-analyze.log`. Kapsamlı biçimleme
  yerine yalnız sahip olunan dosyalar biçimlendirildi; git diff check temiz.
- Gerçek bundled Inter/CupertinoIcons ile EN/TR 600×1000, 2× metin, açık/koyu
  **4 özel QA renderı** ve görüntü incelemesi geçti. Seçim işareti ve klavye
  odağı görünür, içerik kaydırılarak okunur. Görseller yalnız
  `/private/tmp/larenor-scoped-layout-{en,tr}-{light,dark}.png`; README'ye
  eklenmedi. Tek kullanımlık preview testi silindi.
- Bağımsız salt okunur incelemede yukarıdaki hata sınırı dışında P1/P2
  bildirilmedi; son düzeltme de temiz incelendi. CI/E2E/push/merge bu dalda
  yapılmadı; root bunları birleşik kaynak üzerinde ayrı doğrular.

**Kanıt sınırı:** Klasik SharedPreferences getInstance/reload altta getAll
kullanabilir. Bu aynı uygulama içindeki adlandırma ve yetki sınırıdır; OS
principal/sandbox veya legacy preference baytlarının fiziksel olarak hiç
okunmadığı iddiası değildir. Kanıtlanan sınır legacy düzenin otomatik
çözümlenmemesi/hedef olarak seçilmemesi, HA secure connection/provider/REST/WS
okumalarının sıfır kalması ve eski ev içeriğinin UI'ye çıkmamasıdır. Explicit
önizleme yalnız layout kaydını kullanır. Root'un yönettiği ilerleme/kuyruk ve
CI kayıtları bu izole dal tarafından değiştirilmez.
