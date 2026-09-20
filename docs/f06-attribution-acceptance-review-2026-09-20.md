# F06 atfedilebilir işlem açıklaması — kabul incelemesi

**İncelenen taban:** `048179da55766ae7410e61751583918e3ed8c433`
**Karar tarihi:** 20 Eylül 2026
**Karar:** Kod dilimi yerel incelemeden geçti; F06 henüz kabul edilmedi.

Bu belge `docs/execution-queue.json` içindeki F06 kapsamını ve kabul metnini,
uygulama ile testlerden bağımsız olarak yeniden eşler. Kod PR'ı kuyruk kaydını
`done` yapmaz, kanıt alanını doldurmaz ve sayaç artırmaz. Exact PR CI ile tek
Client → izole Core/servis yolculuğu tamamlanmadan kapanış commit'i atılamaz.

## Exact üç kabul ölçütü

1. **Aynı izde doğrulanmış kimlik ve sonuç — yerel PASS.** Açıkça çalıştırılan
   kayıtlı kural gerçek `ruleId` ve `ruleRevision` ile yürütülür; aktör, servis,
   komut, sağlayıcı sonucu ve kural yürütmesi aynı `requestId/correlationId`
   altında kalıcı geçmişe yazılır. Android açıklaması bu alanları birlikte
   gösterir. Doğrudan komut veya `unknown/unknown` kayıtları kural diye
   gösterilemez; yakın olay ya da saatten neden üretilmez.
2. **Sürümlü, yetkili ve sınırlandırılmış uçtan uca sözleşme — PR kapanışında
   doğrulanacak.** Server'ın gerçek FastAPI yönlendirmesi, izole HA adaptörü ve
   kalıcı deposu; yönetici yetkisi, restart, legacy kayıt, bozuk şifreli durum
   ve kapalı alan sözleşmelerinde yerel olarak geçti. Client ayrıca sürümlü ve
   sınırlı history API'sini, bozuk attribution/cursor yanıtlarını, iptal edilen
   bağlamı ve geç cevabı kapalı ele alıyor. Bu iki tarafın tek gerçek Client →
   izole Core/servis yolculuğunda birleştirildiği CI kanıtı henüz yoktur; ayrı
   Server ve widget testleri bunun yerine kabul edilmez.
3. **Exact kaynak incelemesi ve CI — bekliyor.** Kod, sözleşme, EN/TR tablet
   klavye/TalkBack yüzeyi ve gizli veri sınırı bağımsız diff incelemesinden
   geçmeli; aynı PR head'inde Android analiz/test/E2E, Server testleri ve
   güvenlik kapıları yeşil olmalıdır. Fiziksel Home Assistant cihaz sonucu
   yazılım kabulü sayılmaz ve ilgili `MANUAL.*` kaydında ayrı kalır.

## Yerel kanıt

- Rule Server testi: `server/tests/test_f06_rule_attribution.py`, **3/3 PASS**.
- Rule Client modeli ve sunumu:
  `core_ha_activity_models_test.dart` + `core_ha_activity_ui_test.dart`,
  **26/26 PASS**.
- Önceki birleşik regresyon aynı kod diliminde Server **450/450**, Client
  `core_ha` **252/252 PASS** verdi; exact-main rebase çatışmasız olduğundan bu
  pahalı paketler tekrarlanmadı.
- EN/TR 600/1280 mantıksal piksel, 2x metin, en az 48 dp hedef, donanım klavyesi
  ve TalkBack live-region kopyalama davranışı odak testte korunuyor.

## Korunan karar sınırı

`F06.status` değeri `pending`, `evidence` boş ve `completionCommit` null kalır.
Kuyruk sayacı mevcut main değeri olan **16/125 (%12,8)**, seçili özellik sayacı
**0/63** olarak korunur. Exact PR CI ve birleşik Client → izole Core yolculuğu
kanıtlandıktan sonra ayrı kapanış incelemesi F06'yı kabul edebilir.
