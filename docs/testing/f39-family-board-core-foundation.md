# F39 canlı aile panosu Core foundation kabulü

Bu üretim dilimi F39'un Core veri ve güven sınırını kurar. Flutter köprüsü, eşzamanlı çevrimdışı birleştirme ve gerçek Client→Core E2E sonraki dilimlerdir; bu belge F39'u tamamlandı saymaz ve fiziksel cihaz kanıtı iddia etmez.

## Üç kabul ölçütü

1. **Kapalı ve sınırlı pano modeli.** Kart metni, çizgi noktaları, öğe/pano/günlük/receipt sayıları ve snapshot/delta sayfaları üst sınırlarla doğrulanır. Her işlem resolver tarafından doğrulanan exact `coreId`, `homeId`, `homeRevision`, `boardId`, `accountRevision`, `memberRevision` ve `sessionFamilyId` otoritesine bağlıdır.
2. **Tek etkili ve denetlenebilir mutasyon.** Append/update/delete işlemleri account+session-family+request kapsamında idempotenttir. Aynı anahtarın farklı gövdesi, eski board revision, başka aktörün request tekrar kullanımı ve geç yetki snapshot'ı fail-closed olur. Audit sırası, actor/element/action/revision/zaman ve önceki hash ile immutable zincire bağlıdır.
3. **Şifreli ve yetkili kalıcılık.** Pano durumu, receipt'ler ve olaylar AES-256-GCM ile diskte şifrelenir; HMAC durum başı silme/değiştirme/sıra bozulmasını açılışta reddeder. Okuma/yazma rol izinleri ayrı uygulanır. Dışa aktarılan sınırlı snapshot/delta nonce, ciphertext, anahtar, session veya account revision içermez.

## Otomatik kanıt

`server/tests/test_f39_family_board_core.py` model sınırlarını, optimistic conflict ve scoped replay'i, immutable audit zincirini, şifreli restart davranışını, role-based read/write ayrımını, stale authority reddini, kurcalama reddini ve secret-free export'u kapsar.

Queue ilerlemesi bu foundation diliminde değişmez; F39'un kalan çevrimdışı birleştirme, Flutter ve gerçek E2E kapıları açıktır.
