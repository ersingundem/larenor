# S06.3e — özel kontrol ağı sözleşmesi

5 Eylül 2026. İlk **saf** alt adım `a814edc` ile yerelde donduruldu.
Ağ oluşturan bir transport, journal etki köprüsü veya kurulum API'si değildir.
Gerçek ev/Docker işlemi yapılmadı; `installAvailable=false` korunur.

`network_resources.py` bütün stack/katalog/politika kaynaklarını yeniden
türetir. Oluşturma önerisi yalnız kalıcı niyete bağlı sabit ad, bridge/local,
internal ve kapalı IPv6/attach/ingress/config-only profilidir. Client Docker
seçeneği, IPAM, serbest Options veya ConfigFrom göndermez. Sahiplik label'ları
Core/ev/hazırlık/kaynak/işlem, journal nonce/specification, plan/katalog ve
politika kimliğini bağlar. Hash eşitliği işlem yetkisi sayılmaz.

Liste sorgusu yalnız üretilmiş adı filtreler; label veya driver filtresi aynı
adlı yabancı ağı saklayamaz. Tam HTTP 200 yanıtı ve en fazla 128 KiB/128 kayıt
ile `missing` veya aday ID döner. Aday **hazır ağ makbuzu değildir**: API 1.28
ve sonrasında liste attached container bilgisini taşımadığından tam 64 hex ID
ile ayrıca inspect gerekir. Inspect'te tam label/profil, boş Containers ve
varsayılan IPv4 IPAM doğrulanır. Aynı adlı iki kayıt, yabancı label, yanlış
özellik, eksik gözlem, çelişkili framing veya kısmi liste kabul edilmez.
[Moby v27.5.1, API 1.47 şeması](https://raw.githubusercontent.com/moby/moby/v27.5.1/api/swagger.yaml).

Sürüm nüansı: güncel doküman snapshot'ındaki EnableIPv4 alanı, sabitlenen
v27.5.1 create tipinde yoktur. İstek bu alanı göndermez; IPv4 varsayılanı
inspect'te canonical IPv4 subnet ile doğrulanır. Daemon'ın null/boş varsayılan
map'leri ve otomatik subnet/gateway cevabı desteklenir; eksik zorunlu alan
boş varsayılan gibi değerlendirilmez.
[Network tipleri](https://raw.githubusercontent.com/moby/moby/v27.5.1/api/types/network/network.go).

TDD: `ad03d5b` RED → `c035329` ilk GREEN. Eksik Options ve bozuk liste
adları için `a0c753a` / `cc02b4c` RED → `5b12c66` GREEN; framing için
`dda1db5` RED → `a814edc` GREEN. **88 test**, 188/188 statement ve 40/40
dal ile **%100** kapsam. Bu yalnız yeni saf modülün kapsamıdır.
Bağımsız kök incelemesinde somut P1/P2 bulgu kalmadı. Testler geçici özel
SQLite niyeti ve sentetik HTTP cevabı kullanır; gerçek Engine ağı yaratmaz.

Bir sonraki [transport dilimi](network-transport-plan-2026-09-05.md), imajın
mevcut bağlantı/peer/sürüm/iptal/framing katmanını koruyarak önce salt list/inspect
sağlayacaktır. Journal etki köprüsü, gerçek actor/daemon/kapasite yetkisi ve
iki mimarili geçici Engine kabulü açık olduğundan S06.3e bütünü kapanmaz.
