# Jellyfin native storage: ayrı manuel CI kapısı

8 Eylül 2026. Dal `codex/jellyfin-storage-workflow`, taban
`58970d60926189472938d46d07c5f88ada047cea`. Bu taban, `7990fe9` fixture'ının
bağımsız incelemesindeki iki kaynak/context P2'sini kapatır. Workflow bu
fixture'ı tüketir; helper, probe, runner, Dockerfile ve Server üretimi değişmez.
**Bu teslimde Docker, native workflow, ev/Engine bağlantısı veya push yapılmadı.**

## Çalıştırılabilir sınır

[Yeni workflow](../.github/workflows/jellyfin-storage-characterization.yml)
yalnız `workflow_dispatch` ile çalışır. Koşu `ersingundem/larenor`,
`refs/heads/main`, aynı `GITHUB_SHA`/`GITHUB_WORKFLOW_SHA` ve GitHub-hosted
ortam şartını sağlar; uyumsuz seçim başarısız olur, job skip edilmez.
Checkout exact SHA kullanır ve credential kalıcılığı kapalıdır. Matrix iki
ayrı native VM ister; QEMU, self-hosted, varsayılan Docker veya buildx yolu yoktur.

| Etiket | Runtime eşleşmesi | Artifact son eki |
| --- | --- | --- |
| `ubuntu-24.04` | Linux x86_64 / X64 / linux/amd64 | X64 |
| `ubuntu-24.04-arm` | Linux aarch64 / ARM64 / linux/arm64 | ARM64 |

