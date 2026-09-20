# F06 atfedilebilir işlem açıklaması — kabul incelemesi

**İncelenen taban:** `67261f690f74b813ed22b65237999d9dca9e1cef`
**Karar tarihi:** 20 Eylül 2026
**Karar:** Kod dilimi yerel incelemeden geçti; F06 henüz kabul edilmedi.

Bu belge `docs/execution-queue.json` içindeki F06 kapsamını ve kabul metnini,
uygulama ile testlerden bağımsız olarak yeniden eşler. Kod PR'ı kuyruk kaydını
`done` yapmaz, kanıt alanını doldurmaz ve sayaç artırmaz. Exact PR CI aynı
head'i doğrulamadan kapanış commit'i atılamaz.

## Exact üç kabul ölçütü

1. **Aynı izde doğrulanmış kimlik ve sonuç — yerel PASS.** Açıkça çalıştırılan
   kayıtlı kural gerçek `ruleId` ve `ruleRevision` ile yürütülür; aktör, servis,
   komut, sağlayıcı sonucu ve kural yürütmesi aynı `requestId/correlationId`
   altında kalıcı geçmişe yazılır. Android açıklaması bu alanları birlikte
   gösterir. Doğrudan komut veya `unknown/unknown` kayıtları kural diye
   gösterilemez; yakın olay ya da saatten neden üretilmez.
2. **Sürümlü, yetkili ve sınırlandırılmış uçtan uca sözleşme — yerel PASS.**
   Server'ın gerçek FastAPI yönlendirmesi, izole HA adaptörü ve
   kalıcı deposu; yönetici yetkisi, restart, legacy kayıt, bozuk şifreli durum
   ve kapalı alan sözleşmelerinde yerel olarak geçti. Client ayrıca sürümlü ve
   sınırlı history API'sini, bozuk attribution/cursor yanıtlarını, iptal edilen
   bağlamı ve geç cevabı kapalı ele alıyor. Loopback-only izole Core HTTP
   endpointi gerçek `IOClient`, oturum, ev kapsamı ve activity controller
   üzerinden rule/direct/unknown geçmişini okur; offline retain edilen kaydı
   stale yapar ve geç cevap otorite değişiminden sonra yayınlanmaz.
3. **Exact kaynak incelemesi ve CI — bekliyor.** Kod, sözleşme, EN/TR tablet
   klavye/TalkBack yüzeyi ve gizli veri sınırı bağımsız diff incelemesinden
   geçmeli; aynı PR head'inde Android analiz/test/E2E, Server testleri ve
   güvenlik kapıları yeşil olmalıdır. Fiziksel Home Assistant cihaz sonucu
   yazılım kabulü sayılmaz ve ilgili `MANUAL.*` kaydında ayrı kalır.

## Yerel kanıt

- Rule Server testi: `server/tests/test_f06_rule_attribution.py`, **3/3 PASS**.
- RED `95843e2a` eksik rule fixture ve lifecycle kapılarını gösterdi; GREEN
  `29b7a216` ile loopback Core HTTP entegrasyon paketi **8/8 PASS** verdi.
- Rule Client modeli ve sunumu:
  `core_ha_activity_models_test.dart` + `core_ha_activity_ui_test.dart`,
  **26/26 PASS**.
- S08.10 ve S06.6 birleşmelerinden sonraki exact-main rebase sırasında ortak
  sentetik Core fixture'ındaki event ve history alanları birlikte korundu; odak
  Server paketi **12/12**, birleşik Client HTTP/model/UI paketi **36/36 PASS**
  verdi.
- Önceki birleşik regresyon aynı kod diliminde Server **450/450**, Client
  `core_ha` **252/252 PASS** verdi; pahalı paketlerin tamamı kaynak değişmediği
  için tekrarlanmadı.
- EN/TR 600/1280 mantıksal piksel, 2x metin, en az 48 dp hedef, donanım klavyesi
  ve TalkBack live-region kopyalama davranışı odak testte korunuyor.

## Bağımsız saldırgan inceleme

20 Eylül 2026 tarihli ikinci kaynak incelemesinde F06 kapsamını durduracak P1
veya P2 bulunmadı. İnceleme aşağıdaki güven sınırlarını doğrudan ürün koduna
bağladı:

- **Sahte aktör/kural/istek korelasyonu:** HA kalıcı kayıt modeli attribution
  korelasyonunu istek kimliğine bağlar ve yalnız kapalı kaynak/sebep çiftlerini
  kabul eder (`server/larenor_server/home_assistant/models.py:153-202`). Kural
  yürütmesi aktörün gönderemediği attribution alanlarını kayıtlı kural ve istek
  kimliğinden Core içinde üretir (`server/larenor_server/home_assistant/rules.py:162-199`).
  Keenetic ve Proxmox günlükleri de aktör, correlation ve servis sürümünü imzalı
  olay satırıyla yeniden eşler (`server/larenor_server/keenetic_commands/journal.py:91-165`,
  `server/larenor_server/proxmox_commands/storage.py:62-135`).
