# S08.7 — Merkezi Home Assistant adaptörü

6 Eylül 2026. Uygulama hazırlığı; kabul veya çalışan adaptör iddiası değildir.
S08.5/S08.6'nın kendi CI kabulü önkoşuldur. İncelenen Server/Client kaynağı
`38e78a34bc554c39647a8616b905aa2f9c9627b9`; araştırma gerçek eve bağlanmadı.
Üç teslim aynı adaptörü tamamlar. Salt okuma altparçası S08.7'yi kapatmaz.

## Kullanılacak mevcut yapı

- `server/larenor_server/services/`: şifreli HA bağlantısı, revision ve admin
  probe'u. İsim değişikliği de revision'ı artırır; ilk sürüm bunu konservatif
  geçersizleştirme olarak kabul edebilir. Admin-only bağlantı API'si üyeye açılmaz.
- `server/larenor_server/home_resources/`: sabit ref, kayıt/ACL revision'ları
  ve güncel transaction içinde yetki. Mevcut `write` izni gelecek komutlar
  için ayrılmıştır; ikinci bir genel ACL sistemi oluşturulmaz. Bir DTO'daki
  `canWrite` veya geçmiş `authorize()` sonucu, gelecekteki dispatch izni değildir.
- `HomeSessionScope` ve güncel account/context/generation: Core runtime sınırı.
  Core kaynak ekranı metadata gösterir. Direct HA providerları, credential
  deposu ve ağ istemcileri yeni Core yolunda oluşturulmaz.
- Kişisel Vault ortak HA token deposu yapılmaz. Kullanıcı, Core/ev ve resource
  kimlikleri birbirinin yerine kullanılmaz.

## 1. Açık kaynak bağlama ve typed durum

Server'da `home_assistant/` altında model, binding, transport, snapshot/cache
ve API modülleri; Client'ta `features/core_ha/` altında karşılık gelen model,
API, controller/provider ve seçilen kaynak ekranı. Mevcut Core resource
satırından küçük bir giriş; genel Direct dashboard'a Core override eklenmez.

Admin mevcut HA service kaydı ve Core resource için süreli preview/onay yapar.
Server kendi opaque source/binding kimliğini üretir; Core/home, bağlantı,
upstream entity ve service/resource/ACL revision'ları bağlanır. Bağlantı
değişirse eski binding sessizce yeni upstream'e taşınmaz. URL, `/api/config`,
HA sürümü veya başarılı probe fiziksel kurulum kimliği olarak sunulmaz.
Authenticated HA principal gerekiyorsa ayrı sınırlı WebSocket akışıyla
doğrulanır; HA kullanıcı ID'si Core hesabı veya hane kişisi değildir.

İlk gerçek fixture tek switch olabilir; üretim adaptörü domain başına
kopyalanmaz. Sürümlü ortak projection ve kapalı durum/capability türleri
kullanılır. Ham attributes, URL'ler, servis parametreleri ve sırlar Client'a
aktarılmaz. Önerilen resource snapshot yolu:
`GET /api/v1/home-assistant/{coreId}/{homeId}/resources/{resourceId}/snapshot`.

Hazırlık transaction'ında güncel oturum/kullanıcı, resource ACL ve
service/binding revision birlikte okunur. Sınırlı ağ okumasından sonra aynı
bağlar tekrar denetlenir; ancak sonra typed sonuç yayınlanır/cache'e girer.
Eksik veya yetkisiz resource aynı404; yetkisiz istekte upstream çağrısı sıfır.
İç service okuma seam'i gerekiyorsa aynı DB bağlantısına dar kapsamla eklenir.

