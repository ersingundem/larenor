# S08.4 — Direct Proxmox kaydı ve açık kurtarma

6 Eylül 2026. İzole dal `codex/direct-proxmox-boundary`, başlangıç
`a2658ec902aea9b358e1ff0e10e093db773de238`.
Üretim dondurması `996bbaac4a51320d0177729a1e87fa0a4014d733`.
Bu paket mevcut Proxmox Direct tüketicisini sınırlar; bütün S08.4'ün veya
Core üzerinden Proxmox kontrolünün tamamlandığı anlamına gelmez.

## Altı alan, kaynak ve belirsiz yazı

`ProxmoxCredentialsStore`, mevcut `DirectCredentialRecord` içindeki kapalı
Proxmox host, port, username, realm, password ve allowSelfSigned alanlarını
kullanır. `proxmox_connection_pending_v1` ilk alan etkisinden önce yazılır;
bütün alanlar ve güncellik kontrolleri tamamlanınca kaldırılır. Non-null
marker, boş veya beklenmedik metin olsa da, tuple okumasını statik
`pending_mutation` ile engeller. Platform okuma/yazı hataları gizli değerleri
veya ham platform mesajını kullanıcıya taşımaz.

Altı alanın tamamının bulunmaması yalnız gerçekten boş kayıtta normaldir.
Herhangi bir alan eksik veya boşsa açık kurtarma gerekir. Port yalnız
kanonik ondalık `1..65535`; TLS tercihi yalnız tam `true` veya `false` olabilir.
Eski beş alanlı kaydın eksik TLS değerini otomatik kabul etmesi ve bozuk portu
8006'ya çevirmesi güvenli olmadığı için korunmadı. Eksik/bozuk kayıt istemci
oluşturmaz, ticket almaz ve kendiliğinden silinmez veya dönüştürülmez. Geçerli
port/realm ve açık self-signed tercihi korunur; HTTPS/form endpoint ayrıştırma,
cookie/ticket protokolü, VM/container/power ve diğer API yöntemleri değişmedi.

Üretim store/provider ilk `DirectHomeAccess` sahibine bağlıdır. Core,
başlangıç pending/error ve eski kaynak nesnesi read/save/clear veya login
başlatamaz. Direct → Core → Direct aynı yapılandırmayla dönse bile eski
nesne ve route source closure yeniden yetki kazanmaz. Opsiyonel `access`
ve `isCurrent` parametreleri mevcut kapsamsız test/store çağrılarını korur;
üretim bağlantısı kaynağı daima bağlar. Her await sonrasında kaynak, işlem
kuşağı ve varsa action callback yeniden denetlenir. Ortak helper,
ConfigurationWrites, backup allowlist'i ve diğer servisler değiştirilmedi.

Kısmi host yazısından sonra eski parola birleşimi yeni store'da da okunamaz.
Son marker kaldırma yanıtı kaybolursa tam yeni kayıt gerçekte kalmış olabilir;
controller yine AsyncError verir, iyimser bağlantı ve otomatik reader login'i
yayımlamaz. Açık tam yeniden bağlanma veya clear ile kurtarma mümkündür.
Otomatik retry, rollback, marker cleanup ya da başka servisin marker'ını
kaldırma yapılmaz. Native Keystore transaction/fsync veya fiziksel restart
kanıtı değildir.

## Ticket, form ve yetkili okumalar

Sign-in mevcut adapter ile ticket login ve ardından gerçek node GET
doğrulamasını tamamlar; yalnız login yanıtı başarı sayılmaz. Geç ticket/node
cevabı kaynak veya pencere yetkisi kaybolduktan sonra yeni istek ya da alan
yazısı başlatamaz. `cancelSignIn(owner)` yalnız aynı callback kimliği ve
güncel işlem kuşağının doğrulama istemcisini kapatır. Eski/farklı owner yeni
login'i veya normal Direct reader'ı kapatamaz. Önceden gönderilmiş HTTP
isteğinin geri alındığı iddia edilmez.

Connect ve Nodes eylemleri AppInteraction epoch, lifecycle, TickerMode,
current route, ilk Direct kaynağı ve aynı native view'ın focus durumunu
denetler. Eski connect/clear/discovery/TLS/refresh callback'i yeni taslakla
veya tekrar odaklanmayla canlanmaz. Başka view'ın focus olayı yok sayılır;
observer dispose sırasında kaldırılır. Yetkili Direct pasif okumalar yalnız
formun odağı veya idle eylem yetkisi kaybolduğu için kapatılmaz. Gerçek normal
reader'ın unfocused durumda node okuması pozitif testte korunur. Bu özellik
global native-focus paketini değiştirmez veya onun teslim kanıtı değildir.

