# S06.3e — kontrollü özel ağ oluşturma taşıması

5 Eylül 2026. [Etki/kurtarma planının](network-effect-bridge-plan-2026-09-05.md)
ilk parçası `UnixNetworkCreator` ve ortak HTTP katmanındaki dar POST yeteneğidir.
Bu özel worker bağımlılığı API, IPC, Client veya CLI üzerinden açılmaz.
`installAvailable=false` korunur; journal bağlantısı ayrıca geliştirilmektedir.

## Davranış

- Tam bağlı kaynak planı ve başlanmış journal intent'inden canonical gövde
  yeniden türetilir. Tek hedef `POST /v1.47/networks/create`; bridge/local,
  internal=true ve kapalı sabit profil. Serbest isim, Options, IPAM, sürücü,
  Client gövdesi veya genel Docker proxy yoktur.
- Her işlem yeni Unix bağlantısında peer UID, socket kimliği ve aynı
  bağlantının API/platform sürümünü doğrular. Zorunlu `before_dispatch`
  callback'i bu sürüm kontrolünden sonra, POST öncesinde literal `True`
  vermelidir. Gövde/istek, socket kimliği, iptal ve süre tekrar denetlenir.
- Callback güvenilen senkron worker bağımlılığıdır; gerçek actor, daemon,
  host veya journal lease yetkisini kendisi üretmez. Keyfi kodu süreyle
  kesebilen bir sandbox değildir. Gelecek koordinatör gerçek yetkiyi ve
  toplam iş bütçesini sağlamakla yükümlüdür.
- Varsayılan toplam 10 saniye, idle 2 saniye; 128 chunk ve 4 KiB cevap
  sınırı. Cevapta tamamlanmış 201, tam 64 hex `Id`, tekil ve boş `Warning`
  beklenir. Bu ACK sahiplik veya hazır olma makbuzu değildir; ayrıca yeni
  list/inspect gözlemi gerekir. EOF framing yalnız mevcut imaj pull şekli
  için kalır; ağ POST'u için açılamaz.
- Kayıp cevapta otomatik tekrar, silme, container attach/start veya journal
  yazımı yoktur. İptal veya hata sonrasında bir ağın oluşmuş olabileceği
  yok sayılmaz; read-only reconciliation gelecek journal köprüsündedir.
- Dış hata mesajları sabit kodlardır. Engine Warning, raw cevap, endpoint
  adresi veya host dosya yolu kullanıcının hata metnine taşınmaz.

## Kanıt ve durum

İzole `codex/network-effect-bridge` dalında `ee0d0c1` RED → `ccc9137` ilk
GREEN → `aa23437` sınır regresyonları. Üretim kaynağı ilk GREEN sonrasında
değişmedi. `8767608` ile yerel main içine, RED/GREEN geçmişi korunarak
birleştirildi. Bu birleştirme henüz uzak CI kabulü değildir.

**741 ilgili test geçti, dört Linux testi Mac'te atlandı** (45,21 saniye).
Geçici gerçek Unix listener ve SQLite fixture'ları kullanıldı; ev Docker
sunucusuna bağlanılmadı. Kaynak/intent/nonce değişimi, callback'in literal
True/exception/iptal/süre sonuçları, socket değiştirme, bozuk veya kısmi ACK,
framing/chunk/gövde sınırları, sabit allowlist ve mevcut imaj/read davranışı
sınandı. İlk iki harness hatası (Mac socket yolu uzunluğu ve pytest'in ayrılmış
parametre adı) testlerde düzeltildi; ürün hatası olarak sunulmaz.

Coverage.py: yeni `network_effects` **74 statement / 4 dal, %100**; ortak
HTTP **%98**, imaj **%99**, ağ okuma **%100**. Root ve bağımsız ikinci
incelemede yeni P1/P2 kalmadı. Tam birleştirilmiş regresyon ve kaynak commit'ine
ait Linux/yayın sonucu [PROGRESS](PROGRESS.md) içinde ayrı kaydedilir.

S06.3e bütünü, gerçek Engine kabulü ve otomatik medya kurulumu bu taşıma ile
tamamlanmış sayılmaz. Bir sonraki parça; kalıcı begin → read → güncel yetki →
tek create → yeni list/ACK-ID inspect → journal reconciliation akışıdır.
Yeniden başlayan veya sonucu bilinmeyen işlem yalnız okuyarak toparlanmalıdır.

Birleştirilmiş `876760827c1887cff7ddd5ffb29d682761759281` kaynağında tam
Server **2.454 geçti / 7 Linux atlaması** (349,75 saniye); tam Client
**2.739 test geçti** (3:50) ve tam analiz temiz. Commit aralığının gitleaks
taraması ve kuyruk doğrulaması/24 regresyonu geçti. Bu uzak Linux veya ev
kurulumu kanıtı değildir. İlerleyen journal köprüsü bu kaynakta bulunmaz.
