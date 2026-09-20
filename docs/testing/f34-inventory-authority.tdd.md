# F34 envanter otoritesi ikinci Server dilimi — TDD kanıtı

20 Eylül 2026. Bu yerel dilim ilk QR envanter modülünü korur; Android tarama
arayüzü, medya ve ortak tablet dosyalarına dokunmaz. F34 tamamlanmış sayılmaz ve
ilerleme sayaçları değiştirilmez.

## Üç kabul ölçütü

1. Oda ve cihaz kimlikleri güncel Core'un doğrulanmış Home Resource kaydında
   sırasıyla `room` ve `resource` türünde bulunmalıdır. Belge kimliği aynı
   Core/home scope'unda kalıcı product blob'a bağlı olmalıdır. Eksik, yanlış
   türde, yabancı scope'ta veya sonradan kaldırılmış referans fail-closed kalır.
2. Yalnız current/ready yönetici reader grant listesini okuyabilir, grant
   ekleyebilir, eşya metadatasını güncelleyebilir veya grant'i geri alabilir.
   Her gerçek değişim tek item revision artırır; stale revision hiçbir yazım
   yapmaz ve reader geri alındığında öğenin varlığı kullanıcıdan yeniden
   gizlenir.
3. Create, update, grant ve revoke olayları anahtarlı, scope'a bağlı ve kesintisiz
   hash zincirine eklenir. Yetkili history okuması tüm zinciri doğrular; restart
   geçmişi korur. Satır, zincir başı veya authenticated state değişikliği Core
   başlangıcında `inventory_storage_invalid` ile kapanır.

## RED / GREEN ve sınır

- RED `1e753ceb`: mevcut ilk dilimde olmayan resolver, revisioned grant/update
  ve kalıcı doğrulanmış history için üç HTTP kabul testi eklendi.
- GREEN `dd9b8118`: resolver, yönetim rotaları ve authenticated append-only audit
  state/zinciri uygulandı.
- `test_f34_inventory_foundation.py` + `test_f34_inventory_authority.py`: **6/6
  PASS**. Python compile, diff/progress/queue ve merge-tree kontrolleri son yerel
  doğrulamada kaydedilir.

Android QR kamera/SAF sunumu, envanter listeleme/sayfalama, silme yaşam döngüsü,
Client → izole Core E2E, exact-head CI ve fiziksel cihaz kabulü sonraki
dilimlerdir. `F34.status` pending; kuyruk **16/125**, seçili özellik kabulü
**0/63** kalır.
