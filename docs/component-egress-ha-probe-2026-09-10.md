# F13 — Home Assistant bağlantı denetiminin çıkış izni

Bu ilk Server dilimi, F13 “Bileşen bazında internet izinleri” için mevcut
`POST /api/v1/admin/services/{serviceId}/check` yürütme yolunda yalnız
`home_assistant` bağlantısının `GET /api/config` denetimini kapsar. Exact başlangıç
`70f20e181193d66857eb1153b693da2524720357`, dal `codex/core-component-egress`.
Üretim checkpoint'i `339e24e67d232412dbbba06b227a593550f6bbc9`.

## Davranış ve sözleşme

Yeni veya eski kayıtlı HA servisleri için başlangıç **grants=[] / deny** olur.
Servis eklemek, mevcut token'a sahip olmak veya geçmiş `authenticated` denetimi
tek başına ağ izni değildir. İzinsiz kontrol `403 outbound_denied` verir;
resolver, connector ve HA probe çağrılmaz. Mevcut yapılandırma, token ve servis
revision'u migration veya politika düzenlemesiyle değiştirilmez.

Yönetici API'si:

- `GET /api/v1/admin/services/{serviceId}/outbound-policy`
- `PUT /api/v1/admin/services/{serviceId}/outbound-policy`

PUT kapalı gövdesi:

```json
{
  "expectedRevision": 0,
  "expectedServiceRevision": 1,
  "grants": [{
    "scheme": "https", "host": "ha.example.test", "port": 443,
    "addresses": [{"address": "10.20.30.40", "network": "lan"}]
  }]
}
```

Yanıt `policy` ve o servise ait en son 20 kapalı `audit` olayıdır. Policy alanları:
`component="home_assistant_probe"`, `serviceId`, `serviceRevision`, `revision`,
`grants`. En çok bir exact origin ve 8 canonical IP verilebilir; port açıkça
zorunludur. `grants=[]` açık iptaldir. Wildcard, CIDR, URL/userinfo/query,
yönlendirme/proxy/retry ayarı veya başka component kabul edilmez. Grant origin'i
kayıtlı servisin scheme/host/port'u ile eşleşir; tüm path-prefix ve credential
bağı da aynı servis revision'una sabittir. Servis değişirse grant yeni kayda
kendiliğinden taşınmaz. GET eski policy revision'unu gösterir; yönetici güncel
servis kaydını okuyup beklenen iki revision ile açıkça değiştirir.

Üye/ilk parola hesabı `403`; oturumsuz/iptal edilmiş hesap `401`; bilinmeyen veya
HA olmayan servis `404`; stale revision `409`; bozuk politika `400` alır.
Yinelenen Authorization veya herhangi query alanı reddedilir. API `check`
yanıtının eski service DTO'sunu değiştirmez; başarılı check için yeni açık izin
önkoşulu gerekir. Client izin düzenleme UI'si bu pakette yoktur.

## Bağlantı sınırı

Tam DNS A/AAAA yanıt listesindeki her adres, canonical sayısal forma çevrildikten
sonra aynı grant'te bulunmak zorundadır. Güvenli görünen ilk cevap yanında
izinsiz ikinci cevap varsa hiç bağlantı kurulmaz. Tek DNS çözümündeki seçili
sayısal adres socket'e verilir; hostname ile ikinci çözümleme yapılmaz. Yeniden
kontrol yeni DNS cevabını tekrar değerlendirir; alternate-address retry yoktur.
Bağlı socket'in `getpeername()` sonucu seçilen sayısal hedefle eşleşmelidir.
HTTPS mevcut varsayılan CA/hostname kontrolünü ve seçilen host için SNI'ı korur.

Genel İnternet IP'si `public`; yalnız RFC1918 veya IPv6 ULA adresi açık `lan`
sınıfıyla verilebilir. Loopback/Core adresleri, link-local/cloud metadata,
multicast, unspecified, reserved, CGNAT, IPv4-mapped IPv6 ve 6to4/Teredo geçiş
adresleri bu API ile açılamaz. LAN istisnası exact IP'dir; otomatik keşif veya
subnet izni yoktur. IP pinning HTTP hedefindeki fiziksel cihazın kimliğini
kanıtlamaz; HTTP açıkça seçilmişse trafik TLS ile şifrelenmez.

Mevcut `ServiceTransport` body/framing limitleri, doğrudan socket kullanımı,
proxy/redirect/retry yokluğu korunur. Packaged probe bir 12 saniye bütçe,
tek HTTP isteği en fazla 8 saniye network deadline ve 64 KiB yanıt sınırını
kullanır; DNS slotları en fazla 4, cevap sayısı en fazla 16'dır. DB auth/policy
kontrolleri ayrı, mevcut en fazla 5 saniye SQLite busy timeout'una tabidir;
network deadline bunları sınırsız bir retry'a dönüştürmez. Policy/current actor
ve exact servis kaydı DNS sonrası, connect öncesi, TLS sonrası gövdeyi göndermeden
önce ve sonuç saklama transaction'ında yeniden doğrulanır. İptal sonrası önceki
izin sonraki isteğe taşınmaz. Son gate'ten sonra zaten gönderilmiş baytlar geri
alınamaz; bu dilim çalışan socket'ler için bağımsız anlık iptal servisi değildir.

## Kalıcılık ve audit

