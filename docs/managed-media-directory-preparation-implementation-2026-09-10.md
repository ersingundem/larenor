# Yönetilen medya dizini hazırlığı

Bu dilim, Larenor Core'un ortak medya hacminde ihtiyaç duyduğu iki sabit kökü
container binding'i kurulmadan önce hazırlar:

- Sonarr: `/data/shows`
- Radarr: `/data/movies`
- qBittorrent ve Arr servisleri aynı yönetilen hacmi `/data` olarak kullanır.
- Jellyfin aynı hacmi `/media` altında salt okunur tüketir.

Core, journal'daki güncel `managed_library` intent'ini yeniden doğrular. Yalnız
Larenor'un ürettiği hacim adı, kaynak/işlem kimliği, revision, journal nonce,
`jellyfin` sahipliği, `/media` hedefi ve `1000:1000` kullanıcı sözleşmesi tam
eşleşirse sabit helper çalışabilir. Helper ağsızdır; salt okunur rootfs, düşürülmüş
capability'ler, `no-new-privileges`, bellek ve süreç sınırları kullanır. Hacmi
yalnız `/volume` hedefine yazılabilir bağlar ve çağıranın seçemediği
`prepare_media_directories` komutunu çalıştırır.

Helper yalnız `movies` ve `shows` dizinlerini `0750`, UID/GID 1000 ile oluşturur
veya aynı güvenli durum zaten varsa kabul eder. Sembolik bağlantı, farklı inode,
yanlış sahiplik ya da izin çakışması başarı sayılmaz. Docker container
create/start/wait/remove işlemleri işlem başına 10 saniye, bütün kurulum ise
mevcut 120 saniyelik ortak deadline ile sınırlıdır.

Binding kanıtı, hazırlık makbuzunun aynı resource, operation, journal, nonce ve
revision'a ait olduğunu doğruladıktan sonra kökü yeniden salt okunur helper ile
kanıtlar. İstemci veya public API helper komutu, host yolu, Docker seçeneği,
volume adı ya da ağ hedefi sağlayamaz.

Yerel doğrulama:

- Yeni helper ve proof testleri önce eksik yöntemler nedeniyle beklenen RED
  sonucunu verdi.
- 27 odaklı volume/proof testi PASS.
- Jellyfin, qBittorrent, Sonarr/Radarr bootstrap ve installation paketlerinde
  180 test PASS.
- Ruff, `compileall`, security policy, kuyruk doğrulaması, `git diff --check`
  ve Gitleaks PASS.

Bu kaynak henüz exact GitHub CI ve gerçek amd64/arm64 native kabulünden geçmedi.
`installAvailable=false` korunur. qBittorrent'ın Sonarr/Radarr download-client
kaydı, Seerr bağlantısı ve Music Assistant bootstrap sonraki S06.5 dilimleridir.
