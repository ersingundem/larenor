# F34 envanter Android Client üçüncü dilimi — TDD kanıtı

20 Eylül 2026. Bu yerel dilim, Server envanter sözleşmesini Android tablet için
bağımsız bir read-only feature modülüne bağlar. Route/app ve ortak l10n dosyaları
değişmez; route katmanı sonraki birleşimde `AppLocalizations` değerlerinden typed
`InventoryStrings` üretir. F34 pending ve sayaçlar sabit kalır.

## Üç kabul ölçütü

1. Kamera kaynağından gelen metin ile elle girilen metin aynı controller yolunda
   yalnız canonical küçük-harfli, exact-scope `larenor:inventory:v1` QR sözleşmesi
   olarak ayrıştırılır. Client yalnız Core `qr/resolve`, `history` ve yönetici için
   `grants` GET/okuma yüzeylerini kullanır; yazım, cihaz komutu ve otomatik retry
   metodu yoktur.
2. Çözümlenen öğeler tablet listesindeki tek güncel kayıt olarak tutulur. Ayrıntı
   paneli gerçek oda, cihaz ve belge kimliklerini; doğrulanmış okuma erişimini,
   reader sayısını ve doğrulanmış audit olay sayısını gösterir. Item, grant ve
   history response modelleri kapalı alan setini, Core/home scope'unu ve aynı item
   revision'ını doğrular.
3. Bozuk/yabancı QR ağ isteği üretmez. Offline, doğrulanamayan response, yanlış
   item ve session/authority değişiminden sonra gelen geç sonuç listeye girmez;
   stale durumda önceki görünür kanıt da temizlenir. Ekran metinleri yalnız
   enjekte edilen typed bundle'dan gelir; EN/TR fixture'ları 600 ve 1200 dp'de
   2x metin, TalkBack anlamı, klavye submit ve 48 dp eylemi doğrular.

## RED / GREEN ve kanıt

- RED `bfa0e662`: strict model, gerçek HTTP method/path, controller authority ve
  EN/TR responsive erişilebilirlik sözleşmeleri üretim modülü yokken eklendi.
- GREEN `4197bd70`: bağımsız domain/API/controller/screen uygulaması eklendi.
- Üç hedef test dosyası: **8/8 PASS**.
- `flutter analyze lib/features/inventory test/features/inventory`: **No issues
  found**.

Kamera plugin permission/lifecycle adaptörü, AppLocalizations route adaptörü,
navigasyon girişi, gerçek izole Core E2E, exact-head CI ve fiziksel tablet/kamera
kabulü sonraki dilimlerdir. Kuyruk **16/125**, seçili özellik kabulü **0/63**.
