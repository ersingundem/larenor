# Hazırlanmış dosya geri yükleme sınırı — S08.5 ilk dilim

Bu dilim, gerçek `BackupScreen` dosya akışını tek kullanımlık hazırlanmış işlemle
`ConfigurationScope`'a devreder. Kaynak, onaylanan içerik, hedefin önceki değerleri
ve işlem sahibi persistence başlamadan önce bağlanır. Normal provider ağacı
kasıtlı olarak kapatıldığında yeni sınır, artık kapalı ekranın callback'ini
kullanmadan aynı durable hedefi doğrular.

Bu belge **S08.5'in tamamlandığını söylemez**. Core'a ait scoped dashboard arşiv
formatı eklenmedi. ServerVault üretim yolunun aynı prepared protokole taşınması
zorunlu, ayrı bir birleşim adımıdır; bu dalın eski Vault regresyonu onun yeni
entegrasyonunun kanıtı değildir.

## Kaynak ve gerçek kullanılan API

- Dal: `codex/prepared-restore`; izole ağaç: `/private/tmp/larenor-prepared-restore`.
- Başlangıç: `1592ced762a62ec8d7a4ec2ae0fa4fe16e224606`.
- Son üretim/test biçimlendirme kaynağı: `44c3eb68d98122dae3435e7eb2da1158fb27149a`.
- Son davranış değişikliği: `5e5f3fe`; recovery bağının son düzeltmesi `1fa12a1`.
- Ana dal, auth/account controller, Server üretimi, yürütme kuyruğu ve PROGRESS
  bu iş ağacında değiştirilmedi. Push, CI yeniden çalıştırma veya cihaz kurulumu
  yapılmadı.

Yeni `BackupRestoreAccess` canlı onay ile durable kimlik doğrulamasını ayırır.
`CapturedRestoreAccess` bunu mevcut HomeSession, seçili kaynak, PIN ve Core'da
canlı doğrulanmış scope/oturum üzerinden yakalar. Ekran şu sırayı gerçekten çağırır:

1. `backupRestoreAccessFactoryProvider(expectedPin: ..., isCurrent: ...)`.
2. `BackupRepository.prepareRestore(snapshot, selection,
   conflictPolicy: ..., access: ...)`.
3. Hazırlanmış, dondurulmuş özeti gösteren gerçek onay penceresi.
4. `preparedBackupRestoreHandlerProvider(context, prepared, l10n)` üzerinden
   `ConfigurationScope.restorePrepared(...)`.
5. Queue içinde `checkBeforeHandoff()` ve tek kullanımlık
   `claimForHandoff(owner)`; sonra eski provider ağacının kapanması.
6. Ayrı Scope sahibiyle `applyAfterHandoff(owner, isCurrentBoundary: ...)`;
   gerektiğinde aynı capability'nin `recoverAfterHandoff()` işlemi.

`BackupRepository` ayrıca isteğe bağlı `recoverySourceStore` ve
`recoverySessionStore` alır. Bunlar mevcut `HomeSourcePersistence` ve
`ServerSessionPersistence` tipleridir; recovery yalnız okur. Varsayılan adapter
aynı durable `BackupStorage` üzerinden kapalı `home_source_v1` ve
`larenor_server_session_v1` anahtarlarını okur. Testte ayrı kaynak/oturum store'u
kullanılıyorsa aynı persistence nesneleri bu parametrelere verilir. Parametreler
backup'a yeni mutable anahtar veya dışarıdan bir HTTP yetkisi eklemez.

## Hedef ve sahiplik

Snapshot ve seçim, configuration queue beklenmeden kopyalanır. Read-set, değişim
listesi ve önce/sonra değerleri deep-copy ile capability'ye alınır. Sonraki nested
map/list değişikliği onaylanmış yazıyı değiştiremez. Expiry en çok beş dakikadır ve
canlı Core oturumunun sınırını aşmaz; capability yeniden kullanılamaz.

