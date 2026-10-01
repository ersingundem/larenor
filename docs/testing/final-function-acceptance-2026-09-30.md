# FINAL.FUNCTION acceptance evidence

## Current state — 1 October 2026

FINAL.FUNCTION is the only active final. Development and focused validation are complete for 56 selected features / 65 tasks, which await final-HEAD CI. F22/F35 have new local regression failures under investigation; F60/F62 remain reworking. Accepted counts stay 37/127 tasks and 3/63 selected features. Physical, household and account gates remain MANUAL; the next final starts only after this final completes.

| Gate | Latest named evidence | Open boundary |
| --- | --- | --- |
| F01/F02/F03 durable history | Root live-source22/22, default256/128 and signed4096-event restart capacity; current/live/replay/tamper/rollback protected | Broad finalHEAD CI; household HA observation/device effects separate |
| F14 support lifecycle/retention | Root11/11Client, normal TCP two-process sameDBrestart1+1, Server3/3; retention9/9 | Broad finalHEAD CI; actual clipboard/supporter MANUAL |
| F58 e-paper retention | Root18/18, signed2000history/restart, owned HA/OEPL HTTP | Actual physical label/display delivery MANUAL; broadCI |
| F59 workshop retention | Root28/28normal Core/owned HTTP/default10000signedhistory/restart; current/replay/unknown/tamper/rollback | Physical printer/sensors MANUAL; broadCI |
| F57 calibration retention | Root30/30normal Core/owned HA/fusion/retention; true256capacity/restart; conservative v1migration/current/replay/uncertain/newest32terminal/tamper/rollback | Broad finalHEAD CI; calibration is advisory/local, no physical mmWave reconfiguration claim |
| F60 NSD | Exact `5fa91e43` / run `36802851003`: canonical 1 test / 0 skips, two fresh discovery lifetimes; streamAccepted=false | Embed-v3 discovery at exact `36269cf0`, run `36813871246`, awaits acceptance; discovery does not prove streaming |
| F60 streaming | Embed-v3 cancellation/deadline: 40 native tests, root 165 tool checks, real open-socket PIN newline RED→GREEN | Exact `36269cf0`, [run 36813869676](https://github.com/ersingundem/larenor/actions/runs/36813869676), awaits strict frame/PCM/input/two-lifetime/stop/disconnect acceptance. Previous pairing timeout cause remains unproved |
| F62 native RDP | Exact `c8291061` / run `36811909218`: canonical 1 test / 1 failure / 0 errors / 0 skips; no owned frames or lifecycle stage; serverResizeRequested=false. Early/live diagnostics at `70ab1058` passed root 51 checks, AndroidTest compilation and independent review | [Run 36814807367](https://github.com/ersingundem/larenor/actions/runs/36814807367) awaits strict TLS/NLA/SPKI/frame/ACK/key/DISP/Unicode/disabled clipboard/two-lifetime acceptance. Diagnostic stages do not prove feature acceptance |
| Product native composition | Embed-v3 actual two-ABI APK passed all 5 root verifiers. Required-package JVM: 345 total / 343 passed / 2 explicit opt-in skips / 0 failures / 0 errors | Hosted exact `36269cf0` dual-native package step failed and is under repair; local packaging does not prove hosted runtime acceptance |
| Broad Android/Server | Exact `36269cf0`, run `36813872693`, is still running; its dual-native package step failed. Local full Server regression has new F22/F35 and plugin-artifact failures under investigation | Broad final-HEAD acceptance remains open; passing Security alone does not close it |
| Security | Exact `81cd4172`, [run 36814632423](https://github.com/ersingundem/larenor/actions/runs/36814632423): all 3 jobs passed after 15 exact historical false-positive fingerprints were classified; new synthetic candidate still blocks | This is named Security evidence, not complete Server/Android/final-HEAD acceptance |

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

56 seçili özellik / 65 iş CI beklerken, F22/F35 yerel regresyon ve F60/F62 gerçek işlev kapıları
`reworking` durumundayken ve geniş exact-HEAD CI tamamlanmamışken
`FINAL.FUNCTION` kanıtla tamamlandı sayılmaz; `FINAL.UI` başlatılmaz.

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