[GitHub runner belgesi](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
bu iki native Linux etiketini ve hosted VM'lerde passwordless sudo desteğini
listeler. [Değişken sözleşmesi](https://docs.github.com/en/actions/reference/workflows-and-actions/variables)
RUNNER_ARCH/RUNNER_ENVIRONMENT ile kaynak SHA'nın anlamını tanımlar.
Bu ortam değerleri fixture yanlış-kullanım kapısıdır; gerçek kurulum yetkisi değildir.

Varsayılan repository izni yalnız `contents: read`; package, OIDC ve kullanıcı
secret girdisi yoktur. Checkout/upload action'ları mevcut repo CI'sındaki tam
commit SHA'larına bağlıdır. [GitHub güvenlik kılavuzu](https://docs.github.com/en/actions/reference/security/secure-use#using-third-party-actions)
immutable action referansı için tam commit SHA kullanılmasını önerir.
Python 3.12.14, uv 0.12.10 ve mevcut `server/uv.lock` ayrı geçici ortamda kullanılır.
Helper base image ve Jellyfin catalog image digest'leri fixture'ın pinleridir.

Hosted Ubuntu image'i, kernel ve önceden kurulu `/usr/bin/docker`, `dockerd`,
`unshare` sürümleri GitHub tarafından güncellenir; bunları immutable olarak
pinlediğimiz iddia edilmez. Koşunun runner-image/setup metadatası exact native
kanıta dahil edilmelidir. Sabit API 1.47, legacy build, vfs, mount/PID namespace
ve root helper profilini desteklemeyen ortam açık failure üretir; alternatif
Engine/tool kurma veya ev socket'ine düşme yoktur. Legacy builder deprecation'ı
fixture'ın gerçek karakterizasyon kapısında ayrıca görünür kalır.

## Launcher, bütçe ve cleanup

[CI launcher](../tool/jellyfin_storage_ci.py), frozen runner'ın
`capture_source` → `EphemeralDaemon` → `characterize` akışını çağırır. `exec sudo
--non-interactive env -i` ile shell giriş süreci devredilir; root Python'a yalnız
PATH/PYTHONPATH ve kapalı CI/kaynak/platform değerleri aktarılır. HOME,
DOCKER_HOST/config, proxy, access token ve secret ortamı aktarılmaz. Docker
çocuklarının ortam/config/root/soket sınırları frozen fixture'da kalır.

Job **25 dakika**, native adım **22 dakika**, launcher alarmı **20 dakika** ile
sınırlıdır. Alarm işin tamamını sınırlamak ve normal durumda cleanup/artifact
adımlarına pay bırakmak içindir; filesystem/syscall veya GitHub'a tek atomik
süre garantisi değildir. Fixture'ın daha kısa komut/HTTP sınırları korunur.

SIGINT/SIGTERM/alarm, yalnız launcher'ın tuttuğu daemon süreç grubuna SIGKILL
uygular ve context'ten exception ile çıkar. Frozen bounded-command finally
bloğu o anki CLI çocuğunu; daemon context'i kendi süreç/dizinini toplar. İlk
iptal işlenirken sonraki sinyaller cleanup'ı bölmez. Başarı JSON'u ancak context
cleanup ve son kaynak kontrolünden sonra yazılır. Normal Engine'de prune veya
isimle kaynak keşfi yoktur.

[GitHub cancellation sözleşmesi](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-cancellation)
step giriş sürecine önce SIGINT, ardından SIGTERM ve gerektiğinde process-tree
kill uygular. Yerel test gerçek bash girişinde `exec` gereğini doğrular. Fakat
SIGKILL, VM kaybı veya kesilemeyen kernel işlemi için Python cleanup garantisi
verilmez; gerçek native namespace/process cleanup kabulü henüz çalıştırılmadı.

## Sonuç ve test kanıtı

Yalnız kapalı schema'lı, en fazla 32 KiB JSON receipt doğrulanır: kaynak SHA,
native platform, gerçek katalog/config/manifest pinleri ve yedi source hash,
iki volume, bir restart, aynı fixture Server ID ve hazır image/volume durumları.
Bilinmeyen/tekrarlı key, bozuk JSON/UTF-8, NaN, yanlış bool/type/count, başka
source/platform veya fabricated published helper digest reddedilir. Doğrulama
adımı Engine başlatmaz. Dosya sadece public fixture kanıtıdır; image Config/Env,
private path veya token içermez.

Artifact adı `jellyfin-storage-<exact SHA>-X64|ARM64`; yalnız doğrulanmış receipt
alınır. Eksik dosya veya upload failure job'u başarısız yapar. Matrix fail-fast
kapalıdır, fakat iki mimari de başarılı olmadıkça native kabul tamam değildir.
Skip, cancellation veya bir tek platform receipt'i çift mimari başarı sayılmaz.

- `2b90c2d` RED: eksik launcher için **29 assertion FAIL**, eksik workflow için
  **5 unittest FAIL**; setup/compile error yok. `0e37599` minimal GREEN:
  **29 + 5 PASS**. İlk signal fake'inde GITHUB_SHA verilmemesi üç test failure
  üretmişti; env fixture düzeltilerek actual signal akışı çalıştırıldı.
- `b1d6e6e` RED: gerçek shell entry cancellation **1 FAIL / 7 PASS**;
  `6cd2298` `exec` handoff ile **8 PASS**. İlk harness'te açık pipe yüzünden
  communicate timeout'u ve macOS otomatik locale anahtarı iki false negative
  ayrıca düzeltildi; bunlar ek production bug sayılmaz.
- Final launcher + frozen üç fixture dosyası: **122 PASS / 3.34 s**, sıfır skip.
  Yeni launcher dosyası **35 test** içerir; frozen fixture kümesi 87 testtir.
  Gerçek yerel synthetic subprocess SIGTERM/kill/reap ve actual extracted-shell
  sanitized-env/nonzero-exit testleri vardır; Docker çalıştırılmaz.
- Yeni launcher coverage: **93/94 satır + 22/24 branch, %97.46**. Native kernel
  başarısı yerine kullanılamaz. Server production/full Core tekrar koşulmadı.
- Security'nin dependency-free unittest keşfi yeni **8** policy testi toplar;
  pytest testleri `server/tests` altındadır. İlk broad policy denemesi macOS'un
  eklediği locale anahtarı nedeniyle 214 testte iki FAIL verdi; düzeltilmiş tam
  koşu **215 PASS / 49.454 s**, exit 0 ve reap ile tamamlandı.

Özel kanıt prefix'i `/private/tmp/larenor-jellyfin-workflow-*`: `focused.log`,
`focused.xml`, `coverage.json`, `policy-final-verified.log`, `shell-red-verified.log`,
`shell-green.log` ve delivery receipt. Eski 7990fe9 ve kaynak/context onarım
receipt'leri korunmuştur.

Bu kapı `bootstrapAccountConfigured=false` ve `installAvailable=false`
sonucunu zorunlu tutar. Gerçek first-account bootstrap, mounted-container
installer journal, actor/native issuer ve ev donanımı kabulü sonraki plan
adımlarıdır. Workflow yalnız kaynak incelemesi ve root'un ayrı yayın/dispatch
kararından sonra native kanıt üretebilir; bu belge koşu başarısı iddiası değildir.
