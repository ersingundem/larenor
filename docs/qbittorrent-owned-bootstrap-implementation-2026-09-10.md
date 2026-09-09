# qBittorrent sahipli bootstrap — uygulama ve açık kabul sınırı

**Tarih:** 10 Eylül 2026  
**Kuyruk:** S06.5 — özel bootstrap ve otomatik servis eşleştirme  
**PR:** [#28 — Define owned qBittorrent bootstrap configuration](https://github.com/ersingundem/larenor/pull/28)

## Bu dilimde tamamlananlar

- LinuxServer qBittorrent `5.2.3_v2.0.14-ls474` imajıyla eşleşen qBittorrent
  `v5.2.3` config sözleşmesi tanımlandı.
- `larenor-system` WebUI kullanıcısı için PBKDF2-HMAC-SHA512 parola kaydı,
  100.000 iterasyon, 16 bayt salt ve 64 bayt anahtar biçimi upstream kaynakla
  eşleştirildi.
- Core'a özel Bearer API anahtarı config içine alınırken sonuç ve hata
  gösterimleri sır içermeyecek şekilde kapatıldı.
- İndirme kökü `/data/downloads`, geçici indirme kökü `/data/incomplete`,
  WebUI/torrent portları ve WebUI güvenlik bayrakları sahipli config kapsamında
  tam olarak doğrulanıyor.
- Tek önceden doğrulanmış bağlantıda sırasıyla `/api/v2/app/version`,
  `/api/v2/app/preferences` ve `/api/v2/torrents/categories` okunuyor. Exact
  `v5.2.3` kimliği doğrulanmadan ayarlar kabul edilmiyor.
- `movies` ve `tv` kategorileri sabit yollarla idempotent biçimde eklenebiliyor.
  Mevcut doğru kayıtlar korunuyor; yanlış, yabancı veya biçimsiz kayıtlar yazma
  yapılmadan kapalı hata üretiyor.
- Yazma isteğinden sonra bağlantı kaybı otomatik tekrar denemeye dönüşmüyor;
  sonuç `uncertain_effect` ile insan incelemesine bırakılıyor.

## Güvenlik sınırı

Bu adaptörler hedef URL, host, resolver, proxy, ortam başlığı veya genel amaçlı
istek gövdesi kabul etmiyor. Sabit `Host: qbittorrent` ve Bearer başlığı yalnız
worker içinde önceden doğrulanmış akışta kullanılıyor. Yanıt boyutu ve toplam
süre sınırlı; redirect ve retry yok. Parola, PBKDF2 çıktısı ve Bearer anahtarı
public modele, hata metnine veya `repr` çıktısına taşınmıyor.

## Doğrulama

- 104 qBittorrent config, projeksiyon, kimlik, transport, kategori, timeout ve
  hata sözleşmesi testi geçti.
- Ortak Jellyfin HTTP çerçeveleme ve geri okuma testleriyle birlikte 149 test
  geçti.
- Değişen Python modülleri `compileall` kontrolünden geçti.
- Tek commitlik PR aralığında gitleaks sır taraması ve `git diff --check` geçti.

## Açık kabul kapıları

- Config bytes henüz doğrulanmış qBittorrent appdata hacmine atomik olarak
  yazılmıyor.
- Ortak medya hacmi qBittorrent'e `/data` yazılabilir ve Jellyfin'e `/media`
  salt okunur olarak bağlanan tek kaynak kanıtına dönüştürülmedi.
- Pinned amd64 ve arm64 qBittorrent container'larında başlatma, restart,
  exact sürüm/ayar/kategori geri okuması henüz çalıştırılmadı.
- Sonarr ve Radarr download-client bağlantıları, Seerr akışı ve kurulum
  koordinatörü bu dilimde bağlı değil.
- `installAvailable=false` korunuyor; gerçek ev Docker Engine'ine veya medya
  dosyalarına dokunulmadı.

Bu kapılar tamamlanmadan S06.5 veya kuyruk kabul sayacı artırılmayacak.
