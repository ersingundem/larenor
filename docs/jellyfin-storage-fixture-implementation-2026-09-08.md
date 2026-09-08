# Jellyfin storage karakterizasyon fixture'ı

8 Eylül 2026. Taban `960691c113b10e08ebddf75d464b99e74bdd4cb1`, dal
`codex/jellyfin-storage-fixture`; ilk kaynak/test freeze
`25d5e0c523609d86a87508b638c521ac5d3254f8`; bağımsız inceleme sonrası
kaynak düzeltmesi `9a9d477`. İlk `7990fe9` teslimi ara kanıt olarak korunur. Bu, `25e211c` planındaki ilk
checkpoint'in çalıştırılabilir fixture'ıdır. **Gerçek Docker/daemon/image build,
amd64/arm64 CI veya ev kurulumu bu teslimde çalıştırılmadı.**

## Eklenen gerçek akış

- [Helper](../tool/volume_bootstrap_helper.py) yalnız `/volume` üzerindeki
  ayrı Linux mount'u held FD ile açar. Boş `0:0/0755` kökün kendisini
  `1000:1000/0750` yapar; recursive chown, seed kopyalama, path/komut girdisi
  ve otomatik rollback/retry yoktur. Kısmi metadata etkisi korunur.
- [Probe](../tool/jellyfin_storage_probe.py) fixture'ın kendi sentinel'ını,
  yazılabilirliği, ilk SQLite/config dosyasını, kapalı loopback health'i ve
  uygulamanın PID 1 UID/GID'sini ölçer. Bilinen image sentinel'ının NoCopy
  volume'a taşınmamış olması da akışın koşuludur.
- [Runner](../tool/jellyfin_storage_smoke.py) gerçek paket kataloğu ve mevcut
  `JournaledImageOperations`/`JournaledVolumeCreates` ile yalnız Jellyfin'in
  iki dedicated `/config` ve `/cache` volume'unu hazırlar. Helper sonrasında
  pinli Jellyfin'i `1000:1000`, iki NoCopy mount ve portsuz `network=none`
  profiliyle başlatır; ilk veri/health, bir restart ve aynı Server ID/sentinel
  sonuçlarını zorunlu tutar. Eski mountsuz worker doğrulayıcısını kullanıma
  açmaz veya gevşetmez.

Fixture CLI yalnız `--run-ephemeral-ci` kabul eder. Kendi yeni `/tmp` kökü,
socket/data/exec dizinleri, mount/PID namespace'i ve dockerd sürecini üretir;
socket/platform girdisi veya ortam `DOCKER_HOST` fallback'i yoktur. Docker
client config'i boştur; varsayılan bridge/iptables/IP forwarding kapalıdır.
İzin verilen çalışma ortamı native Linux GitHub-hosted amd64/arm64 ve root'tur.
Bu kontroller yanlış kullanımı sınırlayan fixture koşullarıdır, production
actor/daemon grant'i değildir.

Her CLI çocuk sürecinin çıktı/süre sınırı ve tüm sahip olunan süreç grubuna
kill/reap uygulanır; ana süreç erken çıksa da alt süreç atlanmaz. Daemon
cleanup yalnız kendi namespace/process grubunu ve kimliği değişmemiş geçici
kökünü toplar. Normal Engine'de prune/delete veya dış volume adı seçimi yoktur.
Komut/HTTP süreleri ayrı sınırlardır; bütün filesystem/syscall zincirine tek
kesin süre garantisi verilmez.