“Settings” bütünüyle cihaz verisi sayılmaz. Eski `dashboard_layout`, servis
bağlantıları, etkin servisler, kapı istasyonları ve film-gecesi ev yapılandırması
Direct hedeflerdir. Seçili Core altında bu legacy içerikler statik
`restore_target_mismatch` ile reddedilir. Yalnız izinli cihaz tercihlerini içeren
seçili içerik Core altında geri yüklenebilir. Legacy dosyanın ev verisi içeren
Settings grubu sessizce cihaz-only veya başka Core'a dönüştürülmez.

Direct ev hedefleri, HA URL/token tuple'ına da bağlanır; kaynak enum'unun Direct
kalması HA A→B değişimini gizleyemez. HA alanlarının kendisi seçilmişse yalnız
onaylanan yazı sırasındaki **tam tuple prefix'leri** geçerlidir. Her alanın bağımsız
before/after karışımı geçerli bir tuple sayılmaz. Cihaz-only hedefler Direct HA
sırlarını okumaz; Direct cihaz hedefleri Core oturumunu da okumaz.

Seçili bağlantı servislerinin tam mevcut tuple'ları ve ilgili public pending
markerları hazırlıkta ve apply boyunca yeniden denetlenir. Geç marker yeni
forward yazıları durdurur. Markerlar, source tercihi, Core session/token, PIN,
kişisel arşiv veya scoped Core layout anahtarları export/mutable restore
allowlist'ine eklenmedi. Private journal recovery marker yazmaz, silmez veya
credential tamamlama işi yapmaz.

## Durable journal ve kurtarma

Export edilen şifreli dosyanın mevcut **v1/v2 formatları değişmedi**. Ayrı private
secure-storage intent'i `backup_restore_journal_v2` kullanır. Bu, dış backup
formatının üçüncü sürümü değildir.

Envelope; rastgele işlem nonce'u, kapalı owner/scope, kaynak/hedef digestleri,
`applying|committed` fazı, kapalı anahtarlarla before/after değişimleri ve canonical
SHA-256 bütünlük kontrolünü içerir. Recovery tanığı, Core için mevcut canonical
session'ın fingerprint'ini; Direct ev hedefleri için nonce'a bağlı tam HA tuple
prefix fingerprint'lerini içerir. Bu tanıklar salt okunurdur. Token veya yeni
source/session değeri journal'dan geri yüklenmez. Journal hâlâ özel secure-storage
verisidir; seçilmiş credential hedeflerinin before/after değerleri de özel kalır.

Journal alanları/tipleri, owner, izinli anahtarlar ve her iki tarafın değeri tekrar
validate edilir. Sınır **100 değişim / 8 MiB**'dır. Yalnız doğru biçimli hash sahibi
olmak canlı yetki yerine geçmez. Apply/recovery bağlamı da yeniden okunur.

- Journal niyeti ilk forward yazıdan önce kalıcılaştırılır ve okunarak doğrulanır.
- Await edilmiş before okumasından sonra owner/durable kontrol yeniden yapılır.
  Son target taraması, daha önceki bir alanın sonraki await sırasında değişmesini
  yakalar. Commit öncesinde marker ve journal sahipliği de tekrar kontrol edilir.
- `applying` kurtarma yalnız bütünüyle mümkün bir yazı prefix'ini geriye alır;
  `committed` yalnız tüm after değerlerini doğrular. Üçüncü değerler korunur.
- Otomatik catch **ve explicit Continue**, yalnız kendi applying/committed journal
  baytlarını kabul eder. Geçerli başka bir B intent'i A tarafından benimsenmez,
  geri alınmaz veya silinmez. Aynı payload için nonce'lar da farklıdır.
- Recovery sonunda bütün hedefler tekrar okunur; journal silinmeden hemen önce
  aynı niyet ve durable kaynak/session tanıkları tekrar denetlenir.
- Boot ve Continue, artık seçili başka kaynak/HA tuple veya Core session
  (`authMutationPending`, scope/user, expiry ve exact session fingerprint dahil)
  altında eski intent'i uygulamaz. Veri ve journal unresolved bırakılır.
- Journal'ın dışarıdan kaybolması kısmi işlemi başarılı saydırmaz: explicit
  Continue yalnız tamamen before veya tamamen after ve aynı durable bağlamı
  doğrulayabilir. Yeni kaynağa geçmek onun recovery yetkisini yenilemez.