Yeni `component_egress_schema=1` extension'ı mevcut Core initialize transaction'ında
kurulur. Tek `component_egress_state` satırı, scope-bound AAD ile AES-GCM şifrelidir:
policy hedefleri ve ayrıntılı audit aynı authenticated ciphertext içinde kalır.
En fazla 128 servis policy'si, 256 olay, toplam 1 MiB ciphertext kabul edilir.
SQL type/byte-length/count ve exact schema preflight bozuk veya eklenmiş
index/trigger'ı Python materyalizasyonundan önce reddeder. Missing/partial/bozuk
storage başlangıçta kapanır; reset veya otomatik grant oluşturulmaz.

Policy update ve ayrıntılı audit aynı transaction'dadır. Her HTTP body gönderimi
öncesi `dispatch_authorized` audit kalıcılaşır. Actor ID, source=`core_api`,
kapalı reason, service ID, policy revision ve opaque correlation kaydedilir;
request URL/path, token, raw exception veya provider body kaydedilmez. Aynı
transaction'da mevcut `service_audit` alanına kapalı `admin.component.egress`
olayı eklenir. Normal probe tamamlama ve verification yazısı aynı transaction
kontrolünden geçer. Grant yokluğu veya geç kayıp ayrı karardır; audit'in
authorization kaydı HA'nın isteği aldığını veya gerçek bir ev eylemini kanıtlamaz.

Açık policy düzenlemesi sırasında yalnız artık servis kaydı olmayan policy
metadata'sı çıkarılabilir; bu upstream DELETE veya otomatik yapılandırma
silmesi değildir. Son 256 audit olayı tutulur, eski olaylar sınırlı retention
gereği düşer. Bu envanter F20'nin HA komut zincirine eklenmez; kendi AES-GCM
bütünlüğü vardır. Tam geçerli eski DB snapshot'ına dönüş, tek başına bu encrypted
policy envanteri tarafından saptanmaz. Host/container firewall, başka entegrasyon
kodu veya yetkili Core process'inin farklı socket açması bu dilimle kısıtlanmaz.

## TDD ve doğrulama

- RED `62ec450`: 3 gerçek runtime FAIL; izinsiz check çalışıyor, policy API yok.
- GREEN `48d9617`: aynı 3 PASS; default deny, migration ve gerçek runner bağlandı.
- RED `b977a9d`: 30 PASS / 2 FAIL. Address-block/peer ret eski probe tarafından
  `unsupported` gözlemiyle 200'e çevriliyordu; credential gönderimi yine sıfırdı.
- GREEN `339e24e`: aynı 32 PASS / 7,31 s; ret `outbound_denied` olur ve yanlış
  check confirmation yazılmaz.
- Son odaklı paket: **56 PASS / 14,30 s**; 39 yeni egress testi + 17 mevcut probe.

Yeni testler actual Core auth/ASGI/SQLite ve packaged HA parser + gerçek HTTP
wire encoder/reader kullanır. DNS ve socket etkisi sayısal peer'i açık fake
connector ile modellenir; özel LAN veya gerçek HA'ya bağlantı yapılmaz.
Mevcut bağımsız transport testleri gerçek owned loopback/TLS/framing davranışını
korur. İki eski API-loopback pozitif testi artık üretimin bilinçli Core/loopback
reddini doğrular; bunu yeni izinli LAN bağlantısı kabulü diye raporlamıyoruz.
Servis shared Client contract gövdesi aynı kalır; test öncesi explicit grant
setup'ı eklendi. Tarihsel context-free migration fixture'ları yeni scope-bound
extension'ı da kaldırır; üretim startup gevşetilmez.

Son tek ilgili gate **543 PASS, 0 skip / 106,92 s**: component egress, bütün
`service_*` testleri, Core context/admin migration ve F06/F20 history. Global
Server paketi tekrar koşulmadı. Yeni modüller branch-inclusive **%92,02**
(300/326 line+branch); değişen taşıma/runner/service dahil **%91,79**
(1.051/1.145 line+branch). Yeni admin API %100, storage %85 kapsamda.

Kanıtlar: `/private/tmp/larenor-component-egress-{red,green,safety-first,safety-green,focused,related}.log`
ve `/private/tmp/larenor-component-egress-coverage.json`. İki mevcut
FastAPI/Starlette deprecation uyarısı test hatası değildir. Gate süreci exit 0
ile kapandı; `git diff --check` temiz.

Son komut (worktree kökünde):

```sh
COVERAGE_FILE=/private/tmp/larenor-component-egress-related.coverage \
PYTHONPATH=server:.:/private/tmp/larenor-f06-coverage \
/tmp/larenor-server-test-venv-1789025227538/bin/python -m coverage run \
  --branch --source=larenor_server.component_egress,larenor_server.services \
  -m pytest server/tests/test_component_egress*.py server/tests/test_service*.py \
  server/tests/test_core_context*.py server/tests/test_admin_migration.py \
  server/tests/test_command_history*.py -ra
```

Resmî temel kaynaklar: [OWASP SSRF önleme](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html)
(allowlist, tüm A/AAAA cevapları ve DNS pinning), [Python SSL](https://docs.python.org/3.12/library/ssl.html)
(mevcut hostname/CA/SNI davranışı), [Home Assistant REST](https://developers.home-assistant.io/docs/api/rest/)
(yalnız mevcut `/api/config` denetimi). Bu kaynaklar yerel test kanıtı veya gerçek
cihaz kabulü değildir.

Global Server/Flutter, CI, PR/push, gerçek HA/ev/medya kurulumu çalıştırılmadı.
F13'ün tüm bileşenleri veya roadmap kabulü tamamlandı iddiası yoktur.
