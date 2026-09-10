# S06.5 — Sonarr/Radarr sahipli yapılandırma yazıcısı

Bu dilim, Larenor'un daha önce exact olarak ürettiği Sonarr ve Radarr
`config.xml` baytlarını yalnız journal ile kanıtlanmış yeni `/config` hacmine
yazabilecek kapalı helper komutlarını ekler. Helper servis, yol, dosya adı,
kullanıcı veya izin seçimini çağırandan almaz.

## Uygulanan sınır

- `install_sonarr_config` yalnız Sonarr `4.0.19.2979` için sabit port, örnek adı
  ve güvenlik alanlarına sahip exact XML'i kabul eder.
- `install_radarr_config` yalnız Radarr `6.3.0.10514` için aynı kapalı sözleşmeyi
  kabul eder. Bir servisin dosyası diğer komutta kullanılamaz.
- Özel yapılandırma yalnız stdin'den, en fazla 4096 byte olarak alınır. Çıktı
  sadece sabit durum ve SHA-256 özetidir; API anahtarı veya XML geri dönmez.
- Hedef yalnız `/volume/config.xml` olabilir. Helper UID/GID `1000:1000`, hacim
  modu `0750` ve sonuç dosyası modu `0600` olmadan yazmaz.
- `O_NOFOLLOW`, `O_EXCL`, tek-link doğrulaması, geçici dosyaya tam yazma,
  `fsync`, hard-link ile üzerine yazmayan yayın ve exact geri okuma uygulanır.
  Symlink, dizin, hardlink, yanlış izin, yabancı içerik ve kalan geçici dosya
  korunur ve insan incelemesi gerektiren sabit çakışma sonucuna dönüşür.
- Aynı exact dosya ikinci çağrıda değiştirilmeden kabul edilir. Farklı veya
  belirsiz mevcut içerik hiçbir zaman sahiplenilmez, silinmez ya da düzeltilmez.

## Kanıt ve açık iş

- Exact kaynak `0643801437eb1a39089e6c7f0a71bff32ded6661`.
- Helper paketinde **58 PASS**; owned yapılandırma paketiyle **94 PASS**.
- `compileall`, güvenlik politikası, kuyruk ve diff kontrolleri PASS.
- Önceki owned-renderer kaynağı `45f53ea` için
  [Android/Server CI 34439991038](https://github.com/ersingundem/larenor/actions/runs/34439991038)
  Android analiz, API 35 emulator E2E, debug APK ve Server kapılarını geçti;
  bağımsız Security ve amd64/arm64 medya karakterizasyonları da yeşil.

Bu helper tek başına Docker etkisine veya kurulum yetkisine sahip değildir.
Sıradaki dilim, config baytlarını container metadata'sına koymadan sabit ağsız
helper'a ileten journal-bound effect'i bağlayacak. Ardından aynı retained daemon
üzerinde Sonarr/Radarr başlangıcı ve `X-Api-Key` ile authenticated
`/api/v3/system/status` geri okuması iki mimaride doğrulanacaktır. S06.5 ve
`installAvailable=false` açık kalır.