- İlk journal ACK kaybolursa veya recovery belirsiz kalırsa typed Scope hata
  ekranındaki Continue normal providerları açmaz. Başarılı exact recovery ve
  initialization sonrasında yeni provider kuşağı açılır.

**Legacy conservative recovery behavior change:** eski `backup_restore_journal_v1`
yalnız before değerlerini tutar; after/sahip çıkarılamaz. Boot'ta bütün hedefler
hâlâ before ise yalnız aynı journal temizlenebilir. Herhangi bir farklı değerde
veri ve journal korunur; tahmini rollback yapılmaz. Bu geriye uyumlu otomatik
kurtarma iddiası değildir. Eski crash-image, HA/Direct failed-rollback ve panel
regresyonları bilinçli olarak bu beklentiye uyarlandı; aktif legacy restore'un
kendi in-memory rollback testi korunur.

`ConfigurationWrites` aynı süreçteki işleri sıralar. Platform reload/readback ve
tekrar doğrulama **çok süreçli atomik CAS, dış yazarlara karşı kilit veya ABA
koruması değildir**. Tanıklığı uyuşmayan kayıt için otomatik retarget/rebase yoktur.
Yeni oturumla unresolved intent'in açık yeniden yetkilendirilmesi bu dilimde
uygulanmadı.

## Gerçek ekran ve erişilebilirlik

PIN loading/değişimi, Core/source kuşağı, eski provider kimliği, root/nested route,
opaque route dönüşü, native view focus, lifecycle, window ve AppInteraction
kontrolleri eski onayı emekliye ayırır. Onay penceresinin kendi route'u ile başka
route ayrılır. Handoff sonrasında kapalı eski ekranın callback'i meşru işlemi
iptal etmek için kullanılmaz; Scope kendi sahibi ve yaşam döngüsüyle devam eder.

Final modal, yeniden hazırlanmış hedefi, seçili grupları, “Yedekten” ve
“Bu cihazdaki mevcut veriler” başlıkları altında dondurulmuş sayıları ve conflict
politikasını gösterir. Eski decrypt-time conflict sayısıyla sessiz rebase olmaz.
Yalnız cihaz tercihleri seçiliyken sıfır oda/kart/favori satırları gösterilmez.

Gerçek fontlarla TR/EN, 320/600/1280 px, 2× metin testleri; taşma olmadığını,
48 px üstü iki eylemi ve isimli button semantics'i denetler. Tab/Enter iptalinin
sıfır restore yazısı ürettiği gerçek widget akışı vardır. SDK'nin büyük-yazı
CupertinoDialogAction yolundaki eksik button rolü ve klavye activation'ı yalnız
bu modalın özel action bileşeninde tamamlandı; başka ekranların genel dialogları
bu değişiklikle otomatik düzelmiş sayılmaz.

PNG üretimi yalnız açık `--dart-define=RESTORE_PREVIEW_DIR=...` ile yapılır.
Normal CI binary veya README ekran görüntüsü oluşturmaz. Gerçek özel çıktılar:
`/private/tmp/larenor-restore-previews/restore-{en|tr}-{320|600|1280}-2x.png`.
Root TR600/1280 ilk görsellerini açtı; etiketli son görseller aynı yerde yenilendi.

## RED → GREEN ve son yerel kanıt

Aşağıdaki gruplar birbirleriyle örtüşür; test sayıları toplanmamalıdır.

