# F34 QR envanteri ilk Server dilimi — TDD kanıtı

20 Eylül 2026. Bu yerel dal, F34'ün diğer aktif medya, kurulum, transfer ve
ortak tablet dosyalarına dokunmayan ilk üç kabul ölçütünü gerçek Core HTTP
yüzeyinde uygular. F34 tamamlanmış sayılmaz ve sayaçlar değişmez.

## İlk üç kabul ölçütü

1. Core, her eşya için yeniden başlatmada değişmeyen 128 bit opaque kimlik ve
   scope'a bağlı canonical QR değeri üretir. QR; etiket, belge kimliği, kullanıcı
   listesi, erişim tokenı veya başka bir gizli değer taşımaz. Eşya içeriği
   AES-GCM ile şifreli saklanır.
2. Sürüm 1 kapalı sözleşmesi Türkçe etiketi ve isteğe bağlı oda/cihaz ile en
   fazla 16 benzersiz belge referansını kalıcı tutar. Fazladan alan, yabancı
   sürüm, bozuk kimlik, tekrar eden referans ve sınır aşımı kayıt oluşturmadan
   reddedilir.
3. QR yalnız current ve ready Core oturumunda bir okuma referansıdır. Yönetici,
   oluşturucu veya açık reader listesi dışındaki kullanıcı eşyanın varlığını
   göremez; bozuk ya da yabancı scope QR'ı öğe açmaz. QR çözümleme için komut,
   Home Assistant yazımı, silme veya güncelleme yüzeyi yoktur.

## RED / GREEN

- RED `e76077a1`: üç test de eksik HTTP rotalarında 404 ile beklenen şekilde
  başarısız oldu.
- GREEN `10ab6351`: F34 odak paketi **3/3 PASS**; Core context ve admin migration
  ile birlikte **34/34 PASS**. Python compile ve `git diff --check` temiz.

## Açık sınır

Bu dilim oda/cihaz/belge kimliklerini kapalı ve şifreli ilişki olarak saklar;
referans verilen kaynağın güncel varlığını veya erişimini henüz kanıtlamaz.
Android QR tarama/üretme ve eşya ayrıntısı, reader listesini sonradan değiştirme,
listeleme/sayfalama, gerçek Client → izole Core E2E, exact-head CI ve fiziksel
kamera kabulü sonraki dilimlerdir. `F34.status` pending; kuyruk **16/125**, seçili
özellik kabulü **0/63** kalır.
