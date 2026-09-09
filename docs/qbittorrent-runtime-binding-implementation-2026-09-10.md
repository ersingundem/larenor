# qBittorrent config runtime bağı — uygulama ve açık kabul sınırı

**Tarih:** 10 Eylül 2026
**Kuyruk:** S06.5 — özel bootstrap ve otomatik servis eşleştirme

## Tamamlanan worker bağı

Larenor installation worker artık qBittorrent config etkisini çağırmadan önce
paketlenmiş medya stack'ini yeniden doğruluyor, güncel volume planını üretiyor ve
yalnız `qbittorrent` servisinin `managed_appdata` türündeki `/config` kaydını
worker-owned `VolumeCreateJournal` içinden yeniden bağlıyor. Client veya IPC
çağrısı host yolu, volume adı, Docker komutu, container gövdesi ya da helper
imajı seçemiyor.

Runtime parolayı, Bearer API anahtarını ve kalıcı idempotency için gereken
16-byte salt değerini yalnız özel bellekte config binding'e iletiyor. Helper
imajı digest ile sabit, platform yalnız `linux/amd64` veya `linux/arm64` ve
Docker endpoint'i operator policy'den geliyor. Bilinmeyen adapter hataları ham
mesaj taşımayan, belirsiz etki işaretli sabit koda indirgeniyor.

Installation supervisor'a eklenen kapalı çağrı aynı native thread üzerinde
çalışıyor. Retained daemon lease, socket kimliği, peer pidfd/proc kanıtı,
daemon startup/security attestation ve worker Engine bağlantıları etkiden önce,
iç gate çağrılarında ve etkiden sonra yeniden sınanıyor. Kanıt kaybederse
supervisor kapanıyor ve başarı dönmüyor.

## Doğrulama

- Yeni runtime seçimi, stale/corrupt journal, kapalı girdi, pinned image/platform
  ve secret-free bilinmeyen etki testleri: 12.
- Installation runtime ve retained-daemon supervisor ile birlikte 71 test
  toplandı; 70 geçti, mevcut Linux-only peer-pidfd testi macOS'ta atlandı.
- Engine/config/volume zinciri de katıldığında 345 ilgili test toplandı; 343
  geçti ve iki mevcut Linux-only test macOS'ta atlandı.
- Değişen Python kaynakları `compileall` ve diff kontrolünden geçti.

## Açık kabul kapıları

- Bu özel runtime metodu henüz UID-korumalı installation IPC operasyonuna ve
  şifreli, kalıcı qBittorrent config job state'ine bağlı değil.
- Salt/parola/API anahtarı için restart sonrası aynı isteği güvenle sürdürecek
  encrypted coordinator kaydı henüz yok.
- Config effect receipt'i qBittorrent managed container create/start önkoşulu
  haline gelmedi.
- Gerçek qBittorrent 5.2.3 üzerinde iki mimarili config, authenticated readback,
  kategori ve restart kabulü tamamlanmadı; `installAvailable=false` korunuyor.