| Anlamlı sınır | RED checkpoint / gerçek runtime sonucu | GREEN |
| --- | --- | --- |
| Hazırlanmış işlem, tek kullanım, meşru provider disposal | `fb5dca7`: 1 geçti / 7 başarısız | `0e8efc8`: 8 geçti |
| Gerçek SharedPreferences optimistic cache, awaited-read retirement, final target scan, frozen nested değerler | `ea7304f`: 8 başarısız | `380ec44`: 16 geçti; 149 eski engine testi de geçti |
| Canlı/durable access, HA origin, gerçek Scope ve dosya ekranı | `64cba78`, `b153a9e`: access 2/7, origin+Scope 5/5, ekran 0/3 | `c6e693f`, `379696d`: 48 birleşik; 19 eski ekran testi |
| Geçerli replacement intent ve await-sonrası owner | `c46945d`: 4/1; bağımsız 380ec44 incelemesinde iki P2 | `9aa0ab7`, `379696d`; bağımsız exact-SHA kaynak kapanışı CLEAR |
| Opaque route dönüşünde eski onay | `7946c75`: 7/1 | `65614f9`: 8 geçti |
| Explicit Continue ownership, applying/committed son drift, nonce, frozen summary | `c671b22`: 16/5 | `5e3d304`: 31 geçti |
| Legacy before-only boot | `07c552c`: 4 başarısız | `3e5e749`: 153 ilgili geçti; panel fixture son 5e5f3fe'de aynı kurala uyarlandı |
| Son target okumasında geç marker | `d95c94d`: 9/1 | `bd502b6`: 17 geçti |
| Modal 2× semantics ve klavye | `d3c7be7`: 9/7 | `e3c96cb`: 16 geçti |
| Boot source/Core/session ve tam HA prefix | `e335500`: 3/10 | `5f2de8e`: 13 geçti |
| Journalsız Continue ve keep-existing witness | `948403b`: 13/2 | `1fa12a1`: Scope dahil 19 geçti |
| Son count başlıkları | `fdd18f5`: 1 başarısız | `5e5f3fe`: ekran + gerçek Core/legacy fixture uyumu 38 geçti |

İlk screenshot denemesindeki lazy ListView finder/semantics-handle fixture
sorunları ve geçici eksik import derleme hatası davranış RED'i sayılmadı. Son
broad ilk denemesindeki iki eski Core double gerçek canonical session/scope ile
onarılmıştır; literal `private-session` geçerli oturum olarak kabul edilmedi.

Son aynı kaynak kapısı:

- **376 PASS, yaklaşık 13 saniye**: bütün `test/features/backup`; prepared/legacy
  ConfigurationScope; HomeSource/HomeSession; SettingsGate/SettingsSplit;
  Proxmox ve movie-night backup; bu dalın mevcut ServerVault controller/screen.
- **25 sahipli Dart dosyası analyze: 0 sorun**.
- **25 dosya format: 0 değişiklik**; `git diff --check` temiz.
- LCOV satır kapsamı: transaction **457/514 (%88,91)**; captured access
  **59/60 (%98,33)**; access provider **11/11 (%100)**; Scope **144/150 (%96)**;
  BackupScreen **566/604 (%93,71)**; BackupRepository **252/255 (%98,82)**;
  PlatformBackupStorage **16/20 (%80)**. Branch coverage ölçümü değildir.

Bütün SDK işlemleri `python3 /private/tmp/larenor-flutter-check.py` ortak kilidiyle
çalıştı. Loglar `/private/tmp/larenor-restore-` önekinde
`final-related-2.log`, `final-analyze-3.log`, `final-format-3.log`,
`coverage-summary.json` ve `final-coverage/lcov.info` dosyalarıdır. RED/GREEN
ara logları aynı önekte korundu. Testler sentetik platform/depolama/HTTP seams
kullanır; gerçek HA/LAN/Core, native Keystore, fiziksel tablet veya Android E2E
çalıştırılmadı.

## Birleşimden sonra zorunlu kalanlar

Bu kaynakta `ServerVaultScreen`/`ServerVaultController` hâlâ eski raw handler ve
`repository.restore` yolunu kullanır; ayrı Vault prepared dalı birleştirilmeli,
sonra production raw caller taraması ve birleşik regresyon tekrar yapılmalıdır.
Eski handler/API burada bu birleşim için bırakıldı; güvenli typed yolun kalıcı
alternatifi diye sunulmamalıdır. Core scoped layout arşivi, unresolved intent için
açık yeniden yetkilendirme/çözüm ve yeni Android gerçek yolculuk/CI kabulü ayrı
sınırlar olarak açık kalır. Bu dosya S08.5'in genel kabul sayısını artırmaz.
