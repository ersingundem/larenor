# FINAL.FUNCTION acceptance evidence

## Current state — 3 October 2026

Canonical current totals are **56 selected features / 67 tasks awaiting CI**; accepted totals remain **3/63 features and 35/127 tasks**. Only `FINAL.FUNCTION` is active. **F04/F19/F60/F62 are reworking**: F04 ownership dispatch and F19 rejection/restore/search-cache acceptance have independent P1 findings; both named Client→Core runners are absent from required CI. Exact F60 `7e552` run `37140213824` and F62 `7e6d` run `37141178524` are terminal failed. Startup and private200-JVM/313-task AndroidTest compile evidence is scoped local proof. See the [gap review](f04-f19-acceptance-gap-review-2026-10-03.md), [terminal receipts](native-strict-7e552-7e6d-failure-2026-10-03.md), [queue](../EXECUTION_QUEUE.md), and [visible live work](function-live-work-2026-10-03.md).

All selected software items and their dependencies must be accepted, then the final branch exact HEAD must pass required CI. Only after the completion branch is merged to `main` and ancestry/content are verified may `FINAL.UI` start from current `main` on its separate branch. Historical runs below remain evidence for their exact sources and are not current acceptance.

| Gate | Latest named evidence | Open boundary |
| --- | --- | --- |
| F01/F02/F03 durable history | Root live-source22/22, default256/128 and signed4096-event restart capacity; current/live/replay/tamper/rollback protected | Broad finalHEAD CI; household HA observation/device effects separate |
| F14 support lifecycle/retention | Root11/11Client, normal TCP two-process sameDBrestart1+1, Server3/3; retention9/9 | Broad finalHEAD CI; actual clipboard/supporter MANUAL |
| F58 e-paper retention | Root18/18, signed2000history/restart, owned HA/OEPL HTTP | Actual physical label/display delivery MANUAL; broadCI |
| F59 workshop retention | Root28/28normal Core/owned HTTP/default10000signedhistory/restart; current/replay/unknown/tamper/rollback | Physical printer/sensors MANUAL; broadCI |
| F57 calibration retention | Root30/30normal Core/owned HA/fusion/retention; true256capacity/restart; conservative v1migration/current/replay/uncertain/newest32terminal/tamper/rollback | Broad finalHEAD CI; calibration is advisory/local, no physical mmWave reconfiguration claim |
| F21/F24/F25/F26/F27 media composition | Normal verified-Core local-player entry, leader/follower controls, actual reported track selection, validated segment seek, non-recording quality advice, explicit single-use playback lease and completed encrypted offline inventory; root110 Client/46 Server tests passed | All five await final combined HEAD CI; F27 duplicate signout purge is fixed243cc694/root49+analysis and complete Analyze&Test1f35/run36829836571 passed. Physical decoding, rendering, multi-device timing, storage pressure and provider DRM/account limits remain MANUAL |
| F60 NSD | Embed-v3 exact `36269cf0`, run `36813871246`: canonical 1 test / 0 skips / 0 failures / 0 errors, two fresh discovery lifetimes; bounded receipt independently verified | streamAccepted=false; discovery does not prove streaming |
| F60 streaming | Exact7e552 strict37140213824 failed, named1/1/0/0; first frame/PCM/listener observed | Real pointer/button/gamepad/two lifetimes/close remain open; fixture repair and new changed-source CI required |
| F62 native RDP | Exact7e6d Linux37141178524 failed at linker; closed source-bound699B receipt verified | Target/symbol unproved; Linux/Android Gateway/SAF/audio/mic effects and final CI remain open |
| Product native composition | Embed-v3 actual two-ABI APK passed all 5 root verifiers. Required-package JVM: 345 total / 343 passed / 2 explicit opt-in skips / 0 failures / 0 errors. The separate-source ABI repair passed 2 actual AAR builds, root product verification and 5 workflow/package tests | Hosted exact `36269cf0` failed before this repair; new hosted acceptance is required |
| Broad Android/Server | Exact721 run36832137026 completed: four Server shards, all Flutter/static/aggregate, emulator journeys, native engines/productAPK and host-worker passed | Old F08 observer and Server aggregate failed; changed-source exacta8 scoped F08 run36835138089 passed. Neither partial broad gates nor scoped success replaces final combined HEAD acceptance |
| Combined current-source Android/Server | Exact-721 run 36832137026 is terminal FAILED: all four Server shards, Flutter, native/APK/emulator/host passed | Older F08 observer and Server aggregate failed; changed-source a8 scoped F08 passed. Final combined HEAD CI and strict F60/F62 runtime acceptance remain open |
| Security | Exact `721952a00d8ac02c5e6b2ada71211a579b8eb768`, [run36831975047](https://github.com/ersingundem/larenor/actions/runs/36831975047): secret-scan, dependency-scan and platform-policy all passed | This is named Security evidence, not complete Server/Android/native runtime acceptance |

[Retention evidence](final-function-retention-review-2026-10-01.md), [actual product build](product-android-dual-native-actual-build-2026-10-01.md), [F60 source/diagnostic proof](f60-pin-delivery-pairing-stage-2026-10-01.md), [complete production feature matrix](final-function-feature-matrix-2026-09-30.md).

3 October changed-source integration: actual embed-v4 + FreeRDP schema3
product mount passed all receipt/API/ABI gates; root112 JVM tests
(47 Moonlight +65 RDP, including9 failure-open diagnostics) passed with
zero skips/failures/errors, and AndroidTest Kotlin compilation passed314tasks.
Root225tools/184subtests and Ruff passed. Output-audio software is implemented
with actual OpenSL completion, while mic/SAF/Gateway software and changed-source
strict stream/RDP runtime acceptance remain open. Latest exact7a53 Security
run37122724149 passed; final combined HEAD CI remains necessary.
[F60 v4](f60-nonzero-pcm-consumer-2026-10-03.md),
[F62 open facts](f62-owned-open-boundaries-2026-10-03.md).

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

56 seçili özellik / 67 iş CI beklerken, F04/F19/F60/F62 üretim/kabul açıkları
`reworking` durumundayken ve geniş exact-HEAD CI tamamlanmamışken
`FINAL.FUNCTION` kanıtla tamamlandı sayılmaz. Tüm yazılım kabulü ve final dal
exact-HEAD zorunlu CI tamamlandıktan sonra dal `main`e birleşir; ancestry/içerik
doğrulanmadan `FINAL.UI` başlatılmaz.

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


3 October local integration: F62 schema-2 display/pointer/wheel and same-route
fullscreen software passed all 81 RDP Flutter tests/analyze, actual verified
dual-ABI product and 90 native tests/AndroidTest compile. F60 exact Game boundary
diagnostics passed 46 JVM tests plus 54 runner tests/36 subtests and 10 workflow tests/12 subtests.
These checkpoints do not accept the earlier failed hosted runs or replace
new exact-source runtime acceptance. F62 audio/microphone/real SAF/Gateway
software remains open; F60/F62 remain reworking. Counts remain 69 tasks/58 features
awaitingCI and 35/127 tasks/3/63 features accepted. Only FINAL.FUNCTION is active.
