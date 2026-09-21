# F39 aile panosu Android Client kabulü

Bu paket güncel F39 Core foundation üzerine yığılmış Android tablet dilimidir. F39 tamamlanmış sayılmaz: çevrimdışı çok-yazarlı birleştirme, öğe bazlı yetki ve gerçek çok-cihaz kabulü sonraki kapılardır.

## Üç kabul ölçütü

1. **Tablet pano ve beyaz tahta.** EN/TR Cupertino yüzeyi 600 ve 1200 genişlikte, 2x yazıda kart oluşturma/düzenleme/onaylı silme ve en çok 256 noktalı çizim sağlar. Dokunma çizimine 48dp düğme, klavye etkinleştirmesi ve TalkBack etiketiyle eşdeğer erişilebilir eylem vardır.
2. **Exact otorite ve tek etkili yazma.** Transport, cache ve controller `core/home/homeRevision/board/account/accountRevision/memberRevision/sessionFamily/routeRevision/lifecycleRevision` bağını taşır. Her optimistic komut benzersiz request ID ile bir kez gönderilir; `revision_conflict` otomatik tekrar edilmez, açık yenileme gerekir. Geç route/lifecycle/account sonucu ve farklı bağ fail-closed olur.
3. **Çevrimdışı salt okunur görünüm ve delta uzlaştırma.** Son doğrulanmış snapshot yalnız exact hesap/ev/pano kapsamındaki Android secure storage kaydından okunur ve hiçbir yazma yetkisi vermez. Yeniden bağlantıda sıralı, hash-bağlı ve sınırlı delta doğrulanır; değişiklik varsa tek authoritative snapshot readback alınır. Geç cache yazımı silinir.

## Uygulama entegrasyonu

1. **Gerçek Core HTTP sınırı.** Hazır kullanıcı oturumu default ev panosu yetkisini Core'dan alır; boş pano revision 0 olarak okunur. Snapshot, en çok 100 olaylık delta ve append/update/delete komutu aynı account/home/session revision beklentilerini taşır. Başka ev, oturum ailesi veya eski revision fail-closed olur.
2. **Route sahipliği.** `/family-board` yalnız doğrulanmış Core evinde görünür. Route account generation, Core/home, session, pencere, görünürlük, lifecycle ve route revision değişiminde gateway/controller/cache yetkisini emekli eder; geç callback yeni ekrana taşınmaz.
3. **Keşfedilebilir tablet yüzeyi.** Core ev ekranındaki 48dp klavye/TalkBack eylemi EN/TR AppLocalizations kopyasıyla panoyu açar. 600/1200 genişlik ve 2x metinde kart, çizim, loading/offline/conflict/error durumları taşmadan kalır.

## Otomatik kanıt

`server/tests/test_f39_family_board_api.py`, `server/tests/test_f39_family_board_core.py`, `test/features/family_board/` ve `test/features/home_scope/core_home_status_tablet_accessibility_test.dart` HTTP authority, strict model/transport, no-retry conflict, late callback, secure cache, offline read-only, delta reconciliation, lifecycle retirement, keşif ve 600/1200 @2x EN/TR erişilebilirliğini kapsar. Fiziksel tablet, iki gerçek istemcide eşzamanlı düzenleme veya gerçek ağ kabulü iddia edilmez; queue ilerlemesi bu dilimde değişmez.
