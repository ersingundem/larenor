# Core/Client bütünleştirmesinde sıradaki somut dilimler

**5 Eylül 2026 · Durum: S06 dilim 1 uygulandı; dilim 2 sırada.** Bu belge yeni özellik seçimi
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
| 2 | Worker/daemon host bağlamı, depolama ve ağ doğrulaması | Worker namespace'inde boş portun daemon hostunda uygun sayılmaması; dosya sistemi ve alıcı keşfi kanıtı yoksa sonuç `unknown` |
| 3 | Sahiplikli kaynak hazırlığı | Digest ile imaj edinme, veri dizini/mount ve özel kontrol ağı; yabancı kaynağı sahiplenmeme ve yarıda kalınca aynı kaynakla devam |
| 4 | Dar, süreli kurulum adımlarının API/işçiye bağlanması | Her yan etkide güncel yetki/oturum/iptal/katalog kontrolü; serbest Docker seçenekleri yok; belirsiz create yanıtında sahiplik uzlaştırması |
| 5 | Özel bootstrap ve otomatik servis eşleştirmesi | Kimlik bilgilerinin Server'da üretilip şifreli saklanması; ilk kullanıcı API'sinin denetimsiz LAN'a açılmaması; medya adres/anahtar/kütüphanelerinin otomatik eşleşmesi |
| 6 | Tamamlama, iptal ve kurtarma | Create/start makbuzu yerine doğrulanmış servis sonucu; iptal/hata veriyi otomatik silmez. İki mimarili geçici Linux CI'da gerçek bileşen kabulü |

Sadece `/version` okumak çalışma yetkisini, mount geçerliliğini, portu veya
HomePod keşfini doğrulamaz. Bütünleşik Music Assistant ve medya motorlarının
aynı Larenor kurulumu altında yönetilmesi S07'nin teslimidir. Eski MA-only
Compose dosyası bu koordinatörün yerine geçirilmez. Kullanıcının ev sunucusuna
kurulum en sonda manuel yapılır.

## B3/S08: kimliği gerçek Client kapsamına bağlama

Server'ın kalıcı Core/ev kimliği hazırdır. Ana Client ekranı hâlâ ayrı HA
oturumuna ve bazı bağlamsız yerel kayıtlara dayanır. Sadece kimlik modelini
Client'a eklemek eski ev verisinin yeni Core'da görünmesini engellemez.

- [ ] **Doğrulanmış oturum:** Core/ev bağlamını oturumla atomik sakla. Başarılı
  login/refresh/password POST'undan sonra context GET başarısız olursa yeni
  tokenları koru, yalnız bağlam okumasını tekrar dene; eski refresh tokenını
  tekrar kullanma. Bağlam doğrulanmadan ev kapsamını açma.
- [ ] **Geçiş ve uyumluluk:** İlk parola aşamasında korumalı bağlam API'sini
  çağırma; parola değişiminden sonra doğrula. Eski Server 404 veya bozuk yanıt
  halinde URL'den kimlik türetme. Saklanan kimlik tek başına yetki sayılmaz.
- [ ] **Ekran/provider sınırı:** `(coreId, homeId, userId)` değişince eski ev
  ekranını, ikincil rotaları, istekleri, WS aboneliklerini ve callback'leri
  kapat. Aynı bağlamdaki token yenilemesi gereksiz ekran sıfırlaması yapmaz.
  Hesap controller'ı bu yeniden kurulan alt ağacın dışında kalır.
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