Riverpod aynı notifier nesnesini korusa bile dış provider reload'un ilk
AsyncLoading bildirimi form kuşağını eşzamanlı emekliye ayırır. Yalnız bu
formun signIn çağrısındaki tek eşzamanlı own-loading geçişi hariç tutulur;
giriş sürerken gelen dış reload da eski callback'i kapatır. Başarılı
standalone bağlantı yalnız hâlâ current olan kendi route'unu pop eder.

Gerçek Settings PIN → Integrations → Manage Integrations → Proxmox yolu
pending/eksik kayıt için boş altı alanlı kurtarma formunu açar. Self-signed
varsayılanı kapalıdır; eski hassas alanlar doldurulmaz, LAN discovery kurulmaz.
Kullanıcı tam kayıtla yeniden bağlanır veya yalnız kayıtlı bağlantıyı kaldırır.
Clear sonrası boş form ve Done/Bitti kalır; otomatik provider invalidate,
discovery veya login başlamaz. İki yeni EN/TR anahtar
`proxmoxConnectionIncomplete` ve `proxmoxRemoveConnection`; önceki çeviri
değerleri aynen korundu. 320×640/TR ve 1366×1024/EN, 2× metin düzenleri gerçek
widget testlerinden geçti.

## RED → GREEN ve fixture sınırı

| Dilim | Gerçek runtime RED | GREEN |
|---|---|---|
| Kaynak, altı alan ve kurtarma | `aa819d0`: 3 PASS / 53 FAIL | `557b7ed`: 64 PASS |
| Tutulmuş form / dış provider reload | `36dd2a9`: 2 PASS / 2 FAIL | `da6121b`: 208 PASS |
| Native view odağı ve kalan ticket isteği | `e9bbb26`: 3 FAIL | `996bbaa`: 213 odaklı, 665 ilişkili PASS |

Önceki geçerli route/clone/provider fixture'ları production override yaparken
yeni Direct kaynak aboneliğini atlıyordu. Dört mevcut test dosyasında bu
abonelik veya opsiyonel method imzası düzeltildi; VM/route/assertion davranışı
gevşetilmedi. Geniş koşudaki tek eski seed fixture'ı Proxmox'u beş alanla
configured sayıyordu: açık `proxmox_allow_self_signed: false` eklendi,
assertion'ları korundu. İlk geniş koşunun 664 PASS / 1 FAIL sonucu bu fixture
drift'idir; sonraki tam ilişkili koşu ayrıca kaydedilir. Eksik TLS negatifleri
aynen kalır. İlk codegen/test sözdizimi hatası runtime RED sayılmadı.

## Son yerel kanıt

- **213 odaklı PASS**, 8 saniye: `direct_proxmox_boundary_test.dart` ve
  bütün mevcut/yeni Proxmox testleri.
- **665 ilişkili PASS**, 23 saniye: odaklı küme, ortak credential helper,
  Direct HA/source lifecycle, home session controller/scope/runtime, dört Arr
  store/action/form, MediaSessionState ve bütün backup testleri. Bu sayılar
  örtüşür; toplanmaz.
- **12 dosya analyze: 0 bulgu.** Formatter 12 dosyada 0 değişiklik;
  `git diff --check` temiz. EN/TR parse kontrolü yalnız iki yeni anahtarı
  doğruladı; eski değerlerin tümü korundu.
- Son ilişkili LCOV, değişen beş üretim dosyasında **554/638 = %86,8 satır**:
  store 25/25, provider 110/137, Connect 214/235, Nodes 114/133, session guard
  91/108. Generated kaynaklar hariçtir; branch coverage iddiası yoktur.
- Root kaynak incelemesi ilk altı alan/TLS paketi, dış reload listener ve son
  native-view delta için **P1/P2 bulgusu yok** sonucu verdi. Kaynak incelemesi
  fiziksel runtime veya yeni exact CI kanıtı değildir.

Özel test logları `/private/tmp/larenor-direct-proxmox-` önekiyle:
`red.log`, `first-green.log`, `reload-red.log`, `expanded-green.log`,
`receipt-green.log`, `native-focus-red.log`, `final-green.log`,
`related-before-fixture.log`, `related.log`, `analyze.log`, `format.log`,
`related-coverage.info`; özet `delivery-evidence.json` dosyasındadır.

Sentetik fixture'lar gerçek HomeSessionController/provider ve
secure-storage MethodChannel kullanır. HTTP MockClient'tır; network_info
kanalı null döndüğünden ev ağı keşfedilmez. Canlı Proxmox/HA/LAN çağrısı,
VM/container işlemi, credential taşıma, ev kurulumu veya fiziksel tablet
testi yapılmadı. İzole paket push edilmedi; birleşik Client ve exact GitHub CI
kabulü root'un sonraki teslim kapısıdır.
