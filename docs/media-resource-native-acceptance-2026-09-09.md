# S06.3f — native image ve control-network kaynak kabulü

Bu dilim Larenor Core’un kuruluma geçmeden önce ihtiyaç duyduğu iki Engine
kaynağını gerçek Linux üzerinde sınamak için dar bir fixture ekler. Çıktı
`resources_ready` durumudur; hizmetin kurulduğunu, çalıştığını veya sağlıklı
olduğunu bildirmez. `installAvailable=false` kalır.

## Etki sınırı

Fixture yalnız katalogda digest ile sabit Jellyfin image’ı için pull ve inspect,
tek `Internal=true`, `Attachable=false` control network için create, tam adla
list ve full-ID inspect çağrılarını yapabilir. Container create/start/exec,
volume API, network attach/delete, image delete ve prune yüzeyi yoktur. Var olan
bir Docker socket’i veya `DOCKER_HOST` kabul edilmez; manual GitHub workflow’u
yalnız kendisinin oluşturduğu geçici rootful Engine ve sahiplikli transient
systemd cgroup’u içinde çalışır. Ortak daemon açılışındaki `docker info` yolu
bu fixture için override edilmiştir: aktif systemd MainPID’nin cmdline değeri,
başlatılan `/usr/bin/dockerd` argv’sinin tamamı ve owned `--data-root` dahil
bayt düzeyinde eşleşir. Fixture’ın `docker()` yüzeyi her çağrıyı reddeder.

İlk mutation öncesinde literal `True` yetki kapısı ve güncel journal revision
kontrol edilir. Pull veya create yanıtı kaybolursa mevcut journal sözleşmesi
yalnız taze gözlemle uzlaştırır; mutation otomatik tekrarlanmaz. Hazır image ve
network makbuzları aynı journal kapatılıp yeniden açıldıktan sonra bütün Engine
bağımlılıkları hata verecek nesnelerle değiştirilerek yeniden okunur. Böylece
restart kanıtı yeni I/O veya gizli bir mutation’a dayanmaz.

Public makbuz sabit, tam alan kümesine sahiptir: kaynak commit’i ve allowlist
dosya SHA-256’ları, platform, katalog ve image config digest’i, iki hazır durum,
iki kaynak türü, bir journal restart, sıfır container işlemi ve
`installAvailable=false`. Dinamik network ID ve preparation ID yayımlanmaz;
network ID yalnız tek yönlü SHA-256 olarak kaydedilir. Verifier 32 KiB sınırı,
yinelenen JSON alanları, non-finite sayılar, alan/tür/değer değişiklikleri ve
değişmiş kaynak hash’lerinde kapalı hata verir.

## Yerel doğrulama

- Eksik modül/workflow başlangıcı: 17 beklenen RED.
- Yeni smoke, CI ve workflow güvenlik sözleşmesi: 44/44 PASS.
- Image, network, journal ve iki native workflow regresyon seçkisi: 674 test,
  yalnız mevcut platform skip’leriyle PASS.
- `tool/check_security_policy.py`, JSON parse, Python compileall,
  `tool/execution_queue.py validate` ve `git diff --check`: PASS.
- Tam Server + araç koleksiyonu 4.284 test içeriyor. Ortam verilmeden yalnız
  dört release-verifier testi zorunlu apksig değişkeninde setup hatası verdi;
  depodaki apksig 9.1.0 dosyası beklenen
  `562cd0a88890960d2ece48e116c61f12872222f1dcc306890799382bc019b201`
  SHA-256 ile doğrulandı ve Homebrew Java 17 ile aynı testler 4/4 PASS oldu.

S06.3d’nin Native18 koşusu managed volume UID/GID, NoCopy, başlangıç verisi,
container restart kalıcılığı ve taze sahiplik uzlaştırmasını amd64/arm64 için
zaten kanıtladı. S06.3f ancak bu commit’in bağımsız Server CI’ı, iki mimarili
native workflow’u ve indirilen iki receipt’in yeniden doğrulaması başarılı
olduktan sonra tamamlanabilir.
