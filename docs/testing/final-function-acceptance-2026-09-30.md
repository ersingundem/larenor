# FINAL.FUNCTION acceptance evidence

## Current state — 1 October 2026

FINAL.FUNCTION is the only active final. Development and focused validation are complete for **58 selected features / 69 tasks**, which await the complete branch-source CI. F21/F24/F25/F26/F27 completed the normal Core player and offline-entry composition, independently verified by root110 Client and46 Server tests. Only F60/F62 remain `reworking` for actual native runtime acceptance. Accepted counts stay **35/127 tasks (27.6%) and3/63 selected features (4.8%)**. Physical, household and account gates remain MANUAL; the next final starts only after this final completes. The older results below are source-specific historical evidence, not current counters or broad latest-HEAD acceptance. [Current queue](../EXECUTION_QUEUE.md), [media closure](media-core-composition-closure-2026-10-01.md).

| Gate | Latest named evidence | Open boundary |
| --- | --- | --- |
| F01/F02/F03 durable history | Root live-source22/22, default256/128 and signed4096-event restart capacity; current/live/replay/tamper/rollback protected | Broad finalHEAD CI; household HA observation/device effects separate |
| F14 support lifecycle/retention | Root11/11Client, normal TCP two-process sameDBrestart1+1, Server3/3; retention9/9 | Broad finalHEAD CI; actual clipboard/supporter MANUAL |
| F58 e-paper retention | Root18/18, signed2000history/restart, owned HA/OEPL HTTP | Actual physical label/display delivery MANUAL; broadCI |
| F59 workshop retention | Root28/28normal Core/owned HTTP/default10000signedhistory/restart; current/replay/unknown/tamper/rollback | Physical printer/sensors MANUAL; broadCI |
| F57 calibration retention | Root30/30normal Core/owned HA/fusion/retention; true256capacity/restart; conservative v1migration/current/replay/uncertain/newest32terminal/tamper/rollback | Broad finalHEAD CI; calibration is advisory/local, no physical mmWave reconfiguration claim |
| F21/F24/F25/F26/F27 media composition | Normal verified-Core local-player entry, leader/follower controls, actual reported track selection, validated segment seek, non-recording quality advice, explicit single-use playback lease and completed encrypted offline inventory; root110 Client/46 Server tests passed | All five await complete-source CI; physical decoding, rendering, multi-device timing, storage pressure and provider DRM/account limits remain MANUAL |
| F60 NSD | Embed-v3 exact `36269cf0`, run `36813871246`: canonical 1 test / 0 skips / 0 failures / 0 errors, two fresh discovery lifetimes; bounded receipt independently verified | streamAccepted=false; discovery does not prove streaming |
| F60 streaming | Exact `691b54c4` source added closed dispatch-stage/cause diagnostics; root42 native JVM tests with zero skips,60 runner/workflow checks and actual AndroidTest compile277 passed | [Run36825268673](https://github.com/ersingundem/larenor/actions/runs/36825268673) failed original1/1/0/0: firstStreamOutput, closed dispatch beforeIssue/IllegalArgumentException/none, unknown command and absentOrUnreadable lease. The precise guard and visible uncertain-local-session cleanup are under focused repair. Actual frame/PCM/input/two-lifetime/stop/disconnect acceptance remains open |
| F62 native RDP | Exact `6bbe8b03` source-locked test-body stage/class diagnostics passed root57 checks/40subtests, actual AndroidTest compile277 and independent privacy/fence review | [Run36826438225](https://github.com/ersingundem/larenor/actions/runs/36826438225) is running. Previous exact5aa run36822994907 passed arm64 packaging but failed x86 original1/1/0/0 with unclassified/no owned frames/lifecycle marker. Strict TLS/NLA/SPKI/frame/ACK/key/DISP/Unicode/disabled clipboard/two-lifetime acceptance remains open; diagnostics do not prove it |
| Product native composition | Embed-v3 actual two-ABI APK passed all 5 root verifiers. Required-package JVM: 345 total / 343 passed / 2 explicit opt-in skips / 0 failures / 0 errors. The separate-source ABI repair passed 2 actual AAR builds, root product verification and 5 workflow/package tests | Hosted exact `36269cf0` failed before this repair; new hosted acceptance is required |
| Broad Android/Server | [Run36826527140](https://github.com/ersingundem/larenor/actions/runs/36826527140) is running at exact `1916395b1d55828c5640b23bd1d04b8ca5f453df`, including complete Flutter, emulator journeys, required dual-native product packaging/JVM and default-all Server gates. Earlier alla51 Server run36823315743 passed all four shards, host workers and Linux cgroup | The passed alla51 gate predates the latest media code. Current191 broad acceptance is pending and does not replace standalone strict F60/F62 runtime gates. Interrupted local full Server and older red runs remain historical only |
| Security | Exact `1916395b1d55828c5640b23bd1d04b8ca5f453df`, [run36826516434](https://github.com/ersingundem/larenor/actions/runs/36826516434): secret-scan, dependency-scan and platform-policy all passed | This is named Security evidence for191, not complete Server/Android/native runtime acceptance |

[Retention evidence](final-function-retention-review-2026-10-01.md), [actual product build](product-android-dual-native-actual-build-2026-10-01.md), [F60 source/diagnostic proof](f60-pin-delivery-pairing-stage-2026-10-01.md), [complete production feature matrix](final-function-feature-matrix-2026-09-30.md).

## Tarihsel yerel kabul tabanı — 30 Eylül

Aşağıdaki sonuçlar önceki `06f5551a242aca47ebcf0f2476881e2deec5d1da` uygulama
tabanının kanıtını korur; güncel birleşik HEAD doğrulaması değildir.

- Flutter tam paketi 7.637 geçti; 4 platform testi atlandı. `flutter analyze`
  aynı kabul tabanında sıfır uyarı ve hatayla geçti.
- F08–F11 için 4 Server ve 4 Flutter; F24–F27 için 16 Server, 8 Flutter ve
  2 Android/JVM; F48–F51 için 8 Flutter ve 49 ilişkili Server testi geçti.
- Platform politika paketi 442 geçti, 4 atlandı; içindeki 25 kuyruk testi
  o tarihteki 126 iş ve 63 özellik şemasını doğruladı. Güncel kuyruk 127 iştir.
- `tool/check_commit_progress.py` eski workflow düzeltme tabanı
  `52b30612b19d0dba7e4e3fb41a1dfcddba38243c` için 323 commit’i doğruladı.

## İnceleme kapsamı

Kapanış incelemesi Flutter kullanıcı akışları ve yaşam döngüsü, Server/Core
sözleşme ve geri kazanma sınırları, kuyruk/kanıt tutarlılığı olarak yürütülür.
Geçmiş kırmızı koşular yalnız tarihsel tanı kaydıdır; güncel durum yerine
sunulmaz ve değişen kaynak kanıtı olmadan kabul verilmez.

F14 tarihsel failedreview korunur; bulunan Client açıkları şimdi kapatıldı. Root
11/11 controller/dialog/navigation/clipboard-error testi, scoped analyze ve
gerçek normal Core TCP iki ayrı Client süreci/DB restart kabulünü 1+1 geçti.
Named Server 3/3 kanıtı ayrı korunur. F14 `awaiting_ci`; [yeni kabul](f14-normal-core-acceptance-2026-10-01.md).

F50 normal Core HTTP64distinctplan+DBrestart sonrası65inciPUT429 RED’i
signed bounded retention ile kapandı. Root16retention dahil33/33F50 testi
geçti; current/live/dispatching/unknown/replay parentları ve silme rollback
korunur. F50 `awaiting_ci`; [retention kabulü](f50-room-comfort-retention-2026-10-01.md).

## Açık kapı

58 seçili özellik / 69 iş CI beklerken, yalnız F60/F62 gerçek native işlev kapıları
`reworking` durumundayken ve geniş exact-HEAD CI tamamlanmamışken
`FINAL.FUNCTION` kanıtla tamamlandı sayılmaz; `FINAL.UI` başlatılmaz.

### Tarihsel inceleme ve tanı ekleri

Aşağıdaki kaynak ve koşu kayıtları geçmiş checkpointleri korur; güncel durum üstteki tablo ve execution queue ile belirlenir.

F57/F58 gerçek production-route onay hatası kapandı. Root **21/21** focused
management/route testi ve altı dosya scoped analyze geçti. Yalnız sahipli exact
dialog runtimeı korur; yabancı route/authority değişimi emekli eder. Captured
Confirm/Cancel yabancı routeu kaldıramaz; parent kapanışı ve pending temizliği
doğrulandı. İkisi `awaiting_ci`; fiziksel sensör/köprü/etiket kabulü ayrı.
[Route kabulü](f57-f58-owned-confirmation-lifecycle-2026-10-01.md).

F62 güncel exact1d/run36805226494 terminal **failure**. Root canonical
artifact11137802839 (SHA25611f0923dc134ac0ac4e6775189a19fb380bd7140b710cb62c0c27dc37f6c8cef)
source/package/fixture/originalmethod kimliğini doğruladı:1test/1failure/0error/0skip;
ownedframe255+98 ilk1280x800framewaiti gösterir. Linuxfixturebuild/arm64APKpassed
kalır; resizeRequested=false ve iki yaşam/DISP/Clipboard kabulü yok. Alt neden
kanıtlanmadı; aynı kaynak yeniden başlatılmaz.

F60 güvenli hata tanısı root **42/42** runner/workflow kontrolü ve actionlint
kabulünü geçti. Kaynak hash değiştiğinde satır haritasından aşama çıkarılmaz;
ham XML veya özel mesaj yayımlanmaz. Yeni hosted stream sonucu gerekir.
[tanı ve sınırlar](f60-owned-stream-failure-diagnostics-2026-10-01.md).

F62 fixture-only subscriber repair is locally source-verified: root fresh exact
archive preparation, patch/source hashes and actual subscriber/event/refresh
ordering passed; 18/18 focused checks and independent review passed. The old
initial-frame failure cause remains an inference and the unchanged strict
hosted frame/channel gate must still pass. F62 remains `reworking`.
[Source repair evidence](f62-initial-frame-subscriber-2026-10-01.md).

F60 changed-source diagnostic run [36808021320](https://github.com/ersingundem/larenor/actions/runs/36808021320)
started at exact `3feb723c28aa745445edcc770b27d9794b7e5b11`; source SHA was
independently verified. Pending execution is not acceptance.

F62 changed-source strict native run [36808149011](https://github.com/ersingundem/larenor/actions/runs/36808149011)
started at exact `36c3e015d27c3ff4b21b0e7d834075b7107bb479`; source SHA was
independently verified. Pending execution is not acceptance.
