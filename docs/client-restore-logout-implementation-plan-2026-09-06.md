# S08.5 — geri yükleme, çıkış ve hedef sahipliği

6 Eylül 2026. Başlangıç bağımlılığı S08.4, `1c2db57` / APK 100 ile kabul
edildi. Bu belge uygulama sırasıdır; aşağıdaki açık maddeler tamamlanmış test
veya ürün davranışı sayılmaz. Mevcut [kuyruk](execution-queue.json) kapsamı korunur.

| Sıra | Dilim | Somut sonuç ve kabul |
| --- | --- | --- |
| 1a | Kalıcı logout niyeti | Gerçek secure store silmesi ve uzak logout başarısızsa eski normal kaydın restart'ta sessiz kullanılması engellenir; kalıcılık hatası açık kalır. Nesil/yazı sırası yeni login'i korur. |
| 1b | Logout sonucu görünürlüğü | Core hesabı kapatılınca yeni ana ekranda gecikmiş storage/logout hatası görünür; kapatılan hesap ekranına bağlı kalmaz. |
| 2a | Hedefe bağlı geri yükleme hazırlığı | Snapshot/seçim/çakışma kararı ve gerçek hedef okuma kümesi dondurulur; kaynak/hesap/PIN/route/target değişimi eski onayı kapatır. |
| 2b | ConfigurationScope'a devir | Yazı kuyruğu sahipliğinde son canlı UI kontrolü yapılır; ardından eski providerların kasıtlı kapanması onaylı işlemi yanlışlıkla iptal etmez. Hedef yeniden okunur, tek kez uygulanır. |
| 2c | Private journal v2 | Kapalı hedef listesi, before/after, applying/committed ve durable readback. Başkasının yeni değeri üzerine kör rollback yok; belirsiz ACK otomatik tekrar yazmaz. |
| 3 | Server kasasından geri yükleme | ServerVaultScreen ve takeRestore aynı prepared hedef/handoff/journal yoluna geçti; hesap/vault revision ve yerel hedef birlikte korunur. Yerel kanıt79f313b, erişilebilir modal eklemesi1ab3483. Birleşik test ve teslim kabulü ayrıca gereklidir. |
| 4 | Tarihsel journal kararı | Eski v1 yalnız before içerir. After/owner uydurulmaz: mevcut değer before ile farklıysa veri ve journal korunur, açık recovery hatası kalır. Yerel regresyon ve UI kanıtı4667456; bu bütün eski yarım işlemlerin otomatik çözülebileceği iddiası değildir. |
| 5 | Core düzeninin açık yedeği | Mevcut scoped repository revision/fingerprint sınırına bağlı küçük ayrı format; cross-home veya Direct kopya sessiz eşleme yapmaz. |
| 6 | Birleşim ve teslim | Gerçek platform/repository, actual ConfigurationScope/HomeSessionScope UI, EN/TR tablet/DeX, Android yolculuğu ve exact-source CI + APK. |

1 ve 2 bağımsız dallarda paralel yürütülür. İlk dosya biçimi v1/v2 kalır;
Core düzeni kapsamı ayrı açık teslimdir. Backup oturum, Core kimliği, kaynak
seçimi, PIN, auth marker veya kişisel sağlık/fotoğraf içeriklerini taşımaz.

Settings grubunun tamamı cihaz ayarı değildir: enabled_services, diafon ve
film gecesi Direct ev bağlarıdır. Core'da seçili grup bu alanları içeriyorsa
sessiz filtreleme veya legacy hedefe yazma yapılmaz; açık hedef uyuşmazlığı
verilir. Cihaz hedefi ve ev hedefi önizlemede ayrılır.

Logout için gerçek SecureServerSessionStore + platform map üzerinde yazma/
silmenin etkiden önce ve sonra hata vermesi, pending initialize, çift logout,
gecikmiş login ve restart sınanır. Bütün kalıcı yazma/silme ve uzak revoke
birlikte başarısızsa süreçler arası garanti mümkün değildir; bellek scope'u
hemen kapanır ve başarısızlık görünür kalır. Böyle bir durum başarı sayılmaz.

Restore için olumlu gerçek provider-dispose akışı kadar A→B, kuyrukta bekleme,
PIN reload/rotation, eski Confirm, durable preference reload, üçüncü hedef
değeri ve her journal/commit/silme kesilme noktası da sınanır. Canlı ev işlemi
veya fiziksel disk/Keystore process-death kabulü sentetik testlerden çıkarılmaz.

## Uygulama notu

Logout1a/1b, `2911ac9` üzerinde25 odaklı/1.547 ilgili test ve bağımsız son
incelemeyle yerelde geçti; kendi CI kabulü açık. İlk restore dalı yalnız
BackupScreen'i yeni prepared yola bağlar. ServerVaultScreen274 ve
ServerVaultController.takeRestore243'teki eski closure ayrı zorunlu3.
adımdır; tarihsel handler'ı geçici korumak bu yolu güvenli tamamlandı saymaz.
Yeni handler/access ortak kullanılarak tekrar bir restore motoru yazılmaz.

## 6 Eylül yerel birleşim

Prepared dosya restore `4667456` ve Server kasası `79f313b`, erişilebilir
modal düzeltmesi `1ab3483` ile birlikte incelemeden geçti. `lib` kaynaklarında
raw backup restore handler'ının uygulama içi tüketicisi kalmadı; iki gerçek
ekran prepared yolu kullanır. Tarihsel handler/repository API'si eski birim
testleri için korunur ve yeni kullanıcı akışında çağrılmaz.

Dosya dalının376 ve Vault dalının387 testini toplamak doğru değildir. Modal
eklemesinin73 ilgili testi de ayrı alt kümedir. Yeni birleşimin tüm Client
koşusu, yeni kişi API'sinin tüm Server koşusu ve kendi exact-source CI'si
ayrı izlenir. [Dosya kanıtı](prepared-backup-restore-implementation-2026-09-06.md),
[Vault kanıtı](server-vault-prepared-restore-implementation-2026-09-06.md).

Adım5 Core düzeninin açık yedeği sürer. İlk ayrı sözleşme dilimi pasif kişisel
Core oda düzenini, aynı Core/ev/kullanıcı bağını ve değişen hedefin reddini
ele alacak. Mevcut Direct dosya biçimi veya private journal sessiz genişlemez.
Model, şifreli codec, kalıcı kayıt/geri yükleme ve gerçek tablet UI kabulü
ayrı doğrulanmadan bütün S08.5 kapatılmayacak.
