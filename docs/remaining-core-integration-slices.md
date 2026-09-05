# Core/Client bütünleştirmesinde sıradaki somut dilimler

**5 Eylül 2026 · Durum: S06 ilk iki dilim ve kaynak temelinin 4/6 alt adımı kabul edildi.** Bu belge yeni özellik seçimi
değildir; [S06–S09](PROGRESS.md#sıradaki-geliştirme-paketleri) ve
[B1/B3 temellerinin](feature-expansion-plan-2026-09-05.md) açık bağlantılarını
ayrıntılandırır. Aşağıdaki kutular teslim kanıtı oluşmadan tamamlanmış sayılmaz.

## S06: tek kurulumdan çalışan bileşenlere

Mevcut katalog, süreli önizleme, kalıcı gereksinim işleri, Linux IPC ve isteğe
bağlı Docker sürüm kontrolü korunur. [worker.py](../server/larenor_server/plugins/worker.py)
dar create/start ve sahiplik ilkelleri içerir; bunların ürün API'sinden
kuruluma açıldığı anlamına gelmez. Kalıcı volume/mount hazırlığı desteklenmez.
Journal'daki `(job, step)` anahtarı tek işte birden çok bileşenin aynı adlı
adımını ayıramaz; kurulum koordinatörü bunu alt işlemlere ayırmalıdır.

| Sıra | Açık teslim | Kabul kanıtı |
| --- | --- | --- |
| 1 | **Uygulandı:** tek Larenor kurulumu için birleşik plan ve kalıcı hazırlık kaydı | Altı bileşen, benzersiz işlem/adım kimlikleri, şifreli geçmiş, idempotent oluşturma, restart ve iptal; Client admin ekranı ve ortak HTTP sözleşmesi. [Kanıt ve sınırlar](media-preparations-implementation-2026-09-05.md); gerçek kurulum hâlâ kapalı |
| 2 | **Uygulandı, test/yayın kapıları geçti:** birleşik gereksinim işleri, worker/daemon bağlamı ve depolama gözlemi | [Ayrı bağlam sonuçları, 49.152 MiB toplam disk bütçesi, kalıcı kontrol/geçmiş/iptal ve Client](media-inspections-implementation-2026-09-05.md). Port/alıcı ağı kanıtı yoksa `unknown`; kurulum kapalı |
| 3 | [Altı alt adıma ayrılan sahiplikli kaynak hazırlığı](media-resource-preparation-plan-2026-09-05.md), **4/6 kabul** | Saf plan, kalıcı journal, imaj/journal ve ağ/journal yazılımı kabul edildi. Appdata gerçek yetki/yazma ve iki mimarili gerçek kaynak kurulumu açık |
| 4 | Dar, süreli kurulum adımlarının API/işçiye bağlanması | Her yan etkide güncel yetki/oturum/iptal/katalog kontrolü; serbest Docker seçenekleri yok; belirsiz create yanıtında sahiplik uzlaştırması |
| 5 | Özel bootstrap ve otomatik servis eşleştirmesi | Kimlik bilgilerinin Server'da üretilip şifreli saklanması; ilk kullanıcı API'sinin denetimsiz LAN'a açılmaması; medya adres/anahtar/kütüphanelerinin otomatik eşleşmesi |
| 6 | Tamamlama, iptal ve kurtarma | Create/start makbuzu yerine doğrulanmış servis sonucu; iptal/hata veriyi otomatik silmez. İki mimarili geçici Linux CI'da gerçek bileşen kabulü |

Sadece `/version` okumak çalışma yetkisini, mount geçerliliğini, portu veya
HomePod keşfini doğrulamaz. Bütünleşik Music Assistant ve medya motorlarının
aynı Larenor kurulumu altında yönetilmesi S07'nin teslimidir. Eski MA-only
Compose dosyası bu koordinatörün yerine geçirilmez. Kullanıcının ev sunucusuna
kurulum en sonda manuel yapılır.

### Dilim 2'nin ilk uygulama ve kabul sırası

İlk artış, mevcut doğrulanmış Unix bağlantısına bağlı **daemon bağlamı
gözlemi** olur. `docker_engine` API/platform sonucunun anlamı korunur;
worker'ın yerel disk ölçümü ile daemon'ın mount/network/process-root bağlamı
ayrı kanıtlardır. Bu gözlem kaynak ayırmaz ve kurulum yetkisi vermez.

| Sıra | Yeni kabul senaryosu | Beklenen sonuç |
| --- | --- | --- |
| 1 | Doğru UID/API/platform, farklı worker/daemon namespace'i | Worker'daki dizin veya boş port daemon için uygun sayılmaz; API kontrolü geçebilir, host bağlamı doğrulanmamış kalır |
| 2 | Erişilemeyen namespace/root, proxy peer, değişen süreç kimliği veya süre aşımı | Sonuç `unknown`; ham PID/yol/hata yayılmaz. Ortak 5 saniyelik IPC bütçesi alt gözlemlerde yeniden başlatılmaz |
| 3 | Aynı yol metni farklı process root/dizine işaret ediyor veya mount/dizin kimliği değişiyor | Önceki dosya sistemi/kapasite kanıtı yeni hedefe taşınmaz |
| 4 | Altı child aynı 16 GiB dosya sisteminde ayrı ayrı 8 GiB kontrolünü geçiyor | Birleşik 49.152 MiB isteği başarısız olmalı. Her child'ın bütçesi her ayrı yazılabilir dosya sistemine bir kez eklenir; config/cache ve kök alias'ları alanı çoğaltmaz, salt okunur Jellyfin görünümü yazma bütçesi eklemez |
| 5 | Bağlam ve API uygun, port/alıcı için bağımsız kanıt yok | `port_availability` ve `receiver_network` hâlâ `unknown`; gözlem bind/listen, container start veya alıcı keşif trafiği üretmez |

[DockerProbe](../server/larenor_server/plugins/docker_probe.py) tek doğrulanmış
socket'e bağlı peer/process/namespace/root gözlemini, açık v3 executable
politikasıyla yapar. [HostInspector](../server/larenor_server/plugins/host_preflight.py)
artık altı child'ın bütçesini dosya sistemi başına birlikte hesaplar ve dizin
kimliğini ölçüm sonrasında yeniden doğrular. Sonuç modeli, Client tablet
anlatımı ve [ortak gerçek HTTP sözleşmesi](../contracts/media-inspections.v1.json)
birlikte eklendi. `62b2054` tam yerel/uzak test ve imzalı APK teslimini geçti;
S06 yazılım kabulü **2/6**. Port/alıcı ağı kanıtı ve gerçek kurulum ayrı kalır.

## B3/S08: kimliği gerçek Client kapsamına bağlama

Server'ın kalıcı Core/ev kimliği hazırdır. Ana Client ekranı hâlâ ayrı HA
oturumuna ve bazı bağlamsız yerel kayıtlara dayanır. Sadece kimlik modelini
Client'a eklemek eski ev verisinin yeni Core'da görünmesini engellemez.

- [x] **Doğrulanmış oturum (S08.1, fc632b6 tam CI):** Core/ev bağlamını oturumla atomik sakla. Başarılı
  login/refresh/password POST'undan sonra context GET başarısız olursa yeni
  tokenları koru, yalnız bağlam okumasını tekrar dene; eski refresh tokenını
  tekrar kullanma. Bağlam doğrulanmadan ev kapsamını açma.
  [Kod/test/yayın kanıtı](client-context-implementation-2026-09-05.md);
  aşağıdaki global provider/cache sınırı henüz açık.
- [x] **Geçiş ve uyumluluk (S08.2, 19dbcbe tam CI/APK 91):** İlk parola aşamasında korumalı bağlam API'sini
  çağırma; parola değişiminden sonra doğrula. Eski Server 404 veya bozuk yanıt
  halinde URL'den kimlik türetme. Saklanan kimlik tek başına yetki sayılmaz.
  `67cb058` ile yalnız bağlam GET 404 için adres kontrolü/güncelleme açıklaması
  eklendi; 531 regresyon ve son tam CI geçti. [Kapsam ve kanıt](client-context-compatibility-2026-09-05.md).
- [ ] **Ekran/provider sınırı (S08.3, main içinde, CI kabulü bekliyor):** `(coreId, homeId, userId)` değişince eski ev
  ekranını, ikincil rotaları, istekleri, WS aboneliklerini ve callback'leri
  kapat. Aynı bağlamdaki token yenilemesi gereksiz ekran sıfırlaması yapmaz.
  Hesap controller'ı bu yeniden kurulan alt ağacın dışında kalır.
  `10d3eb1` → main `4ba7024` içinde kalıcı doğrudan HA/Core seçimi,
  parentless runtime ve boşta ekranı dahil veri sınırı uygulandı; 50 odaklı ve
  1.093 ilgili test ve dashboard ile birleşik 2.815 Flutter testi/analiz geçti.
  Gerçek uygulama başlangıcıyla beşinci emülatör
  akışı eklendi; toplam dokuz cihaz senaryosunun yeni CI kabulü bekleniyor.
- [ ] **Kalıcı cache:** Dashboard ve diğer ev verilerini bağlamlı anahtarlara
  taşı. Eski `dashboard_layout`, `ha_base_url` ve `ha_token` verisini yeni
  Core'a sessizce bağlama; yalnız açık önizlemeli taşıma uygula.
- [ ] **Restore ve logout:** Restore önizlemesi ve journal hedefi doğrulanmış
  bağlama bağlı olsun; inceleme A evinde, onay B evinde yapılamasın. Yedek
  oturum/bağlam kimliği geri yüklemesin. Logout kapsamı kapatsın ve tokenı
  silsin; diğer kayıtları topluca silmek yerine görünmez bıraksın.
- [ ] **Merkezi adaptörler:** HA ardından medya/ağ kaynakları, komut yetkileri
  ve olay akışını Server'a taşı; mevcut direct-HA yolu otomatik fallback olup
  eski ev verisini geri getirmesin.

Kabulde aynı URL ve kullanıcı kimliği altında değişen Core, ağ kesintisi,
gecikmiş cevap, restart, restore sırasında bağlam değişimi ve logout ayrı
senaryolardır. Bunlar [hesap testlerine](../test/features/server/server_account_test.dart),
[provider sınırına](../test/features/ha_client/connection_scope_providers_test.dart),
[dashboard depolamasına](../test/features/dashboard/dashboard_repository_test.dart)
ve [restore testlerine](../test/features/backup/backup_repository_test.dart)
eklenir. Çoklu ev/federasyon F19'un ayrı kabulüdür.