[Helper Dockerfile](../server/Dockerfile.volume-bootstrap) mevcut pinli Python
base'ini kullanır. Legacy builder, Dockerfile'a özel `.dockerignore`
dosyasını uygulamadığından runner artık checkout'u build context olarak vermez.
Kendi özel kökü altında yeni `helper-context` dizinine yalnız helper, probe,
Dockerfile, LICENSE ve NOTICE kopyalanır. `.git`, artifact'lar ve diğer repo
dosyaları context'e girmez; ignore dosyasına güvenilmez.
[Docker belgeleri](https://docs.docker.com/reference/cli/docker/image/build/#build-context-with-the-legacy-builder)
legacy context'in tamamının aktarıldığını açıklar;
[CLI kaynağı](https://github.com/docker/cli/blob/master/cli/command/image/build.go)
context kökündeki `ReadDockerignore` yolunu kullanır. Gerçek koşuda local build IID,
inspect platform/config ID, checkout commit'i ve image'a gömülen kaynak bundle
hash'i eşleştirilir. Bu local build kaydı yayımlanmış/signed OCI provenance
değildir; `publishedManifestDigest=null` kalır. Helper digest'i uydurulmadı.

## İlk teslimin TDD ve yerel kanıtı

| Checkpoint | Gerçek sonuç |
| --- | --- |
| `da9e62a` → `bd31d49` | Eksik helper/build: **6 test FAIL + 16 fixture/setup ERROR** → 22 PASS. 22 runtime ürün hatası değildir. |
| `e8f8003` → `e35855e` | Eksik owned-daemon sınırı/primitives composition: 21 FAIL → 21 PASS. İlk boundary checkpoint'i henüz tam consumer değildi. |
| `580c594` → `99465fe` | Eksik probe/consumer: 12 FAIL + 21 PASS → birleşik 55 PASS. |
| `c0dfe13` → `15c59db` → `5c37b51` | Uygulama UID oracle'ı ve statik CLI hatası: 3 FAIL + 40 PASS. `15c59db` henüz GREEN değildir: koşuda kalan test-only NameError görülmeden commit edilmişti. Yanlış fonksiyona taşınan assertion'lar `5c37b51` ile yerine döndü; 65 PASS. |
| `3ead64d` → `871110b` | Kaynak/etiket bağı ve exited-parent süreç grubu: 4 FAIL + 36 PASS → 73 PASS. Gerçek yerel alt süreçle cleanup RED doğrulandı. |
| `25d5e0c` | Üç pytest dosyası Server tests'e taşındı; Server cwd'den 73 PASS. Security'nin dependency-free unittest dizinine pytest yüklenmez. |

İlk full-flow test kurulumunda uzun macOS temp socket yolu nedeniyle alınan
hatalar ürün RED sayılmadı; kısa owned temp fixture ile gerçek RED tekrar
ölçüldü. Dockerfile yorumundaki `VOLUME` sözcüğünü direktif sanan test de
düzeltilmiştir. İlgili regresyonun ilk komutunda bulunmayan `test_worker.py`
adı nedeniyle collection 0 oldu; aşağıdaki 261 sayısı düzeltilmiş gerçek koşudur.

Sonuçlar farklı kümelerdir; tam Core veya gerçek Engine koşusu değildir:

- **73 PASS**, 0 fail/error/skip, 2.62 s: Server `test_volume_bootstrap_helper.py`,
  `test_jellyfin_storage_probe.py`, `test_jellyfin_storage_smoke.py`.
- **261 PASS**, 0 fail/error/skip, 11.08 s: mevcut worker/startup safety,
  image preparation, volume preparation/plan ve media stack plan testleri.
- **207 unittest PASS**, 45.479 s: mevcut Security araç testleri. Kesinti
  sonrasında eski process handle erişilemedi; tamamlanmış `OK` logu vardır.
  Bu kayıt için yeni bir exit/reap sonucu uydurulmadı.
- Dal kapsamı dahil coverage: helper **%82.83**, probe **%81.48**, runner
  **%91.79**, toplam **%87.83**. Gerçek Linux mount/PID/daemon dallarının tamamı
  yerel mock sonucundan doğrulanmış sayılmaz.
- Üç Python kaynak AST parse, diff whitespace kontrolü ve 12 owned commit
  üzerinde redacted gitleaks: temiz. Import yolları bu worktree'ye doğrulandı.

Özel kanıtlar `/private/tmp/larenor-jellyfin-fixture-*` prefix'indedir:
`focused-final.log`/`focused.xml`, `compat-corrected.log`/`compat.xml`,
`tool-compat.log`, `coverage-final.json`, `gitleaks.log` ve delivery receipt.

## Bağımsız inceleme sonrası kaynak/context düzeltmesi

İki P2, `a65ff3c` checkpoint'inde **4 gerçek FAIL** ile doğrulandı:
legacy build'in tüm checkout'u alması; ilk commit kontrolünden sonra hazırlık
sırasında helper veya LICENSE değişiminin yeni hash ile eski commit'e
bağlanabilmesi; LICENSE'ın Git temizliğine dahil olmaması. `9a9d477` ile
**77 PASS**, ilave sınır regresyonlarıyla **87 PASS / 2.53 s** alındı.

CLI, daemon başlamadan önce clean commit kontrolü arasında yedi dosyanın
immutable hash bağını yakalar: helper, probe, runner, Dockerfile, ignore,
LICENSE ve NOTICE. Consumer bu bağı hazırlık sonrasında, staging öncesi/sonrası,
build sonrasında ve sonuçtan önce yeniden doğrular. Staged beş dosyanın da
beklenen byte hash'leri kontrol edilir. Kaynak okumaları 1 MiB sınırında,
regular-file ve final-component no-follow şartındadır. Mevcut stage tekrar
kullanılmaz; failure başarı kaydı üretmez. Bu, ayrı imzalı provenance veya
kötü niyetli eşzamanlı yerel writer/ABA'ya karşı atomik filesystem snapshot
iddiası değildir.

Ek testler gerçek yerel geçici dosyalar ve fake Docker consumer ile daemon
başlangıcındaki drift'i, build sırasında staged/checkout değişimini, beklenmeyen
context dosyasını, son oracle sırasında değişimi ve read/copy sınırlarını kapsar.
Docker çalıştırılmadı. Coverage (dal dahil): helper **%82.83**, probe **%81.48**,
runner **%95.05**, toplam **%90.13**. İlgili altı mevcut Server test dosyasında **261 PASS / 11.53 s**
alındı; tam Core tekrarlanmadı. Kaynak+test dondurulunca readonly inceleme
ayrıca kapatılır. İlk coverage komutundan önce yanlış cwd ile test append
başarısız olduğu için o 77-test koşusu genişletilmiş 87-test kanıtı sayılmaz.

Güncel özel loglar `/private/tmp/larenor-jellyfin-context-*` prefix'indedir;
önceki receipt/loglar değiştirilmemiştir. İlgili regresyon komutunda yanlış
`test_startup_safety.py` adıyla collection 0 olan hazırlık denemesi kabul
sayılmaz; doğru dosya `test_plugin_worker_startup_safety.py` ile sonuç ayrı kaydedilir.

## Açık kalan gerçek kabul

Native ephemeral CI workflow taslağı sonraki ayrı inceleme adımıdır; bu paket
bir workflow başlatmaz. Kernel'de root helper için `CHOWN` yeterliliği,
chown sonrası held-FD scandir/fsync, gerçek iki image platformu, ilk Jellyfin
dosya yolları ve namespace cleanup o koşuda doğrulanmalıdır. Başarısızlık
veya Engine yokluğu success/skip'e çevrilmez; profil varsayımı yanlışsa açık
karakterizasyon hatası kalır.

Bu fixture ilk Jellyfin hesabını kurmaz (`bootstrapAccountConfigured=false`).
Durable mounted-container installer, gerçek actor/native issuer, özel hesap
bootstrap'ı ve authenticated Core bağlantısı planın sonraki sonlu adımlarıdır.
Server API/runtime, katalog/plan biçimleri, eski worker guard'ları, contracts
ve Android değişmedi; `installAvailable=false` korunur. S06 kurulum veya ev
donanımı kabulü eklenmez.
