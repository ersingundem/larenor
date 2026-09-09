# Home Assistant salt okunur domain dilimi

9 Eylül 2026. Uygulama commit'i
`9cabd4b834591be076b24a2412902a2875715de1`.

## Sonuç

Larenor Core'un seçili Home Assistant kaynak adaptörü artık yalnız `switch`
değil, güvenli ASCII `domain.object_id` biçimindeki standart veya özel bir
domain'i bağlayıp okuyabilir. `sensor.room_temperature`,
`binary_sensor.front_door`, `sun.sun` ve `custom_house_mode.current` gerçek
HTTP/SQLite/loopback testlerinde sınandı.

Core yalnız üç alanlı kapalı bir projeksiyon yayınlar: domain `kind`, en çok
255 karakterlik `state` ve literal `commandAvailable`. Home Assistant'ın
`attributes`, zaman damgaları, entity kimliği, upstream gövdesi, URL'si ve
erişim tokenı bu sözleşmeye girmez. Kontrol/biçimlendirme karakterleri ve
taşan durumlar statik `ha_projection_unsupported` hatasıyla kapanır.

Genel domain'ler salt okunurdur. Yazma izni olan admin için bile
`commandAvailable=false` kalır; komut POST'u worker/HA ağına çıkmadan ve
`home_assistant_commands` journal'ına kayıt yazmadan reddedilir. Mevcut
switch komut ve kayıp yanıt kurtarma davranışı korunur. Direct→Core aktarımı
da yalnız `switch.*` seçer; bu dilim eski sır aktarımını veya otomatik Direct
fallback'i genişletmez.

Android modeli domain ve ham durumu kapalı sınırlar içinde doğrular. Genel
durumlar tablet ekranında salt okunur görünür; switch düğmeleri üretilmez.
`unknown` ile `unavailable` ayrı tutulup yerelleştirilir. EN/TR hata, boş durum
ve salt okunur metinleri artık “varlık” kapsamını doğru anlatır.

## Uyum temeli

- [Home Assistant REST API](https://developers.home-assistant.io/docs/api/rest/)
  `GET /api/states/<entity_id>` durum okumasını, Bearer kimlik doğrulamayı ve
  `POST /api/services/<domain>/<service>` servis yolunu tanımlar.
- [Home Assistant entity modeli](https://developers.home-assistant.io/docs/core/entity/)
  state ile domain'e özel ek attributes alanlarını ayırır. Larenor bu dilimde
  yalnız state'i kapalı projeksiyona alır.
- [Unavailable kuralı](https://developers.home-assistant.io/docs/core/integration-quality-scale/rules/entity-unavailable/)
  `unknown` ve `unavailable` anlamlarını ayırır. Genel domain projeksiyonu bu
  ayrımı korur; eski switch v1 eşlemesi sözleşme uyumluluğu için değişmemiştir.

## Kanıt

- İlk RED: Server yeni domain senaryolarında 8 beklenen hata; Android modelde
  yeni kapalı alan getter'ları yoktu.
- Server ilgili paket: **200 PASS**; adapter, güvenlik, komut, binding yaşam
  döngüsü ve Direct aktarım testleri birlikte çalıştı.
- Android Core HA paketi: **219 PASS**; gerçek fontlu EN/TR,
  320/600/1280 genişlik, 2× metin, klavye ve ekran okuyucu sınırları dahil.
- Ek son odak: Server güvenlik paketi ve Android model/UI paketi geçti.
- `flutter analyze`: **0 sorun**. JSON ve `git diff --check` temiz.
- `contracts/home-assistant.v1.json` değişmedi; switch v1 HTTP fixture'ı aynı
  kaldı.

Canlı ev sistemine yazma yapılmadı. Exact-source GitHub CI ve fiziksel
Huawei/DeX kabulü bekliyor.

## Açık kapsam

Bu dilim “Home Assistant'ın tüm API'leri tamamlandı” anlamına gelmez. Domain'e
özel allowlist attributes, entity/device/area registry keşfi, uygulanabilir
servis kataloğu, ışık/kapak/iklim/medya gibi tipli komut şemaları, event stream,
history ve fiziksel cihaz kabulü sonraki S08.7 paketleridir. Her yazma alanı,
servis keşfinden gelen yetenek ve açık kullanıcı onayıyla ayrı açılacaktır.
