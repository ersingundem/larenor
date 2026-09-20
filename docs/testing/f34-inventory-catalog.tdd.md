# F34 kalıcı envanter kataloğu TDD kanıtı

21 Eylül 2026. Bu dilim mevcut QR envanterini kalıcı Core listesi ve güvenli
sayfalama sözleşmesiyle genişletir. F34 kapanışı, yazdırılabilir etiket yönetimi,
Android paylaşım hedefi ve fiziksel kamera kabulü tamamlanana kadar açık kalır.

## Üç kabul ölçütü

1. `GET /inventory/{core}/{home}/items` en fazla 100 kaydı sabit öğe kimliği
   sırasıyla döndürür. Yönetici bütün kayıtları, ev üyesi yalnız sahibi olduğu
   veya açıkça okuyucu olarak atandığı kayıtları görür; gizli kayıtlar sayfa
   boyu ya da sonraki sayfa hakkında kanıt sızdırmaz.
2. Sonraki sayfa işaretçisi AES-GCM ile doğrulanır ve tam Core, ev ve hesap
   kimliğine bağlanır. Yeniden başlatmadan sonra geçerliliğini korur; başka
   hesapta tekrar kullanım, değiştirilmiş veya canonical olmayan değerler ve
   sınır dışı sayfa boyları ağ geçidinde kapalı reddedilir.
3. Android Client kapalı alan setli, kapsamı doğrulanmış ve tekrar kimliksiz
   `InventoryPage` modeli kullanır. Katalog controller yalnız güncel
   hesap/route/lifecycle otoritesinde refresh veya next kabul eder; geç sonuç,
   sayfalar arası tekrar ve 100 kayıt sınırını aşan zincir görünür veriyi
   temizleyerek kapalı başarısız olur.

RED `e262d042`, eksik Server liste rotasını ve eksik Client sayfa/controller
sözleşmelerini testlerle kaydeder.

## Doğrulama

```text
cd server
uv run --locked --no-sync python -m pytest -q \
  tests/test_f34_inventory_listing.py \
  tests/test_f34_inventory_foundation.py \
  tests/test_f34_inventory_authority.py

flutter test test/features/inventory \
  test/integration_support/synthetic_core_inventory_test.dart

flutter analyze lib/features/inventory test/features/inventory
python3 tool/check_security_policy.py
python3 tool/execution_queue.py validate
git diff --check
```

Bu yazılım dilimi ilerleme sayaçlarını tek başına değiştirmez. Gerçek Android
etiket taraması ve paylaşım hedefi MANUAL/sonraki yazılım kapılarında kalır.
