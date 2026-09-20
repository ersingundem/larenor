# F34 envanter Android Client dördüncü dilimi — TDD kanıtı

20 Eylül 2026. Bu yerel dilim F34 envanter okuyucusunu doğrulanmış Core ev
oturumuna ve Android tablet navigasyonuna bağlar. Fiziksel kamera doğrulaması
MANUAL kalır; F34 tamamlanmış sayılmaz ve ilerleme sayaçları değişmez.

## Üç kabul ölçütü

1. `InventoryRoute`, EN/TR `AppLocalizations` değerlerini typed
   `InventoryStrings` paketine dönüştürür. Route ProviderContainer, home runtime
   identity, hesap generation, interaction epoch, native view/focus, lifecycle,
   window policy ve geçerli route'u tek authority olarak bağlar. Bunlardan biri
   değişince HTTP transport, kamera ve görünür kanıt emekli edilir; geç yanıt
   ekrana dönemez. Doğrulanmış Core ana ekranı `/inventory` tablet rotasını
   sunar.
2. Android üretim katmanı `mobile_scanner` CameraX/ML Kit QR okuyucusunu yalnız
   açık ve current bir camera flight içinde kullanır. İzin reddi, kamera hatası,
   background, rotation veya authority kaybı okuyucuyu kapatır; otomatik yeniden
   açmaz ve elle giriş her zaman kalır. Canonical scoped QR'dan üretilen bounded
   SVG export modeli yalnız Core/home/item kimliklerini taşır; label, belge,
   grant veya token kabul etmez. Kamera izni manifestte opsiyonel hardware ile
   bildirilir.
3. Gerçek loopback TCP/HTTP sınırındaki izole Core fixture'ı resolve, yerel
   bounded list/detail, grants ve doğrulanmış history yolculuğunu çalıştırır.
   En fazla 100 kayda izin veren controller sayfa sınırı uygulanır; bozuk veya
   limit dışı QR ağ isteği üretmez. Route/transport kapanışı gecikmiş isteği
   iptal eder ve retained evidence bırakmaz. Fixture yalnız `POST qr/resolve`
   ile history/grants `GET` görür; admin veya inventory mutator görmez.

## RED / GREEN ve doğrulama

- RED `9d686236`: QR export, kamera permission/lifecycle/authority ve bounded
  liste sözleşmeleri üretim sınıfları yokken eklendi ve derleme kırmızıydı.
- GREEN `5ea5b168`: route/session binding, refresh-aware read gateway, gerçek
  Android QR platformu, secret-free SVG, tablet kamera/manual-entry sunumu ve
  izole Core HTTP E2E eklendi.
- `flutter test test/features/inventory
  test/integration_support/synthetic_core_inventory_test.dart`: **16/16 PASS**.
- Hedefli `flutter analyze`: **No issues found**.
- `flutter build apk --debug`: **PASS**, Android plugin/native derlemesi
  tamamlandı.

Fiziksel Android tablette kamera izin diyalogu, QR odaklama/rotation ve gerçek
etiket taraması MANUAL'dır. Server tarafında printable label yönetim akışı,
Android export/share hedefi, exact-head CI ve B3/B5 kuyruk bağımlılıkları F34
kapanışından önce tamamlanmalıdır. Kuyruk **16/125**, seçili özellik kabulü
**0/63** kalır.