- **Ev/kullanıcı geçmişi yalıtımı:** HA geçmişi yetkili kaynakla sınırlanır;
  yönetici olmayan görünüm ayrıca güncel aktöre süzülür ve görünmeyen cursor
  `404` olur (`server/larenor_server/home_assistant/service.py:366-422`). Proxmox
  ve Keenetic attributed uçları güncel yönetici oturumunu, gerçek ev/kaynak
  kaydını ve okuma öncesi/sonrası revision değerlerini doğrular
  (`server/larenor_server/proxmox_commands/service.py:486-499`,
  `server/larenor_server/keenetic_commands/api.py:93-103`). Component egress
  geçmişi de güncel admin ve seçilen servis kimliğiyle sınırlıdır
  (`server/larenor_server/component_egress/service.py:84-97`).
- **Legacy/unknown yükseltmesi:** HA eski satırları servis ve kural alanları boş
  `unknown/unknown` olarak taşır; Client unknown kaydında bu alanları kesin olarak
  reddeder (`server/larenor_server/home_assistant/models.py:168-184`,
  `lib/features/core_ha/domain/core_ha_activity_models.dart:117-151`). Component
  egress v1 kayıtları komut ve sonucu da `unknown` yapar
  (`server/larenor_server/component_egress/storage.py:65-103`). Yakın zamanlı
  başka bir olay neden olarak yükseltilmez.
- **Journal tamper/restart:** HA şifreli snapshot, append hash zinciri, güncel
  tablo eşliği ve caller-retained checkpoint/prefix karşılaştırmasını birlikte
  doğrular (`server/larenor_server/home_assistant/command_chain.py:108-129`,
  `server/larenor_server/home_assistant/command_chain.py:177-207`). Keenetic ve
  Proxmox yarım işlemleri restartta yeniden yürütmeden `unknown` yapar
  (`server/larenor_server/keenetic_commands/journal.py:358-378`,
  `server/larenor_server/proxmox_commands/storage.py:263-283`). Bütün geçerli
  depoyu eski bir snapshot ile değiştiren saldırının dış ankora dayalı genel
  çözümü F20 sınırında kalır; F06 yalnız mevcut doğrulanmış kayıtları neden diye
  yükseltmez.
- **Sayfalama/cursor ve geç otorite:** HA history cursor'u yalnız görünür
  kayıtlarda kabul edilir; event cursor'u görünür aktör/kaynak görünümünde tekrar
  numaralanır ve global sıra bilgisi sızdırmaz
  (`server/larenor_server/home_assistant/service.py:381-422`). Client her sayfada
  sıralama, tekillik, cursor ve kesintisiz event sequence sözleşmesini kapalı
  doğrular (`lib/features/core_ha/domain/core_ha_activity_models.dart:175-219`,
  `lib/features/core_ha/domain/core_ha_activity_models.dart:261-329`). Oturum,
  ev, aktör, endpoint, interaction epoch veya süre değişirse geç cevap yayınlanmaz
  (`lib/features/core_ha/data/core_ha_activity_controller.dart:201-258`).
- **Açıklama ve sır sınırı:** Tablet açıklaması yalnız kapalı enum çiftinden
  metin seçer; unknown için doğrulanmış neden olmadığını söyler
  (`lib/features/core_ha/presentation/core_ha_activity_screen.dart:122-157`).
  Görünür ayrıntılar aktör, eylem, sonuç, correlation, isteğe bağlı kural ve
  servis kimliği/sürümüdür; pano yalnız request trace alır
  (`lib/features/core_ha/presentation/core_ha_activity_screen.dart:381-495`).
  Sağlayıcı gövdesi, URL, erişim anahtarı, parola veya confirm/idempotency tokenı
  bu projection'a girmez.

Bu inceleme F20 bütünlük genişletmesini veya fiziksel Home Assistant kabulünü
F06 yazılım kanıtı saymaz. Kuyruk durumu ve sayaçlar değişmedi.
İnceleme sonrası dört F06 Server dosyası yeniden **12/12**, Client
model/UI/izole Core HTTP paketi yeniden **36/36 PASS** verdi.

## Korunan karar sınırı

`F06.status` değeri `pending`, `evidence` boş ve `completionCommit` null kalır.
Kuyruk sayacı mevcut main değeri olan **17/125 (%13,6)**, seçili özellik sayacı
**0/63** olarak korunur. Exact PR CI kanıtlandıktan sonra ayrı kapanış
incelemesi F06'yı kabul edebilir.
