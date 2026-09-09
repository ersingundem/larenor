# qBittorrent config helper — uygulama ve açık kabul sınırı

**Tarih:** 10 Eylül 2026
**Kuyruk:** S06.5 — özel bootstrap ve otomatik servis eşleştirme

## Tamamlanan yardımcı etkisi

Paketli `volume_bootstrap_helper.py`, doğrulanmış qBittorrent config bytes
değerini yalnız stdin üzerinden kabul eden `install_qbittorrent_config` modunu
kazandı. Çağrı bir yol, dosya adı, kullanıcı, volume veya genel komut kabul
etmiyor. Tek yazma hedefi `/volume/qBittorrent/qBittorrent.conf`.

Yardımcı depolamaya dokunmadan önce config satırlarının sırasını ve tamamını
allowlist ile doğruluyor. `/data/downloads`, `/data/incomplete`, CSRF,
clickjacking, host header, secure cookie, localhost auth, UPnP, server domain,
sabit sistem kullanıcısı, ayrık geçerli portlar, özel API anahtarı ve
qBittorrent PBKDF2 salt/key boyutları exact eşleşmeli.

Kabul edilen yazmada:

- mount kökü ve alt dizin `1000:1000 / 0750`, hedef dosya `1000:1000 / 0600`
  olarak doğrulanıyor;
- kök, alt dizin ve dosyalar yalnız `dir_fd`, `O_NOFOLLOW` ve sabit adlarla
  açılıyor;
- geçici dosya `O_EXCL` ile oluşturuluyor, eksiksiz yazılıp `fsync` ediliyor;
- hard-link yayını mevcut hedefin üzerine yazmadan atomik sonuç üretiyor;
- hedef, içerik, inode, boyut ve link sayısı yeniden okunuyor;
- aynı exact config idempotent kabul ediliyor; farklı dosya, link veya yarım
  geçici etki korunup insan incelemesine bırakılıyor.

Başarı çıktısı yalnız şema, kapalı durum ve SHA-256 özeti taşır. Config, parola
hash'i ve API anahtarı stdout/stderr ya da hata metnine girmez.

## Doğrulama

- 16 yeni config yazma, idempotency, bozuk giriş ve dosya sistemi çatışması
  vakası eklendi; helper paketi 41 testten geçti.
- Config üretimi, journal bağı, ortak library tüketicileri ve runtime testleriyle
  birlikte 136 ilgili test geçti.
- Python derleme, diff, kuyruk şeması ve secret taraması teslim kapısına dahil.

## Açık kabul kapıları

- Core worker henüz config bytes değerini Docker stdin üzerinden bu moda
  göndermiyor; yardımcı public API'den çağrılamıyor.
- Yazma öncesi ve sonrası aynı journal, daemon ve retained volume lease'i için
  yeni bir effect receipt üretilmedi.
- qBittorrent container create/start ve authenticated readback aynı native
  işlemde bağlanmadı.
- AMD64 ve ARM64 gerçek yardımcı/container kabulü tamamlanmadan
  `installAvailable=false` ve S06.5 sayacı korunuyor.

Sonraki dilim private binding'i stdin-enabled, networksüz, read-write appdata
mount'lu Docker helper yürütücüsüne bağlayacak ve etkiden sonra journal kaynağını
yeniden doğrulayacak.
