# F14 bağımsız işlev incelemesi — 1 Ekim 2026

İnceleme tabanı `e52b0708ab67b89f166745d7e2fbfb61b577de32` üzerindeki gerçek
Client ve normal Core kaynaklarıdır. Bu kayıt başarısız bağımsız incelemedir;
kapanış veya CI kanıtı değildir. F14 `reworking` durumuna alınmıştır.

## Somut eksikler

- `lib/features/server/support_sessions/presentation/server_support_sessions_screen.dart`
  token penceresi hesabın/evin/rolün veya parent route’un otoritesi değiştiğinde
  otomatik kapanmaz. Yakalanmış token için copy callback’i current authority
  ve sahiplik epoch’unu tekrar doğrulamadan clipboard’a yazabilir.
- `lib/features/server/support_sessions/data/server_support_sessions_controller.dart`
  action await sonrasında geçerliliği tekrar sınamaz; invalidate sonrası geç
  yanıt eski state veya tokenı commit edebilir.
- Belirsiz create yanıtı `needsRefresh` yapar, fakat ekranda açık bir yeniden
  listeleme/uzlaşma eylemi yoktur. Tekrar create göndermeden gerçek server
  kaydını bulup iptal edebilen görünür bir yol gerekir.
- Bu production Client yolu için adlandırılmış Flutter model/API/controller,
  dialog/navigation ve gerçek normal Core TCP kabul kapısı bulunamadı.

## Gerçekte geçen kanıt ve sınırı

Bağımsız ajan `server/.venv/bin/python -m pytest --collect-only -q
tests/test_f14_support_sessions_normal_core.py` ile **3** test topladı ve
odaklı koşuda **3/3** geçti. Önceki “6 focused +44 admin” kaydı bu Client
kapısının kanıtı değildir. Server incelemesi gerçek normal `create_app`
composition’ını, HMAC/tamper ve hash-only tek gösterimli tokenı, 20 dakika
sınırını, owner/family/admin/revoke/expiry/current core-home yetkisini ve
beş sabit bounded salt okunur görünümü doğruladı. Shell veya serbest komut
yolu bulunmadı. Bu Server kanıtı Client yaşam döngüsü eksiklerini kapatmaz.

## Kapanış kapısı

Dialog sahipliği ve oturum değişimi çiti, her await sonrası current authority
altında state commit’i, belirsiz mutation sonrası tekrar göndermeden listeleme
uzlaşması ve gerçek Flutter→normal Core TCP/restart kabulü geçmelidir.
Düzeltme sonuçları ayrı adlandırılmış kanıtta kaydedilecek; bu tarihsel
başarısız inceleme korunacaktır. Fiziksel clipboard/uzak destekçi ve geniş
final HEAD CI ayrı kapılardır. Gizli token ve gerçek ev cihazı kullanılmadı.