Snapshot ref, şema, binding/record/ACL revision, gözlem zamanı ve sınırlı
kalan TTL taşır. İlk cache bellekte ve Core/ev/kullanıcı/resource/binding
kimliğine bağlıdır. Boyut, kayıt kotası ve TTL sözleşme testinde sayısal olarak
belirlenir; bu plan tahmini sınırları uygulandı saymaz. Her cache okumasında
Server yeniden yetkilendirir. Client monotonic süre kullanır ve istek süresini
kalan TTL'den düşer; wall-clock kayması tazeliği uzatamaz. Bilinen yetki/kaynak
kaybı veriyi kapatır. Offline eski gözlem gösterilecekse açıkça eski olarak,
komutsuz ve kesin saklama süresiyle gösterilir.

HA'nın [REST sözleşmesi](https://developers.home-assistant.io/docs/api/rest/)
tek entity durumunu okumayı destekler. İlk seçili-resource akışı tüm evin
durumunu gereksiz çekmez. Principal ve sonraki gözlem ilişkileri için
[WebSocket sözleşmesi](https://developers.home-assistant.io/docs/api/websocket/)
ve [auth uygulaması](https://github.com/home-assistant/core/blob/dev/homeassistant/components/auth/__init__.py)
uygulama sırasında sabit kaynak/sürümle tekrar değerlendirilir.

## 2. Komut, kalıcı makbuz ve gözlenen sonuç

Aynı source/binding üzerinden kapalı action ve argument modelleri kullanılır.
İlk turn_on/turn_off akışı, ortak komut sözleşmesinin ilk desteklenen
capability'sidir. Server güncel resource WRITE, kaynak/capability, oturum ve
beklenen revision'ları dispatch öncesinde doğrular. Eski Client callback'i
bu denetimi atlatamaz.

Komuttan önce kalıcı intent yazılır. Immutable request ID aynı payload ile
tek işlemi tanımlar; aynı ID ve farklı payload409 verir. Yanıt kaybı veya
yeniden başlama halinde durum unknown kalır; otomatik tekrar/rollback yoktur.
Client ayrı sonuç GET'iyle sorgular. Provider'ın kabulü, yeni hedef durum
gözlemi ve fiziksel sonuç aynı başarı etiketi altında birleştirilmez. HA
context veya sonradan eşleşen durum tek başına nedensellik kanıtı değildir.

## 3. Direct ayarlarının açık aktarımı ve kabul

Eski HA bağlantısı/sırları, alan/entity/scene/service seçimleri ayrı PIN
korumalı preview/onayla aktarılır. Eski Direct tuple fingerprint'i, yeni
source binding ve hedef revision birlikte tekrar denetlenir. Desteklenmeyen
öğeler görünür kalır; web-origin izinleri sessizce dahil edilmez. Core hata
veya offline durumunda otomatik Direct fallback oluşmaz.

Ortak `contracts/home-assistant.v1.json`, gerçek Server HTTP test çıktısından
üretilip Client decoder testlerinde kullanılır. Yeni testler aşağıdakileri
kanıtlamadan bu adım tamamlanmaz:

- SQLite/auth HTTP ile ACL, farklı ev/kullanıcı, service/source değişimi;
  gecikmiş yanıt sırasında logout/demotion/iptal ve yetkisiz outbound0.
- Büyük/bozuk/secret-echo upstream yanıtları, TTL/kota/saat kayması ve
  yetki kaybında cache geçersizleştirme; HA401 ile Core401 ayrımı.
- Kayıp ACK, aynı request ID, restart ve belirsiz komutta sıfır yeniden dispatch.
- Gerçek HomeSessionScope ile ayrı container/route/PIN/native focus ve stale401;
  Core ekranında Direct credential/REST/WS sayaçları sıfır.
- Tablet kaynak→durum→komut→makbuz ve migration preview/cancel/confirm akışları;
  aynı kaynağın tam yerel test, Linux CI, Android E2E ve bağımsız APK kanıtı.

Gerçek HA/ev komutları bu yazılım çalışmasının parçası değildir. Cihaz sonucu
ve gerçek ev kurulumu, mevcut salt okunur sınır ve son manuel kabul altında kalır.
