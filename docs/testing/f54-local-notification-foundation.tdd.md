# F54 yerel bildirim Core temeli

Bu dilim Android teslim motoru veya dış bir bildirim servisi kurmaz. Core içinde
ağ çıkışı olmayan, istemcinin kimliği doğrulanmış HTTPS oturumuyla çektiği kalıcı
bir bildirim kutusu kurar. Böylece sonraki Android alıcı/foreground-service işi,
Google servislerine veya ayrı bir ntfy kurulumuna sözleşme düzeyinde bağımlı
olmadan ilerleyebilir.

## Üç kabul ölçütü

1. **Sürümlü, sıralı ve tekrar güvenli olay:** Yönetici bir kullanıcı hedefi,
   güvenli uygulama içi rota ve idempotency anahtarıyla olay ekler. Aynı istek
   aynı sonucu döndürür; aynı anahtarın farklı içeriği reddedilir. İçerik diskte
   AEAD ile şifrelenir ve olaylar artan Core sıra numarasıyla çekilir.
2. **Yetki ve yaşam döngüsü:** Abonelik kullanıcıya ve mevcut oturum ailesine
   bağlıdır. İzin reddi, süre sonu, iptal, farklı oturum ve eski abonelik
   revizyonu pull/ack işlemlerini kapalı biçimde reddeder. Bildirim üretimi
   yönetici yetkisidir; kullanıcılar birbirinin aboneliğini veya olaylarını
   göremez.
3. **Teslim ve okunma ayrımı:** İlk başarılı pull abonelik bazında teslimi
   kalıcı kaydeder; okundu onayı ayrı ve idempotenttir, teslim edilmemiş olaya
   onay verilemez. Yeniden bağlantı ve Core yeniden başlatması sıra, teslim ve
   okunma durumunu korur. `private` olayın kilit ekranı projeksiyonu başlık,
   içerik ve hedef rotayı açığa çıkarmaz.

## Bu dilimde açık kalanlar

- F54 kuyruk işi kapanmaz: B5, B3 ve F05 bağımlılıkları ile gerçek Android
  Client alıcısı, bildirim izni, güvenli hedefe dönüş, foreground-service/OEM
  güç davranışı ve Huawei cihaz kabulü henüz yoktur.
- Core dışarı bağlantı açmaz ve push yaptığını iddia etmez. Android istemcinin
  uzun poll/SSE/yerel ağ yeniden bağlanma stratejisi sonraki bağımsız dilimdir.
- Fiziksel cihaz ve 24 saat pil ölçümü yalnız `MANUAL.*` kanıtıyla kapanabilir.

## Kanıt

- `test_local_notifications.py`: model sınırları, idempotency çatışması, kullanıcı
  ve oturum yalıtımı, izin/revizyon/süre sonu/iptal, sıralı pull, teslim-okunma,
  yeniden başlatma ve hassas içerik projeksiyonu.
- `test_core_context.py`: yeni şemanın mevcut Core oluşturma, göç ve yeniden
  başlatma sözleşmesini bozmadığını sınar.
